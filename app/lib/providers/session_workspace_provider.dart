import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/lap_detector.dart';
import '../data/workspace.dart';
import 'session_provider.dart';

/// Per-session [Workspace] state, loaded from `.idl0w` and written back on
/// every mutation. Keyed by session UUID. See §12.1.
///
/// Each call site creates a notifier scoped to one session — the workspace
/// for two different sessions are independent state objects. Build does
/// `Workspace.load(meta.workspacePath)` if the file exists, else
/// [Workspace.empty]; load/save errors surface via [AsyncValue.error].
///
/// **Save semantics — synchronous, not debounced:** every mutation method
/// awaits [WorkspaceSaver.save] before completing. Gate placement is a small
/// number of deliberate user actions per session, so the simpler always-flush
/// model is preferred over a debounce timer that adds a "did my last edit
/// land before the app crashed" failure mode.
class SessionWorkspaceNotifier extends FamilyAsyncNotifier<Workspace, String> {
  WorkspaceSaver? _saver;

  @override
  Future<Workspace> build(String sessionId) async {
    final sessions = ref.read(sessionProvider).sessions;
    final meta = sessions.firstWhere(
      (s) => s.sessionId == sessionId,
      orElse: () =>
          throw StateError('Session $sessionId not in sessionProvider'),
    );

    _saver = ref.read(workspaceSaverFactoryProvider)(meta.workspacePath);

    final file = File(meta.workspacePath);
    if (!await file.exists()) {
      return Workspace.empty(sessionId);
    }
    return Workspace.load(meta.workspacePath);
  }

  /// Adds [gate] to the end of the lap-gate list and saves.
  ///
  /// First gate becomes the active start/finish (circuit mode); a second
  /// gate switches detection to point-to-point (start = first, finish =
  /// second). Additional gates are stored but not used by the detector —
  /// the user can [removeLapGate] to switch which is active.
  @Deprecated('Future Session Gates — see docs/IDL0_SPEC.md §17')
  Future<void> addLapGate(LapGate gate) async {
    final ws = state.requireValue;
    await _persist(ws.copyWith(lapGates: [...ws.lapGates, gate]));
  }

  /// Removes the lap gate at [index]. No-op if [index] is out of range.
  @Deprecated('Future Session Gates — see docs/IDL0_SPEC.md §17')
  Future<void> removeLapGate(int index) async {
    final ws = state.requireValue;
    if (index < 0 || index >= ws.lapGates.length) return;
    final next = [...ws.lapGates]..removeAt(index);
    await _persist(ws.copyWith(lapGates: next));
  }

  /// Replaces the name of the lap gate at [index] with [newName].
  /// No-op if [index] is out of range.
  @Deprecated('Future Session Gates — see docs/IDL0_SPEC.md §17')
  Future<void> renameLapGate(int index, String newName) async {
    final ws = state.requireValue;
    if (index < 0 || index >= ws.lapGates.length) return;
    final next = [...ws.lapGates]..[index] =
        ws.lapGates[index].withName(newName);
    await _persist(ws.copyWith(lapGates: next));
  }

  /// Replaces the lap gate at [index] with [updated]. No-op when out of range.
  ///
  /// Used by the GPS map endpoint-drag flow, which hands back a full new
  /// [LapGate] with one or both endpoint coordinates moved.
  @Deprecated('Future Session Gates — see docs/IDL0_SPEC.md §17')
  Future<void> updateLapGate(int index, LapGate updated) async {
    final ws = state.requireValue;
    if (index < 0 || index >= ws.lapGates.length) return;
    final next = [...ws.lapGates]..[index] = updated;
    await _persist(ws.copyWith(lapGates: next));
  }

  /// Swaps `lapGates[0]` and `lapGates[1]` so the user can fix a
  /// reversed start/finish without deleting and re-placing.
  ///
  /// No-op when fewer than two lap gates are defined; only the first two
  /// are exchanged even when more exist (extras stored but unused by the
  /// detector — see [addLapGate]).
  @Deprecated('Future Session Gates — see docs/IDL0_SPEC.md §17')
  Future<void> swapLapGates() async {
    final ws = state.requireValue;
    if (ws.lapGates.length < 2) return;
    final next = [...ws.lapGates];
    final tmp = next[0];
    next[0] = next[1];
    next[1] = tmp;
    await _persist(ws.copyWith(lapGates: next));
  }

