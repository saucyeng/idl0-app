import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'device_provider.dart';

/// Best-effort auto-connect on app open — the nearest IDL0 connects
/// automatically (the "headphones" model), so the common case needs no tap.
///
/// Fires exactly once at startup: the controller is non-autoDispose and watched
/// once by the app shell, so a manual **Disconnect** stays disconnected for the
/// session rather than immediately reconnecting. Silent on failure — no device
/// nearby, or Bluetooth off / unsupported (desktop), is the normal case on open
/// and must not surface an error.
///
/// TODO(idl0): refine to auto-connect only a *known* (previously-paired) device
/// once a persisted paired-list exists (§23.8) — today it connects the single
/// nearest IDL0 — and surface every nearby IDL0 in the picker via a live
/// scan-list (system-Bluetooth style). See device_picker.dart.
class AutoConnectController extends Notifier<void> {
  @override
  void build() {
    // Schedule off the build frame so we never connect synchronously during
    // provider construction.
    Future<void>(() async {
      if (ref.read(deviceProvider).isConnected) return;
      try {
        await ref.read(deviceProvider.notifier).connect();
      } on Object catch (_) {
        // best-effort: nothing nearby / BLE unavailable is expected on open
      }
    });
  }
}

/// Activates [AutoConnectController]. Watch once at the app shell to fire the
/// single startup auto-connect.
final autoConnectControllerProvider =
    NotifierProvider<AutoConnectController, void>(AutoConnectController.new);
