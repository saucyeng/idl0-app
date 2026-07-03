import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/channel_sources/gps_source.dart';

void main() {
  group('GpsSource', () {
    test('resolveRegistryEntries — emits 8 entries with sequential ids', () {
      // Arrange
      final src = GpsSource(
        gpsConfig: const {'sample_rate_hz': 5},
        channelIdBase: 30,
      );

      // Act
      final entries = src.resolveRegistryEntries();

      // Assert
      expect(entries.length, 8);
      expect(entries.first.name, 'GPS_EpochMs');
      expect(entries.first.channelId, 30);
      expect(entries.last.channelId, 37);
      expect(entries.first.sampleRateHz, 5);
    });

    test('sourceKey + sourceLabel + sampleRateHz', () {
      // Arrange + Act
      final g = GpsSource(
        gpsConfig: const {'sample_rate_hz': 10},
        channelIdBase: 0,
      );

      // Assert
      expect(g.sourceKey, 'gps');
      expect(g.sourceLabel, 'GPS');
      expect(g.sampleRateHz, 10);
      expect(g.enabled, isTrue);
    });

    test('resolveRegistryEntries — sample rate defaults to 5 when missing', () {
      // Arrange + Act
      final entries = GpsSource(
        gpsConfig: const <String, dynamic>{},
        channelIdBase: 0,
      ).resolveRegistryEntries();

      // Assert
      expect(entries.every((e) => e.sampleRateHz == 5), isTrue);
    });
  });
}