  /// Appends [gate] to the sector-gate list. Order matters — sector boundaries
  /// are evaluated in list order within each lap.
  @Deprecated('Future Session Gates — see docs/IDL0_SPEC.md §17')
  Future<void> addSectorGate(SectorGate gate) async {
    final ws = state.requireValue;
    await _persist(ws.copyWith(sectorGates: [...ws.sectorGates, gate]));
  }

  /// Inserts [gate] at [index]. Clamps [index] to `[0, length]`.
  @Deprecated('Future Session Gates — see docs/IDL0_SPEC.md §17')
  Future<void> insertSectorGate(int index, SectorGate gate) async {
    final ws = state.requireValue;
    final clamped = index.clamp(0, ws.sectorGates.length);
    final next = [...ws.sectorGates]..insert(clamped, gate);
    await _persist(ws.copyWith(sectorGates: next));
  }

  /// Removes the sector gate at [index]. No-op if [index] is out of range.
  @Deprecated('Future Session Gates — see docs/IDL0_SPEC.md §17')
  Future<void> removeSectorGate(int index) async {
    final ws = state.requireValue;
    if (index < 0 || index >= ws.sectorGates.length) return;
    final next = [...ws.sectorGates]..removeAt(index);
    await _persist(ws.copyWith(sectorGates: next));
  }

  /// Replaces the name of the sector gate at [index] with [newName].
  /// No-op if [index] is out of range.
  @Deprecated('Future Session Gates — see docs/IDL0_SPEC.md §17')
  Future<void> renameSectorGate(int index, String newName) async {
    final ws = state.requireValue;
    if (index < 0 || index >= ws.sectorGates.length) return;
    final old = ws.sectorGates[index];
    final next = [...ws.sectorGates]..[index] =
        SectorGate(name: newName, gate: old.gate);
    await _persist(ws.copyWith(sectorGates: next));
  }

  /// Replaces the sector gate at [index] with [updated]. No-op when out of
  /// range. Used by the GPS map endpoint-drag flow — the caller passes a
  /// full new [SectorGate] (preserving or changing name as desired).
  @Deprecated('Future Session Gates — see docs/IDL0_SPEC.md §17')
  Future<void> updateSectorGate(int index, SectorGate updated) async {
    final ws = state.requireValue;
    if (index < 0 || index >= ws.sectorGates.length) return;
    final next = [...ws.sectorGates]..[index] = updated;
    await _persist(ws.copyWith(sectorGates: next));
  }

  /// Moves the sector gate at [oldIndex] to [newIndex].
  ///
  /// Follows the [ReorderableListView.onReorder] convention: if [newIndex] is
  /// greater than [oldIndex], it is decremented by one because the source
  /// item is removed before insertion. No-op when either index is out of
  /// range or the move would not change the order.
  @Deprecated('Future Session Gates — see docs/IDL0_SPEC.md §17')
  Future<void> reorderSectorGates(int oldIndex, int newIndex) async {
    final ws = state.requireValue;
    final list = [...ws.sectorGates];
    if (oldIndex < 0 || oldIndex >= list.length) return;
    var targetIndex = newIndex;
    if (targetIndex > oldIndex) targetIndex -= 1;
    if (targetIndex < 0) targetIndex = 0;
    if (targetIndex >= list.length) targetIndex = list.length - 1;
    if (targetIndex == oldIndex) return;
    final item = list.removeAt(oldIndex);
    list.insert(targetIndex, item);
    await _persist(ws.copyWith(sectorGates: list));
  }

  /// Adds [lapNumber] to [Workspace.ignoredLapNumbers] and saves.
  ///
  /// Ignored laps stay visible in the lap table (greyed) but are excluded
  /// from best-lap selection, Δ-sector colouring, and ghost-timing
  /// reference. No-op when [lapNumber] is already ignored.
  Future<void> ignoreLap(int lapNumber) async {
    final ws = state.requireValue;
    if (ws.ignoredLapNumbers.contains(lapNumber)) return;
    final next = {...ws.ignoredLapNumbers, lapNumber};
    await _persist(ws.copyWith(ignoredLapNumbers: next));
  }

