import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which detail card is open in the Data tab's right-pane (or bottom sheet
/// on narrow widths). See `docs/IDL0_SPEC.md §24`.
enum DetailKind {
  /// No detail card is open.
  none,

  /// Session detail card is open.
  session,

  /// Venue detail card is open.
  venue,

  /// Track detail card is open.
  track,
}

/// Immutable state for [detailSelectionProvider].
class DetailSelection {
  /// The kind of entity to show, or [DetailKind.none] for an empty pane.
  final DetailKind kind;

  /// The entity's identifier — sessionId, venueName, or trackId — or null
  /// when [kind] is [DetailKind.none].
  final String? entityId;

  /// Creates a [DetailSelection].
  const DetailSelection({this.kind = DetailKind.none, this.entityId});

  /// Sentinel for the empty state.
  static const none = DetailSelection();
}

/// Drives the right-pane detail card. Independent of `selectionProvider`
/// (which tracks the multi-select queued for Analyze).
class DetailSelectionNotifier extends Notifier<DetailSelection> {
  @override
  DetailSelection build() => DetailSelection.none;

  /// Open the session detail card. Tapping the same row twice closes the card.
  void showSession(String sessionId) => _toggle(DetailKind.session, sessionId);

  /// Open the venue detail card. Tapping the same venue twice closes the card.
  void showVenue(String venueName) => _toggle(DetailKind.venue, venueName);

  /// Open the track detail card. Tapping the same track twice closes the card.
  void showTrack(String trackId) => _toggle(DetailKind.track, trackId);

  /// Clear the pane.
  void clear() => state = DetailSelection.none;

  void _toggle(DetailKind kind, String entityId) {
    if (state.kind == kind && state.entityId == entityId) {
      state = DetailSelection.none;
    } else {
      state = DetailSelection(kind: kind, entityId: entityId);
    }
  }
}

/// Provider exposing the active detail-card target.
final detailSelectionProvider =
    NotifierProvider<DetailSelectionNotifier, DetailSelection>(
  DetailSelectionNotifier.new,
);
