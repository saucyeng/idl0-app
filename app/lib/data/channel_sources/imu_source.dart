import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/tabs/device/source_dialogs/imu_dialog.dart';
import '../channel_source.dart';

const _kAxisKeys = [
  'accel_x',
  'accel_y',
  'accel_z',
  'gyro_x',
  'gyro_y',
  'gyro_z',
];
const _kAxisDisplay = ['AccelX', 'AccelY', 'AccelZ', 'GyroX', 'GyroY', 'GyroZ'];
const _kAxisIsGyro = [false, false, false, true, true, true];

const _kImuLabels = [
  'IMU0 (sprung)',
  'IMU1 (front fork)',
  'IMU2 (rear)',
];

/// One of the three IMUs (sprung / front fork / rear).
///
/// IMU rate is shared across all three IMUs (the SPI bus reads them in
/// lockstep), so [sampleRateHz] reads from `imu.sample_rate_hz`. Per-IMU
/// fields (`enabled`, `accel_range_g`, `gyro_range_dps`, `channels`) live
/// in `imu.imu{0,1,2}` sub-blocks per §8.
class ImuSource extends ChannelSource {
  /// Creates an [ImuSource].
  ///
  /// [imuConfig] is the `config['imu']` map. [channelIdBase] is the first
  /// `channel_id` this IMU's enabled axes occupy in the §5.2 registry.
  ImuSource({
    required this.index,
    required this.imuConfig,
    required this.channelIdBase,
  });

  /// 0 (sprung), 1 (front fork), or 2 (rear).
  final int index;

  /// View into `config['imu']` from the active profile.
  final Map<String, dynamic> imuConfig;

  /// First `channel_id` this source's enabled axes will be assigned.
  final int channelIdBase;

  Map<String, dynamic> get _slot =>
      (imuConfig['imu$index'] as Map<String, dynamic>?) ?? const {};

  @override
  String get sourceKey => 'imu$index';

  @override
  String get sourceLabel => _kImuLabels[index];

  @override
  int? get sampleRateHz => imuConfig['sample_rate_hz'] as int?;

  @override
  bool get enabled => (_slot['enabled'] as bool?) ?? false;

  double get _accelG => ((_slot['accel_range_g'] as num?) ?? 32).toDouble();
  double get _gyroDps => ((_slot['gyro_range_dps'] as num?) ?? 2000).toDouble();

  Map<String, dynamic> get _channels =>
      (_slot['channels'] as Map<String, dynamic>?) ?? const {};

  @override
  List<ChannelRow> get channels {
    return List.generate(6, (i) {
      final isGyro = _kAxisIsGyro[i];
      final scale = (isGyro ? _gyroDps : _accelG) / 32768.0;
      return ChannelRow(
        channelName: 'IMU${index}_${_kAxisDisplay[i]}',
        units: isGyro ? 'dps' : 'g',
        scale: scale,
        offset: 0.0,
        enabled: (_channels[_kAxisKeys[i]] as bool?) ?? false,
        buildDialog: (_, __) => const _ImuRowDialogStub(),
      );
    });
  }

  @override
  List<RegistryEntry> resolveRegistryEntries() {
    if (!enabled) return const [];
    final rate = imuConfig['sample_rate_hz'] as int? ?? 0;
    var nextId = channelIdBase;
    final out = <RegistryEntry>[];
    for (var i = 0; i < 6; i++) {
      if ((_channels[_kAxisKeys[i]] as bool?) != true) continue;
      final isGyro = _kAxisIsGyro[i];
      final scale = (isGyro ? _gyroDps : _accelG) / 32768.0;
      out.add(RegistryEntry(
        channelId: nextId++,
        dataType: DataType.i16,
        sampleRateHz: rate,
        scale: scale,
        offset: 0.0,
        name: 'IMU${index}_${_kAxisDisplay[i]}',
        units: isGyro ? 'dps' : 'g',
      ),);
    }
    return out;
  }

  @override
  Widget buildSourceDialog(BuildContext context, WidgetRef ref) =>
      ImuSettingsDialog(imuIndex: index);
}

/// Read-only informational dialog for an individual IMU axis row. The
/// axis's scale/offset are derived from the IMU's range setting (edit
/// it in the IMU source dialog); enable/disable also lives there.
class _ImuRowDialogStub extends StatelessWidget {
  const _ImuRowDialogStub();
  @override
  Widget build(BuildContext context) => const AlertDialog(
        title: Text('IMU axis'),
        content: Text(
          'Per-axis scale and offset derive from the IMU range. '
          'Edit enable, range, and bus rate in the IMU source dialog '
          '(gear icon).',
        ),
      );
}
