import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/lap_detection_bridge.dart';
import '../data/lap_detector.dart';
import '../data/lap_distance_accumulator.dart';
import '../data/session_model.dart';
import '../data/track_matching_bridge.dart';
import '../data/workspace.dart';
import '../src/rust/session.dart' as rust_session;
import '../src/rust/tracks.dart' as rust;
import 'channel_provider.dart';
import 'session_workspace_provider.dart';
import 'track_provider.dart';

/// Detected [Lap] list for a single session, flattened across every
/// [TrackVisit] in the session's workspace. See §14.3.
///
/// Composes [sessionWorkspaceProvider] and all per-visit [visitLapsProvider]
/// instances without async/await so consumers see incremental state:
/// - `AsyncLoading` while the workspace or any visit-lap future is still
///   loading.
/// - `AsyncError` if the workspace load fails.
/// - `AsyncData([])` when there are no [TrackVisit]s or no laps detected.
/// - `AsyncData([...])` with detected laps sorted by [Lap.startTimestampMs]
///   and renumbered 1-based across the full session.
///
/// Workspace `lapGates` fields are dormant (no UI); laps now come exclusively
/// from Track-level timing configured via the Track editor (§17).
final sessionLapsProvider = Provider.autoDispose
    .family<AsyncValue<List<Lap>>, String>((ref, sessionId) {
  final wsValue = ref.watch(sessionWorkspaceProvider(sessionId));

  if (wsValue is AsyncError) {
    return AsyncError(
      (wsValue as AsyncError).error,
      (wsValue as AsyncError).stackTrace,
    );
  }
  if (!wsValue.hasValue) {
    return const AsyncLoading();
  }

  final workspace = wsValue.requireValue;
  if (workspace.trackVisits.isEmpty) {
    return const AsyncData<List<Lap>>([]);
  }

  // Collect per-visit lap futures. Return AsyncLoading if any is still
  // loading; accumulate laps from resolved visits and skip errored ones.
  final all = <Lap>[];
  for (final visit in workspace.trackVisits) {
    final visitValue = ref.watch(
      visitLapsProvider((sessionId: sessionId, visitId: visit.visitId)),
    );
    if (visitValue.isLoading) return const AsyncLoading();
    if (visitValue.hasValue) {
      all.addAll(visitValue.requireValue);
    }
    // Skip individual visit errors — surface what's readable.
  }

  all.sort((a, b) => a.startTimestampMs.compareTo(b.startTimestampMs));

  // Renumber session-wide so lap numbers are 1-based and contiguous.
  final renumbered = [
    for (var i = 0; i < all.length; i++)
      Lap(
        lapNumber: i + 1,
        startTimestampMs: all[i].startTimestampMs,
        endTimestampMs: all[i].endTimestampMs,
        rawElapsedMs: all[i].rawElapsedMs,
        lapTimeMs: all[i].lapTimeMs,
        startTimeSecs: all[i].startTimeSecs,
        endTimeSecs: all[i].endTimeSecs,
        sectors: all[i].sectors,
        neutralZoneVisits: all[i].neutralZoneVisits,
      ),
  ];
  return AsyncData(renumbered);
});

/// Returns the slice of [gps] whose timestamps fall in
/// `[startTimestampMs, endTimestampMs]` (both ends inclusive).
///
/// `gps` must be sorted by [GpsFix.timestampMs] — same invariant as the
/// engine `gps_track` output. Used by [lapDistanceAccumulatorProvider] to slice
/// a lap's GPS window. (Lap detection itself windows in the engine — see
/// [visitLapsProvider] — so it no longer calls this.)
List<GpsFix> sliceGpsByWindow(
  List<GpsFix> gps,
  int startTimestampMs,
  int endTimestampMs,
) {
  final out = <GpsFix>[];
  for (final f in gps) {
    if (f.timestampMs < startTimestampMs) continue;
    if (f.timestampMs > endTimestampMs) break;
    out.add(f);
  }
  return out;
}

