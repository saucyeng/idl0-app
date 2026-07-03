import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../providers/profile_provider.dart';
import '../../../brand/brand.dart';
import 'dialog_chrome.dart';

/// Per-entry analog channel dialog. Edits one entry in
/// `config.analog.channels[]` and supports deletion.
class AnalogChannelDialog extends ConsumerStatefulWidget {
  /// Creates an [AnalogChannelDialog] for the entry whose `key` matches
  /// [channelKey].
  const AnalogChannelDialog({super.key, required this.channelKey});

  /// Entry key (e.g. `strain_left`).
  final String channelKey;

  @override
  ConsumerState<AnalogChannelDialog> createState() =>
      _AnalogChannelDialogState();
}

class _AnalogChannelDialogState extends ConsumerState<AnalogChannelDialog> {
  late Map<String, dynamic> _draft;

  @override
  void initState() {
    super.initState();
    final analog = ref
            .read(profileProvider)
            .value!
            .activeProfile!
            .config['analog'] as Map<String, dynamic>? ??
        const <String, dynamic>{};
    final list = (analog['channels'] as List?) ?? const [];
    final entry = list.firstWhere(
      (e) => e is Map<String, dynamic> && e['key'] == widget.channelKey,
      orElse: () => <String, dynamic>{
        'key': widget.channelKey,
        'label': widget.channelKey,
        'adc_pin': 0,
        'units': '',
        'scale': 1.0,
        'offset': 0.0,
        'enabled': true,
      },
    ) as Map<String, dynamic>;
    _draft = Map<String, dynamic>.from(entry);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: sourceDialogTitle('Analog: ${_draft['key']}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              initialValue: _draft['label'] as String? ?? '',
              decoration: const InputDecoration(labelText: 'Label'),
              onChanged: (v) => _draft['label'] = v,
            ),
            TextFormField(
              initialValue: '${_draft['adc_pin'] ?? 0}',
              decoration: const InputDecoration(labelText: 'ADC pin (GPIO #)'),
              keyboardType: TextInputType.number,
              onChanged: (v) =>
                  _draft['adc_pin'] = int.tryParse(v) ?? _draft['adc_pin'],
            ),
            TextFormField(
              initialValue: _draft['units'] as String? ?? '',
              decoration: const InputDecoration(labelText: 'Units'),
              onChanged: (v) => _draft['units'] = v,
            ),
            TextFormField(
              initialValue: '${_draft['scale'] ?? 1.0}',
              decoration: const InputDecoration(labelText: 'Scale'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              onChanged: (v) =>
                  _draft['scale'] = double.tryParse(v) ?? _draft['scale'],
            ),
            TextFormField(
              initialValue: '${_draft['offset'] ?? 0.0}',
              decoration: const InputDecoration(labelText: 'Offset'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              onChanged: (v) =>
                  _draft['offset'] = double.tryParse(v) ?? _draft['offset'],
            ),
            SwitchListTile(
              title: const Text('Enabled'),
              value: (_draft['enabled'] as bool?) ?? false,
              activeThumbColor: brandGood,
              onChanged: (v) => setState(() => _draft['enabled'] = v),
            ),
          ],
        ),
      ),
      actions: sourceDialogActions(
        onCancel: () => Navigator.pop(context),
        onPrimary: _save,
        destructiveLabel: 'Delete',
        onDestructive: _delete,
      ),
    );
  }

  Future<void> _save() async => _commit((channels) {
        final idx = channels.indexWhere((e) => e['key'] == widget.channelKey);
        if (idx >= 0) {
          channels[idx] = Map<String, dynamic>.from(_draft);
        } else {
          channels.add(Map<String, dynamic>.from(_draft));
        }
      });

  Future<void> _delete() async => _commit(
        (channels) =>
            channels.removeWhere((e) => e['key'] == widget.channelKey),
      );

  Future<void> _commit(
    void Function(List<Map<String, dynamic>>) mutate,
  ) async {
    final lib = await ref.read(profileProvider.future);
    final active = lib.activeProfile!;
    final cfg = Map<String, dynamic>.from(active.config);
    final analog = Map<String, dynamic>.from(
      (cfg['analog'] as Map<String, dynamic>?) ?? const {},
    );
    final channels = List<Map<String, dynamic>>.from(
      (analog['channels'] as List?) ?? const [],
    );
    mutate(channels);
    analog['channels'] = channels;
    cfg['analog'] = analog;
    await ref
        .read(profileProvider.notifier)
        .updateConfig(active.profileId, cfg);
    if (mounted) Navigator.pop(context);
  }
}
