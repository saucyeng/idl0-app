import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../providers/profile_provider.dart';
import '../../../brand/brand.dart';
import 'dialog_chrome.dart';

/// IMU source dialog — master ODR (shared across all IMUs), per-IMU
/// accel/gyro ranges, and per-axis enables.
class ImuSettingsDialog extends ConsumerStatefulWidget {
  /// Creates an [ImuSettingsDialog] for IMU [imuIndex] (0/1/2).
  const ImuSettingsDialog({super.key, required this.imuIndex});

  /// 0 = sprung, 1 = front fork, 2 = rear.
  final int imuIndex;

  @override
  ConsumerState<ImuSettingsDialog> createState() => _ImuSettingsDialogState();
}

class _ImuSettingsDialogState extends ConsumerState<ImuSettingsDialog> {
  // Valid LSM6DSO32 high-performance ODRs from §8.
  static const _kRatesHighPerf = <num>[12.5, 26, 52, 104, 208, 416, 833, 1666];
  static const _kAccelRanges = <int>[4, 8, 16, 32];
  static const _kGyroRanges = <int>[125, 250, 500, 1000, 2000];
  static const _kAxisKeys = <String>[
    'accel_x',
    'accel_y',
    'accel_z',
    'gyro_x',
    'gyro_y',
    'gyro_z',
  ];
  static const _kAxisLabels = <String>[
    'Accel X',
    'Accel Y',
    'Accel Z',
    'Gyro X',
    'Gyro Y',
    'Gyro Z',
  ];

  late num _rate;
  late bool _enabled;
  late int _accelG;
  late int _gyroDps;
  late Map<String, bool> _channels;

  @override
  void initState() {
    super.initState();
    final config = ref.read(profileProvider).value!.activeProfile!.config;
    final imu = (config['imu'] as Map<String, dynamic>?) ?? const {};
    final slot =
        (imu['imu${widget.imuIndex}'] as Map<String, dynamic>?) ?? const {};
    // Snap any stored sample rate to the nearest valid LSM6DSO32 high-perf
    // ODR. Older profiles saved 800 Hz (an invalid value the dropdown could
    // not display) so reading them raw would crash the dialog; the snap
    // rewrites such values to 833 Hz on the next save.
    final stored = (imu['sample_rate_hz'] as num?) ?? 833;
    _rate = _kRatesHighPerf.reduce(
      (a, b) => (a - stored).abs() < (b - stored).abs() ? a : b,
    );
    _enabled = (slot['enabled'] as bool?) ?? false;
    _accelG = (slot['accel_range_g'] as int?) ?? 32;
    _gyroDps = (slot['gyro_range_dps'] as int?) ?? 2000;
    _channels = <String, bool>{
      for (final k in _kAxisKeys)
        k: (slot['channels'] as Map<String, dynamic>?)?[k] as bool? ?? false,
    };
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: sourceDialogTitle('IMU${widget.imuIndex} settings'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              title: const Text('Enabled'),
              value: _enabled,
              activeThumbColor: brandGood,
              onChanged: (v) => setState(() => _enabled = v),
            ),
            ListTile(
              title: const Text('IMU bus rate (Hz) — shared across all IMUs'),
              subtitle: DropdownButton<num>(
                value: _rate,
                isExpanded: true,
                items: [
                  for (final r in _kRatesHighPerf)
                    DropdownMenuItem(value: r, child: Text('$r')),
                ],
                onChanged: (v) => setState(() => _rate = v ?? _rate),
              ),
            ),
            ListTile(
              title: const Text('Accel range'),
              subtitle: DropdownButton<int>(
                value: _accelG,
                isExpanded: true,
                items: [
                  for (final r in _kAccelRanges)
                    DropdownMenuItem(value: r, child: Text('±${r}g')),
                ],
                onChanged: (v) => setState(() => _accelG = v ?? _accelG),
              ),
            ),
            ListTile(
              title: const Text('Gyro range'),
              subtitle: DropdownButton<int>(
                value: _gyroDps,
                isExpanded: true,
                items: [
                  for (final r in _kGyroRanges)
                    DropdownMenuItem(value: r, child: Text('±$r dps')),
                ],
                onChanged: (v) => setState(() => _gyroDps = v ?? _gyroDps),
              ),
            ),
            const Divider(),
            sourceDialogSectionLabel('Axes'),
            for (var i = 0; i < 6; i++)
              CheckboxListTile(
                title: Text(_kAxisLabels[i]),
                value: _channels[_kAxisKeys[i]] ?? false,
                activeColor: brandGood,
                onChanged: (v) => setState(() {
                  _channels[_kAxisKeys[i]] = v ?? false;
                }),
                contentPadding: EdgeInsets.zero,
              ),
          ],
        ),
      ),
      actions: sourceDialogActions(
        onCancel: () => Navigator.pop(context),
        onPrimary: _save,
      ),
    );
  }

  Future<void> _save() async {
    final lib = await ref.read(profileProvider.future);
    final active = lib.activeProfile!;
    final cfg = Map<String, dynamic>.from(active.config);
    final imu = Map<String, dynamic>.from(
      (cfg['imu'] as Map<String, dynamic>?) ?? const {},
    );
    imu['sample_rate_hz'] = _rate;
    final slot = Map<String, dynamic>.from(
      (imu['imu${widget.imuIndex}'] as Map<String, dynamic>?) ?? const {},
    );
    slot['enabled'] = _enabled;
    slot['accel_range_g'] = _accelG;
    slot['gyro_range_dps'] = _gyroDps;
    slot['channels'] = _channels;
    imu['imu${widget.imuIndex}'] = slot;
    cfg['imu'] = imu;
    await ref
        .read(profileProvider.notifier)
        .updateConfig(active.profileId, cfg);
    if (mounted) Navigator.pop(context);
  }
}
