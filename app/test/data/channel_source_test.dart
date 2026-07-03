import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/channel_source.dart';

void main() {
  group('DataType', () {
    test('byteWidth — returns correct width for every variant', () {
      expect(DataType.u8.byteWidth, 1);
      expect(DataType.i8.byteWidth, 1);
      expect(DataType.u16.byteWidth, 2);
      expect(DataType.i16.byteWidth, 2);
      expect(DataType.u32.byteWidth, 4);
      expect(DataType.i32.byteWidth, 4);
      expect(DataType.f32.byteWidth, 4);
      expect(DataType.f64.byteWidth, 8);
    });

    test('wireId — matches §5.2 data_type encoding (0..7)', () {
      expect(DataType.u8.wireId, 0);
      expect(DataType.u16.wireId, 1);
      expect(DataType.u32.wireId, 2);
      expect(DataType.i8.wireId, 3);
      expect(DataType.i16.wireId, 4);
      expect(DataType.i32.wireId, 5);
      expect(DataType.f32.wireId, 6);
      expect(DataType.f64.wireId, 7);
    });
  });

  group('RegistryEntry', () {
    test('equality — value-based', () {
      // Arrange + Act
      const a = RegistryEntry(
        channelId: 0,
        dataType: DataType.i16,
        sampleRateHz: 800,
        scale: 0.001,
        offset: 0.0,
        name: 'IMU0_AccelX',
        units: 'g',
      );
      const b = RegistryEntry(
        channelId: 0,
        dataType: DataType.i16,
        sampleRateHz: 800,
        scale: 0.001,
        offset: 0.0,
        name: 'IMU0_AccelX',
        units: 'g',
      );

      // Assert
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('inequality — different channelId', () {
      // Arrange
      const a = RegistryEntry(
        channelId: 0,
        dataType: DataType.i16,
        sampleRateHz: 800,
        scale: 0.001,
        offset: 0.0,
        name: 'X',
        units: 'g',
      );
      const b = RegistryEntry(
        channelId: 1,
        dataType: DataType.i16,
        sampleRateHz: 800,
        scale: 0.001,
        offset: 0.0,
        name: 'X',
        units: 'g',
      );

      // Assert
      expect(a, isNot(equals(b)));
    });
  });
}
