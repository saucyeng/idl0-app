import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:idl0/data/cursor_pair.dart';

/// Manages the synchronized A/B cursor pair for one worksheet.
///
/// Cursors are stored as elapsed seconds from session start. Both values
/// independently nullable — a fresh worksheet has both unset
/// (`CursorPair()` with `aSecs == null && bSecs == null`).
class CursorNotifier extends StateNotifier<CursorPair> {
  /// Creates a [CursorNotifier] with no cursors placed.
  CursorNotifier() : super(const CursorPair());

  /// Places cursor A at [timeSeconds].
  void setA(double timeSeconds) => state = state.copyWith(aSecs: timeSeconds);

  /// Places cursor B at [timeSeconds].
  void setB(double timeSeconds) => state = state.copyWith(bSecs: timeSeconds);

  /// Removes cursor A; cursor B is unchanged.
  void clearA() => state = state.copyWith(aSecs: null);

  /// Removes cursor B; cursor A is unchanged.
  void clearB() => state = state.copyWith(bSecs: null);

  /// Removes both cursors.
  void clearBoth() => state = const CursorPair();
}

/// Synchronized A/B cursor pair in seconds for the worksheet identified by
/// [worksheetId]. Cursor A is the historical "the cursor" — set by chart
/// taps, used by the worksheet bar's time readout. Cursor B is set
/// explicitly via the chart context menu and used for delta readouts and
/// "Zoom to Cursors". All charts in the same worksheet read this provider
/// and render both cursors as vertical lines (A and B in different colors).
final cursorProvider =
    StateNotifierProvider.family<CursorNotifier, CursorPair, String>(
  (ref, worksheetId) => CursorNotifier(),
);

/// Transient hover-cursor position in session-relative seconds for the
/// worksheet identified by [worksheetId]. Same scope and lifecycle as before
/// the CursorPair migration — only [cursorProvider]'s shape changed, not
/// hover behavior.
final hoverCursorProvider = StateProvider.family<double?, String>(
  (ref, worksheetId) => null,
);
