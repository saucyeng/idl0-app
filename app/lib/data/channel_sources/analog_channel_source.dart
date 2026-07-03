import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/tabs/device/source_dialogs/analog_dialog.dart';
import '../channel_source.dart';

/// One user-added analog (ADC) channel.
///
/// Cardinality: 0..N per profile. Each instance is keyed by [key] —
/// the entry's `key` field inside the `config.analog.channels[]` array.
/// Sample rate is shared across all analog channels (`config.analog.sample_rate_hz`)
/// because the ESP32-C6 ADC scheduler round-robins between configured pins.
class AnalogChannelSource extends ChannelSource {
  /// Creates an [AnalogChannelSource].
  AnalogChannelSource({
    required this.key,
    required this.analogConfig,
    required this.channelIdBase,
  });

  /// Identifier inside `config.analog.channels[]` (e.g. `strain_left`).
  final String key;

  /// View into `config['analog']`.
  final Map<String, dynamic> analogConfig;

  /// `channel_id` this source occupies in the registry when enabled.
  final int channelIdBase;

  Map<String, dynamic>? get _entry {
    final list = analogConfig['channels'];
    if (list is! List) return null;
    for (final raw in list) {
      if (raw is Map<String, dynamic> && raw['key'] == key) return raw;
    }
    return null;
  }

  @override
  String get sourceKey => 'analog/$key';

  @override
  String get sourceLabel => (_entry?['label'] as String?) ?? key;

  @override
  int? get sampleRateHz => analogConfig['sample_rate_hz'] as int?;

  @override
  bool get enabled => (_entry?['enabled'] as bool?) ?? false;

  @override
  List<ChannelRow> get channels {
    final e = _entry;
    if (e == null) return const [];
    return [
      ChannelRow(
        channelName: (e['label'] as String?) ?? key,
        units: (e['units'] as String?) ?? '',
        scale: ((e['scale'] as num?) ?? 1.0).toDouble(),
        offset: ((e['offset'] as num?) ?? 0.0).toDouble(),
        enabled: enabled,
        buildDialog: (_, __) => AnalogChannelDialog(channelKey: key),
      ),
    ];
  }

  @override
  List<RegistryEntry> resolveRegistryEntries() {
    if (!enabled) return const [];
    final e = _entry!;
    return [
      RegistryEntry(
        channelId: channelIdBase,
        dataType: DataType.u16,
        sampleRateHz: sampleRateHz ?? 0,
        scale: ((e['scale'] as num?) ?? 1.0).toDouble(),
        offset: ((e['offset'] as num?) ?? 0.0).toDouble(),
        name: (e['label'] as String?) ?? key,
        units: (e['units'] as String?) ?? '',
      ),
    ];
  }

  @override
  Widget buildSourceDialog(BuildContext context, WidgetRef ref) =>
      AnalogChannelDialog(channelKey: key);

  /// Used by `kChannelSourceFactories` to create a fresh empty analog
  /// source when the user picks "Analog channel" in `+ Add channel…`.
  static AnalogChannelSource empty() => AnalogChannelSource(
        key: '__new__',
        analogConfig: const {
          'sample_rate_hz': 100,
          'channels': <Map<String, dynamic>>[],
        },
        channelIdBase: 0,
      );
}
