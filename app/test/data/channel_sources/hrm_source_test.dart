import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/channel_source.dart';
import 'package:idl0/data/channel_sources/hrm_source.dart';

void main() {
  group('HrmSource', () {
    test('resolveRegistryEntries — emits channels 22 + 23 when enabled', () {
      // Arrange
      final hrm = HrmSource(hrmConfig: const {
        'enabled': true,
        'device_address': 'AA:BB:CC:DD:EE:FF',
        'device_name': 'Polar H10 12345678',
      },);

      // Act
      final entries = hrm.resolveRegistryEntries();

      // Assert
      expect(entries, hasLength(2));
      expect(entries[0].channelId, HrmSource.hrChannelId);
      expect(entries[0].name, 'HR_BPM');
      expect(entries[0].units, 'bpm');
      expect(entries[0].dataType, DataType.u8);
      expect(entries[0].sampleRateHz, 1);
      expect(entries[1].channelId, HrmSource.rrChannelId);
      expect(entries[1].name, 'HR_RR');
      expect(entries[1].units, 'ms');
      expect(entries[1].dataType, DataType.u16);
      expect(entries[1].scale, closeTo(1000.0 / 1024.0, 1e-9));
      expect(entries[1].sampleRateHz, 0);
    });

    test('resolveRegistryEntries — empty when disabled', () {
      // Arrange + Act
      final hrm = HrmSource(hrmConfig: const {'enabled': false})
          .resolveRegistryEntries();

      // Assert
      expect(hrm, isEmpty);
    });

    test('resolveRegistryEntries — empty when block absent', () {
      // Arrange + Act
      final hrm = HrmSource(hrmConfig: const {}).resolveRegistryEntries();

      // Assert
      expect(hrm, isEmpty);
    });

    test('channels — always reports 2 rows; enabled mirrors source enabled',
        () {
      // Arrange + Act
      final enabled = HrmSource(hrmConfig: const {'enabled': true}).channels;
      final disabled = HrmSource(hrmConfig: const {'enabled': false}).channels;

      // Assert
      expect(enabled.map((c) => c.channelName), ['HR_BPM', 'HR_RR']);
      expect(enabled.every((c) => c.enabled), isTrue);
      expect(disabled.map((c) => c.channelName), ['HR_BPM', 'HR_RR']);
      expect(disabled.every((c) => !c.enabled), isTrue);
    });

    test('sourceLabel — falls back to plain label when no device_name', () {
      // Arrange + Act
      final blank = HrmSource(hrmConfig: const {}).sourceLabel;
      final named = HrmSource(hrmConfig: const {
        'device_name': 'Polar H10 12345678',
      },).sourceLabel;

      // Assert
      expect(blank, 'Heart Rate Monitor');
      expect(named, contains('Polar H10 12345678'));
    });

    test('sampleRateHz — null (event-driven)', () {
      // Arrange + Act + Assert
      expect(HrmSource(hrmConfig: const {}).sampleRateHz, isNull);
    });
  });
}
