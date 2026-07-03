import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/device_provider.dart';
import 'package:idl0/providers/mode.dart';
import 'package:idl0/transport/ble_service.dart';

import '../helpers/mock_ble_service.dart';

void main() {
  group('modeOf', () {
    test('wifiOn=false, isRecording=false → Mode.idle', () {
      // Arrange + Act
      final mode = modeOf(const DeviceState());

      // Assert
      expect(mode, equals(Mode.idle));
    });

    test('wifiOn=true → Mode.wifi', () {
      // Arrange + Act
      final mode = modeOf(const DeviceState(wifiOn: true));

      // Assert
      expect(mode, equals(Mode.wifi));
    });

    test('isRecording=true → Mode.recording', () {
      // Arrange + Act
      final mode = modeOf(const DeviceState(isRecording: true));

      // Assert
      expect(mode, equals(Mode.recording));
    });

    test('wifiOn AND isRecording → Mode.unknown', () {
      // Arrange + Act
      final mode = modeOf(const DeviceState(wifiOn: true, isRecording: true));

      // Assert
      expect(mode, equals(Mode.unknown));
    });
  });

  group('modeProvider', () {
    test('reflects DeviceState as it changes', () async {
      // Arrange
      final mock = MockBleService();
      final container = ProviderContainer(
        overrides: [bleServiceProvider.overrideWithValue(mock)],
      );
      addTearDown(container.dispose);
      await container.read(deviceProvider.notifier).connect();

      // Act + Assert — idle by default
      expect(container.read(modeProvider), equals(Mode.idle));

      // Act — flip wifiOn
      mock.statusController.add(DeviceStatus.fromString('WiFi: ON'));
      await Future.delayed(Duration.zero);

      // Assert
      expect(container.read(modeProvider), equals(Mode.wifi));

      // Act — flip to recording
      mock.statusController
          .add(DeviceStatus.fromString('WiFi: OFF\nLogging: RUNNING'));
      await Future.delayed(Duration.zero);

      // Assert
      expect(container.read(modeProvider), equals(Mode.recording));
    });
  });
}
