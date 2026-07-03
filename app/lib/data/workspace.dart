import 'dart:convert';
import 'dart:io';

import 'package:idl0/data/exceptions.dart';
import 'package:idl0/data/lap_detector.dart';
import 'package:idl0/data/math_channel.dart' show MathChannel;
import 'package:idl0/data/session_model.dart' show Lap;

/// Supported workspace file version written by this build of the app.
///
/// Increment when the `.idl0w` schema changes in a breaking way. Old app
/// versions will refuse to open the file with a clean user-facing error.
///
/// Version history:
/// - v1: initial format (lap gates, sector gates, math channels, layout)
/// - v2: added `LapGate.name` and top-level `reference_lap_number` for
///   ghost-lap timing. v1 files load cleanly — missing fields default.
/// - v3: added top-level `ignored_lap_numbers` (List<int>) so the user can
///   exclude spurious gate crossings from best-lap selection, Δ-sector
///   colouring, and ghost-timing reference without deleting them. v1/v2
///   files load cleanly — missing field defaults to an empty set.
/// - v4: added top-level `track_visits` (List<TrackVisit>) and
///   `track_visits_library_hash` (String?) so a single session can
///   reference multiple Tracks ridden back-to-back. Replaces the v3
///   single `SessionMetadata.trackId` binding. v1/v2/v3 files load cleanly
///   — both fields default to empty/null.
/// - v5: added top-level `main_lap_number` (int?), `overlay_lap_key`
///   (nested `{session_id, lap_number}`), and `starred_lap_number` (int?)
///   for the lap-delta-rewrite main/overlay/starred designation. Replaces
///   the top-level `WorkspaceState.baselineLapKey` removed in Task 1.4.
///   v1–v4 files load cleanly — all three fields default to null.
/// - v6: dropped `math_channels` and `workbook_layout` from the schema —
///   math channels now live on the owning [Workbook]; the legacy
///   `workbook_layout` field was never read. v1–v5 files load cleanly;
///   their `math_channels` array remains reachable in memory so the
///   migration pass can dedupe channels into the workbook library on
///   first launch.
/// - v7: `TrackVisit` now carries a `laps` array caching the laps detected
///   within its window, so the Data tab builds aggregates without parsing the
///   `.idl0` (§17.4, §24.7). v1–v6 files load cleanly — `laps` defaults empty.
const int _kSupportedWorkspaceVersion = 7;

/// One contiguous time window during which the rider was on a single Track.
///
/// A session can contain many [TrackVisit]s — e.g., a trail ride that hits
/// `A-Line`, then `Top of the World`, then `A-Line` again produces three
/// visits (two of them to the same Track). Visits are detected by the engine
/// (`idl_rs::tracks::detect_visits`) from the session's GPS and the local Track
/// library, and cached on [Workspace.trackVisits] so the hierarchy view does
/// not re-run detection on every render. See `docs/IDL0_SPEC.md §17`.
///
/// [visitId] is a stable UUID assigned app-side when mapping the engine's
/// visit windows (the engine itself returns no id). A re-detected visit at the
/// same `(trackId, startTimestampMs)` receives a fresh UUID, so consumers
/// keying off `visitId` see it as a new entity — the intended behaviour for
/// caches that must invalidate on rescan.
class TrackVisit {
  /// Stable UUID for this visit. Used as the key for [visitLapsProvider] so
  /// outstanding subscribers do not silently re-resolve to a different visit
  /// when [Workspace.trackVisits] is recomputed.
  final String visitId;

  /// UUID of the Track this visit belongs to. May not resolve to a current
  /// Track if the user has deleted it since detection — consumers should
  /// skip-on-resolve rather than throw.
  final String trackId;

  /// UTC milliseconds since Unix epoch when the rider entered the Track's
  /// matching window. Same scale as [Lap.startTimestampMs].
  final int startTimestampMs;

  /// UTC milliseconds since Unix epoch when the rider left the Track's
  /// matching window. Always `>= startTimestampMs`.
  final int endTimestampMs;

