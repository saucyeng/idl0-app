import 'package:flutter/material.dart';

import '../../../data/track.dart';

/// Three-section sidebar for [TrackEditorModal]. See `docs/IDL0_SPEC.md §24`.
class TrackEditorSidebar extends StatelessWidget {
  /// Creates a [TrackEditorSidebar].
  const TrackEditorSidebar({
    super.key,
    required this.draft,
    required this.onChanged,
    required this.detailsSlot,
    required this.lapTimingSlot,
    required this.sectorListSlot,
    required this.neutralZoneListSlot,
  });

  /// The in-progress edited Track. Read-only (the slots own mutation).
  final Track draft;

  /// Called when one of the slot widgets requests a draft replacement.
  final void Function(Track next) onChanged;

  /// Widget for the TRACK region (Name + Venue fields).
  final Widget detailsSlot;

  /// Widget for the LAP TIMING region.
  final Widget lapTimingSlot;

  /// Widget for the SECTOR GATES region.
  final Widget sectorListSlot;

  /// Widget for the NEUTRAL ZONES region.
  final Widget neutralZoneListSlot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          const _SectionHeader(label: 'TRACK'),
          detailsSlot,
          const Divider(height: 24),
          const _SectionHeader(label: 'LAP TIMING'),
          lapTimingSlot,
          const Divider(height: 24),
          _SectionHeader(
            label: 'SECTOR GATES (${draft.sectorGates.length})',
          ),
          sectorListSlot,
          const Divider(height: 24),
          _SectionHeader(
            label: 'NEUTRAL ZONES (${draft.neutralZones.length})',
          ),
          neutralZoneListSlot,
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      );
}
