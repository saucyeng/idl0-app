import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/device_provider.dart';
import 'package:idl0/transport/ble_service.dart';

import '../helpers/mock_ble_service.dart';

void main() {
  group('DeviceNotifier', () {
    ProviderContainer makeContainer() {
      final container = ProviderContainer(
        overrides: [
          bleServiceProvider.overrideWithValue(MockBleService()),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('initial state — isConnected is false', () {
      // Arrange
      final container = makeContainer();

      // Act
      final state = container.read(deviceProvider);

      // Assert
      expect(state.isConnected, isFalse);
      expect(state.deviceName, isNull);
      expect(state.batteryPercent, isNull);
      expect(state.isRecording, isFalse);
      expect(state.currentConfig, isNull);
    });

    test('connect — isConnected becomes true and deviceName is populated',
        () async {
      // Arrange
      final container = makeContainer();

      // Act
      await container.read(deviceProvider.notifier).connect();
      final state = container.read(deviceProvider);

      // Assert
      expect(state.isConnected, isTrue);
      expect(state.deviceName, isNotNull);
      expect(state.batteryPercent, isNotNull);
    });

    test('startRecording when disconnected — isRecording stays false',
        () async {
      // Arrange
      final container = makeContainer();

      // Act
      await container.read(deviceProvider.notifier).startRecording();
      final state = container.read(deviceProvider);

      // Assert
      expect(state.isRecording, isFalse);
    });

    test('startRecording after connect — isRecording becomes true', () async {
      // Arrange
      final container = makeContainer();
      await container.read(deviceProvider.notifier).connect();

      // Act
      await container.read(deviceProvider.notifier).startRecording();
      final state = container.read(deviceProvider);

      // Assert
      expect(state.isRecording, isTrue);
    });

    test('disconnect after connect — resets all state to initial values',
        () async {
      // Arrange
      final container = makeContainer();
      await container.read(deviceProvider.notifier).connect();
      await container.read(deviceProvider.notifier).startRecording();

      // Act
      await container.read(deviceProvider.notifier).disconnect();
      final state = container.read(deviceProvider);

      // Assert
      expect(state.isConnected, isFalse);
      expect(state.deviceName, isNull);
      expect(state.isRecording, isFalse);
    });

    test('pushConfig — stores config in currentConfig', () async {
      // Arrange
      final container = makeContainer();
      await container.read(deviceProvider.notifier).connect();
      const config = {'config_version': 1, 'device_id': 'test'};

      // Act
      await container.read(deviceProvider.notifier).pushConfig(config);
      final state = container.read(deviceProvider);

      // Assert
      expect(state.currentConfig, equals(config));
    });

    test('status notification — updates sd/gps/imu state', () async {
      // Arrange
      final mock = MockBleService();
      final container = ProviderContainer(
        overrides: [bleServiceProvider.overrideWithValue(mock)],
      );
      addTearDown(container.dispose);
      await container.read(deviceProvider.notifier).connect();

      // Act
      mock.statusController.add(
        DeviceStatus.fromString(
          'WiFi: OFF\nLogging: STOPPED\nBattery: 90%\n'
          'SD: OK\nGPS: NOFIX\nIMU: ABSENT',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      // Assert
      final state = container.read(deviceProvider);
      expect(state.sdState, equals('OK'));
      expect(state.gpsState, equals('NOFIX'));
      expect(state.imuState, equals('ABSENT'));
      expect(state.batteryPercent, equals(90));
    });

    test('_onStatus — wifiOn=true → state.wifiOn becomes true', () async {
      // Arrange
      final mock = MockBleService();
      final container = ProviderContainer(
        overrides: [bleServiceProvider.overrideWithValue(mock)],
      );
      addTearDown(container.dispose);
      await container.read(deviceProvider.notifier).connect();

      // Act
      mock.statusController.add(
        DeviceStatus.fromString(
          'WiFi: ON\nLogging: STOPPED\nBattery: 70%',
        ),
      );
      await Future.delayed(Duration.zero);

      // Assert
      expect(container.read(deviceProvider).wifiOn, isTrue);
    });

    test('_onStatus — wifiOn=false → state.wifiOn becomes false', () async {
      // Arrange
      final mock = MockBleService();
      final container = ProviderContainer(
        overrides: [bleServiceProvider.overrideWithValue(mock)],
      );
      addTearDown(container.dispose);
      await container.read(deviceProvider.notifier).connect();
      mock.statusController.add(DeviceStatus.fromString('WiFi: ON'));
      await Future.delayed(Duration.zero);

      // Act
      mock.statusController.add(DeviceStatus.fromString('WiFi: OFF'));
      await Future.delayed(Duration.zero);

      // Assert
      expect(container.read(deviceProvider).wifiOn, isFalse);
    });

    test('link-loss event — resets state to disconnected', () async {
      // Arrange
      final mock = MockBleService();
      final container = ProviderContainer(
        overrides: [bleServiceProvider.overrideWithValue(mock)],
      );
      addTearDown(container.dispose);
      await container.read(deviceProvider.notifier).connect();
      mock.statusController.add(
        DeviceStatus.fromString(
          'WiFi: ON\nLogging: RUNNING\nBattery: 80%\nHR: CONNECTED 142',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(deviceProvider).isConnected, isTrue);

      // Act
      mock.simulateConnectionLoss();
      await Future<void>.delayed(Duration.zero);

      // Assert
      final state = container.read(deviceProvider);
      expect(state.isConnected, isFalse);
      expect(state.deviceName, isNull);
      expect(state.isRecording, isFalse);
      expect(state.wifiOn, isFalse);
      expect(state.hr, isNull);
    });

    test('link-loss after disconnect — no double-reset side effects', () async {
      // Arrange
      final mock = MockBleService();
      final container = ProviderContainer(
        overrides: [bleServiceProvider.overrideWithValue(mock)],
      );
      addTearDown(container.dispose);
      await container.read(deviceProvider.notifier).connect();
      await container.read(deviceProvider.notifier).disconnect();

      // Act — a stale link-loss event arriving after disconnect must be a
      // no-op (subscription should already be cancelled).
      mock.simulateConnectionLoss();
      await Future<void>.delayed(Duration.zero);

      // Assert — already disconnected; staying disconnected is the only
      // observable outcome.
      expect(container.read(deviceProvider).isConnected, isFalse);
    });

    test('reconnectAfterReboot — re-establishes the link, returns true',
        () async {
      // Arrange
      final mock = MockBleService();
      final container = ProviderContainer(
        overrides: [bleServiceProvider.overrideWithValue(mock)],
      );
      addTearDown(container.dispose);
      await container.read(deviceProvider.notifier).connect();

      // Act
      final ok =
          await container.read(deviceProvider.notifier).reconnectAfterReboot(
                bootDelay: Duration.zero,
                retryDelay: Duration.zero,
              );

      // Assert
      expect(ok, isTrue);
      expect(container.read(deviceProvider).isConnected, isTrue);
    });

    test('reconnectAfterReboot — retries past transient scan failures',
        () async {
      // Arrange — device not advertising yet for the first two scans.
      final mock = MockBleService()..connectFailures = 2;
      final container = ProviderContainer(
        overrides: [bleServiceProvider.overrideWithValue(mock)],
      );
      addTearDown(container.dispose);

      // Act
      final ok =
          await container.read(deviceProvider.notifier).reconnectAfterReboot(
                bootDelay: Duration.zero,
                retryDelay: Duration.zero,
                maxAttempts: 3,
              );

      // Assert — two failures + one success.
      expect(ok, isTrue);
      expect(mock.connectCalls, equals(3));
    });

    test('reconnectAfterReboot — returns false when attempts exhausted',
        () async {
      // Arrange
      final mock = MockBleService()..connectFailures = 5;
      final container = ProviderContainer(
        overrides: [bleServiceProvider.overrideWithValue(mock)],
      );
      addTearDown(container.dispose);

      // Act
      final ok =
          await container.read(deviceProvider.notifier).reconnectAfterReboot(
                bootDelay: Duration.zero,
                retryDelay: Duration.zero,
                maxAttempts: 3,
              );

      // Assert
      expect(ok, isFalse);
      expect(container.read(deviceProvider).isConnected, isFalse);
    });
  });
}
