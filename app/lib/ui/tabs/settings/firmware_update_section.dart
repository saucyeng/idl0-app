import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/exceptions.dart';
import '../../../providers/auto_connect.dart';
import '../../../providers/device_provider.dart';
import '../../../providers/firmware_update_provider.dart';
import '../../../providers/mode.dart';
import '../../../providers/mode_controller.dart';
import '../../../providers/runs_provider.dart' show wifiServiceProvider;
import '../../../providers/settings_provider.dart';
import '../../../providers/wifi_bind_controller.dart';
import '../../../transport/firmware_catalog.dart';
import '../../../transport/wifi_service.dart';
import '../../brand/brand.dart';

/// Result of [FirmwarePicker] — a picked `.bin` file ready to push.
///
/// [name] is the on-disk filename (for display); [bytes] is the raw image.
class PickedFirmware {
  /// Display name of the picked file, e.g. `idl0_v2.bin`.
  final String name;

  /// Raw firmware image bytes.
  final Uint8List bytes;

  /// Creates a [PickedFirmware].
  const PickedFirmware({required this.name, required this.bytes});

  /// Size of [bytes] in bytes.
  int get sizeBytes => bytes.length;
}

/// Async callback that prompts the user for a `.bin` file and returns it.
///
/// Returns `null` if the user cancels the system file dialog. Injectable
/// via [FirmwareUpdateSection.pickerOverride] so widget tests don't need
/// to drive the real `file_picker` platform dialog.
typedef FirmwarePicker = Future<PickedFirmware?> Function();

/// Default [FirmwarePicker] backed by the `file_picker` package.
///
/// Restricts the dialog to `.bin` extensions and loads the picked file
/// into memory (`withData: true`) so we can stream the bytes straight to
/// the device without re-reading from disk.
Future<PickedFirmware?> _defaultFirmwarePicker() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['bin'],
    withData: true,
  );
  final file = result?.files.singleOrNull;
  if (file == null || file.bytes == null) return null;
  return PickedFirmware(name: file.name, bytes: file.bytes!);
}

/// Phase of the OTA push state machine for [FirmwareUpdateSection].
///
/// Drives which controls render: [idle] shows the picker/Push button,
/// [pushing] shows the progress bar + Cancel, [rebooting] grays out and
/// counts down to the auto-reconnect attempt. The OTA-confirm card is
/// orthogonal — driven by [DeviceState.otaPendingVerify], not by this
/// enum — so a user can land on the panel after a bootloader-side OTA
/// (e.g. flashed over USB) and see the commit prompt without ever having
/// touched the Push button.
enum _PushPhase { idle, downloading, pushing, rebooting }

/// Settings → Update Firmware section. See task brief.
///
/// Renders three orthogonal UI elements:
/// 1. The push state machine ([_PushPhase]) — pick → push → progress →
///    rebooting → reconnect.
/// 2. The precondition gate — disables Push when the device isn't BLE
///    connected OR when the device is not in [Mode.wifi].
/// 3. The OTA commit card — visible whenever [DeviceState.otaPendingVerify]
///    is true, regardless of how the device got there.
///
/// The push runs the HTTP POST only — the WiFi AP must already be up
/// (Device-tab ModePicker → WiFi). The button is disabled outside
/// [Mode.wifi]; tapping it (if somehow not disabled) shows a refusal
/// SnackBar. See §5.3 of the WiFi/Logging mutex design.
class FirmwareUpdateSection extends ConsumerStatefulWidget {
  /// File-picker override for widget tests. Production passes `null` and
  /// gets the real [_defaultFirmwarePicker].
  final FirmwarePicker? pickerOverride;

  /// Creates a [FirmwareUpdateSection].
  const FirmwareUpdateSection({super.key, this.pickerOverride});

  @override
  ConsumerState<FirmwareUpdateSection> createState() =>
      _FirmwareUpdateSectionState();
}

class _FirmwareUpdateSectionState extends ConsumerState<FirmwareUpdateSection> {
  /// Seconds the "rebooting" UI stays up before the auto-reconnect runs.
  /// Matches the device-side reboot delay (§6.1 OTA) plus boot time.
  static const _rebootHoldDuration = Duration(seconds: 5);

