import 'package:uuid/uuid.dart';

import 'lap_detector.dart';
import 'lap_timing.dart';

/// A reusable track defined by a venue's gates and reference geometry.
///
/// Tracks are the cross-session anchor that makes day-over-day lap-time
/// comparison possible: gates and a reference polyline are stored once at
/// the venue level, and each session that crosses the same physical trail
/// references that Track via one or more [TrackVisit] entries on its
/// [Workspace.trackVisits]. See `docs/IDL0_SPEC.md §12.3`.
///
/// **Storage model — Drive-as-database.** The canonical representation of a
/// Track is a JSON file at `IDL0/tracks/<trackId>.idl0t` in the user's Google
/// Drive. A local SQLite cache ([TrackIndex]) mirrors that JSON for fast
/// queries without a network round-trip; conflicts on cross-device edits are
/// resolved by [updatedAtMs] (last-write-wins).
///
/// **Lap detection per visit.** When a visit's lap detection runs, the
/// session's gate overrides (deprecated) are ignored; lap detection reads
/// only [lapTiming] and [neutralZones] from the Track. The Analyze gate-edit
/// panel's per-visit "Push to Track" / "Reset to Track gates" affordances
/// will be wired in Phase 4.
class Track {
  /// UUID assigned at creation time. Stable across cross-device sync.
  final String trackId;

  /// User-facing display name, e.g. `Whistler A-Line`.
  final String name;

  /// Venue this Track belongs to, e.g. `Whistler Bike Park`. Mirrored from
  /// [SessionMetadata.venueName] of the session this Track was created from.
  /// Used to scope auto-detection candidates.
  final String venueName;

  /// Lap-timing definition for this Track. `null` means "no lap timing
  /// configured" — sessions visiting this Track will produce zero laps
  /// until the user sets timing via the Track editor.
  ///
  /// Replaces the legacy `lapGates: List<LapGate>` field. See
  /// `docs/IDL0_SPEC.md §16` for the migration rule.
  final LapTiming? lapTiming;

  /// Canonical sector gates for this Track, in order. Sector index in the
  /// lap table follows list order.
  final List<SectorGate> sectorGates;

  /// Neutral zones (timing-pause regions). Crossing `enter` while in a lap
  /// pauses; crossing `exit` resumes. See `docs/IDL0_SPEC.md §16`.
  final List<NeutralZone> neutralZones;

  /// Reference polyline (the GPS track of the run this Track was created
  /// from). Passed to the engine's visit detector
  /// (`idl_rs::tracks::detect_visits`) for auto-detection — sessions whose
  /// per-sample closest-point distance to this polyline is below threshold are
  /// matched to this Track.
  ///
  /// Stored in GPS-fix form (degrees × 1e7, see [GpsFix]); the engine geometry
  /// is scale-invariant. May be empty for Tracks created without a source
  /// session (a future "create from scratch" flow).
  final List<GpsFix> referencePolyline;

  /// Creation timestamp, UTC milliseconds since Unix epoch.
  final int createdAtMs;

  /// Last-modified timestamp, UTC milliseconds since Unix epoch.
  ///
  /// Drives last-write-wins conflict resolution during cross-device sync —
  /// the Drive copy is preferred when its `modifiedTime` exceeds the local
  /// row's `updated_at_ms`, and vice versa.
  final int updatedAtMs;

