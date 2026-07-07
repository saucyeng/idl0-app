import 'dart:async';

import 'package:idl0/data/exceptions.dart';
import 'package:idl0/transport/ack.dart';
import 'package:idl0/transport/ble_service.dart';

/// Hand-written [BleService] test double.
///
/// Returns hardcoded success values with short artificial delays so
/// [DeviceNotifier] tests can exercise state transitions without hardware.
class MockBleService implements BleService {
  /// Controllable status stream so provider tests can push [DeviceStatus].
  ///
  /// Lives for the lifetime of the mock; tests close it in teardown.
  // ignore: close_sinks
  final statusController = StreamController<DeviceStatus>.broadcast();

  @override
  Stream<DeviceStatus> get statusStream => statusController.stream;

  /// Controllable connection-lost stream. Tests call
  /// [simulateConnectionLoss] to fire it; the mock never emits on its own.
  // ignore: close_sinks
  final connectionLostController = StreamController<void>.broadcast();

  @override
  Stream<void> get connectionLost => connectionLostController.stream;

  /// Test hook: fires the [connectionLost] stream once, simulating an
  /// unexpected BLE link drop.
  void simulateConnectionLoss() => connectionLostController.add(null);

  /// Test hook: if non-null, the next call to any command method throws a
  /// [CommandRefusedException] carrying this ATT code instead of completing
  /// normally. The hook is cleared after one use so subsequent calls succeed.
  ///
  /// Use to exercise the WiFi/logging-mutex refusal path (ATT code 0x03)
  /// without needing real firmware.
  int? nextRefusalCode;

  /// If [nextRefusalCode] is set, consume it and throw the matching
  /// [CommandRefusedException]; otherwise returns normally.
  void _maybeRefuse(int command) {
    final code = nextRefusalCode;
    if (code == null) return;
    nextRefusalCode = null;
    throw CommandRefusedException(
      attCode: code,
      command: command,
      reason: defaultAckReason(code, command),
    );
  }

  /// Test hook: number of leading [connect] calls that throw
  /// [DeviceNotFoundException] before one succeeds (decremented per failed
  /// call). Lets [DeviceNotifier.reconnectAfterReboot]'s retry be tested.
  int connectFailures = 0;

  /// Number of times [connect] has been called.
  int connectCalls = 0;

  /// Optional status frame [connect] pushes onto [statusStream] before its
  /// returned future resolves.
  ///
  /// Models real `BleConnection` ordering: the device's GATT-handshake
  /// status notification reaches the stream while the caller (e.g.
  /// `DeviceNotifier.connect`) is still awaiting `connect()` — i.e. before
  /// [DeviceState.isConnected] flips true. Additive: null (the default)
  /// preserves every other test's existing behavior of emitting nothing
  /// during connect.
  DeviceStatus? statusDuringConnect;

  @override
  Future<({String name, int batteryPercent})> connect() async {
    connectCalls++;
    final duringConnect = statusDuringConnect;
    if (duringConnect != null) {
      statusController.add(duringConnect);
    }
    await Future.delayed(const Duration(milliseconds: 300));
    if (connectFailures > 0) {
      connectFailures--;
      throw const DeviceNotFoundException('mock: not advertising yet');
    }
    return (name: 'IDL0-A3F2', batteryPercent: 85);
  }

  @override
  Future<void> disconnect() async {
    await Future.delayed(const Duration(milliseconds: 100));
  }

  @override
  Future<void> startRecording() async {
    _maybeRefuse(kIdl0CmdStartLogging);
    await Future.delayed(const Duration(milliseconds: 100));
  }

  @override
  Future<void> stopRecording() async {
    _maybeRefuse(kIdl0CmdStopLogging);
    await Future.delayed(const Duration(milliseconds: 100));
  }

  @override
  Future<void> pushConfig(Map<String, dynamic> config) async {
    // pushConfig is a multi-step BLE+HTTP flow rather than a single Control
    // byte; the §3.3 ACK protocol only covers single-byte writes, so the
    // refusal hook deliberately does not apply here.
    await Future.delayed(const Duration(milliseconds: 200));
  }

  /// Last config handed to [pushConfigBle]; returned by [pullConfigBle] so
  /// round-trip verification can be exercised without a real device.
  Map<String, dynamic>? lastPushedConfig;

  @override
  Future<void> pushConfigBle(Map<String, dynamic> config) async {
    // Mirrors pushConfig: a multi-step BEGIN/chunk/COMMIT flow, not a single
    // Control byte, so the §3.3 single-write refusal hook does not apply.
    lastPushedConfig = config;
    await Future.delayed(const Duration(milliseconds: 200));
  }

  @override
  Future<Map<String, dynamic>> pullConfigBle() async {
    await Future.delayed(const Duration(milliseconds: 100));
    return lastPushedConfig ?? <String, dynamic>{};
  }

  @override
  Future<void> calibrate() async {
    _maybeRefuse(kIdl0CmdCalibrateImu);
    await Future.delayed(const Duration(seconds: 5));
  }

  /// Ordered record of CMD_WIFI_ON / CMD_WIFI_OFF calls. Tests inspect this
  /// list to assert the panel-scoped bind lifecycle (`'on'` on entry,
  /// `'off'` on disposal).
  final List<String> wifiCalls = [];

  @override
  Future<void> wifiOn() async {
    _maybeRefuse(kIdl0CmdWifiOn);
    wifiCalls.add('on');
  }

  @override
  Future<void> wifiOff() async {
    _maybeRefuse(kIdl0CmdWifiOff);
    wifiCalls.add('off');
  }

  /// Number of times [confirmOta] has been called. Tests inspect this to
  /// assert the OTA-confirm UI commits the new image exactly once.
  int confirmOtaCallCount = 0;

  @override
  Future<void> confirmOta() async {
    _maybeRefuse(kIdl0CmdOtaConfirm);
    confirmOtaCallCount++;
  }
}
