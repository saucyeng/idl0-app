import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/auto_connect.dart';
import 'package:idl0/providers/device_provider.dart';

import '../helpers/mock_ble_service.dart';

/// [AutoConnectController] with a zero retry gap so the scan loop runs at test
/// speed. Everything else — the real loop, lifecycle wiring, pause/resume — is
/// exercised as shipped.
class _FastAutoConnect extends AutoConnectController {
  @override
  Duration get retryGap => Duration.zero;
}

/// Polls [condition] on a short real-time cadence until it holds or [timeout]
/// elapses. The mock's `connect()` uses real delays, so tests wait real time.
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer makeContainer(MockBleService mock) {
    final container = ProviderContainer(
      overrides: [
        bleServiceProvider.overrideWithValue(mock),
        autoConnectControllerProvider.overrideWith(_FastAutoConnect.new),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('scans past initial misses and connects when a device appears',
      () async {
    // Arrange — the first two scans find nothing, the third succeeds.
    final mock = MockBleService()..connectFailures = 2;
    final container = makeContainer(mock);

    // Act — activate the controller; its loop keeps scanning until it connects.
    container.read(autoConnectControllerProvider);
    await _until(() => container.read(deviceProvider).isConnected);

    // Assert — connected after exactly the three attempts (2 misses + 1 hit).
    expect(container.read(deviceProvider).isConnected, isTrue);
    expect(mock.connectCalls, equals(3));
  });

  test('stops scanning once connected — no further attempts', () async {
    // Arrange — connects on the first try.
    final mock = MockBleService();
    final container = makeContainer(mock);
    container.read(autoConnectControllerProvider);
    await _until(() => container.read(deviceProvider).isConnected);
    final callsWhenConnected = mock.connectCalls;

    // Act — let time pass while connected.
    await Future<void>.delayed(const Duration(milliseconds: 400));

    // Assert — the loop exited on connect; no extra scans.
    expect(callsWhenConnected, equals(1));
    expect(mock.connectCalls, equals(1));
  });

  test('unexpected link drop — scanner re-arms and reconnects on its own',
      () async {
    // Arrange — connected.
    final mock = MockBleService();
    final container = makeContainer(mock);
    container.read(autoConnectControllerProvider);
    await _until(() => container.read(deviceProvider).isConnected);
    expect(mock.connectCalls, equals(1));

    // Act — the BLE link drops unexpectedly (device reset / out of range).
    mock.simulateConnectionLoss();
    await _until(() => !container.read(deviceProvider).isConnected);
    await _until(() => container.read(deviceProvider).isConnected);

    // Assert — reconnected without any manual action.
    expect(container.read(deviceProvider).isConnected, isTrue);
    expect(mock.connectCalls, greaterThanOrEqualTo(2));
  });

  test('paused (user Disconnect) — a later drop does not auto-reconnect',
      () async {
    // Arrange — connected.
    final mock = MockBleService();
    final container = makeContainer(mock);
    container.read(autoConnectControllerProvider);
    await _until(() => container.read(deviceProvider).isConnected);
    final callsWhenConnected = mock.connectCalls;

    // Act — user disconnect: park the scanner, then the link goes away.
    container.read(autoConnectControllerProvider.notifier).pause();
    mock.simulateConnectionLoss();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    // Assert — stays disconnected; the parked scanner did not reconnect.
    expect(container.read(deviceProvider).isConnected, isFalse);
    expect(mock.connectCalls, equals(callsWhenConnected));
  });

  test('resume after a pause — scanner reconnects again', () async {
    // Arrange — connected, then user-disconnected (paused) and dropped.
    final mock = MockBleService();
    final container = makeContainer(mock);
    container.read(autoConnectControllerProvider);
    await _until(() => container.read(deviceProvider).isConnected);
    container.read(autoConnectControllerProvider.notifier).pause();
    mock.simulateConnectionLoss();
    await _until(() => !container.read(deviceProvider).isConnected);

    // Act — a manual scan re-arms auto-connect.
    container.read(autoConnectControllerProvider.notifier).resume();
    await _until(() => container.read(deviceProvider).isConnected);

    // Assert — reconnected.
    expect(container.read(deviceProvider).isConnected, isTrue);
  });
}