/// Detected [Lap] list for one [TrackVisit] within a session. See §12.3 and
/// §14.3.
///
/// Runs `idl_rs::laps::detect_laps` (via `rust.detectLaps`) over the session
/// handle, restricted to the `[visit.startTimestampMs, visit.endTimestampMs]`
/// window, using only `Track.lapTiming`, `Track.sectorGates`, and
/// `Track.neutralZones`. The §17 workspace-gate fall-through has been removed;
/// workspace `lapGates` fields stay dormant for future Session Gates work.
/// Returns an empty list when the Track has no timing configured or cannot
/// be resolved.
///
/// Keyed by `(sessionId, visitId)`. The stable `visitId` (assigned app-side
/// when mapping the engine's visit windows — see `track_matching_bridge`) means
/// rescan-on-import produces fresh providers rather than silently re-resolving
/// an existing key to a different visit.
final visitLapsProvider = FutureProvider.autoDispose
    .family<List<Lap>, ({String sessionId, String visitId})>((ref, key) async {
  final ws = await ref.watch(
    sessionWorkspaceProvider(key.sessionId).future,
  );
  final visit = ws.trackVisits.firstWhere(
    (v) => v.visitId == key.visitId,
    orElse: () => throw StateError(
      'visitId ${key.visitId} not in workspace ${key.sessionId}',
    ),
  );

  final tracks = await ref.watch(trackProvider.future);
  final track = tracks.where((t) => t.trackId == visit.trackId).firstOrNull;
  if (track == null) return const [];

  // Track-first lap detection in the idl-rs engine. It reads GPS from the
  // retained session handle and restricts to the visit window; per-session
  // workspace gates no longer override (§17 fall-through removed). Shared with
  // the import/rescan lap-cache writers via [detectLapsForVisit] so the live
  // and cached lap lists are identical.
  final handle = await ref.watch(sessionHandleProvider(key.sessionId).future);
  return detectLapsForVisit(handle: handle, track: track, visit: visit);
});

/// Resolves the lap number that ghost-timing should compare against.
///
/// Layered fallback so neither the pin nor the ignore feature silently
/// swallows the other:
/// 1. Honour [pinned] when it's set AND that lap is not ignored AND the lap
///    actually exists in [laps].
/// 2. Otherwise, the fastest lap among non-ignored laps.
/// 3. Returns `null` when no non-ignored lap exists.
///
/// Used by `lap_table.dart` (ghost button enable + reference label) and
/// `ghost_chart.dart` (worksheet ghost slot reference resolution). Pure
/// function — accepts pre-fetched data so it stays trivial to test.
int? resolveGhostReferenceLapNumber({
  required List<Lap> laps,
  required Set<int> ignored,
  required int? pinned,
}) {
  final eligible = laps.where((l) => !ignored.contains(l.lapNumber)).toList();
  if (eligible.isEmpty) return null;
  if (pinned != null &&
      !ignored.contains(pinned) &&
      laps.any((l) => l.lapNumber == pinned)) {
    return pinned;
  }
  eligible.sort((a, b) => a.lapTimeMs.compareTo(b.lapTimeMs));
  return eligible.first.lapNumber;
}

