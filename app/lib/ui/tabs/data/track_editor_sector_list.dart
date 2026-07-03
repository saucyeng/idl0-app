import 'package:flutter/material.dart';

import '../../../data/lap_detector.dart';

/// Reorderable list of sector gates for the Track editor. Order matters —
/// sector index in the lap table follows list order.
class TrackEditorSectorList extends StatelessWidget {
  /// Creates a [TrackEditorSectorList].
  const TrackEditorSectorList({
    super.key,
    required this.gates,
    required this.onChanged,
    required this.onAdd,
  });

  /// Current sector list (the draft Track's `sectorGates`).
  final List<SectorGate> gates;

  /// Called when the user mutates the list (rename / delete / reorder).
  final void Function(List<SectorGate> next) onChanged;

  /// Invoked when the user clicks "+ Add sector gate".
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorder: (oldIndex, newIndex) {
            var ni = newIndex;
            if (ni > oldIndex) ni -= 1;
            final next = [...gates];
            final item = next.removeAt(oldIndex);
            next.insert(ni, item);
            onChanged(next);
          },
          children: [
            for (var i = 0; i < gates.length; i++)
              _row(context, i, gates[i]),
          ],
        ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add sector gate'),
          onPressed: onAdd,
        ),
      ],
    );
  }

  Widget _row(BuildContext context, int i, SectorGate g) {
    return Padding(
      key: ValueKey('sector-$i'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: i,
            child: const Icon(Icons.drag_indicator, size: 18),
          ),
          const SizedBox(width: 4),
          Expanded(child: Text(g.name.isEmpty ? 'Sector ${i + 1}' : g.name)),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: () => _rename(context, i, g),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: () {
              final next = [...gates]..removeAt(i);
              onChanged(next);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context, int i, SectorGate g) async {
    final ctrl = TextEditingController(text: g.name);
    final s = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename sector'),
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
      final next = [...gates]
        ..[i] = SectorGate(name: s, gate: g.gate);
      onChanged(next);
    }
  }
}
