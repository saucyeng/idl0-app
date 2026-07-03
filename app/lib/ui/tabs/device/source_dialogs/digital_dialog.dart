import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../providers/profile_provider.dart';
import '../../../brand/brand.dart';
import 'dialog_chrome.dart';

/// Per-entry digital channel dialog. Edits one entry in
/// `config.digital.channels[]` and supports deletion. Spec 1 ships the
/// `marker` kind; `level` and `pwm` are forward-compatible.
class DigitalChannelDialog extends ConsumerStatefulWidget {
  /// Creates a [DigitalChannelDialog] for the entry whose `key` matches
  /// [channelKey].
  const DigitalChannelDialog({super.key, required this.channelKey});

  /// Entry key (e.g. `marker_btn`).
  final String channelKey;

  @override
  ConsumerState<DigitalChannelDialog> createState() =>
      _DigitalChannelDialogState();
}

class _DigitalChannelDialogState extends ConsumerState<DigitalChannelDialog> {
  late Map<String, dynamic> _draft;

  @override
  void initState() {
    super.initState();
    final digital = ref
            .read(profileProvider)
            .value!
            .activeProfile!
            .config['digital'] as Map<String, dynamic>? ??
        const <String, dynamic>{};
    final list = (digital['channels'] as List?) ?? const [];
    final entry = list.firstWhere(
      (e) => e is Map<String, dynamic> && e['key'] == widget.channelKey,
      orElse: () => <String, dynamic>{
        'key': widget.channelKey,
        'label': widget.channelKey,
        'kind': 'marker',
        'gpio_pin': 21,
        'active_low': true,
        'debounce_ms': 20,
        'enabled': true,
      },
    ) as Map<String, dynamic>;
    _draft = Map<String, dynamic>.from(entry);
  }

  @override
  Widget build(BuildContext context) {
    final kind = (_draft['kind'] as String?) ?? 'marker';
    return AlertDialog(
      title: sourceDialogTitle('Digital: ${_draft['key']} ($kind)'),
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
              initialValue: '${_draft['gpio_pin'] ?? 21}',
              decoration: const InputDecoration(labelText: 'GPIO pin'),
              keyboardType: TextInputType.number,
              onChanged: (v) =>
                  _draft['gpio_pin'] = int.tryParse(v) ?? _draft['gpio_pin'],
            ),
            SwitchListTile(
              title: const Text('Active low (internal pull-up)'),
              value: (_draft['active_low'] as bool?) ?? true,
              activeThumbColor: brandGood,
              onChanged: (v) => setState(() => _draft['active_low'] = v),
            ),
            TextFormField(
              initialValue: '${_draft['debounce_ms'] ?? 20}',
              decoration: const InputDecoration(labelText: 'Debounce (ms)'),
              keyboardType: TextInputType.number,
              onChanged: (v) => _draft['debounce_ms'] =
                  int.tryParse(v) ?? _draft['debounce_ms'],
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
    final digital = Map<String, dynamic>.from(
      (cfg['digital'] as Map<String, dynamic>?) ?? const {},
    );
    final channels = List<Map<String, dynamic>>.from(
      (digital['channels'] as List?) ?? const [],
    );
    mutate(channels);
    digital['channels'] = channels;
    cfg['digital'] = digital;
    await ref
        .read(profileProvider.notifier)
        .updateConfig(active.profileId, cfg);
    if (mounted) Navigator.pop(context);
  }
}
