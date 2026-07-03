import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/tabs/device/source_dialogs/wheel_dialog.dart';
import '../channel_source.dart';

/// One wheel-speed slot (front or rear).
///
/// Event-driven (one CHANNEL_SAMPLE record per Hall-effect pulse), u32
/// monotonic counter. Both slots default disabled per §8.
class WheelSource extends ChannelSource {
  /// Creates a [WheelSource].
  ///
  /// [slot] is `'front'` or `'rear'`. [wheelConfig] is the
  /// `config['wheel_speed']` map.
  WheelSource({
    required this.slot,
    required this.wheelConfig,
    required this.channelIdBase,
  });

  /// Slot identifier — `'front'` or `'rear'`.
  final String slot;

  /// View into `config['wheel_speed']`.
  final Map<String, dynamic> wheelConfig;

  /// `channel_id` this source occupies in the registry when enabled.
  final int channelIdBase;

  Map<String, dynamic> get _slot =>
      (wheelConfig[slot] as Map<String, dynamic>?) ?? const {};

  String get _channelName =>
      'Wheel${slot[0].toUpperCase()}${slot.substring(1)}';

  @override
  String get sourceKey => 'wheel_$slot';

  @override
  String get sourceLabel => slot == 'front' ? 'Wheel Front' : 'Wheel Rear';

  @override
  int? get sampleRateHz => null; // Event-driven.

  @override
  bool get enabled => (_slot['enabled'] as bool?) ?? false;

  @override
  List<ChannelRow> get channels => [
        ChannelRow(
          channelName: _channelName,
          units: 'pulse',
          scale: 1.0,
          offset: 0.0,
          enabled: enabled,
          buildDialog: (_, __) => const SizedBox.shrink(),
        ),
      ];

  @override
  List<RegistryEntry> resolveRegistryEntries() {
    if (!enabled) return const [];
    return [
      RegistryEntry(
        channelId: channelIdBase,
        dataType: DataType.u32,
        sampleRateHz: 0,
        scale: 1.0,
        offset: 0.0,
        name: _channelName,
        units: 'pulse',
      ),
    ];
  }

  @override
  Widget buildSourceDialog(BuildContext context, WidgetRef ref) =>
      WheelSettingsDialog(slot: slot);
}
