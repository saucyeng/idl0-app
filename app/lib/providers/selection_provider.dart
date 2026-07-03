import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/tabs/analyze/chart_tile_cache.dart';

/// Mode of the active app-wide selection. The Analyze tab and other consumers
/// derive what to render from a single selection store; XOR semantics keep the
/// model honest — the user is either picking whole sessions OR individual laps,
/// never both at once.
enum SelectionMode {
  /// `selection.sessionIds` is the active set; lap keys are empty.
  session,

  /// `selection.lapKeys` is the active set; session ids are empty.
  lap,
}

/// One lap pinned for lap-granular comparison. Equality and `hashCode` are
/// field-wise so two `LapKey`s with the same `(sessionId, lapNumber)` are
/// interchangeable in [Set]s and [Map] keys.
class LapKey {
  /// UUID of the session the lap belongs to.
  final String sessionId;

  /// 1-based lap number within [sessionId].
  final int lapNumber;

  /// Creates a [LapKey].
  const LapKey({required this.sessionId, required this.lapNumber});

  @override
  bool operator ==(Object other) =>
      other is LapKey &&
      other.sessionId == sessionId &&
      other.lapNumber == lapNumber;

  @override
  int get hashCode => Object.hash(sessionId, lapNumber);

  @override
  String toString() => 'LapKey($sessionId#$lapNumber)';
}

/// Immutable selection state: the active [SelectionMode] plus the active set
/// for that mode. The inactive set is always empty — see [SelectionNotifier]
/// for the XOR invariant.
class Selection {
  /// Which kind of selection is active.
  final SelectionMode mode;

  /// UUIDs of selected sessions. Empty when [mode] is [SelectionMode.lap].
  final Set<String> sessionIds;

  /// Pinned `(sessionId, lapNumber)` pairs. Empty when [mode] is
  /// [SelectionMode.session].
  final Set<LapKey> lapKeys;

  /// The lap designated as the N-lap comparison **Main** (reference). Only
  /// meaningful in lap-mode and only when it is a member of [lapKeys]. `null`
  /// means "auto" — the fastest lap in the selection is Main.
  final LapKey? mainLapKey;

  /// Creates a [Selection].
  const Selection({
    required this.mode,
    required this.sessionIds,
    required this.lapKeys,
    this.mainLapKey,
  });

  /// `true` when there is nothing selected at all (regardless of mode).
  bool get isEmpty => sessionIds.isEmpty && lapKeys.isEmpty;
}

/// Single source of truth for the app's selection. Replaces the legacy
/// `SessionState.selectedSessionIds` / `selectedLaps` pair with a unified
/// store that enforces the session-XOR-lap invariant.
///
/// The notifier guarantees that whichever set is inactive is the empty set
/// (mode flip clears the inactive set), so consumers never have to reason
/// about a "session selected AND a lap selected" mixed state.
class SelectionNotifier extends Notifier<Selection> {
  @override
  Selection build() => const Selection(
        mode: SelectionMode.session,
        sessionIds: <String>{},
        lapKeys: <LapKey>{},
      );

  /// Toggles [sessionId] in the session set. If we are currently in
  /// [SelectionMode.lap], flips to session-mode (clearing the lap set) and
  /// adds [sessionId].
  void toggleSession(String sessionId) {
    if (state.mode == SelectionMode.session) {
      final next = {...state.sessionIds};
      if (next.contains(sessionId)) {
        next.remove(sessionId);
      } else {
        next.add(sessionId);
      }
      state = Selection(
        mode: SelectionMode.session,
        sessionIds: next,
        lapKeys: const <LapKey>{},
      );
    } else {
      state = Selection(
        mode: SelectionMode.session,
        sessionIds: {sessionId},
        lapKeys: const <LapKey>{},
      );
    }
  }

  /// Toggles [key] in the lap set. If we are currently in
  /// [SelectionMode.session], flips to lap-mode (clearing the session set)
  /// and adds [key].
  void toggleLap(LapKey key) {
    if (state.mode == SelectionMode.lap) {
      final next = {...state.lapKeys};
      if (next.contains(key)) {
        next.remove(key);
      } else {
        next.add(key);
      }
      state = Selection(
        mode: SelectionMode.lap,
        sessionIds: const <String>{},
        lapKeys: next,
        // Keep the Main designation only while its lap is still selected.
        mainLapKey: next.contains(state.mainLapKey) ? state.mainLapKey : null,
      );
    } else {
      state = Selection(
        mode: SelectionMode.lap,
        sessionIds: const <String>{},
        lapKeys: {key},
      );
    }
  }

