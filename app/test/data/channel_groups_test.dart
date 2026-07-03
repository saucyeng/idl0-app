import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/channel_groups.dart';

void main() {
  group('groupChannelNames —', () {
    test('buckets GPS/IMU0/IMU1/IMU2 by prefix before first underscore', () {
      // Arrange
      final names = [
        'GPS_Altitude',
        'GPS_SpeedKmh',
        'IMU0_AccelX',
        'IMU0_GyroZ',
        'IMU1_AccelX',
        'IMU2_AccelZ',
      ];

      // Act
      final result = groupChannelNames(names);

      // Assert — one group per prefix, input order preserved, labels are the prefix.
      expect(
        result.groups.map((g) => g.label).toList(),
        equals(['GPS', 'IMU0', 'IMU1', 'IMU2']),
      );
      expect(
        result.groups.first.channels,
        equals(['GPS_Altitude', 'GPS_SpeedKmh']),
      );
      expect(result.ungrouped, isEmpty);
    });

    test('names with no underscore are ungrouped', () {
      // Arrange
      final names = ['WheelFront', 'Time', 'Distance', 'IMU0_AccelX'];

      // Act
      final result = groupChannelNames(names);

      // Assert
      expect(result.groups.map((g) => g.label).toList(), equals(['IMU0']));
      expect(result.ungrouped, equals(['WheelFront', 'Time', 'Distance']));
    });

    test('HR_BPM and HR_RR land in the same HR group', () {
      // Arrange
      final names = ['HR_BPM', 'HR_RR'];

      // Act
      final result = groupChannelNames(names);

      // Assert
      expect(result.groups, hasLength(1));
      expect(result.groups.first.label, equals('HR'));
      expect(result.groups.first.channels, equals(['HR_BPM', 'HR_RR']));
    });

    test('empty input yields empty groups and ungrouped', () {
      // Arrange / Act
      final result = groupChannelNames(const []);

      // Assert
      expect(result.groups, isEmpty);
      expect(result.ungrouped, isEmpty);
    });

    test(
        'a name that is only a prefix and underscore is ungrouped (no empty channel)',
        () {
      // Arrange — "GPS_" has nothing after the underscore; treat as ungrouped
      // rather than emitting a group with an empty channel name.
      final names = ['GPS_', 'GPS_SpeedKmh'];

      // Act
      final result = groupChannelNames(names);

      // Assert
      expect(result.groups, hasLength(1));
      expect(result.groups.first.label, equals('GPS'));
      expect(result.groups.first.channels, equals(['GPS_SpeedKmh']));
      expect(result.ungrouped, equals(['GPS_']));
    });
  });
}
