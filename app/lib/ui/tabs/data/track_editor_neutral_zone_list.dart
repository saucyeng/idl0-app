import 'package:flutter/material.dart';

import '../../../data/lap_timing.dart';

/// Neutral zone list for the Track editor. Each entry is a `(name, enter,
/// exit)` triple; the user can rename the zone, edit either gate, or delete
/// the zone.
class TrackEditorNeutralZoneList extends StatelessWidget {
  /// Creates a [TrackEditorNeutralZoneList].
  const TrackEditorNeutralZoneList({
    super.key,
    required this.zones,
    required this.onChanged,
    required this.onAdd,
  });

  /// Current neutral-zone list.
  final List<NeutralZone> zones;

  /// Called when the user mutates the list.
  final void Function(List<NeutralZone> next) onChanged;

  /// Invoked when the user clicks "+ Add neutral zone".
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < zones.length; i++) _row(context, i, zones[i]),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add neutral zone'),
          onPressed: onAdd,
        ),
      ],
    );
  }

  Widget _row(BuildContext context, int i, NeutralZone z) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  z.name.isEmpty ? 'Neutral zone ${i + 1}' : z.name,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () => _rename(context, i, z),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  final next = [...zones]..removeAt(i);
                  onChanged(next);
                },
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Text(
              'Enter: ${z.enter.name.isEmpty ? '(unnamed)' : z.enter.name}',
              style: const TextStyle(color: Colors.grey),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Text(
              'Exit: ${z.exit.name.isEmpty ? '(unnamed)' : z.exit.name}',
              style: const TextStyle(color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context, int i, NeutralZone z) async {
    final ctrl = TextEditingController(text: z.name);
    final s = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename neutral zone'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (s != null) {
      final next = [...zones]
        ..[i] = NeutralZone(name: s, enter: z.enter, exit: z.exit);
      onChanged(next);
    }
  }
}
