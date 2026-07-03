import 'session_model.dart';

// ---------------------------------------------------------------------------
// LapContext — main/overlay lap state for the lap-aware and variance math
// functions. Lap/sector boundaries already carry engine-computed recording
// seconds ([Lap.startTimeSecs] etc.), so no epoch→Time conversion lives here
// anymore (moved into idl-rs `epoch_ms_to_time_secs`, consumed by the lap
// detector — see the H1 design).
// ---------------------------------------------------------------------------

/// Bundle of per-evaluation lap and overlay state.
class LapContext {
  /// 1-based lap number designated as the main lap of THIS session, or `null`
  /// when the user has not picked one.
  final int? mainLapNumber;

  /// Reference (overlay) lap variance compares against. Carries a sessionId so
  /// the overlay can live in a different session for cross-session compare.
  /// `null` when no overlay is designated.
  final ({String sessionId, int lapNumber})? overlayLapKey;

  /// All laps detected for the current (main) session, in order.
  final List<Lap> mainLaps;

  /// All laps detected for the overlay session. Same list as [mainLaps] when
  /// the overlay points into this session. `null` when not loaded.
  final List<Lap>? overlayLaps;

  /// Creates a [LapContext].
  const LapContext({
    required this.mainLaps,
    this.mainLapNumber,
    this.overlayLapKey,
    this.overlayLaps,
  });
}
