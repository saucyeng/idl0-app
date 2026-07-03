import 'package:flutter/material.dart';

import '../../../data/lap_timing.dart';

/// Sidebar widget for the LAP TIMING region of the Track editor. Hosts
/// Circuit/Point-to-Point tabs and the gate rows for the active mode.
/// See `docs/IDL0_SPEC.md §24`.
class TrackEditorLapTimingTabs extends StatefulWidget {
  /// Creates a [TrackEditorLapTimingTabs].
  const TrackEditorLapTimingTabs({
    super.key,
    required this.value,
    required this.onChanged,
    required this.onPlaceCircuit,
    required this.onPlaceStart,
    required this.onPlaceFinish,
  });

  /// Current lap-timing value. `null` means "no timing configured yet".
  final LapTiming? value;

  /// Called when the user mutates the timing (mode switch, gate rename,
  /// gate delete).
  final void Function(LapTiming?) onChanged;

  /// Invoked when the user requests placement of a Circuit gate.
  final VoidCallback onPlaceCircuit;

  /// Invoked when the user requests placement of a Start gate (P2P).
  final VoidCallback onPlaceStart;

  /// Invoked when the user requests placement of a Finish gate (P2P).
  final VoidCallback onPlaceFinish;

  @override
  State<TrackEditorLapTimingTabs> createState() =>
      _TrackEditorLapTimingTabsState();
}

class _TrackEditorLapTimingTabsState extends State<TrackEditorLapTimingTabs> {
  /// Tracks the user's preferred mode locally so P2P tab is selectable even
  /// when no gates have been placed yet (`value == null`).
  late bool _circuitMode;

  @override
  void initState() {
    super.initState();
    _circuitMode = switch (widget.value) {
      Circuit() => true,
      PointToPoint() => false,
      null => true, // default to Circuit when uninitialised
    };
  }

  @override
  void didUpdateWidget(TrackEditorLapTimingTabs old) {
    super.didUpdateWidget(old);
    // Sync local mode when the parent value's variant changes (e.g. after an
    // undo or external reset). A null value preserves the user's local choice.
    switch (widget.value) {
      case Circuit():
        _circuitMode = true;
      case PointToPoint():
        _circuitMode = false;
      case null:
        break; // keep whatever the user last selected
    }
  }

  Future<void> _setMode({required bool circuit}) async {
    final v = widget.value;
    if (circuit) {
      switch (v) {
        case Circuit():
          return; // no-op
        case PointToPoint(:final start, :final finish):
          // ignore: unused_local_variable
          final _ = finish;
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Use Start as Circuit gate?'),
              content: const Text('Finish gate will be removed.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Convert'),
                ),
              ],
            ),
          );
          if (ok == true) {
            widget.onChanged(Circuit(startFinish: start));
          }
        case null:
          // value is null — just flip local mode so the correct body renders.
          setState(() => _circuitMode = true);
      }
    } else {
      // Going to P2P.
      switch (v) {
        case Circuit(:final startFinish):
          // Promote existing gate to Start; use a copy as placeholder Finish
          // so the finish row shows "[+ Place Finish gate]" prompt.
          widget.onChanged(
            PointToPoint(start: startFinish, finish: startFinish),
          );
        case PointToPoint():
          return; // no-op
        case null:
          // value is null — just flip local mode so the correct body renders.
          setState(() => _circuitMode = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = widget.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('Circuit')),
            ButtonSegment(value: false, label: Text('Point-to-Point')),
          ],
          selected: {_circuitMode},
          onSelectionChanged: (s) => _setMode(circuit: s.first),
        ),
        const SizedBox(height: 8),
        if (_circuitMode)
          _circuitBody(v, theme)
        else
          _pointToPointBody(v, theme),
      ],
    );
  }

  Widget _circuitBody(LapTiming? v, ThemeData theme) {
    final c = (v is Circuit) ? v : null;
    if (c == null) {
      return OutlinedButton.icon(
        icon: const Icon(Icons.add, size: 16),
        label: const Text('Place Circuit gate'),
        onPressed: widget.onPlaceCircuit,
      );
    }
    return _GateRow(
      label: c.startFinish.name.isEmpty ? 'Start/Finish' : c.startFinish.name,
      onRename: (s) => widget.onChanged(
        Circuit(startFinish: c.startFinish.withName(s), name: c.name),
      ),
      onDelete: () => widget.onChanged(null),
      deleteRequiresConfirm: true,
    );
  }

  Widget _pointToPointBody(LapTiming? v, ThemeData theme) {
    final p = (v is PointToPoint) ? v : null;
    if (p == null) {
      return OutlinedButton.icon(
        icon: const Icon(Icons.add, size: 16),
        label: const Text('+ Place Start gate'),
        onPressed: widget.onPlaceStart,
      );
    }
    // The finish is a placeholder (copy of start) when the user has not
    // explicitly placed a distinct finish gate yet.
    final hasFinish = p.start != p.finish;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GateRow(
          label: p.start.name.isEmpty ? 'Start' : p.start.name,
          onRename: (s) => widget.onChanged(
            PointToPoint(start: p.start.withName(s), finish: p.finish),
          ),
          // Symmetric delete: when both gates are distinct, keep Finish as a
          // new Circuit gate. When Start is partial (finish == start), clear
          // everything.
          onDelete: () => hasFinish
              ? widget.onChanged(Circuit(startFinish: p.finish))
              : widget.onChanged(null),
          deleteRequiresConfirm: true,
        ),
        if (hasFinish)
          _GateRow(
            label: p.finish.name.isEmpty ? 'Finish' : p.finish.name,
            onRename: (s) => widget.onChanged(
              PointToPoint(start: p.start, finish: p.finish.withName(s)),
            ),
            onDelete: () => widget.onChanged(Circuit(startFinish: p.start)),
            deleteRequiresConfirm: true,
          )
        else
          OutlinedButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Place Finish gate'),
            onPressed: widget.onPlaceFinish,
          ),
      ],
    );
  }
}

class _GateRow extends StatelessWidget {
  const _GateRow({
    required this.label,
    required this.onRename,
    required this.onDelete,
    required this.deleteRequiresConfirm,
  });

  final String label;
  final void Function(String) onRename;
  final VoidCallback onDelete;
  final bool deleteRequiresConfirm;

  Future<void> _delete(BuildContext context) async {
    if (!deleteRequiresConfirm) {
      onDelete();
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this lap gate?'),
        content: const Text('Sessions visiting this Track will produce 0 laps '
            'until you place a new gate.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) onDelete();
  }

  Future<void> _rename(BuildContext context) async {
    final ctrl = TextEditingController(text: label);
    final s = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename gate'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          onSubmitted: (_) => Navigator.of(ctx).pop(ctrl.text),
        ),
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
    if (s != null) onRename(s);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: () => _rename(context),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: () => _delete(context),
          ),
        ],
      ),
    );
  }
}
