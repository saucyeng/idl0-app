import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/tabs/device/source_dialogs/gps_dialog.dart';
import '../channel_source.dart';

/// (channel name, units, data type) per §5.7 GPS channel set.
const _kGpsChannels = <(String, String, DataType)>[
  ('GPS_EpochMs', 'ms', DataType.i32),
  ('GPS_Latitude', 'deg', DataType.i32),
  ('GPS_Longitude', 'deg', DataType.i32),
  ('GPS_Altitude', 'm', DataType.i16),
  ('GPS_SpeedKmh', 'kmh', DataType.u16),
  ('GPS_Heading', 'deg', DataType.u16),
  ('GPS_FixQuality', '', DataType.u8),
  ('GPS_Satellites', '', DataType.u8),
];

/// GPS source — single instance per profile, always enabled in v1 hardware.
///
/// Contributes the 8 standard GPS-derived channels (lat/lon as i32×1e7,
/// altitude as i16×10, speed/heading as u16×100, etc — see §5.6).
class GpsSource extends ChannelSource {
  /// Creates a [GpsSource].
  ///
  /// [gpsConfig] is the `config['gps']` map. [channelIdBase] is the first
  /// `channel_id` for the 8 derived channels.
  GpsSource({required this.gpsConfig, required this.channelIdBase});

  /// View into `config['gps']`.
  final Map<String, dynamic> gpsConfig;

  /// First `channel_id` for this source's 8 channels.
  final int channelIdBase;

  @override
  String get sourceKey => 'gps';

  @override
  String get sourceLabel => 'GPS';

  @override
  int? get sampleRateHz => gpsConfig['sample_rate_hz'] as int?;

  @override
  bool get enabled => true; // GPS is always on in v1 hardware.

  @override
  List<ChannelRow> get channels => [
        for (final c in _kGpsChannels)
          ChannelRow(
            channelName: c.$1,
            units: c.$2,
            scale: 1.0,
            offset: 0.0,
            enabled: true,
            // GPS rows have no individual dialog — they are read-only.
            buildDialog: (_, __) => const SizedBox.shrink(),
          ),
      ];

  @override
  List<RegistryEntry> resolveRegistryEntries() {
    final rate = sampleRateHz ?? 5;
    var nextId = channelIdBase;
    return [
      for (final c in _kGpsChannels)
        RegistryEntry(
          channelId: nextId++,
          dataType: c.$3,
          sampleRateHz: rate,
          scale: 1.0,
          offset: 0.0,
          name: c.$1,
          units: c.$2,
        ),
    ];
  }

  @override
  Widget buildSourceDialog(BuildContext context, WidgetRef ref) =>
      const GpsSettingsDialog();
}
