import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/channel_source.dart';
import 'package:idl0/data/channel_sources/imu_source.dart';

Map<String, dynamic> _imuConfig({
  bool enabled = true,
  int rate = 800,
  int accelG = 32,
  int gyroDps = 2000,
  Map<String, bool>? channels,
}) {
  return {
    'sample_rate_hz': rate,
    'imu0': {
      'enabled': enabled,
      'accel_range_g': accelG,
      'gyro_range_dps': gyroDps,
      'channels': channels ??
          <String, bool>{
            'accel_x': true,
            'accel_y': true,
            'accel_z': true,
            'gyro_x': true,
            'gyro_y': false,
            'gyro_z': false,
          },
    },
    'imu1': {
      'enabled': false,
      'accel_range_g': 16,
      'gyro_range_dps': 500,
      'channels': <String, bool>{},
    },
    'imu2': {
      'enabled': false,
      'accel_range_g': 16,
      'gyro_range_dps': 500,
      'channels': <String, bool>{},
    },
  };
}

void main() {
  group('ImuSource', () {
    test('resolveRegistryEntries — emits one entry per enabled axis', () {
      // Arrange
      final cfg = _imuConfig();

      // Act
      final entries = ImuSource(index: 0, imuConfig: cfg, channelIdBase: 0)
          .resolveRegistryEntries();

      // Assert
      expect(entries.map((e) => e.name).toList(), [
        'IMU0_AccelX',
        'IMU0_AccelY',
        'IMU0_AccelZ',
        'IMU0_GyroX',
      ]);
      expect(entries.first.scale, closeTo(32.0 / 32768.0, 1e-9));
      expect(entries.first.dataType, DataType.i16);
      expect(entries.first.sampleRateHz, 800);
      expect(entries.first.channelId, 0);
      expect(entries.last.channelId, 3);
    });

    test('resolveRegistryEntries — empty when whole source disabled', () {
      // Arrange
      final cfg = _imuConfig(enabled: false);

      // Act
      final entries = ImuSource(index: 0, imuConfig: cfg, channelIdBase: 0)
          .resolveRegistryEntries();

      // Assert
      expect(entries, isEmpty);
    });

    test('resolveRegistryEntries — channel id base offsets correctly', () {
      // Arrange
      final cfg = _imuConfig();

      // Act
      final entries = ImuSource(index: 0, imuConfig: cfg, channelIdBase: 12)
          .resolveRegistryEntries();

      // Assert
      expect(entries.first.channelId, 12);
      expect(entries.last.channelId, 15);
    });

    test('sampleRateHz — reads from shared imu.sample_rate_hz', () {
      // Arrange
      final cfg = _imuConfig(rate: 416);

      // Act
      final rate =
          ImuSource(index: 0, imuConfig: cfg, channelIdBase: 0).sampleRateHz;

      // Assert
      expect(rate, 416);
    });

    test('channels — reflects per-axis enable state', () {
      // Arrange
      final cfg = _imuConfig(channels: {
        'accel_x': true,
        'accel_y': false,
        'accel_z': false,
        'gyro_x': false,
        'gyro_y': false,
        'gyro_z': false,
      },);

      // Act
      final rows =
          ImuSource(index: 0, imuConfig: cfg, channelIdBase: 0).channels;

      // Assert
      expect(rows.map((r) => '${r.channelName}=${r.enabled}'), [
        'IMU0_AccelX=true',
        'IMU0_AccelY=false',
        'IMU0_AccelZ=false',
        'IMU0_GyroX=false',
        'IMU0_GyroY=false',
        'IMU0_GyroZ=false',
      ]);
    });

    test('sourceLabel — IMU0/1/2 carry the spec-defined location labels', () {
      // Arrange
      final cfg = _imuConfig();

      // Act + Assert
      expect(ImuSource(index: 0, imuConfig: cfg, channelIdBase: 0).sourceLabel,
          'IMU0 (sprung)',);
      expect(ImuSource(index: 1, imuConfig: cfg, channelIdBase: 0).sourceLabel,
          'IMU1 (front fork)',);
      expect(ImuSource(index: 2, imuConfig: cfg, channelIdBase: 0).sourceLabel,
          'IMU2 (rear)',);
    });

    test('scale — accelerometer uses range_g/32768 with i16 units', () {
      // Arrange
      final cfg = _imuConfig(accelG: 16);

      // Act
      final entries = ImuSource(index: 0, imuConfig: cfg, channelIdBase: 0)
          .resolveRegistryEntries();
      final accelX = entries.firstWhere((e) => e.name == 'IMU0_AccelX');

      // Assert
      expect(accelX.scale, closeTo(16.0 / 32768.0, 1e-9));
      expect(accelX.units, 'g');
    });

    test('scale — gyroscope uses range_dps/32768 with dps units', () {
      // Arrange
      final cfg = _imuConfig(gyroDps: 500);

      // Act
      final entries = ImuSource(index: 0, imuConfig: cfg, channelIdBase: 0)
          .resolveRegistryEntries();
      final gyroX = entries.firstWhere((e) => e.name == 'IMU0_GyroX');

      // Assert
      expect(gyroX.scale, closeTo(500.0 / 32768.0, 1e-9));
      expect(gyroX.units, 'dps');
    });
  });
}