  /// Laps detected within this visit window, cached so the Data tab can build
  /// its session/track aggregates and lap-time facets without parsing the
  /// `.idl0` (§17.4, §24.7). These are exactly the laps the engine emits for
  /// this window (per-visit numbering) — the same values [visitLapsProvider]
  /// returns live. Empty until detection runs, and for pre-v7 workspaces that
  /// predate the lap cache. Recomputed with the visit on rescan. Added in
  /// workspace_version 7.
  final List<Lap> laps;

  /// Creates a [TrackVisit].
  const TrackVisit({
    required this.visitId,
    required this.trackId,
    required this.startTimestampMs,
    required this.endTimestampMs,
    this.laps = const [],
  });

  /// Duration of the visit in milliseconds.
  int get durationMs => endTimestampMs - startTimestampMs;

  /// Deserializes from JSON. Tolerates a missing `laps` key (pre-v7 visits) by
  /// defaulting to an empty list.
  factory TrackVisit.fromJson(Map<String, dynamic> json) => TrackVisit(
        visitId: json['visit_id'] as String,
        trackId: json['track_id'] as String,
        startTimestampMs: json['start_timestamp_ms'] as int,
        endTimestampMs: json['end_timestamp_ms'] as int,
        laps: (json['laps'] as List<dynamic>? ?? [])
            .map((l) => Lap.fromJson(l as Map<String, dynamic>))
            .toList(),
      );

  /// Serializes to JSON. The `laps` key is omitted when empty so visit-only
  /// (no-lap) workspaces keep clean on-disk diffs.
  Map<String, dynamic> toJson() => {
        'visit_id': visitId,
        'track_id': trackId,
        'start_timestamp_ms': startTimestampMs,
        'end_timestamp_ms': endTimestampMs,
        if (laps.isNotEmpty) 'laps': laps.map((l) => l.toJson()).toList(),
      };
}

/// Layout of a single analysis component (chart, map, gauge, etc.) within a
/// worksheet. Coordinates are normalized 0.0–1.0 within the worksheet area.
class ComponentLayout {
  /// Component type: `time_series`, `fft`, `histogram`, `gps_map`, `gauge`,
  /// `lap_table`, or `statistics`.
  final String type;

  /// Horizontal position, normalized 0.0 (left) to 1.0 (right).
  final double x;

  /// Vertical position, normalized 0.0 (top) to 1.0 (bottom).
  final double y;

  /// Normalized width.
  final double width;

  /// Normalized height.
  final double height;

