import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../providers/profile_provider.dart';
import '../../../brand/brand.dart';
import 'dialog_chrome.dart';

/// Wheel source dialog — enable, points-per-revolution, wheel circumference.
class WheelSettingsDialog extends ConsumerStatefulWidget {
  /// Creates a [WheelSettingsDialog] for `'front'` or `'rear'`.
  const WheelSettingsDialog({super.key, required this.slot});

  /// `'front'` or `'rear'`.
  final String slot;

  @override
  ConsumerState<WheelSettingsDialog> createState() =>
      _WheelSettingsDialogState();
}

class _WheelSettingsDialogState extends ConsumerState<WheelSettingsDialog> {
  late bool _enabled;
  late int _ppr;
  late int _circ;

  @override
  void initState() {
    super.initState();
    final cfg = (ref
            .read(profileProvider)
            .value!
            .activeProfile!
            .config['wheel_speed'] as Map<String, dynamic>?) ??
        const {};
    final slot = (cfg[widget.slot] as Map<String, dynamic>?) ?? const {};
    _enabled = (slot['enabled'] as bool?) ?? false;
    _ppr = (slot['points_per_revolution'] as int?) ?? 12;
    _circ = (slot['wheel_circumference_mm'] as int?) ?? 2300;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: sourceDialogTitle('Wheel ${widget.slot}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            title: const Text('Enabled'),
            value: _enabled,
            activeThumbColor: brandGood,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          TextFormField(
            initialValue: '$_ppr',
            decoration:
                const InputDecoration(labelText: 'Points per revolution'),
            keyboardType: TextInputType.number,
            onChanged: (v) => _ppr = int.tryParse(v) ?? _ppr,
          ),
          TextFormField(
            initialValue: '$_circ',
            decoration:
                const InputDecoration(labelText: 'Wheel circumference (mm)'),
            keyboardType: TextInputType.number,
            onChanged: (v) => _circ = int.tryParse(v) ?? _circ,
          ),
        ],
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
    final wheel = Map<String, dynamic>.from(
      (cfg['wheel_speed'] as Map<String, dynamic>?) ?? const {},
    );
    wheel[widget.slot] = <String, dynamic>{
      'enabled': _enabled,
      'points_per_revolution': _ppr,
      'wheel_circumference_mm': _circ,
    };
    cfg['wheel_speed'] = wheel;
    await ref
        .read(profileProvider.notifier)
        .updateConfig(active.profileId, cfg);
    if (mounted) Navigator.pop(context);
  }
}