  /// Creates a [Track] with explicit field values.
  const Track({
    required this.trackId,
    required this.name,
    required this.venueName,
    required this.lapTiming,
    required this.sectorGates,
    required this.neutralZones,
    required this.referencePolyline,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  /// Creates a fresh [Track] with a generated UUID and matched
  /// [createdAtMs] / [updatedAtMs] timestamps.
  ///
  /// Pass [now] to override the wall-clock for tests; defaults to
  /// `DateTime.now().toUtc()`.
  factory Track.create({
    required String name,
    required String venueName,
    LapTiming? lapTiming,
    List<SectorGate> sectorGates = const [],
    List<NeutralZone> neutralZones = const [],
    List<GpsFix> referencePolyline = const [],
    DateTime? now,
    String? trackId,
  }) {
    final ts = (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
    return Track(
      trackId: trackId ?? const Uuid().v4(),
      name: name,
      venueName: venueName,
      lapTiming: lapTiming,
      sectorGates: sectorGates,
      neutralZones: neutralZones,
      referencePolyline: referencePolyline,
      createdAtMs: ts,
      updatedAtMs: ts,
    );
  }

  /// Sentinel used with [copyWith] to explicitly clear [lapTiming] to `null`.
  ///
  /// Pass `lapTiming: Track.clearLapTiming` to remove all timing configuration
  /// from a track, since `lapTiming: null` is indistinguishable from "no
  /// change requested" in a nullable `copyWith` parameter.
  // ignore: library_private_types_in_public_api
  static const _Sentinel clearLapTiming = _Sentinel._();

  /// Returns a copy with the given fields replaced. [updatedAtMs] is
  /// auto-bumped when any content field is replaced; pass [updatedAtMs]
  /// explicitly to override (e.g. when downloading from Drive and using the
  /// remote timestamp).
  ///
  /// To explicitly clear [lapTiming] to `null`, pass
  /// `lapTiming: Track.clearLapTiming`.
  Track copyWith({
    String? name,
    String? venueName,
    Object? lapTiming = _Sentinel._instance,
    List<SectorGate>? sectorGates,
    List<NeutralZone>? neutralZones,
    List<GpsFix>? referencePolyline,
    int? updatedAtMs,
    DateTime? now,
  }) {
    final newLapTiming = lapTiming == _Sentinel._instance
        ? this.lapTiming
        : lapTiming as LapTiming?;
    final lapTimingChanged = lapTiming != _Sentinel._instance;
    final mutated = name != null ||
        venueName != null ||
        lapTimingChanged ||
        sectorGates != null ||
        neutralZones != null ||
        referencePolyline != null;
    final newUpdated = updatedAtMs ??
        (mutated
            ? (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch
            : this.updatedAtMs);
    return Track(
      trackId: trackId,
      name: name ?? this.name,
      venueName: venueName ?? this.venueName,
      lapTiming: newLapTiming,
      sectorGates: sectorGates ?? this.sectorGates,
      neutralZones: neutralZones ?? this.neutralZones,
      referencePolyline: referencePolyline ?? this.referencePolyline,
      createdAtMs: createdAtMs,
      updatedAtMs: newUpdated,
    );
  }

  /// Deserializes from JSON. Accepts both the new `lap_timing` object and the
  /// legacy `lap_gates` array (auto-migrated per the rule: 0→null, 1→Circuit,
  /// 2+→PointToPoint(first, second), extras dropped). Tolerates missing
  /// optional fields so older Track files written by earlier app versions load
  /// cleanly.
  factory Track.fromJson(Map<String, dynamic> json) => Track(
        trackId: json['track_id'] as String,
        name: json['name'] as String,
        venueName: json['venue_name'] as String? ?? '',
        lapTiming: _readLapTiming(json),
        sectorGates: (json['sector_gates'] as List<dynamic>? ?? [])
            .map((g) => SectorGate.fromJson(g as Map<String, dynamic>))
            .toList(),
        neutralZones: (json['neutral_zones'] as List<dynamic>? ?? [])
            .map((z) => NeutralZone.fromJson(z as Map<String, dynamic>))
            .toList(),
        referencePolyline: (json['reference_polyline'] as List<dynamic>? ?? [])
            .map((p) => GpsFix.fromJson(p as Map<String, dynamic>))
            .toList(),
        // Legacy keys from the 2026-05-08 variance architecture
        // (`canonical_polyline`, `polyline_source_session_id`,
        // `polyline_source_lap_count`, `polyline_derived_at_ms`) are
        // silently ignored on read — see lap-delta-rewrite spec §3.
        createdAtMs: json['created_at_ms'] as int,
        updatedAtMs: json['updated_at_ms'] as int,
      );

  /// Serializes to JSON for both Drive upload and the [TrackIndex] cache row.
  /// Always emits the new `lap_timing` shape; never the legacy `lap_gates`
  /// array.
  Map<String, dynamic> toJson() => {
        'track_id': trackId,
        'name': name,
        'venue_name': venueName,
        if (lapTiming != null) 'lap_timing': lapTiming!.toJson(),
        'sector_gates': sectorGates.map((g) => g.toJson()).toList(),
        'neutral_zones': neutralZones.map((z) => z.toJson()).toList(),
        'reference_polyline': referencePolyline.map((p) => p.toJson()).toList(),
        'created_at_ms': createdAtMs,
        'updated_at_ms': updatedAtMs,
      };

  // ---------------------------------------------------------------------------
  // Migration helpers
  // ---------------------------------------------------------------------------

  /// Reads `lap_timing` if present; otherwise migrates the legacy
  /// `lap_gates` array.
  static LapTiming? _readLapTiming(Map<String, dynamic> json) {
    final newShape = json['lap_timing'];
    if (newShape is Map<String, dynamic>) {
      return LapTiming.fromJson(newShape);
    }
    final legacy = json['lap_gates'] as List<dynamic>? ?? const [];
    if (legacy.isEmpty) return null;
    final gates =
        legacy.map((g) => LapGate.fromJson(g as Map<String, dynamic>)).toList();
    return _migrateGates(gates);
  }

  /// Maps a legacy length-N gate list onto a `LapTiming` per the rule:
  /// 0 → null, 1 → Circuit, 2+ → PointToPoint(first, second), extras dropped.
  static LapTiming? _migrateGates(List<LapGate> gates) {
    if (gates.isEmpty) return null;
    if (gates.length == 1) return Circuit(startFinish: gates[0]);
    return PointToPoint(start: gates[0], finish: gates[1]);
  }
}

/// Private sentinel used by [Track.copyWith] to distinguish "not provided"
/// from `null` for nullable fields that can be explicitly cleared.
class _Sentinel {
  const _Sentinel._();

  /// The singleton sentinel instance used as the default parameter value.
  static const _Sentinel _instance = _Sentinel._();
}
