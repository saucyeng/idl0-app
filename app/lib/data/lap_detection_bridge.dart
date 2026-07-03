import '../src/rust/laps.dart' as rust;
import '../src/rust/lib.dart' as rust show SessionHandle;
import 'lap_detector.dart' show LapGate, SectorGate;
import 'lap_timing.dart';
import 'session_model.dart' show Lap, Sector;
import 'track.dart' show Track;
import 'workspace.dart' show TrackVisit;

/// Maps the Dart Track config to the `idl_rs::laps` FFI args and maps the
/// engine's lap results back to the app's domain models. Coordinates are passed
/// at the raw degrees × 1e7 channel scale — the engine geometry is
/// scale-invariant, so nothing is rescaled.

/// Converts a [LapGate] to the FFI [rust.GateArg].
rust.GateArg gateArg(LapGate g) => rust.GateArg(
    lat1: g.lat1Deg, lon1: g.lon1Deg, lat2: g.lat2Deg, lon2: g.lon2Deg,);

/// Converts a [LapTiming] to the freezed-free [rust.LapTimingArg].
rust.LapTimingArg timingArg(LapTiming t) => switch (t) {
      Circuit(:final startFinish) => rust.LapTimingArg(
          kind: rust.LapTimingKind.circuit,
          start: gateArg(startFinish),
          finish: gateArg(startFinish),
        ),
      PointToPoint(:final start, :final finish) => rust.LapTimingArg(
          kind: rust.LapTimingKind.pointToPoint,
          start: gateArg(start),
          finish: gateArg(finish),
        ),
    };

/// Converts a [SectorGate] to the FFI [rust.SectorGateArg].
rust.SectorGateArg sectorArg(SectorGate s) =>
    rust.SectorGateArg(name: s.name, gate: gateArg(s.gate));

/// Converts a [NeutralZone] to the FFI [rust.NeutralZoneArg].
rust.NeutralZoneArg nzArg(NeutralZone z) => rust.NeutralZoneArg(
    name: z.name, enter: gateArg(z.enter), exit: gateArg(z.exit),);

/// Maps an engine [rust.Lap] to the app domain [Lap].
Lap lapFromRust(rust.Lap r) => Lap(
      lapNumber: r.lapNumber,
      startTimestampMs: r.startMs,
      endTimestampMs: r.endMs,
      rawElapsedMs: r.rawElapsedMs,
      lapTimeMs: r.lapTimeMs,
      startTimeSecs: r.startTimeSecs,
      endTimeSecs: r.endTimeSecs,
      sectors: [
        for (final s in r.sectors)
          Sector(
            name: s.name,
            startTimestampMs: s.startMs,
            endTimestampMs: s.endMs,
            startTimeSecs: s.startTimeSecs,
            endTimeSecs: s.endTimeSecs,
          ),
      ],
      neutralZoneVisits: [
        for (final v in r.neutralZoneVisits)
          NeutralZoneVisit(
              neutralZoneName: v.name, enterMs: v.enterMs, exitMs: v.exitMs,),
      ],
    );

/// Detects laps for a single [visit] window using its [track]'s timing config,
/// reading GPS from the retained session [handle]. Returns `[]` when the Track
/// has no lap timing configured. Shared by the live `visitLapsProvider` and the
/// import/rescan lap-cache writers so both produce identical laps. The engine
/// reads GPS from the handle and restricts to `[visit.startTimestampMs,
/// visit.endTimestampMs]`; sector splits and neutral-zone subtraction happen
/// Rust-side. See `docs/IDL0_SPEC.md §17.5`.
Future<List<Lap>> detectLapsForVisit({
  required rust.SessionHandle handle,
  required Track track,
  required TrackVisit visit,
}) async {
  if (track.lapTiming == null) return const [];
  final results = await rust.detectLaps(
    handle: handle,
    timing: timingArg(track.lapTiming!),
    sectorGates: [for (final s in track.sectorGates) sectorArg(s)],
    neutralZones: [for (final z in track.neutralZones) nzArg(z)],
    windowStartMs: visit.startTimestampMs,
    windowEndMs: visit.endTimestampMs,
  );
  return [for (final r in results) lapFromRust(r)];
}