  /// Creates a [ComponentLayout].
  const ComponentLayout({
    required this.type,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  /// Deserializes from JSON. Unknown fields are silently ignored.
  factory ComponentLayout.fromJson(Map<String, dynamic> json) =>
      ComponentLayout(
        type: json['type'] as String,
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        width: (json['width'] as num).toDouble(),
        height: (json['height'] as num).toDouble(),
      );

  /// Serializes to JSON.
  Map<String, dynamic> toJson() => {
        'type': type,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };
}

/// One worksheet (page) within the workbook. See §15.5.
class WorksheetLayout {
  /// Display name shown in the worksheet tab, e.g. `Overview` or `Suspension`.
  final String name;

  /// Components placed on this worksheet.
  final List<ComponentLayout> components;

  /// Creates a [WorksheetLayout].
  const WorksheetLayout({required this.name, required this.components});

  /// Deserializes from JSON. Unknown fields are silently ignored.
  factory WorksheetLayout.fromJson(Map<String, dynamic> json) =>
      WorksheetLayout(
        name: json['name'] as String,
        components: (json['components'] as List<dynamic>? ?? [])
            .map((c) => ComponentLayout.fromJson(c as Map<String, dynamic>))
            .toList(),
      );

  /// Serializes to JSON.
  Map<String, dynamic> toJson() => {
        'name': name,
        'components': components.map((c) => c.toJson()).toList(),
      };
}

/// Top-level workbook layout: the ordered collection of worksheets.
class WorkbookLayout {
  /// Worksheets in display order. The first worksheet is shown on open.
  final List<WorksheetLayout> worksheets;

  /// Creates a [WorkbookLayout].
  const WorkbookLayout({required this.worksheets});

  /// Deserializes from JSON. Unknown fields are silently ignored.
  factory WorkbookLayout.fromJson(Map<String, dynamic> json) => WorkbookLayout(
        worksheets: (json['worksheets'] as List<dynamic>? ?? [])
            .map((w) => WorksheetLayout.fromJson(w as Map<String, dynamic>))
            .toList(),
      );

  /// Serializes to JSON.
  Map<String, dynamic> toJson() => {
        'worksheets': worksheets.map((w) => w.toJson()).toList(),
      };
}

/// The workspace file (`.idl0w`) companion to a raw log file (`.idl0`).
///
/// Stores all user-created derived data: gate definitions, math channels,
/// workbook layout. The `.idl0` log is immutable; all edits go here. See §9.4.
///
/// **Version handling:**
/// - `workspace_version` > [_kSupportedWorkspaceVersion]: throws
///   [UnsupportedWorkspaceVersionException] — do not load partial data.
/// - `workspace_version` < current: migrate silently — unknown fields in the
///   JSON are ignored so old workspaces always load cleanly.
class Workspace {
  /// Highest workspace_version this build of the app can read.
  static const int supportedVersion = _kSupportedWorkspaceVersion;

  /// workspace_version stored in this file. Used for forward-compatibility
  /// checks when a newer app writes a workspace that an older app tries to open.
  final int workspaceVersion;

  /// UUID of the `.idl0` session this workspace belongs to.
  final String sessionId;

  /// Start/finish gate(s). At most one gate is active at a time.
  ///
  /// Multiple entries in the list represent alternative gate positions the
  /// user has experimented with; only `lapGates.first` is used for timing.
  /// An empty list means no gate has been placed yet.
  final List<LapGate> lapGates;

  /// Sector gates applied within each lap, in order from start to finish.
  final List<SectorGate> sectorGates;

  /// User-defined derived channels. Evaluated lazily on demand.
  final List<MathChannel> mathChannels;

  /// Workbook layout saved from the Analyze tab.
  final WorkbookLayout workbookLayout;

  /// Lap number used as the reference run for ghost-lap timing comparisons.
  ///
  /// `null` (the default) means "use the fastest lap" — the comparison
  /// auto-selects whichever lap currently has the shortest [Lap.lapTimeMs].
  /// A non-null value pins the reference even when a faster lap is recorded
  /// later in the same session. Added in workspace_version 2.
  ///
  /// Interaction with [ignoredLapNumbers]: callers should fall back to the
  /// fastest non-ignored lap when the pinned reference is itself ignored.
  /// This file just stores the values; the ghost-timing UI is responsible
  /// for applying that policy.
  final int? referenceLapNumber;

  /// 1-based lap numbers the user has flagged as "ignored" for timing.
  ///
  /// Ignored laps stay visible in the lap table (greyed) but are excluded
  /// from best-lap selection, Δ-sector colouring, and ghost-timing
  /// reference. Lap numbers are not renumbered when laps are ignored —
  /// this set carries the same `lapNumber` values that [Lap.lapNumber]
  /// emits. Added in workspace_version 3.
  final Set<int> ignoredLapNumbers;

  /// Cached track visits detected in this session, ordered by
  /// [TrackVisit.startTimestampMs]. See `docs/IDL0_SPEC.md §17`.
  ///
  /// Populated by the engine (`idl_rs::tracks::detect_visits`) on import or
  /// explicit rescan. Empty until detection runs. Replaces the v3 single
  /// `SessionMetadata.trackId` binding. Added in workspace_version 4.
  final List<TrackVisit> trackVisits;

  /// Hash of the Track library at the time [trackVisits] was computed.
  ///
  /// Compared live to a hash of the current [trackProvider] list so the
  /// hierarchy view can flag a session as having stale visits and surface
  /// a "rescan available" affordance. `null` means visits have never been
  /// computed for this workspace. Hash format is implementation-defined —
  /// callers must not parse it. Added in workspace_version 4.
  final String? trackVisitsLibraryHash;

  /// Lap of THIS session designated as the "main" lap for variance math
  /// functions. `null` when the user has not picked one — variance
  /// functions throw `MathChannelEvaluationException` in that state.
  /// Added in workspace_version 5.
  final int? mainLapNumber;

  /// Reference lap variance compares against. Carries a `sessionId` so
  /// the overlay can live in a DIFFERENT session (cross-session compare).
  /// `null` when no overlay is designated. Added in workspace_version 5.
  final ({String sessionId, int lapNumber})? overlayLapKey;

  /// User's "favourite" lap of this session — defaults to fastest
  /// non-ignored on first compute, user-overridable via the lap-table
  /// star icon. Used for sort highlight + gauge defaults. Independent
  /// of [mainLapNumber] / [overlayLapKey] (variance ignores the star).
  /// Added in workspace_version 5.
  final int? starredLapNumber;

  /// Creates a [Workspace].
  const Workspace({
    required this.workspaceVersion,
    required this.sessionId,
    required this.lapGates,
    required this.sectorGates,
    required this.mathChannels,
    required this.workbookLayout,
    this.referenceLapNumber,
    this.ignoredLapNumbers = const {},
    this.trackVisits = const [],
    this.trackVisitsLibraryHash,
    this.mainLapNumber,
    this.overlayLapKey,
    this.starredLapNumber,
  });

  /// Creates an empty workspace for a new session.
  factory Workspace.empty(String sessionId) => Workspace(
        workspaceVersion: _kSupportedWorkspaceVersion,
        sessionId: sessionId,
        lapGates: const [],
        sectorGates: const [],
        mathChannels: const [],
        workbookLayout: const WorkbookLayout(worksheets: []),
      );

  /// Returns a copy with the given fields replaced. Other fields are
  /// preserved verbatim. Pass `null` for [referenceLapNumber] is rejected by
  /// Dart's null-aware default — use [clearReferenceLapNumber] to clear.
  /// Same applies to [trackVisitsLibraryHash] — use [clearTrackVisits] to
  /// reset visit state. For the v5 lap-designation fields, use
  /// [clearMainLapNumber], [clearOverlayLapKey], [clearStarredLapNumber].
  Workspace copyWith({
    List<LapGate>? lapGates,
    List<SectorGate>? sectorGates,
    List<MathChannel>? mathChannels,
    WorkbookLayout? workbookLayout,
    int? referenceLapNumber,
    Set<int>? ignoredLapNumbers,
    List<TrackVisit>? trackVisits,
    String? trackVisitsLibraryHash,
    int? mainLapNumber,
    ({String sessionId, int lapNumber})? overlayLapKey,
    int? starredLapNumber,
  }) =>
      Workspace(
        workspaceVersion: workspaceVersion,
        sessionId: sessionId,
        lapGates: lapGates ?? this.lapGates,
        sectorGates: sectorGates ?? this.sectorGates,
        mathChannels: mathChannels ?? this.mathChannels,
        workbookLayout: workbookLayout ?? this.workbookLayout,
        referenceLapNumber: referenceLapNumber ?? this.referenceLapNumber,
        ignoredLapNumbers: ignoredLapNumbers ?? this.ignoredLapNumbers,
        trackVisits: trackVisits ?? this.trackVisits,
        trackVisitsLibraryHash:
            trackVisitsLibraryHash ?? this.trackVisitsLibraryHash,
        mainLapNumber: mainLapNumber ?? this.mainLapNumber,
        overlayLapKey: overlayLapKey ?? this.overlayLapKey,
        starredLapNumber: starredLapNumber ?? this.starredLapNumber,
      );

  /// Returns a copy with [referenceLapNumber] set to `null`.
  ///
  /// Distinct from [copyWith] because Dart cannot distinguish "omitted" from
  /// "explicitly null" in optional named parameters of nullable types.
  Workspace clearReferenceLapNumber() => Workspace(
        workspaceVersion: workspaceVersion,
        sessionId: sessionId,
        lapGates: lapGates,
        sectorGates: sectorGates,
        mathChannels: mathChannels,
        workbookLayout: workbookLayout,
        ignoredLapNumbers: ignoredLapNumbers,
        trackVisits: trackVisits,
        trackVisitsLibraryHash: trackVisitsLibraryHash,
      );

  /// Returns a copy with [trackVisits] empty and [trackVisitsLibraryHash]
  /// `null` — the "no detection has run" state. Used by Phase 3's rescan
  /// flow when the user wants to drop cached visits before re-running
  /// detection.
  Workspace clearTrackVisits() => Workspace(
        workspaceVersion: workspaceVersion,
        sessionId: sessionId,
        lapGates: lapGates,
        sectorGates: sectorGates,
        mathChannels: mathChannels,
        workbookLayout: workbookLayout,
        referenceLapNumber: referenceLapNumber,
        ignoredLapNumbers: ignoredLapNumbers,
        mainLapNumber: mainLapNumber,
        overlayLapKey: overlayLapKey,
        starredLapNumber: starredLapNumber,
      );

  /// Returns a copy with [mainLapNumber] set to `null`. Distinct from
  /// [copyWith] because Dart cannot distinguish "omitted" from "explicitly
  /// null" in optional named parameters of nullable types.
  Workspace clearMainLapNumber() => Workspace(
        workspaceVersion: workspaceVersion,
        sessionId: sessionId,
        lapGates: lapGates,
        sectorGates: sectorGates,
        mathChannels: mathChannels,
        workbookLayout: workbookLayout,
        referenceLapNumber: referenceLapNumber,
        ignoredLapNumbers: ignoredLapNumbers,
        trackVisits: trackVisits,
        trackVisitsLibraryHash: trackVisitsLibraryHash,
        overlayLapKey: overlayLapKey,
        starredLapNumber: starredLapNumber,
      );

  /// Returns a copy with [overlayLapKey] set to `null`. Distinct from
  /// [copyWith] for the same reason as [clearMainLapNumber].
  Workspace clearOverlayLapKey() => Workspace(
        workspaceVersion: workspaceVersion,
        sessionId: sessionId,
        lapGates: lapGates,
        sectorGates: sectorGates,
        mathChannels: mathChannels,
        workbookLayout: workbookLayout,
        referenceLapNumber: referenceLapNumber,
        ignoredLapNumbers: ignoredLapNumbers,
        trackVisits: trackVisits,
        trackVisitsLibraryHash: trackVisitsLibraryHash,
        mainLapNumber: mainLapNumber,
        starredLapNumber: starredLapNumber,
      );

  /// Returns a copy with [starredLapNumber] set to `null` — restores the
  /// "fastest non-ignored lap" auto-derive default.
  Workspace clearStarredLapNumber() => Workspace(
        workspaceVersion: workspaceVersion,
        sessionId: sessionId,
        lapGates: lapGates,
        sectorGates: sectorGates,
        mathChannels: mathChannels,
        workbookLayout: workbookLayout,
        referenceLapNumber: referenceLapNumber,
        ignoredLapNumbers: ignoredLapNumbers,
        trackVisits: trackVisits,
        trackVisitsLibraryHash: trackVisitsLibraryHash,
        mainLapNumber: mainLapNumber,
        overlayLapKey: overlayLapKey,
      );

  /// Serializes to a JSON-encodable map.
  Map<String, dynamic> toJson() {
    // `math_channels` and `workbook_layout` removed in v6 — channels now live
    // on the owning Workbook; `workbook_layout` was never read in production.
    // The in-memory fields stay on the class so the migration pass can read
    // v5 files via [Workspace.fromJson] before they're rewritten.
    return {
      'workspace_version': workspaceVersion,
      'session_id': sessionId,
      'lap_gates': lapGates.map((g) => g.toJson()).toList(),
      'sector_gates': sectorGates.map((g) => g.toJson()).toList(),
      if (referenceLapNumber != null)
        'reference_lap_number': referenceLapNumber,
      // Sorted for stable on-disk diffs; consumers re-hydrate as a Set.
      if (ignoredLapNumbers.isNotEmpty)
        'ignored_lap_numbers': (ignoredLapNumbers.toList()..sort()),
      if (trackVisits.isNotEmpty)
        'track_visits': trackVisits.map((v) => v.toJson()).toList(),
      if (trackVisitsLibraryHash != null)
        'track_visits_library_hash': trackVisitsLibraryHash,
      if (mainLapNumber != null) 'main_lap_number': mainLapNumber,
      if (overlayLapKey != null)
        'overlay_lap_key': {
          'session_id': overlayLapKey!.sessionId,
          'lap_number': overlayLapKey!.lapNumber,
        },
      if (starredLapNumber != null) 'starred_lap_number': starredLapNumber,
    };
  }

  /// Deserializes from a JSON map.
  ///
  /// Throws [UnsupportedWorkspaceVersionException] if `workspace_version`
  /// exceeds [supportedVersion].
  ///
  /// Unknown fields are silently ignored — workspaces created by older app
  /// versions always load cleanly even as the schema grows.
  static Workspace fromJson(Map<String, dynamic> json) {
    final version = json['workspace_version'] as int;
    if (version > _kSupportedWorkspaceVersion) {
      throw UnsupportedWorkspaceVersionException(
        found: version,
        supported: _kSupportedWorkspaceVersion,
      );
    }

    return Workspace(
      workspaceVersion: version,
      sessionId: json['session_id'] as String,
      lapGates: (json['lap_gates'] as List<dynamic>? ?? [])
          .map((g) => LapGate.fromJson(g as Map<String, dynamic>))
          .toList(),
      sectorGates: (json['sector_gates'] as List<dynamic>? ?? [])
          .map((g) => SectorGate.fromJson(g as Map<String, dynamic>))
          .toList(),
      mathChannels: (json['math_channels'] as List<dynamic>? ?? [])
          .map((c) => MathChannel.fromJson(c as Map<String, dynamic>))
          .toList(),
      workbookLayout: WorkbookLayout.fromJson(
        json['workbook_layout'] as Map<String, dynamic>? ?? {},
      ),
      referenceLapNumber: json['reference_lap_number'] as int?,
      ignoredLapNumbers: (json['ignored_lap_numbers'] as List<dynamic>? ?? [])
          .map((e) => e as int)
          .toSet(),
      trackVisits: (json['track_visits'] as List<dynamic>? ?? [])
          .map((v) => TrackVisit.fromJson(v as Map<String, dynamic>))
          .toList(),
      trackVisitsLibraryHash: json['track_visits_library_hash'] as String?,
      mainLapNumber: json['main_lap_number'] as int?,
      overlayLapKey: _parseOverlayLapKey(json['overlay_lap_key']),
      starredLapNumber: json['starred_lap_number'] as int?,
    );
  }

  /// Parses the nested `overlay_lap_key` JSON object into a record. Returns
  /// `null` when the key is absent or `null`. v5 schema; older workspaces
  /// omit the key entirely.
  static ({String sessionId, int lapNumber})? _parseOverlayLapKey(
    dynamic raw,
  ) {
    if (raw == null) return null;
    final m = raw as Map<String, dynamic>;
    return (
      sessionId: m['session_id'] as String,
      lapNumber: m['lap_number'] as int,
    );
  }

  /// Reads a `.idl0w` file from [path] and deserializes it.
  ///
  /// Throws [UnsupportedWorkspaceVersionException] if the version is too new.
  /// Throws [FileSystemException] if the file cannot be read.
  static Future<Workspace> load(String path) async {
    final content = await File(path).readAsString();
    final json = jsonDecode(content) as Map<String, dynamic>;
    return Workspace.fromJson(json);
  }

  /// Serializes this workspace and writes it to [path] atomically.
  ///
  /// Writes to a `.tmp` sibling first, then renames to avoid corrupt files on
  /// crash mid-write.
  Future<void> save(String path) async {
    final tmp = '$path.tmp';
    await File(tmp).writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
    );
    await File(tmp).rename(path);
  }
}

/// Abstraction for persisting a [Workspace] to durable storage.
///
/// The production implementation ([FileWorkspaceSaver]) delegates to
/// [Workspace.save]. Tests inject a spy via this interface to verify
/// that save is called without touching the filesystem.
abstract class WorkspaceSaver {
  /// Writes [workspace] to durable storage.
  Future<void> save(Workspace workspace);
}

/// Production implementation — delegates to [Workspace.save].
class FileWorkspaceSaver implements WorkspaceSaver {
  /// Creates a [FileWorkspaceSaver] that writes to [path].
  const FileWorkspaceSaver(this.path);

  /// Absolute path to the `.idl0w` file.
  final String path;

  @override
  Future<void> save(Workspace workspace) => workspace.save(path);
}
