import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/exceptions.dart';
import '../../../providers/device_provider.dart';
import '../../../providers/mode.dart';
import '../../../providers/profile_provider.dart';
import '../../../transport/ble_service.dart';
import '../../brand/brand.dart';

/// Config row for the Device card — **Push config** and **Pull from device**.
///
/// **Push** sends `activeProfile.config` to the device over BLE (FF05 +
/// CONFIG_BEGIN/COMMIT, §7.2); the device reboots to apply and the app
/// reconnects and round-trip-verifies. **Pull** reads the device's live config
/// over BLE and saves it as a new library profile (§23).
///
/// Both require [Mode.idle]: BLE control is suspended in WiFi mode (§10.4) and
/// a reboot would abort an active recording. Mode is automatic (§23.9), so the
/// device sits in idle unless actively syncing/recording.
///
/// Disabled when BLE is not connected or while an operation is in flight.
class PushConfigButton extends ConsumerStatefulWidget {
  /// Creates a [PushConfigButton].
  const PushConfigButton({super.key});

  @override
  ConsumerState<PushConfigButton> createState() => _PushConfigButtonState();
}

class _PushConfigButtonState extends ConsumerState<PushConfigButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final isConnected = ref.watch(deviceProvider.select((s) => s.isConnected));
    final libAsync = ref.watch(profileProvider);
    final hasActive = libAsync.maybeWhen(
      data: (lib) => lib.activeProfile != null,
      orElse: () => false,
    );
    final canPush = isConnected && hasActive && !_busy;
    final canPull = isConnected && !_busy;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            ),
          QuietButton(
            label: 'Push config',
            emphasis: canPush ? ButtonEmphasis.go : ButtonEmphasis.normal,
            onPressed: canPush ? _push : null,
          ),
          const SizedBox(width: 8),
          QuietButton(
            label: 'Pull from device',
            onPressed: canPull ? _pull : null,
          ),
        ],
      ),
    );
  }

  Future<void> _push() async {
    if (ref.read(modeProvider) != Mode.idle) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Return to idle mode (Device tab) before pushing config.',
          ),
        ),
      );
      return;
    }
    final lib = await ref.read(profileProvider.future);
    final active = lib.activeProfile;
    if (active == null) return;
    setState(() => _busy = true);
    try {
      final ble = ref.read(bleServiceProvider);
      await ble.pushConfigBle(active.config);
      // The firmware loads idl0_config.json at boot only, so a successful
      // CONFIG_COMMIT restarts the device to apply it (§7.2). Re-establish the
      // BLE link so the user lands back in idle mode ready to log — no manual
      // reconnect.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Config saved — restarting device to apply…'),
          ),
        );
      }
      final reconnected =
          await ref.read(deviceProvider.notifier).reconnectAfterReboot();
      // Round-trip verify (§7.2): read the live config back and confirm it
      // matches what we sent. Best-effort — older firmware without FF06, or a
      // transient read error, falls back to the plain "applied" message.
      final verified = reconnected ? await _verifyApplied(ble, active.config) : null;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_resultMessage(reconnected, verified)),
          ),
        );
      }
    } on TransportException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Config push failed: ${e.message}')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Reads the device's live config over BLE and saves it as a new library
  /// profile. Prompts for a name; sets the new profile active so it appears in
  /// the Config card immediately. Best-effort error surfacing — never throws
  /// into the UI. See §23.
  Future<void> _pull() async {
    if (ref.read(modeProvider) != Mode.idle) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Return to idle mode before pulling config.'),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final live = await ref.read(bleServiceProvider).pullConfigBle();
      if (!mounted) return;
      final name = await showDialog<String>(
        context: context,
        builder: (_) => const _NameProfileDialog(),
      );
      if (name == null || name.trim().isEmpty) return;
      final notifier = ref.read(profileProvider.notifier);
      final id = await notifier.create(name.trim());
      await notifier.updateConfig(id, live);
      await notifier.setActive(id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved device config as “${name.trim()}”.')),
        );
      }
    } on TransportException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Pull failed: ${e.message}')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Reads the live config back and compares it (compact-JSON) to what was
  /// sent. Returns `true`/`false` on a successful read, or `null` when the
  /// read isn't available (old firmware / transient error) so the caller can
  /// fall back to the plain "applied" message rather than a false "mismatch".
  Future<bool?> _verifyApplied(
    BleService ble,
    Map<String, dynamic> sent,
  ) async {
    try {
      final live = await ble.pullConfigBle();
      // The device stores the pushed bytes verbatim, so a clean round trip
      // re-encodes to the same compact JSON.
      return jsonEncode(live) == jsonEncode(sent);
    } on TransportException {
      return null;
    }
  }

  /// Picks the post-push SnackBar message from the reconnect + verify outcome.
  String _resultMessage(bool reconnected, bool? verified) {
    if (!reconnected) {
      return 'Device restarting — reconnect when it’s back.';
    }
    switch (verified) {
      case true:
        return 'Device restarted — config applied and verified.';
      case false:
        return 'Device restarted, but the read-back didn’t match — try again.';
      case null:
        return 'Device restarted — config applied.';
    }
  }
}

/// Prompts for a profile name when saving a pulled device config. Returns the
/// entered name via `Navigator.pop`, or `null` on cancel.
class _NameProfileDialog extends StatefulWidget {
  const _NameProfileDialog();

  @override
  State<_NameProfileDialog> createState() => _NameProfileDialogState();
}

class _NameProfileDialogState extends State<_NameProfileDialog> {
  final _ctrl = TextEditingController(text: 'Device config');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Save as new profile'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Profile name'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
