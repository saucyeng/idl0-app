import 'session_model.dart';
import 'track.dart';
import 'workspace.dart';

/// Returns the laps cached on [ws]'s `TrackVisit`s (§17.4), renumbered 1-based
/// across the whole session in start-time order, each paired with its [Track]
/// (resolved from [tracksById]; `null` when the visit's `trackId` no longer
/// resolves) and whether it is ignored.
///
/// The engine emits **per-visit** lap numbering (each visit window restarts at
/// 1); the **session-wide** lap identity is assigned here so the Data tab's lap
/// numbers and `ignoredLapNumbers` matching agree with the Analyze lap table
/// (`sessionLapsProvider`, which renumbers the same way) and with SPEC §24.7's
/// continuous `Lap 1 / Lap 2 / Lap 3` display across a multi-visit session.
///
/// `isIgnored` is therefore tested against the renumbered session-wide number,
/// the same value the lap table writes into [Workspace.ignoredLapNumbers].
///
/// Pure — reads only the cached workspace; never parses the `.idl0`.
List<({Lap lap, Track? track, bool isIgnored})> cachedSessionLaps(
  Workspace ws,
  Map<String, Track> tracksById,
) {
  // Collect every cached lap with its (possibly unresolved) Track. Even when
  // the Track is null we keep the lap so a session imported pre-Track-deletion
  // still counts as "a session with laps".
  final collected = <({Lap lap, Track? track})>[];
  for (final visit in ws.trackVisits) {
    final track = tracksById[visit.trackId];
    for (final lap in visit.laps) {
      collected.add((lap: lap, track: track));
    }
  }
  collected.sort(
    (a, b) => a.lap.startTimestampMs.compareTo(b.lap.startTimestampMs),
  );

  final out = <({Lap lap, Track? track, bool isIgnored})>[];
  for (var i = 0; i < collected.length; i++) {
    final src = collected[i].lap;
    final lapNumber = i + 1;
    out.add(
      (
        lap: Lap(
          lapNumber: lapNumber,
          startTimestampMs: src.startTimestampMs,
          endTimestampMs: src.endTimestampMs,
          rawElapsedMs: src.rawElapsedMs,
          lapTimeMs: src.lapTimeMs,
          startTimeSecs: src.startTimeSecs,
          endTimeSecs: src.endTimeSecs,
          sectors: src.sectors,
          neutralZoneVisits: src.neutralZoneVisits,
        ),
        track: collected[i].track,
        isIgnored: ws.ignoredLapNumbers.contains(lapNumber),
      ),
    );
  }
  return out;
}
