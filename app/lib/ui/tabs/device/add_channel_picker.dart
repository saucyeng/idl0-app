import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/channel_sources/factories.dart';
import '../../../providers/profile_provider.dart';
import 'source_dialogs/dialog_chrome.dart';

/// Shows the modal `+ Add channel…` picker.
///
/// Lists every entry registered in `kChannelSourceFactories`. On selection,
/// mutates the active profile's config to append a new channel entry to the
/// appropriate array (`config.analog.channels[]` or `config.digital.channels[]`),
/// then persists via `profileProvider.updateConfig`.
Future<void> showAddChannelPicker(BuildContext context, WidgetRef ref) async {
  final picked =
      await showModalBottomSheet<MapEntry<String, ChannelSourcePickerEntry>>(
    context: context,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: sourceDialogTitle('Add channel'),
          ),
          const Divider(height: 1),
          for (final entry in kChannelSourceFactories.entries)
            ListTile(
              title: Text(entry.value.label),
              subtitle: Text(entry.value.description),
              onTap: () => Navigator.pop(ctx, entry),
            ),
        ],
      ),
    ),
  );
  if (picked == null) return;
  await _appendChannel(ref, picked.key);
}

Future<void> _appendChannel(WidgetRef ref, String factoryKey) async {
  final lib = await ref.read(profileProvider.future);
  final active = lib.activeProfile;
  if (active == null) return;
  final cfg = Map<String, dynamic>.from(active.config);

  switch (factoryKey) {
    case 'analog':
      final analog = Map<String, dynamic>.from(
        (cfg['analog'] as Map<String, dynamic>?) ??
            const {'sample_rate_hz': 100, 'channels': <Map<String, dynamic>>[]},
      );
      final channels = List<Map<String, dynamic>>.from(
        (analog['channels'] as List?) ?? const [],
      );
      channels.add(<String, dynamic>{
        'key': 'analog_${channels.length}',
        'label': 'New analog',
        'adc_pin': 0,
        'units': '',
        'scale': 1.0,
        'offset': 0.0,
        'enabled': true,
      });
      analog['channels'] = channels;
      cfg['analog'] = analog;
      break;

    case 'marker':
      final digital = Map<String, dynamic>.from(
        (cfg['digital'] as Map<String, dynamic>?) ??
            const {'channels': <Map<String, dynamic>>[]},
      );
      final channels = List<Map<String, dynamic>>.from(
        (digital['channels'] as List?) ?? const [],
      );
      channels.add(<String, dynamic>{
        'key': 'marker_${channels.length}',
        'label': 'Marker ${channels.length + 1}',
        'kind': 'marker',
        'gpio_pin': 21,
        'active_low': true,
        'debounce_ms': 20,
        'enabled': true,
      });
      digital['channels'] = channels;
      cfg['digital'] = digital;
      break;

    case 'wheel_front':
    case 'wheel_rear':
      final slot = factoryKey == 'wheel_front' ? 'front' : 'rear';
      final wheel = Map<String, dynamic>.from(
        (cfg['wheel_speed'] as Map<String, dynamic>?) ?? const {},
      );
      final slotCfg = Map<String, dynamic>.from(
        (wheel[slot] as Map<String, dynamic>?) ?? const {},
      );
      slotCfg['enabled'] = true;
      slotCfg.putIfAbsent('points_per_revolution', () => 12);
      slotCfg.putIfAbsent('wheel_circumference_mm', () => 2300);
      wheel[slot] = slotCfg;
      cfg['wheel_speed'] = wheel;
      break;

    default:
      throw StateError('Unknown channel factory: $factoryKey');
  }

  await ref.read(profileProvider.notifier).updateConfig(active.profileId, cfg);
}