  /// Removes [lapNumber] from [Workspace.ignoredLapNumbers] and saves.
  /// No-op when [lapNumber] is not currently ignored.
  Future<void> unignoreLap(int lapNumber) async {
    final ws = state.requireValue;
    if (!ws.ignoredLapNumbers.contains(lapNumber)) return;
    final next = {...ws.ignoredLapNumbers}..remove(lapNumber);
    await _persist(ws.copyWith(ignoredLapNumbers: next));
  }

  /// Clears the ignored-lap set (all laps become eligible again) and saves.
  /// No-op when the set is already empty.
  Future<void> clearIgnoredLaps() async {
    final ws = state.requireValue;
    if (ws.ignoredLapNumbers.isEmpty) return;
    await _persist(ws.copyWith(ignoredLapNumbers: const <int>{}));
  }

  /// Pins [lapNumber] as the ghost-timing reference run.
  ///
  /// Pass `null` to clear (the comparison falls back to the fastest lap).
  Future<void> setReferenceLapNumber(int? lapNumber) async {
    final ws = state.requireValue;
    final next = lapNumber == null
        ? ws.clearReferenceLapNumber()
        : ws.copyWith(
            referenceLapNumber: lapNumber,
          );
    await _persist(next);
  }

  /// Designates [lapNumber] as this session's "main" lap for variance math
  /// functions. Pass `null` to clear the designation; variance functions then
  /// throw a friendly `MathChannelEvaluationException` until a main is picked.
  ///
  /// See lap-delta-rewrite spec §7. Persists synchronously to the per-session
  /// `.idl0w`.
  Future<void> setMainLap(int? lapNumber) async {
    final ws = state.requireValue;
    final next = lapNumber == null
        ? ws.clearMainLapNumber()
        : ws.copyWith(mainLapNumber: lapNumber);
    await _persist(next);
  }

  /// Designates [key] as this session's overlay lap (the reference variance
  /// compares against). Pass `null` to clear.
  ///
  /// [key] carries a `sessionId` so the overlay can live in a different
  /// session (cross-session compare). For the same-session case the caller
  /// passes `(sessionId: thisSession, lapNumber: chosenLap)`.
  ///
  /// See lap-delta-rewrite spec §7. Persists synchronously to the per-session
  /// `.idl0w`.
  Future<void> setOverlayLap(
    ({String sessionId, int lapNumber})? key,
  ) async {
    final ws = state.requireValue;
    final next =
        key == null ? ws.clearOverlayLapKey() : ws.copyWith(overlayLapKey: key);
    await _persist(next);
  }

  /// Sets [lapNumber] as this session's "starred" (favourite) lap. Pass
  /// `null` to restore the auto-derived default (fastest non-ignored lap).
  ///
  /// Independent of [setMainLap]/[setOverlayLap] — the star drives sort
  /// emphasis and gauge defaults; variance ignores it.
  Future<void> setStarredLap(int? lapNumber) async {
    final ws = state.requireValue;
    final next = lapNumber == null
        ? ws.clearStarredLapNumber()
        : ws.copyWith(starredLapNumber: lapNumber);
    await _persist(next);
  }

  Future<void> _persist(Workspace next) async {
    state = AsyncData(next);
    final saver = _saver;
    if (saver != null) await saver.save(next);
  }
}

/// Per-session [Workspace] state. See [SessionWorkspaceNotifier].
final sessionWorkspaceProvider =
    AsyncNotifierProvider.family<SessionWorkspaceNotifier, Workspace, String>(
  SessionWorkspaceNotifier.new,
);

/// Factory that produces a [WorkspaceSaver] for a given `.idl0w` path.
///
/// Production builds return [FileWorkspaceSaver]. Tests override to return
/// a fake or no-op saver so workspace mutation tests don't write to disk.
final workspaceSaverFactoryProvider = Provider<WorkspaceSaver Function(String)>(
  (_) => (path) => FileWorkspaceSaver(path),
);
