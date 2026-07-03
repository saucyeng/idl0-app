import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../providers/profile_provider.dart';
import '../../../brand/brand.dart';
import 'dialog_chrome.dart';

/// GPS source dialog — sample rate, dynamic model, NMEA sentences, SBAS.
class GpsSettingsDialog extends ConsumerStatefulWidget {
  /// Creates a [GpsSettingsDialog].
  const GpsSettingsDialog({super.key});

  @override
  ConsumerState<GpsSettingsDialog> createState() => _GpsSettingsDialogState();
}

class _GpsSettingsDialogState extends ConsumerState<GpsSettingsDialog> {
  static const _kDynamicModels = <String>[
    'portable',
    'pedestrian',
    'automotive',
    'sea',
    'airborne',
  ];
  static const _kNmeaSentences = <String>[
    'GGA',
    'RMC',
    'GSA',
    'GSV',
    'GLL',
    'VTG',
  ];

  late int _rate;
  late String _model;
  late Set<String> _sentences;
  late bool _sbas;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(profileProvider).value!.activeProfile!.config['gps']
            as Map<String, dynamic>? ??
        const <String, dynamic>{};
    _rate = (cfg['sample_rate_hz'] as int?) ?? 5;
    _model = (cfg['dynamic_model'] as String?) ?? 'automotive';
    _sentences = {
      ...?(cfg['nmea_sentences'] as List?)?.cast<String>(),
    };
    _sbas = (cfg['sbas_enabled'] as bool?) ?? true;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: sourceDialogTitle('GPS settings'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('Sample rate: $_rate Hz'),
              subtitle: Slider(
                value: _rate.toDouble(),
                min: 1,
                max: 10,
                divisions: 9,
                label: '$_rate',
                onChanged: (v) => setState(() => _rate = v.round()),
              ),
            ),
            ListTile(
              title: const Text('Dynamic model'),
              subtitle: DropdownButton<String>(
                value: _model,
                isExpanded: true,
                items: [
                  for (final m in _kDynamicModels)
                    DropdownMenuItem(value: m, child: Text(m)),
                ],
                onChanged: (v) => setState(() => _model = v ?? _model),
              ),
            ),
            const Divider(),
            sourceDialogSectionLabel('NMEA sentences'),
            for (final s in _kNmeaSentences)
              CheckboxListTile(
                title: Text(s),
                contentPadding: EdgeInsets.zero,
                activeColor: brandGood,
                value: _sentences.contains(s),
                onChanged: (v) => setState(() {
                  if (v == true) {
                    _sentences.add(s);
                  } else {
                    _sentences.remove(s);
                  }
                }),
              ),
            SwitchListTile(
              title: const Text('SBAS enabled'),
              value: _sbas,
              activeThumbColor: brandGood,
              onChanged: (v) => setState(() => _sbas = v),
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
    cfg['gps'] = <String, dynamic>{
      'sample_rate_hz': _rate,
      'dynamic_model': _model,
      'nmea_sentences': _sentences.toList()..sort(),
      'sbas_enabled': _sbas,
    };
    await ref
        .read(profileProvider.notifier)
        .updateConfig(active.profileId, cfg);
    if (mounted) Navigator.pop(context);
  }
}