  PickedFirmware? _picked;
  _PushPhase _phase = _PushPhase.idle;
  int _sentBytes = 0;
  int _totalBytes = 0;
  PushFirmwareHandle? _activeHandle;
  String? _errorMessage;
  bool _userCanceled = false;

  /// Version (no leading `v`) of the release currently queued for push, when
  /// known — i.e. the user accepted a catalog [FirmwareRelease] via
  /// [_downloadAndPush]. Null for a manually-picked `.bin` (no known
  /// version), which never arms the post-reboot OTA auto-confirm. See §27.7.
  String? _pushedVersion;

  @override
  void initState() {
    super.initState();
    // Kick an update check once, so the "update available" card can appear
    // without the user tapping anything — gated on the auto-check setting and
    // a live BLE link (the device version comes from §7.3).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(settingsProvider).autoCheckFirmware &&
          ref.read(deviceProvider).isConnected) {
        ref.read(firmwareUpdateProvider.notifier).check();
      }
    });
  }

  @override
  void dispose() {
    // The OTA reconnect (reconnectAfterReboot) is intentionally detached: it
    // runs on DeviceNotifier and completes — resuming the scanner — even if
    // this panel is disposed mid-reconnect.
    super.dispose();
  }

  /// Downloads [release]'s image, then hands the bytes to the existing OTA push
  /// state machine. Download progress reuses the `_sentBytes`/`_totalBytes`
  /// fields under the [_PushPhase.downloading] phase.
  Future<void> _downloadAndPush(FirmwareRelease release) async {
    setState(() {
      _phase = _PushPhase.downloading;
      _sentBytes = 0;
      _totalBytes = release.sizeBytes;
      _errorMessage = null;
      // Known version — arms the post-reboot OTA auto-confirm in _push().
      _pushedVersion = release.version.toString();
    });
    final Uint8List bytes;
    try {
      bytes = await ref.read(firmwareCatalogProvider).download(
        release,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _sentBytes = received;
            _totalBytes = total;
          });
        },
      );
    } on TransportException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _PushPhase.idle;
        _errorMessage = 'Download failed: ${e.message}';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _picked = PickedFirmware(name: 'v${release.version}', bytes: bytes);
    });
    await _push();
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _pickFile() async {
    final picker = widget.pickerOverride ?? _defaultFirmwarePicker;
    final picked = await picker();
    if (!mounted || picked == null) return;
    // A manual .bin pick abandons any pending catalog-driven expectation —
    // disarm now so a stale armed version (from an earlier accepted catalog
    // update that hasn't rebooted yet) can't be evaluated against this
    // unrelated image's post-reboot status frame. See §27.7.
    ref.read(deviceProvider.notifier).disarmOtaAutoConfirm();
    setState(() {
      _picked = picked;
      _errorMessage = null;
      // Manual .bin picks carry no known version — never arm auto-confirm.
      _pushedVersion = null;
    });
  }

  /// Runs the OTA HTTP POST against the device's WiFi AP.
  ///
  /// Mode is automatic (§23): if the device is not already in [Mode.wifi] this
  /// drives WiFi up via [ModeController.switchTo] before uploading (the file
  /// APIs need the AP). The device reboots after a successful OTA, returning to
  /// idle on its own, so there is no explicit switch back. A failed WiFi entry
  /// (refusal/timeout) is surfaced and the push is abandoned. Errors during the
  /// upload land in [_errorMessage] and reset the phase to idle so the user can
  /// retry without re-picking the file.
  Future<void> _push() async {
    final picked = _picked;
    if (picked == null) return;

    if (ref.read(modeProvider) != Mode.wifi) {
      final result =
          await ref.read(modeControllerProvider.notifier).switchTo(Mode.wifi);
      if (result is! Ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not enter WiFi mode for the update.'),
            ),
          );
        }
        return;
      }
      if (!mounted) return;
    }

    setState(() {
      _phase = _PushPhase.pushing;
      _sentBytes = 0;
      _totalBytes = picked.sizeBytes;
      _errorMessage = null;
      _userCanceled = false;
    });

    // Wait for the WiFi link to actually converge before uploading. `switchTo`
    // only flips Mode; the bind is a reactive, seconds-long consequence
    // (WifiBindController), and pushing before the proxy is up reads the direct
    // `192.168.4.1` (dead route on Android). Same gate the download path uses.
    final linked =
        await ref.read(wifiBindControllerProvider.notifier).awaitLinked();
    if (!mounted) return;
    if (!linked) {
      setState(() {
        _phase = _PushPhase.idle;
        _errorMessage = 'WiFi link not ready — check the device and retry.';
      });
      return;
    }

    final wifi = ref.read(wifiServiceProvider);

    try {
      final handle = wifi.pushFirmware(
        picked.bytes,
        onProgress: (sent, total) {
          if (!mounted) return;
          setState(() {
            _sentBytes = sent;
            _totalBytes = total;
          });
        },
      );
      _activeHandle = handle;
      await handle.done;
      _activeHandle = null;

      if (!mounted) return;
      // The device reboots into the new image now. Park the auto-connect
      // scanner so it can't race the OTA reconnect below — that path owns
      // re-establishing the link and firing the armed auto-confirm. Resumed
      // when reconnectAfterReboot finishes (see _scheduleReconnect).
      ref.read(autoConnectControllerProvider.notifier).pause();
      // Arm the post-reboot OTA auto-confirm before the reconnect timer
      // fires — only when the pushed version is known (catalog releases;
      // never a manual .bin pick). See §27.7. If the section was disposed
      // mid-push we return above without arming: `ref` is unusable after
      // dispose, no reconnect timer runs either, and the manual
      // pending-verify card stays the fallback.
      final pushedVersion = _pushedVersion;
      if (pushedVersion != null) {
        ref.read(deviceProvider.notifier).armOtaAutoConfirm(pushedVersion);
      }
      setState(() {
        _phase = _PushPhase.rebooting;
      });
      _scheduleReconnect();
    } on TransportException catch (e) {
      _activeHandle = null;
      if (!mounted) return;
      setState(() {
        _phase = _PushPhase.idle;
        _errorMessage = _userCanceled ? null : _humanError(e);
        _userCanceled = false;
      });
    } on Object {
      // [PushFirmwareHandle.cancel] completes the done future with a
      // StateError sentinel; catching Object here keeps the panel state
      // sensible even if a future change swaps the cancel error type.
      _activeHandle = null;
      if (!mounted) return;
      setState(() {
        _phase = _PushPhase.idle;
        _errorMessage =
            _userCanceled ? null : 'Update failed unexpectedly, try again.';
        _userCanceled = false;
      });
    }
  }

  Future<void> _cancel() async {
    final handle = _activeHandle;
    if (handle == null) return;
    _userCanceled = true;
    await handle.cancel();
  }

  /// Maps a [TransportException] to user-facing copy.
  ///
  /// Per the brief: 400 → "Firmware file corrupted", 500 → "Device error",
  /// anything else (DeviceUnreachable etc.) → "Could not reach device".
  String _humanError(TransportException e) {
    if (e is FirmwarePushException) {
      if (e.statusCode == 400) {
        return 'Firmware file corrupted, try again.';
      }
      if (e.statusCode == 500) {
        return 'Device error during update, try again.';
      }
    }
    return 'Could not reach device — make sure WiFi is on.';
  }

  void _scheduleReconnect() {
    // Capture the notifiers up front: this reconnect should finish even if the
    // user leaves Settings, so it must not touch `ref` after a dispose.
    final device = ref.read(deviceProvider.notifier);
    final autoConnect = ref.read(autoConnectControllerProvider.notifier);
    unawaited(() async {
      try {
        // A single post-hold connect() is too fragile for the device's
        // post-OTA boot — one missed advertising window and the user is stuck
        // reconnecting by hand. reconnectAfterReboot waits out the boot then
        // retries the scan/connect, and its connect() drives the post-reboot
        // status frame the armed auto-confirm consumes. See §27.7.
        await device.reconnectAfterReboot(
          bootDelay: _rebootHoldDuration,
          retryDelay: const Duration(seconds: 2),
          maxAttempts: 4,
        );
      } finally {
        // Hand reconnection back to the background scanner. Also covers the
        // give-up case: if the device never returned, the scanner keeps trying
        // rather than leaving the user stranded on a dead panel.
        autoConnect.resume();
      }
      if (!mounted) return;
      setState(() {
        _phase = _PushPhase.idle;
        // Keep _picked so the user can re-push if needed; clear progress.
        _sentBytes = 0;
        _totalBytes = 0;
      });
    }());
  }

  Future<void> _confirmOta() async {
    await ref.read(deviceProvider.notifier).confirmOta();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final device = ref.watch(deviceProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (device.otaPendingVerify) ...[
            _PendingVerifyCard(onConfirm: _confirmOta),
            const SizedBox(height: 16),
          ],
          // Channel / auto-check / "check now" + the update-available card.
          // Hidden mid-transfer so the progress views own the panel.
          if (_phase == _PushPhase.idle) ...[
            _UpdateControls(onUpdate: _downloadAndPush),
            const SizedBox(height: 16),
          ],
          _buildPushSection(context, device),
        ],
      ),
    );
  }

  Widget _buildPushSection(BuildContext context, DeviceState device) {
    if (_phase == _PushPhase.downloading) {
      return _buildDownloadingView();
    }
    if (_phase == _PushPhase.pushing) {
      return _buildProgressView();
    }
    if (_phase == _PushPhase.rebooting) {
      return _buildRebootingView();
    }
    return _buildIdleView(device);
  }

  Widget _buildIdleView(DeviceState device) {
    final picked = _picked;
    if (picked == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_errorMessage != null) _ErrorRow(message: _errorMessage!),
          QuietButton(
            label: 'Choose firmware file…',
            icon: Icons.upload_file_outlined,
            onPressed: _pickFile,
          ),
          if (!device.isConnected) ...[
            const SizedBox(height: 8),
            const Text(
              'Connect to device first',
              style: TextStyle(fontSize: 12, color: brandFgDim),
            ),
          ],
        ],
      );
    }

    final sizeMb = (picked.sizeBytes / (1024 * 1024)).toStringAsFixed(2);
    // Gate the Push button on BLE connectivity only. Mode is automatic (§23):
    // _push drives WiFi up itself before uploading, so we no longer require the
    // user to be in WiFi mode first (there is no manual mode picker anymore).
    final canPush = device.isConnected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_errorMessage != null) _ErrorRow(message: _errorMessage!),
        NoteBlock(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.memory_outlined, size: 18, color: brandFgDim),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      picked.name,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      '$sizeMb MB',
                      style: const TextStyle(fontSize: 12, color: brandFgDim),
                    ),
                  ],
                ),
              ),
              QuietButton(
                label: 'Change',
                onPressed: _pickFile,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            QuietButton(
              label: 'Push to Device',
              filled: true,
              onPressed: canPush ? _push : null,
            ),
            if (!canPush) ...[
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Connect to device first',
                  style: TextStyle(fontSize: 12, color: brandFgDim),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildDownloadingView() {
    final total = _totalBytes;
    final fraction = total > 0 ? _sentBytes / total : 0.0;
    final percent = (fraction * 100).clamp(0, 100).toStringAsFixed(0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Downloading update… $percent%',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: fraction),
        const SizedBox(height: 8),
        Text(
          '${_formatBytes(_sentBytes)} / ${_formatBytes(total)}',
          style: const TextStyle(fontSize: 12, color: brandFgDim),
        ),
      ],
    );
  }

  Widget _buildProgressView() {
    final total = _totalBytes;
    final fraction = total > 0 ? _sentBytes / total : 0.0;
    final percent = (fraction * 100).clamp(0, 100).toStringAsFixed(0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Pushing firmware… $percent%',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: fraction),
        const SizedBox(height: 8),
        Text(
          '${_formatBytes(_sentBytes)} / ${_formatBytes(total)}',
          style: const TextStyle(fontSize: 12, color: brandFgDim),
        ),
        const SizedBox(height: 12),
        QuietButton(
          label: 'Cancel',
          onPressed: _cancel,
        ),
      ],
    );
  }

  Widget _buildRebootingView() {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Device is rebooting…',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
        SizedBox(height: 8),
        Text(
          'Reconnecting in a few seconds.',
          style: TextStyle(fontSize: 12, color: brandFgDim),
        ),
        SizedBox(height: 12),
        LinearProgressIndicator(),
      ],
    );
  }

  static String _formatBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _PendingVerifyCard extends StatelessWidget {
  final Future<void> Function() onConfirm;
  const _PendingVerifyCard({required this.onConfirm});

  @override
  Widget build(BuildContext context) {
    return NoteBlock(
      borderColor: brandHivis,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.warning_amber_outlined,
                size: 18,
                color: brandHivis,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'New firmware is running — confirm to commit, '
                  'or power-cycle the device to roll back.',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              QuietButton(
                label: 'Confirm',
                filled: true,
                emphasis: ButtonEmphasis.go,
                onPressed: () {
                  unawaited(onConfirm());
                },
              ),
              const SizedBox(width: 8),
              QuietButton(
                label: 'Roll back',
                emphasis: ButtonEmphasis.alert,
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Power-cycle the device to roll back to the '
                        'previous firmware.',
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Channel picker + auto-check toggle + "Check now" + the update-available
/// card. Reads [firmwareUpdateProvider] / [settingsProvider]; calls back into
/// the section's download-then-push via [onUpdate] when the user accepts.
class _UpdateControls extends ConsumerWidget {
  /// Invoked with the chosen release when the user taps "Update".
  final Future<void> Function(FirmwareRelease) onUpdate;
  const _UpdateControls({required this.onUpdate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final update = ref.watch(firmwareUpdateProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (update is FirmwareUpdateAvailable) ...[
          NoteBlock(
            borderColor: brandHivis,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Update available — v${update.current} → '
                  'v${update.release.version}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (update.release.notes.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    update.release.notes.trim(),
                    style: const TextStyle(fontSize: 12, color: brandFgDim),
                  ),
                ],
                const SizedBox(height: 12),
                QuietButton(
                  label: 'Update to v${update.release.version}',
                  filled: true,
                  emphasis: ButtonEmphasis.go,
                  onPressed: () => onUpdate(update.release),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ] else if (update is FirmwareAheadOfChannel) ...[
          // Informational only — §27.7: a channel switch (or a beta image
          // while following stable) that leaves the device ahead of the
          // channel is never a downgrade prompt. No action button.
          NoteBlock(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Text(
              'Device firmware v${update.current} is ahead of the '
              '${settings.firmwareChannel.name} channel '
              '(latest v${update.release.version}); no action needed.',
              style: const TextStyle(fontSize: 12, color: brandFgDim),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Row(
          children: [
            const Text(
              'Channel  ',
              style: TextStyle(fontSize: 12, color: brandFgDim),
            ),
            SegmentedButton<FirmwareChannel>(
              segments: const [
                ButtonSegment(
                  value: FirmwareChannel.stable,
                  label: Text('Stable'),
                ),
                ButtonSegment(
                  value: FirmwareChannel.beta,
                  label: Text('Beta'),
                ),
              ],
              selected: {settings.firmwareChannel},
              onSelectionChanged: (s) {
                ref.read(settingsProvider.notifier).setFirmwareChannel(s.first);
                ref.read(firmwareUpdateProvider.notifier).check();
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Switch(
              value: settings.autoCheckFirmware,
              onChanged: (v) =>
                  ref.read(settingsProvider.notifier).setAutoCheckFirmware(v),
            ),
            const Expanded(
              child: Text(
                'Check for updates automatically',
                style: TextStyle(fontSize: 12),
              ),
            ),
            QuietButton(
              label: 'Check now',
              onPressed: () =>
                  ref.read(firmwareUpdateProvider.notifier).check(),
            ),
          ],
        ),
        if (update is FirmwareCheckUnknown && update.reason != null) ...[
          const SizedBox(height: 6),
          Text(
            "Couldn't check: ${update.reason}",
            style: const TextStyle(fontSize: 11, color: brandFgDim),
          ),
        ],
      ],
    );
  }
}

class _ErrorRow extends StatelessWidget {
  final String message;
  const _ErrorRow({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: NoteBlock(
        borderColor: brandAccent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          message,
          style: const TextStyle(
            color: brandAccent,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}