/// Per-lap normalised distance accumulator. Resolves the lap's session,
/// finds the bound Track's canonical polyline (falling back to the
/// reference polyline when canonical is empty), slices GPS by the lap's
/// timestamp window, aligns the speed channel, and runs
/// [LapDistanceAccumulator.compute].
///
/// Returns `null` when prerequisites are unmet:
///   - The lap doesn't exist in the session.
///   - The lap is not contained in any [TrackVisit].
///   - The visit's bound [Track] has been deleted.
///   - The Track has no polyline of either kind (or fewer than 2 points).
///   - The lap window contains fewer than 2 GPS samples.
///
/// Sector-gate crossings are an empty-list placeholder for Phase F — the
/// accumulator still anchors lap start/finish so the resulting distance
/// map is useful for variance even before gates are wired.
///
/// Keyed by `(sessionId, lapNumber)`. Cached for the same lifetime as
/// [visitLapsProvider] — invalidates naturally when any of
/// [sessionLapsProvider], [sessionWorkspaceProvider], [trackProvider],
/// [sessionChannelMetaProvider], or [sessionHandleProvider] changes. See
/// variance-architecture design doc §4.4.
final lapDistanceAccumulatorProvider = FutureProvider.autoDispose
    .family<LapDistanceAccumulator?, ({String sessionId, int lapNumber})>(
        (ref, key) async {
  final lapsValue = ref.watch(sessionLapsProvider(key.sessionId));
  if (!lapsValue.hasValue) return null;
  final laps = lapsValue.requireValue;
  final lap = laps.where((l) => l.lapNumber == key.lapNumber).firstOrNull;
  if (lap == null) return null;

  final ws = await ref.watch(
    sessionWorkspaceProvider(key.sessionId).future,
  );
  // Find the Track via the lap's containing TrackVisit. A lap that is
  // not bracketed by any visit (e.g. workspace was rescanned and the lap
  // is now stale) yields null rather than throwing — the caller draws
  // an empty distance map for that lap.
  final visit = ws.trackVisits
      .where(
        (v) =>
            lap.startTimestampMs >= v.startTimestampMs &&
            lap.endTimestampMs <= v.endTimestampMs,
      )
      .firstOrNull;
  if (visit == null) return null;

  final tracks = await ref.watch(trackProvider.future);
  final track = tracks.where((t) => t.trackId == visit.trackId).firstOrNull;
  if (track == null) return null;

  // Track.canonicalPolyline removed in lap-delta-rewrite Task 1.3; the
  // accumulator falls back to referencePolyline for now. The
  // accumulator itself is slated to be replaced by Rust track
  // projection in Phase 3.
  final polyline = track.referencePolyline;
  if (polyline.length < 2) return null;

  final handle = await ref.watch(sessionHandleProvider(key.sessionId).future);
  final allGps = [
    for (final f in await rust.gpsTrack(handle: handle)) gpsFixFromArg(f),
  ];
  final lapGps = sliceGpsByWindow(
    allGps,
    lap.startTimestampMs,
    lap.endTimestampMs,
  );
  if (lapGps.length < 2) return null;

  // Speed channel — match each GPS sample to the closest speed sample
  // by timestamp. `GPS_SpeedKmh` is the canonical name; if it's missing,
  // fall back to a constant above the anchor threshold so confidence
  // anchoring is gated on residual + tangent only (rather than being
  // dropped entirely for sub-threshold default speed). Pulled from the handle
  // directly (rate from metadata, samples via `channelSamples`) — no
  // full-session drain.
  final metas =
      await ref.watch(sessionChannelMetaProvider(key.sessionId).future);
  final speedMeta =
      metas.where((m) => m.channelId == 'GPS_SpeedKmh').firstOrNull;
  final speedSamples = speedMeta == null
      ? const <double>[]
      : await rust_session.channelSamples(
          handle: handle,
          channelId: 'GPS_SpeedKmh',
        );
  final speed = speedSamples.isEmpty
      ? List<double>.filled(lapGps.length, 30.0)
      : _alignSpeedToGps(speedSamples, speedMeta!.sampleRateHz, lapGps);

  // Sector-gate crossings — placeholder for now. Phase B/C did not wire
  // the gate-distance lookup; this returns an empty list, which the
  // accumulator handles fine (start/finish endpoints still anchor the
  // lap). Phase F follow-up wires gate distances when sector gates are
  // first-class on the Track polyline.
  const gateCrossings = <({int sampleIndex, double knownDistance})>[];

  return LapDistanceAccumulator.compute(
    samples: lapGps,
    polyline: polyline,
    speedKmh: speed,
    startGateDistance: 0.0,
    finishGateDistance: null,
    gateCrossings: gateCrossings,
  );
});

/// Resamples a speed channel ([speedSamples] at [sampleRateHz]) to align with
/// [gpsSamples] by timestamp using a nearest-neighbour pick. Speed at GPS sample
/// `i` is `speedSamples[k]` where
/// `k = round((gpsSamples[i].timestampMs - sessionStart) / speedSampleIntervalMs)`,
/// clamped to the index range.
///
/// Falls back to a constant 30 km/h vector when the channel is empty —
/// see [lapDistanceAccumulatorProvider] for the rationale (default keeps
/// confidence anchoring above the speed gate). Samples are pulled from the
/// handle (`channelSamples`), never via a full-session drain.
List<double> _alignSpeedToGps(
  List<double> speedSamples,
  double sampleRateHz,
  List<GpsFix> gpsSamples,
) {
  if (speedSamples.isEmpty) {
    return List<double>.filled(gpsSamples.length, 30.0);
  }
  final intervalMs = sampleRateHz > 0 ? 1000.0 / sampleRateHz : 100.0;
  final sessionStartMs = gpsSamples.first.timestampMs;
  final out = List<double>.filled(gpsSamples.length, 0.0);
  for (var i = 0; i < gpsSamples.length; i++) {
    final t = gpsSamples[i].timestampMs - sessionStartMs;
    final idx = (t / intervalMs).round();
    final clamped = idx.clamp(0, speedSamples.length - 1);
    out[i] = speedSamples[clamped];
  }
  return out;
}
