import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/channel_source.dart';
import 'package:idl0/data/channel_sources/analog_channel_source.dart';

void main() {
  group('AnalogChannelSource', () {
    test('resolveRegistryEntries — one u16 entry when enabled', () {
      // Arrange
      final entry = <String, dynamic>{
        'key': 'strain_left',
        'label': 'Strain Left',
        'adc_pin': 4,
        'units': 'kN',
        'scale': 0.0123,
        'offset': -1.5,
        'enabled': true,
      };
      final analog = <String, dynamic>{
        'sample_rate_hz': 100,
        'channels': [entry],
      };

      // Act
      final entries = AnalogChannelSource(
        key: 'strain_left',
        analogConfig: analog,
        channelIdBase: 32,
      ).resolveRegistryEntries();

      // Assert
      expect(entries, hasLength(1));
      final e = entries.single;
      expect(e.name, 'Strain Left');
      expect(e.units, 'kN');
      expect(e.scale, closeTo(0.0123, 1e-9));
      expect(e.offset, -1.5);
      expect(e.sampleRateHz, 100);
      expect(e.channelId, 32);
      expect(e.dataType, DataType.u16);
    });

    test('resolveRegistryEntries — empty when disabled', () {
      // Arrange
      final entry = <String, dynamic>{
        'key': 'x',
        'label': 'x',
        'adc_pin': 4,
        'units': 'v',
        'scale': 1.0,
        'offset': 0.0,
        'enabled': false,
      };
      final analog = <String, dynamic>{
        'sample_rate_hz': 100,
        'channels': [entry],
      };

      // Act + Assert
      expect(
        AnalogChannelSource(key: 'x', analogConfig: analog, channelIdBase: 0)
            .resolveRegistryEntries(),
        isEmpty,
      );
    });

    test('channels — empty when entry key not found', () {
      // Arrange + Act
      final src = AnalogChannelSource(
        key: 'missing',
        analogConfig: const {'sample_rate_hz': 100, 'channels': []},
        channelIdBase: 0,
      );

      // Assert
      expect(src.channels, isEmpty);
      expect(src.enabled, isFalse);
    });

    test('empty() — fresh blank source with __new__ key', () {
      // Arrange + Act
      final src = AnalogChannelSource.empty();

      // Assert
      expect(src.key, '__new__');
      expect(src.enabled, isFalse);
      expect(src.sampleRateHz, 100);
    });
  });
}
