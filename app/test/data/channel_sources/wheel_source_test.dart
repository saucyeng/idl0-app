import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/channel_source.dart';
import 'package:idl0/data/channel_sources/wheel_source.dart';

void main() {
  group('WheelSource', () {
    test(
        'resolveRegistryEntries — emits one u32 event-driven entry when enabled',
        () {
      // Arrange
      final src = WheelSource(
        slot: 'front',
        wheelConfig: const {
          'front': {
            'enabled': true,
            'points_per_revolution': 12,
            'wheel_circumference_mm': 2300,
          },
          'rear': {
            'enabled': false,
            'points_per_revolution': 12,
            'wheel_circumference_mm': 2300,
          },
        },
        channelIdBase: 18,
      );

      // Act
      final entries = src.resolveRegistryEntries();

      // Assert
      expect(entries, hasLength(1));
      final e = entries.single;
      expect(e.name, 'WheelFront');
      expect(e.dataType, DataType.u32);
      expect(e.sampleRateHz, 0);
      expect(e.channelId, 18);
      expect(e.units, 'pulse');
    });

    test('resolveRegistryEntries — empty when disabled', () {
      // Arrange + Act
      final src = WheelSource(
        slot: 'rear',
        wheelConfig: const {
          'rear': {
            'enabled': false,
            'points_per_revolution': 12,
            'wheel_circumference_mm': 2300,
          },
        },
        channelIdBase: 19,
      );

      // Assert
      expect(src.resolveRegistryEntries(), isEmpty);
    });

    test('sourceLabel — capitalises slot', () {
      // Arrange + Act + Assert
      final front = WheelSource(
        slot: 'front',
        wheelConfig: const {},
        channelIdBase: 0,
      );
      final rear = WheelSource(
        slot: 'rear',
        wheelConfig: const {},
        channelIdBase: 0,
      );
      expect(front.sourceLabel, 'Wheel Front');
      expect(rear.sourceLabel, 'Wheel Rear');
    });

    test('sampleRateHz — null (event-driven)', () {
      // Arrange + Act
      final src = WheelSource(
        slot: 'front',
        wheelConfig: const {},
        channelIdBase: 0,
      );

      // Assert
      expect(src.sampleRateHz, isNull);
    });
  });
}
