import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/device_provider.dart';
import 'package:idl0/transport/ack.dart';
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

  group('DeviceNotifier — OTA auto-confirm (§27.7)', () {
    ProviderContainer makeContainer(MockBleService mock) {
      final container = ProviderContainer(
        overrides: [bleServiceProvider.overrideWithValue(mock)],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
        'armOtaAutoConfirm — version-bearing frame during connect '
        'handshake — arm survives and no confirm sent', () async {
      // Arrange — the mock pushes a matching, pending-verify status frame
      // DURING connect() (before its future resolves), modeling the real
      // BleConnection ordering: the device's first status notification
      // arrives on the stream while isConnected is still false.
      final mock = MockBleService()
        ..statusDuringConnect =
            DeviceStatus.fromString('Firmware: 1.5.0\nOTA: PENDING_VERIFY');
      final container = makeContainer(mock);
      container.read(deviceProvider.notifier).armOtaAutoConfirm('1.5.0');

      // Act
      await container.read(deviceProvider.notifier).connect();
      await Future<void>.delayed(Duration.zero);

      // Assert — the handshake frame's data did land in state (proving it
      // was really received, matching version + pending), yet no confirm
      // fired for it — the pre-connect frame must be ignored, not evaluated.
      final state = container.read(deviceProvider);
      expect(state.firmwareVersion, equals('1.5.0'));
      expect(state.otaPendingVerify, isTrue);
      expect(mock.confirmOtaCallCount, equals(0));
    });

    test(
        'armOtaAutoConfirm — handshake frame then post-connect matching '
        'frame with pending — confirm sent exactly once', () async {
      // Arrange — the production sequence, end-to-end through the notifier:
      // a version-bearing frame during the connect handshake (ignored),
      // followed by the firmware's real 1 Hz post-connect status notify
      // carrying the same version + pending-verify.
      final mock = MockBleService()
        ..statusDuringConnect =
            DeviceStatus.fromString('Firmware: 1.5.0\nOTA: PENDING_VERIFY');
      final container = makeContainer(mock);
      container.read(deviceProvider.notifier).armOtaAutoConfirm('1.5.0');

      // Act
      await container.read(deviceProvider.notifier).connect();
      await Future<void>.delayed(Duration.zero);
      mock.statusController.add(
        DeviceStatus.fromString('Firmware: 1.5.0\nOTA: PENDING_VERIFY'),
      );
      await Future<void>.delayed(Duration.zero);

      // Assert — the arm survived the handshake frame and fired exactly
      // once, on the first frame received after isConnected flipped true.
      expect(mock.confirmOtaCallCount, equals(1));
      expect(container.read(deviceProvider).otaPendingVerify, isFalse);
    });

    test(
        'armOtaAutoConfirm — matching version frame + pending — '
        'confirm sent exactly once and flag cleared', () async {
      // Arrange
      final mock = MockBleService();
      final container = makeContainer(mock);
      await container.read(deviceProvider.notifier).connect();
      container.read(deviceProvider.notifier).armOtaAutoConfirm('1.5.0');

      // Act
      mock.statusController.add(
        DeviceStatus.fromString('Firmware: 1.5.0\nOTA: PENDING_VERIFY'),
      );
      await Future<void>.delayed(Duration.zero);

      // Assert
      expect(mock.confirmOtaCallCount, equals(1));
      expect(container.read(deviceProvider).otaPendingVerify, isFalse);
    });

    test(
        'armOtaAutoConfirm — repeated matching frames — single confirm',
        () async {
      // Arrange
      final mock = MockBleService();
      final container = makeContainer(mock);
      await container.read(deviceProvider.notifier).connect();
      container.read(deviceProvider.notifier).armOtaAutoConfirm('1.5.0');

      // Act — the device keeps re-emitting the same status while the app
      // is settled on the pending-verify state.
      mock.statusController.add(
        DeviceStatus.fromString('Firmware: 1.5.0\nOTA: PENDING_VERIFY'),
      );
      await Future<void>.delayed(Duration.zero);
      mock.statusController.add(
        DeviceStatus.fromString('Firmware: 1.5.0\nOTA: PENDING_VERIFY'),
      );
      await Future<void>.delayed(Duration.zero);

      // Assert — one-shot: the second frame arrives after disarm.
      expect(mock.confirmOtaCallCount, equals(1));
    });

    test(
        'armOtaAutoConfirm — mismatched version frame — disarms without '
        'confirm', () async {
      // Arrange — armed for the pushed version, but the device comes back
      // reporting its old version (e.g. bootloader rolled back the image).
      final mock = MockBleService();
      final container = makeContainer(mock);
      await container.read(deviceProvider.notifier).connect();
      container.read(deviceProvider.notifier).armOtaAutoConfirm('1.5.0');

      // Act
      mock.statusController.add(
        DeviceStatus.fromString('Firmware: 1.4.0\nOTA: PENDING_VERIFY'),
      );
      await Future<void>.delayed(Duration.zero);

      // Assert — no confirm sent for the mismatched version.
      expect(mock.confirmOtaCallCount, equals(0));
      expect(container.read(deviceProvider).firmwareVersion, equals('1.4.0'));

      // Act — a later frame reporting the originally-expected version must
      // not retroactively confirm; the one-shot expectation already fired.
      mock.statusController.add(
        DeviceStatus.fromString('Firmware: 1.5.0\nOTA: PENDING_VERIFY'),
      );
      await Future<void>.delayed(Duration.zero);

      // Assert — still no confirm; the expectation was disarmed above.
      expect(mock.confirmOtaCallCount, equals(0));
    });

    test(
        'armOtaAutoConfirm — matching version but not pending — no send, '
        'disarmed', () async {
      // Arrange
      final mock = MockBleService();
      final container = makeContainer(mock);
      await container.read(deviceProvider.notifier).connect();
      container.read(deviceProvider.notifier).armOtaAutoConfirm('1.5.0');

      // Act — version matches but the device never flagged pending-verify
      // (e.g. it was already confirmed by the time this frame arrived).
      mock.statusController.add(DeviceStatus.fromString('Firmware: 1.5.0'));
      await Future<void>.delayed(Duration.zero);

      // Assert
      expect(mock.confirmOtaCallCount, equals(0));

      // Act — a later matching+pending frame must not confirm either; the
      // one-shot expectation was consumed by the first version-bearing frame.
      mock.statusController.add(
        DeviceStatus.fromString('Firmware: 1.5.0\nOTA: PENDING_VERIFY'),
      );
      await Future<void>.delayed(Duration.zero);

      // Assert
      expect(mock.confirmOtaCallCount, equals(0));
    });

    test(
        'armOtaAutoConfirm — confirm send throws — otaPendingVerify stays '
        'true', () async {
      // Arrange
      final mock = MockBleService();
      final container = makeContainer(mock);
      await container.read(deviceProvider.notifier).connect();
      container.read(deviceProvider.notifier).armOtaAutoConfirm('1.5.0');
      mock.nextRefusalCode = kIdl0AckMutexRefused;

      // Act
      mock.statusController.add(
        DeviceStatus.fromString('Firmware: 1.5.0\nOTA: PENDING_VERIFY'),
      );
      await Future<void>.delayed(Duration.zero);

      // Assert — the failed send never rethrows into the stream listener,
      // and the manual pending-verify card stays the fallback.
      expect(container.read(deviceProvider).otaPendingVerify, isTrue);
    });

    test('disarmOtaAutoConfirm — cancels a pending arm before any frame',
        () async {
      // Arrange
      final mock = MockBleService();
      final container = makeContainer(mock);
      await container.read(deviceProvider.notifier).connect();
      container.read(deviceProvider.notifier).armOtaAutoConfirm('1.5.0');

      // Act
      container.read(deviceProvider.notifier).disarmOtaAutoConfirm();
      mock.statusController.add(
        DeviceStatus.fromString('Firmware: 1.5.0\nOTA: PENDING_VERIFY'),
      );
      await Future<void>.delayed(Duration.zero);

      // Assert
      expect(mock.confirmOtaCallCount, equals(0));
    });
  });
}
