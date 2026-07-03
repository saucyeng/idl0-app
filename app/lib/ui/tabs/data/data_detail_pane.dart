import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/data_results_provider.dart';
import '../../../providers/detail_selection_provider.dart';
import 'session_detail_card.dart';
import 'track_results.dart';
import 'venue_detail_card.dart';

/// Switch widget that renders the active detail card based on
/// [detailSelectionProvider]. Returns [SizedBox.shrink] when no selection
/// is active so the parent column can hide entirely. See `docs/IDL0_SPEC.md §24`.
class DataDetailPane extends ConsumerWidget {
  /// Creates a [DataDetailPane].
  const DataDetailPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sel = ref.watch(detailSelectionProvider);
    switch (sel.kind) {
      case DetailKind.none:
        return const SizedBox.shrink();
      case DetailKind.session:
        return SessionDetailCard(sessionId: sel.entityId!);
      case DetailKind.venue:
        return VenueDetailCard(venueName: sel.entityId!);
      case DetailKind.track:
        // TrackDetailPanel takes a TrackRow from filteredTrackRowsProvider.
        // If the row is filtered out of the current view, fall back to a
        // small "not in current view" state — the user can clear filters
        // to bring it back, or pick another Track from the list.
        final rows = ref.watch(filteredTrackRowsProvider).value ?? const [];
        TrackRow? row;
        for (final r in rows) {
          if (r.track.trackId == sel.entityId) {
            row = r;
            break;
          }
        }
        if (row == null) {
          return Material(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(child: Text('Track not in current view')),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => ref
                            .read(detailSelectionProvider.notifier)
                            .clear(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Clear active filters or pick a Track from the list to '
                    'open it here.',
                  ),
                ],
              ),
            ),
          );
        }
        return TrackDetailPanel(
          row: row,
          onClose: () =>
              ref.read(detailSelectionProvider.notifier).clear(),
        );
    }
  }
}
