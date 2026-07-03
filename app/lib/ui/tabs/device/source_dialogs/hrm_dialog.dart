import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../providers/profile_provider.dart';
import '../../../brand/brand.dart';
import '../hrm_pair_dialog.dart';
import 'dialog_chrome.dart';

/// Heart Rate Monitor source dialog.
///
/// Minimal pairing UI: enable/disable, BLE address (manual entry), display
/// name. A live BLE scan dialog is the next task on Track C — until that
/// lands, users paste the strap's address from the manufacturer's app.
///
/// Forget button clears the saved pairing entirely (removes the
/// `heart_rate_monitor` block from the profile).
class HrmSettingsDialog extends ConsumerStatefulWidget {
  /// Creates an [HrmSettingsDialog].
  const HrmSettingsDialog({super.key});

  @override
  ConsumerState<HrmSettingsDialog> createState() => _HrmSettingsDialogState();
}

class _HrmSettingsDialogState extends ConsumerState<HrmSettingsDialog> {
  late TextEditingController _addressController;
  late TextEditingController _nameController;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    final hrm = ref
            .read(profileProvider)
            .value!
            .activeProfile!
            .config['heart_rate_monitor'] as Map<String, dynamic>? ??
        const <String, dynamic>{};
    _enabled = (hrm['enabled'] as bool?) ?? false;
    _addressController = TextEditingController(
      text: (hrm['device_address'] as String?) ?? '',
    );
    _nameController = TextEditingController(
      text: (hrm['device_name'] as String?) ?? '',
    );
  }

  @override
  void dispose() {
    _addressController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: sourceDialogTitle('Heart Rate Monitor'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              title: const Text('Enabled'),
              value: _enabled,
              activeThumbColor: brandGood,
              onChanged: (v) => setState(() => _enabled = v),
              contentPadding: EdgeInsets.zero,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: QuietButton(
                  label: 'Search nearby HRMs…',
                  emphasis: ButtonEmphasis.info,
                  icon: Icons.bluetooth_searching,
                  onPressed: _scanAndPair,
                ),
              ),
            ),
            TextField(
              controller: _addressController,
              decoration: const InputDecoration(
                labelText: 'BLE address',
                hintText: 'AA:BB:CC:DD:EE:FF',
              ),
              textCapitalization: TextCapitalization.characters,
            ),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Device name (informational)',
                hintText: 'Polar H10 12345678',
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Logs channels HR_BPM (22) and HR_RR (23) when enabled. '
                'Tap "Search nearby HRMs…" to scan over Bluetooth — the '
                'phone listens but never connects; the ESP32 connects to '
                'the strap after you Push Config.',
                style: plexSans(fontSize: 12, color: brandFgDim),
              ),
            ),
          ],
        ),
      ),
      actions: sourceDialogActions(
        onCancel: () => Navigator.pop(context),
        onPrimary: _save,
        destructiveLabel: 'Forget',
        onDestructive: _forget,
      ),
    );
  }

  /// Opens [HrmPairDialog], scans for HRMs, and prefills the address +
  /// name fields with the chosen result. Auto-enables the source so the
  /// usual case ("found a strap, want to use it") is one fewer tap. The
  /// settings dialog stays open — user must press Save to commit and
  /// then Push Config to send the new address to the device.
  Future<void> _scanAndPair() async {
    final picked = await showDialog<({String address, String name})>(
      context: context,
      builder: (_) => const HrmPairDialog(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _addressController.text = picked.address;
      _nameController.text = picked.name;
      _enabled = true;
    });
  }

  Future<void> _save() async {
    final lib = await ref.read(profileProvider.future);
    final active = lib.activeProfile!;
    final cfg = Map<String, dynamic>.from(active.config);
    cfg['heart_rate_monitor'] = <String, dynamic>{
      'enabled': _enabled,
      'device_address': _addressController.text.trim().toUpperCase(),
      'device_name': _nameController.text.trim(),
    };
    await ref
        .read(profileProvider.notifier)
        .updateConfig(active.profileId, cfg);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _forget() async {
    final lib = await ref.read(profileProvider.future);
    final active = lib.activeProfile!;
    final cfg = Map<String, dynamic>.from(active.config);
    cfg.remove('heart_rate_monitor');
    await ref
        .read(profileProvider.notifier)
        .updateConfig(active.profileId, cfg);
    if (mounted) Navigator.pop(context);
  }
}
