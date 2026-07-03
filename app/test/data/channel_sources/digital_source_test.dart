import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/channel_source.dart';
import 'package:idl0/data/channel_sources/digital_source.dart';

void main() {
  group('DigitalSource', () {
    test('marker kind — resolves one event-driven u8 entry', () {
      // Arrange
      final entry = <String, dynamic>{
        'key': 'marker_btn',
        'label': 'Marker',
        'kind': 'marker',
        'gpio_pin': 21,
        'active_low': true,
        'debounce_ms': 20,
        'enabled': true,
      };
      final digital = <String, dynamic>{
        'channels': [entry],
      };

      // Act
      final entries = DigitalSource(
        key: 'marker_btn',
        digitalConfig: digital,
        channelIdBase: 40,
      ).resolveRegistryEntries();

      // Assert
      expect(entries, hasLength(1));
      final e = entries.single;
      expect(e.name, 'Marker');
      expect(e.dataType, DataType.u8);
      expect(e.sampleRateHz, 0); // event-driven
      expect(e.units, 'event');
      expect(e.channelId, 40);
    });

    test('marker() — fresh source with marker kind', () {
      // Arrange + Act
      final src = DigitalSource.marker();

      // Assert
      expect(src.kind, DigitalKind.marker);
      expect(src.enabled, isFalse);
    });

    test('level kind — u8 sampled at 50 Hz', () {
      // Arrange
      final entry = <String, dynamic>{
        'key': 'brake',
        'label': 'Brake',
        'kind': 'level',
        'gpio_pin': 5,
        'active_low': false,
        'debounce_ms': 0,
        'enabled': true,
      };
      final digital = <String, dynamic>{
        'channels': [entry],
      };

      // Act
      final src = DigitalSource(
        key: 'brake',
        digitalConfig: digital,
        channelIdBase: 50,
      );

      // Assert
      expect(src.kind, DigitalKind.level);
      expect(src.sampleRateHz, 50);
      final e = src.resolveRegistryEntries().single;
      expect(e.dataType, DataType.u8);
      expect(e.sampleRateHz, 50);
      expect(e.units, 'bool');
    });

    test('pwm kind — u32 sampled at 50 Hz', () {
      // Arrange
      final entry = <String, dynamic>{
        'key': 'engine_rpm',
        'label': 'Engine RPM',
        'kind': 'pwm',
        'gpio_pin': 6,
        'enabled': true,
      };
      final digital = <String, dynamic>{
        'channels': [entry],
      };

      // Act
      final src = DigitalSource(
        key: 'engine_rpm',
        digitalConfig: digital,
        channelIdBase: 60,
      );

      // Assert
      expect(src.kind, DigitalKind.pwm);
      final e = src.resolveRegistryEntries().single;
      expect(e.dataType, DataType.u32);
      expect(e.sampleRateHz, 50);
      expect(e.units, 'Hz');
    });

    test('disabled — resolves empty', () {
      // Arrange
      final entry = <String, dynamic>{
        'key': 'x',
        'label': 'X',
        'kind': 'marker',
        'enabled': false,
      };
      final digital = <String, dynamic>{
        'channels': [entry],
      };

      // Act + Assert
      expect(
        DigitalSource(key: 'x', digitalConfig: digital, channelIdBase: 0)
            .resolveRegistryEntries(),
        isEmpty,
      );
    });

    test('missing entry — channels empty, enabled false', () {
      // Arrange + Act
      final src = DigitalSource(
        key: 'missing',
        digitalConfig: const {'channels': []},
        channelIdBase: 0,
      );

      // Assert
      expect(src.channels, isEmpty);
      expect(src.enabled, isFalse);
    });
  });
}
