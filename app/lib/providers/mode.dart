import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'device_provider.dart';

/// The three mutually-exclusive operational modes of an IDL0 device, plus
/// `unknown` for the spec-impossible (WiFi up + recording) combination.
enum Mode {
  /// WiFi off, no session — HR available, device idle.
  idle,

  /// SoftAP up — file transfer, config push, or OTA. HR suspended (§10.4).
  wifi,

  /// Session writing to SD. WiFi off by mutex.
  recording,

  /// Transitional / illegal combination observed in a single status frame.
  /// Never shown to the user; callers wait for the next frame.
  unknown,
}

/// Pure derivation of [Mode] from [DeviceState]. The mutex (§7.2 / §10.4)
/// is enforced by firmware; the (wifiOn && isRecording) combination is only
/// ever observed during a transitional status frame.
Mode modeOf(DeviceState state) {
  if (state.wifiOn && state.isRecording) return Mode.unknown;
  if (state.wifiOn) return Mode.wifi;
  if (state.isRecording) return Mode.recording;
  return Mode.idle;
}

/// Reactive [Mode] computed from [deviceProvider]. Riverpod only rebuilds
/// subscribers when the returned enum identity changes.
final modeProvider = Provider<Mode>(
  (ref) => modeOf(ref.watch(deviceProvider)),
);
