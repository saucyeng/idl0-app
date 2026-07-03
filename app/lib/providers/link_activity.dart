import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Live link-activity counters driving the RX/TX "blink" chips on the Device
/// hero.
///
/// [rx] increments on every status frame the device pushes over BLE; [tx] on
/// every command the app sends (connect, mode change, push config, calibrate).
/// These are monotonic sequence counters — the UI watches for a *change* and
/// flashes the corresponding chip; it never reads the absolute value. This
/// keeps [DeviceState] free of UI-only churn.
class LinkActivity {
  /// Count of status frames received from the device.
  final int rx;

  /// Count of commands sent to the device.
  final int tx;

  /// Creates a [LinkActivity].
  const LinkActivity({this.rx = 0, this.tx = 0});

  /// Returns a copy with the given counters replaced.
  LinkActivity copyWith({int? rx, int? tx}) =>
      LinkActivity(rx: rx ?? this.rx, tx: tx ?? this.tx);
}

/// Holds [LinkActivity] and exposes pulse methods the transport/command layer
/// calls to flash the hero's RX/TX chips.
class LinkActivityNotifier extends Notifier<LinkActivity> {
  @override
  LinkActivity build() => const LinkActivity();

  /// Pulse RX — a status frame arrived from the device.
  void pulseRx() => state = state.copyWith(rx: state.rx + 1);

  /// Pulse TX — a command was sent to the device.
  void pulseTx() => state = state.copyWith(tx: state.tx + 1);
}

/// Provides [LinkActivity] and the [LinkActivityNotifier] pulse methods.
final linkActivityProvider =
    NotifierProvider<LinkActivityNotifier, LinkActivity>(
  LinkActivityNotifier.new,
);