  /// Replaces the active set with [sessions] (switching to session-mode) or
  /// [laps] (switching to lap-mode). Pass exactly one of the two named args.
  /// Passing both is a misuse — only [sessions] is honoured to preserve the
  /// XOR invariant.
  void selectMany({Set<String>? sessions, Set<LapKey>? laps}) {
    if (sessions != null) {
      state = Selection(
        mode: SelectionMode.session,
        sessionIds: {...sessions},
        lapKeys: const <LapKey>{},
      );
      return;
    }
    if (laps != null) {
      state = Selection(
        mode: SelectionMode.lap,
        sessionIds: const <String>{},
        lapKeys: {...laps},
      );
    }
  }

  /// Switches modes and clears the inactive set. No-op when [mode] already
  /// matches the active mode.
  void setMode(SelectionMode mode) {
    if (state.mode == mode) return;
    state = Selection(
      mode: mode,
      sessionIds:
          mode == SelectionMode.session ? state.sessionIds : const <String>{},
      lapKeys: mode == SelectionMode.lap ? state.lapKeys : const <LapKey>{},
    );
  }

  /// Designates [key] as the comparison Main lap, or `null` for auto (the
  /// fastest selected lap). No-op outside lap-mode or when [key] is not a
  /// current lap selection.
  void setMainLap(LapKey? key) {
    if (state.mode != SelectionMode.lap) return;
    if (key != null && !state.lapKeys.contains(key)) return;
    state = Selection(
      mode: SelectionMode.lap,
      sessionIds: const <String>{},
      lapKeys: state.lapKeys,
      mainLapKey: key,
    );
  }

  /// Empties both sets and resets to [SelectionMode.session].
  void clear() {
    state = const Selection(
      mode: SelectionMode.session,
      sessionIds: <String>{},
      lapKeys: <LapKey>{},
    );
  }

  /// Drops every selection entry that references [sessionId]. Called by
  /// [SessionNotifier.removeSession] when a session is deleted from the
  /// library so its UUID does not linger in either set.
  void removeSessionFromSelection(String sessionId) {
    final filteredSessions =
        state.sessionIds.where((s) => s != sessionId).toSet();
    final filteredLaps =
        state.lapKeys.where((k) => k.sessionId != sessionId).toSet();
    if (filteredSessions.length == state.sessionIds.length &&
        filteredLaps.length == state.lapKeys.length) {
      return;
    }
    state = Selection(
      mode: state.mode,
      sessionIds: filteredSessions,
      lapKeys: filteredLaps,
      // Drop the Main designation if its lap no longer survives.
      mainLapKey: filteredLaps.contains(state.mainLapKey) ? state.mainLapKey : null,
    );

    // Drop the tile-cache slice for this session. Its samples live only in the
    // session handle now (Phase 3c), freed when sessionHandleProvider(sessionId)
    // disposes — there is no separate Rust-side buffer to release.
    ref.read(chartTileCacheProvider).invalidateSession(sessionId);
  }
}

/// Provider exposing the global [Selection] store.
final selectionProvider = NotifierProvider<SelectionNotifier, Selection>(
  SelectionNotifier.new,
);

/// Set of session UUIDs to render in the Analyze tab and other downstream
/// consumers. In session-mode this is `selection.sessionIds` verbatim; in
/// lap-mode it is the set of distinct sessionIds across `selection.lapKeys`
/// so that "Analyze N selected laps" still has a session list to pull
/// channel data from.
final effectiveSessionIdsProvider = Provider<Set<String>>((ref) {
  final s = ref.watch(selectionProvider);
  return s.mode == SelectionMode.session
      ? s.sessionIds
      : s.lapKeys.map((k) => k.sessionId).toSet();
});

/// Set of pinned `(sessionId, lapNumber)` pairs. Empty in session-mode —
/// callers that want lap-granular rendering should prefer this provider over
/// reading [selectionProvider] directly.
final effectiveLapKeysProvider = Provider<Set<LapKey>>((ref) {
  final s = ref.watch(selectionProvider);
  return s.mode == SelectionMode.lap ? s.lapKeys : const <LapKey>{};
});
