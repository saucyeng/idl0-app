import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'device_provider.dart';

/// Keeps the app connected to an IDL0 device without the user having to tap.
///
/// While disconnected (and the app is foregrounded), it scans on a steady
/// cadence and connects to the nearest IDL0 the instant one appears — the
/// "headphones" model. This covers both cold start (open the app, then power
/// the device on) and recovery (an unexpected BLE drop reconnects on its own),
/// so the common case never needs a manual scan.
///
/// It is not an unconditional reconnect:
///  * A user-initiated **Disconnect** [pause]s the loop for the session — so
///    "disconnect" means disconnect — and a manual **Scan** (or [resume])
///    re-arms it. See `device_picker.dart`.
///  * The OTA push [pause]s it around its own reboot-reconnect
///    ([DeviceNotifier.reconnectAfterReboot]) so the two never race for the
///    link. See `firmware_update_section.dart`, §27.7.
///  * It runs only while the app is foregrounded — a backgrounded BLE scan is
///    throttled by the OS anyway and would just drain the battery.
///
/// Silent on failure — nothing nearby, or Bluetooth off / unsupported
/// (desktop), is the normal case on open and must never surface an error.
/// Concurrency is safe because [DeviceNotifier.connect] dedups overlapping
/// attempts.
///
/// TODO(idl0): refine to auto-connect only a *known* (previously-paired) device
/// once a persisted paired-list exists (§23.8) — today it connects the single
/// nearest IDL0 — and surface every nearby IDL0 in the picker via a live
/// scan-list (system-Bluetooth style). See device_picker.dart.
class AutoConnectController extends Notifier<void> {
  /// True while a user Disconnect / OTA push has parked the loop. Cleared by
  /// [resume].
  bool _suppressed = false;

  /// Whether the app is foregrounded. Scanning is gated on this.
  bool _foreground = true;

  /// True while [_scanLoop] is running, so overlapping triggers ([build], the
  /// link-state listener, [resume], lifecycle) never start a second loop.
  bool _scanning = false;

  /// Set once the controller is disposed, so a detached [_scanLoop] stops
  /// touching `ref` after teardown.
  bool _disposed = false;

  AppLifecycleListener? _lifecycle;

  /// Delay after a failed attempt before the next one. Each
  /// [DeviceNotifier.connect] is itself a ~10 s scan, so this only paces the
  /// gap after a miss (nothing nearby, or a fast failure like Bluetooth off,
  /// which must not spin the loop). Overridable so tests run the loop fast.
  @visibleForTesting
  Duration get retryGap => const Duration(seconds: 3);

  @override
  void build() {
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        final foreground = state == AppLifecycleState.resumed;
        if (foreground == _foreground) return;
        _foreground = foreground;
        if (foreground) _maybeScan();
      },
    );
    ref.onDispose(() {
      _disposed = true;
      _lifecycle?.dispose();
    });

    // Re-arm whenever the link is (or goes) down. An unexpected drop clears
    // isConnected via DeviceNotifier._onLinkLost and lands here, giving
    // automatic recovery for free.
    ref.listen(
      deviceProvider.select((d) => d.isConnected),
      (_, connected) {
        if (!connected) _maybeScan();
      },
    );

    _maybeScan();
  }

  /// Parks the scan loop and keeps it parked until [resume]. Called by a
  /// user-initiated Disconnect (so it stays disconnected) and by the OTA push
  /// (which owns its own reconnect).
  void pause() => _suppressed = true;

  /// Clears a [pause] and re-arms the scan loop if still disconnected.
  void resume() {
    if (!_suppressed) return;
    _suppressed = false;
    _maybeScan();
  }

  /// Starts [_scanLoop] if it should be running and isn't already.
  void _maybeScan() {
    if (_disposed || _scanning || _suppressed || !_foreground) return;
    if (ref.read(deviceProvider).isConnected) return;
    _scanning = true;
    unawaited(_scanLoop());
  }

  Future<void> _scanLoop() async {
    try {
      while (!_disposed &&
          !_suppressed &&
          _foreground &&
          !ref.read(deviceProvider).isConnected) {
        try {
          await ref.read(deviceProvider.notifier).connect();
        } on Object {
          // Nothing nearby / Bluetooth off — the normal idle case. Wait before
          // retrying so a fast failure can't busy-spin the scan.
          await Future<void>.delayed(retryGap);
        }
      }
    } finally {
      _scanning = false;
    }
  }
}

/// Activates [AutoConnectController]. Watch once at the app shell so the loop
/// follows the link for the whole app session.
final autoConnectControllerProvider =
    NotifierProvider<AutoConnectController, void>(AutoConnectController.new);
