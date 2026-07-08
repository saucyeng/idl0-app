import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/transport/ble_service.dart';

void main() {
  group('DeviceStatus.fromString — Firmware line', () {
    test('parses a Firmware: semver line into firmwareVersion', () {
      // Arrange
      const text = 'WiFi: OFF\nLogging: STOPPED\nBattery: 90%\nFirmware: 1.5.0';

      // Act
      final status = DeviceStatus.fromString(text);

      // Assert
      expect(status.firmwareVersion, equals('1.5.0'));
    });

    test('preserves case in a pre-release version tag', () {
      // Arrange — uppercasing would corrupt the semver pre-release component.
      const text = 'Firmware: 1.6.0-beta.1';

      // Act
      final status = DeviceStatus.fromString(text);

      // Assert
      expect(status.firmwareVersion, equals('1.6.0-beta.1'));
    });

    test('strips a leading v from a git-describe tag build', () {
      // Arrange — a local build from the clean `v0.1.0` tag reports the tag
      // name verbatim (leading `v`); the version of record is the tag with its
      // `v` stripped (§27.7), matching how the catalog parses release tags.
      const text = 'Firmware: v0.1.0';

      // Act
      final status = DeviceStatus.fromString(text);

      // Assert
      expect(status.firmwareVersion, equals('0.1.0'));
    });

    test('strips the leading v but preserves a pre-release suffix', () {
      // Arrange — a v-prefixed tag build of a pre-release version.
      const text = 'Firmware: v1.6.0-beta.1';

      // Act
      final status = DeviceStatus.fromString(text);

      // Assert
      expect(status.firmwareVersion, equals('1.6.0-beta.1'));
    });

    test('leaves firmwareVersion null when no Firmware line present', () {
      // Arrange
      const text = 'WiFi: OFF\nLogging: STOPPED\nBattery: 90%';

      // Act
      final status = DeviceStatus.fromString(text);

      // Assert
      expect(status.firmwareVersion, isNull);
    });
  });
}
