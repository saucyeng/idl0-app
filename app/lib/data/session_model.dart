import 'dart:convert';
import 'lap_timing.dart';

/// Snapshot of a bike profile taken at session creation time. See §19.1.
class BikeProfile {
  /// Stable UUID for this profile.
  final String profileId;

  /// Human-readable bike name, e.g. `Trek Session 2024`.
  final String name;

  /// Frame type: `full_suspension`, `hardtail`, or `ebike`.
  final String type;

  /// Number of IMUs mounted on this bike (1–3).
  final int imuCount;

  /// Rider name pre-populated on every new session. Overridable per session.
  final String defaultRider;

  /// Front wheel circumference in millimetres, used for wheel-speed distance.
  final int wheelCircumferenceFrontMm;

  /// Rear wheel circumference in millimetres.
  final int wheelCircumferenceRearMm;

  /// Creates a [BikeProfile].
  const BikeProfile({
    required this.profileId,
    required this.name,
    required this.type,
    required this.imuCount,
    required this.defaultRider,
    required this.wheelCircumferenceFrontMm,
    required this.wheelCircumferenceRearMm,
  });

  /// Deserializes from the JSON object stored inside `idl0_config.json`.
  factory BikeProfile.fromJson(Map<String, dynamic> json) => BikeProfile(
        profileId: json['profile_id'] as String? ?? '',
        name: json['name'] as String,
        type: json['type'] as String,
        imuCount: json['imu_count'] as int,
        defaultRider: json['default_rider'] as String? ?? '',
        wheelCircumferenceFrontMm:
            json['wheel_circumference_front_mm'] as int? ?? 0,
        wheelCircumferenceRearMm:
            json['wheel_circumference_rear_mm'] as int? ?? 0,
      );

  /// Serializes to JSON.
  Map<String, dynamic> toJson() => {
        'profile_id': profileId,
        'name': name,
        'type': type,
        'imu_count': imuCount,
        'default_rider': defaultRider,
        'wheel_circumference_front_mm': wheelCircumferenceFrontMm,
        'wheel_circumference_rear_mm': wheelCircumferenceRearMm,
      };
}

/// Origin of a session — distinguishes device-recorded `.idl0` files from
/// external imports (currently `.gpx` from Garmin Connect / Strava). See §12.
enum SessionSourceType {
  /// Recorded by an IDL0 device and downloaded as a `.idl0` binary log.
  idl0,

  /// Imported from a third-party `.gpx` track (Garmin / Strava).
  gpx,
}

/// Per-session metadata shown in the Runs tab library. See §12.1.
///
/// All string fields default to empty string rather than null so the UI
/// never needs to null-check them before display.
class SessionMetadata {
  /// UUID assigned at download time.
  final String sessionId;

  /// Absolute path to the immutable `.idl0` raw log file.
  final String filePath;

  /// Absolute path to the mutable `.idl0w` workspace file.
  final String workspacePath;

  /// Session creation timestamp in UTC milliseconds since Unix epoch.
  final int createdTimestampMs;

  /// Size of the `.idl0` raw log file in bytes.
  final int fileSizeBytes;

  /// Rider name. Pre-populated from [BikeProfile.defaultRider]. Overridable.
  final String rider;

  /// Bike name, e.g. `Trek Session 2024`.
  final String bike;

  /// Bike setup note for this session, e.g. `Fresh tires`.
  final String bikeComment;

  /// Venue name, pre-filled from most recent session at same location.
  final String venueName;

  /// Competition / riding event name.
  final String eventName;

  /// Session within the event, e.g. `Practice 2` or `Race run`.
  final String eventSession;

  /// One-line comment shown in the session list.
  final String shortComment;

  /// Free-form notes about this session.
  final String longComment;

  /// Device ID, last 4 hex digits of MAC, e.g. `A3F1`.
  final String deviceId;

  /// Completed lap count, or `null` if no gate has been set yet.
  final int? lapCount;

  /// Session duration in milliseconds, or `null` if not yet computed.
  ///
  /// Computed from the primary IMU channel via [computeDurationMs].
  final int? durationMs;

  /// Origin of this session. [SessionSourceType.idl0] for device-recorded
  /// sessions; [SessionSourceType.gpx] for imported Garmin/Strava tracks.
  ///
  /// Drives parser dispatch and Runs-tab badging; defaults to `idl0` so
  /// existing call sites and persisted rows pre-dating this field continue
  /// to work unchanged.
  final SessionSourceType sourceType;

  /// Free-text user-set label for this session, e.g. `Practice`, `Heat 1`,
  /// `Race`, `Warmup`. Drives the tag chip filter in the Runs tab
  /// hierarchical view. Defaults to `''` (no tag) so pre-existing rows
  /// load unchanged after the v4 SessionIndex migration.
  ///
  /// Track binding is no longer per-session — see [Workspace.trackVisits]
  /// (v4) for the multi-track replacement of the v3 `trackId` field.
  final String tag;

  /// Creates a [SessionMetadata].
  const SessionMetadata({
    required this.sessionId,
    required this.filePath,
    required this.workspacePath,
    required this.createdTimestampMs,
    required this.fileSizeBytes,
    required this.rider,
    required this.bike,
    required this.bikeComment,
    required this.venueName,
    required this.eventName,
    required this.eventSession,
    required this.shortComment,
    required this.longComment,
    required this.deviceId,
    this.lapCount,
    this.durationMs,
    this.sourceType = SessionSourceType.idl0,
    this.tag = '',
  });

  /// Creates a [SessionMetadata] pre-populated from a [BikeProfile].
  ///
  /// [rider] is set to [BikeProfile.defaultRider]; [bike] is set to
  /// [BikeProfile.name]. All other editable fields default to empty string.
  factory SessionMetadata.fromBikeProfile(
    BikeProfile profile, {
    required String sessionId,
    required String filePath,
    required String workspacePath,
    required int createdTimestampMs,
    required int fileSizeBytes,
    required String deviceId,
  }) =>
      SessionMetadata(
        sessionId: sessionId,
        filePath: filePath,
        workspacePath: workspacePath,
        createdTimestampMs: createdTimestampMs,
        fileSizeBytes: fileSizeBytes,
        rider: profile.defaultRider,
        bike: profile.name,
        bikeComment: '',
        venueName: '',
        eventName: '',
        eventSession: '',
        shortComment: '',
        longComment: '',
        deviceId: deviceId,
      );

  /// Computes session duration in milliseconds from [sampleCount] samples
  /// recorded at [sampleRateHz] samples per second.
  ///
  /// Example: 800,000 samples at 800 Hz → 1,000,000 ms (1,000 s).
  static int computeDurationMs(int sampleCount, double sampleRateHz) =>
      ((sampleCount / sampleRateHz) * 1000).round();

  /// Deserializes from the JSON object stored in `.idl0w` or the SQLite index.
  factory SessionMetadata.fromJson(Map<String, dynamic> json) =>
      SessionMetadata(
        sessionId: json['session_id'] as String,
        filePath: json['file_path'] as String,
        workspacePath: json['workspace_path'] as String,
        createdTimestampMs: json['created_timestamp_ms'] as int,
        fileSizeBytes: json['file_size_bytes'] as int,
        rider: json['rider'] as String? ?? '',
        bike: json['bike'] as String? ?? '',
        bikeComment: json['bike_comment'] as String? ?? '',
        venueName: json['venue_name'] as String? ?? '',
        eventName: json['event_name'] as String? ?? '',
        eventSession: json['event_session'] as String? ?? '',
        shortComment: json['short_comment'] as String? ?? '',
        longComment: json['long_comment'] as String? ?? '',
        deviceId: json['device_id'] as String? ?? '',
        lapCount: json['lap_count'] as int?,
        durationMs: json['duration_ms'] as int?,
        sourceType: _parseSourceType(json['source_type'] as String?),
        tag: json['tag'] as String? ?? '',
      );

  /// Serializes to JSON.
  Map<String, dynamic> toJson() => {
        'session_id': sessionId,
        'file_path': filePath,
        'workspace_path': workspacePath,
        'created_timestamp_ms': createdTimestampMs,
        'file_size_bytes': fileSizeBytes,
        'rider': rider,
        'bike': bike,
        'bike_comment': bikeComment,
        'venue_name': venueName,
        'event_name': eventName,
        'event_session': eventSession,
        'short_comment': shortComment,
        'long_comment': longComment,
        'device_id': deviceId,
        if (lapCount != null) 'lap_count': lapCount,
        if (durationMs != null) 'duration_ms': durationMs,
        'source_type': sourceType.name,
        if (tag.isNotEmpty) 'tag': tag,
      };

  /// Returns a copy with the given fields replaced.
  ///
  /// [filePath], [workspacePath], and [createdTimestampMs] are overridable so
  /// the file-naming/timestamp repair (SPEC §5.6 / §15) can rewrite a session's
  /// on-disk paths and corrected recording time in place; all other identity
  /// fields ([sessionId], [deviceId], [fileSizeBytes]) are preserved.
  SessionMetadata copyWith({
    String? filePath,
    String? workspacePath,
    int? createdTimestampMs,
    String? rider,
    String? bike,
    String? bikeComment,
    String? venueName,
    String? eventName,
    String? eventSession,
    String? shortComment,
    String? longComment,
    int? lapCount,
    int? durationMs,
    String? tag,
  }) =>
      SessionMetadata(
        sessionId: sessionId,
        filePath: filePath ?? this.filePath,
        workspacePath: workspacePath ?? this.workspacePath,
        createdTimestampMs: createdTimestampMs ?? this.createdTimestampMs,
        fileSizeBytes: fileSizeBytes,
        rider: rider ?? this.rider,
        bike: bike ?? this.bike,
        bikeComment: bikeComment ?? this.bikeComment,
        venueName: venueName ?? this.venueName,
        eventName: eventName ?? this.eventName,
        eventSession: eventSession ?? this.eventSession,
        shortComment: shortComment ?? this.shortComment,
        longComment: longComment ?? this.longComment,
        deviceId: deviceId,
        lapCount: lapCount ?? this.lapCount,
        durationMs: durationMs ?? this.durationMs,
        sourceType: sourceType,
        tag: tag ?? this.tag,
      );

  static SessionSourceType _parseSourceType(String? raw) {
    if (raw == null) return SessionSourceType.idl0;
    for (final t in SessionSourceType.values) {
      if (t.name == raw) return t;
    }
    return SessionSourceType.idl0;
  }
}

/// One sub-division of a lap between two sector gates. See §14.3.
class Sector {
  /// Display name, e.g. `S1`, `S2`, or a venue-specific name like `Rock garden`.
  final String name;

  /// Sector start in UTC milliseconds.
  final int startTimestampMs;

  /// Sector end in UTC milliseconds.
  final int endTimestampMs;

  /// Recording-time seconds of [startTimestampMs] (engine-computed; 0.0 when
  /// constructed outside the lap detector, e.g. test/UI fixtures).
  final double startTimeSecs;

  /// Recording-time seconds of [endTimestampMs].
  final double endTimeSecs;

  /// Elapsed time for this sector in milliseconds.
  ///
  /// Equal to `endTimestampMs - startTimestampMs`.
  int get sectorTimeMs => endTimestampMs - startTimestampMs;

  /// Creates a [Sector].
  const Sector({
    required this.name,
    required this.startTimestampMs,
    required this.endTimestampMs,
    this.startTimeSecs = 0.0,
    this.endTimeSecs = 0.0,
  });

  /// Deserializes from JSON.
  factory Sector.fromJson(Map<String, dynamic> json) => Sector(
        name: json['name'] as String,
        startTimestampMs: json['start_timestamp_ms'] as int,
        endTimestampMs: json['end_timestamp_ms'] as int,
        startTimeSecs: (json['start_time_secs'] as num?)?.toDouble() ?? 0.0,
        endTimeSecs: (json['end_time_secs'] as num?)?.toDouble() ?? 0.0,
      );

  /// Serializes to JSON.
  Map<String, dynamic> toJson() => {
        'name': name,
        'start_timestamp_ms': startTimestampMs,
        'end_timestamp_ms': endTimestampMs,
        'start_time_secs': startTimeSecs,
        'end_time_secs': endTimeSecs,
      };
}

/// One complete lap, bounded by consecutive start/finish gate crossings.
/// See §12.2 and §14.3.
///
/// Lap 1 starts at the first sample of the session and ends at the first
/// gate crossing. Subsequent laps start at the previous crossing.
class Lap {
  /// 1-based lap number within the session.
  final int lapNumber;

  /// Lap start in UTC milliseconds.
  final int startTimestampMs;

  /// Lap end (gate crossing) in UTC milliseconds.
  final int endTimestampMs;

  /// Recording-time seconds of [startTimestampMs] (engine-computed; 0.0 when
  /// constructed outside the lap detector, e.g. test/UI fixtures).
  final double startTimeSecs;

  /// Recording-time seconds of [endTimestampMs].
  final double endTimeSecs;

  /// Total elapsed wall-clock duration of the lap in milliseconds.
  /// Equal to `endTimestampMs - startTimestampMs`.
  final int rawElapsedMs;

  /// Effective lap time in milliseconds. Equals [rawElapsedMs] when no
  /// neutral zones were crossed; otherwise [rawElapsedMs] minus the sum of
  /// every [neutralZoneVisits] duration.
  final int lapTimeMs;

  /// Sector splits within this lap. Empty when no sector gates are defined.
  ///
  /// When non-empty, the sum of all [Sector.sectorTimeMs] equals [lapTimeMs]
  /// (within floating-point rounding of the interpolated crossing timestamps).
  final List<Sector> sectors;

  /// Detected neutral-zone enter→exit pairs that fell within this lap.
  /// Used by the lap-table UI to disclose what was excluded and why.
  final List<NeutralZoneVisit> neutralZoneVisits;

  /// Creates a [Lap].
  const Lap({
    required this.lapNumber,
    required this.startTimestampMs,
    required this.endTimestampMs,
    required this.rawElapsedMs,
    required this.lapTimeMs,
    this.startTimeSecs = 0.0,
    this.endTimeSecs = 0.0,
    this.sectors = const [],
    this.neutralZoneVisits = const [],
  });

  /// Deserializes from JSON.
  ///
  /// Accepts legacy v1 records that lack `raw_elapsed_ms` /
  /// `lap_time_ms` / `neutral_zone_visits` — those default to
  /// `(end - start)` / `(end - start)` / `[]` respectively.
  factory Lap.fromJson(Map<String, dynamic> json) {
    final start = json['start_timestamp_ms'] as int;
    final end = json['end_timestamp_ms'] as int;
    final raw = (json['raw_elapsed_ms'] as int?) ?? (end - start);
    final time = (json['lap_time_ms'] as int?) ?? raw;
    return Lap(
      lapNumber: json['lap_number'] as int,
      startTimestampMs: start,
      endTimestampMs: end,
      rawElapsedMs: raw,
      lapTimeMs: time,
      startTimeSecs: (json['start_time_secs'] as num?)?.toDouble() ?? 0.0,
      endTimeSecs: (json['end_time_secs'] as num?)?.toDouble() ?? 0.0,
      sectors: (json['sectors'] as List<dynamic>? ?? [])
          .map((s) => Sector.fromJson(s as Map<String, dynamic>))
          .toList(),
      neutralZoneVisits: (json['neutral_zone_visits'] as List<dynamic>? ?? [])
          .map((v) => NeutralZoneVisit.fromJson(v as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Serializes to JSON.
  Map<String, dynamic> toJson() => {
        'lap_number': lapNumber,
        'start_timestamp_ms': startTimestampMs,
        'end_timestamp_ms': endTimestampMs,
        'start_time_secs': startTimeSecs,
        'end_time_secs': endTimeSecs,
        'raw_elapsed_ms': rawElapsedMs,
        'lap_time_ms': lapTimeMs,
        'sectors': sectors.map((s) => s.toJson()).toList(),
        'neutral_zone_visits':
            neutralZoneVisits.map((v) => v.toJson()).toList(),
      };
}

/// Time-series data for a single sensor channel within a session. See §12.2.
class ChannelData {
  /// Registry name for this channel, e.g. `IMU0_AccelZ` or `WheelFront`.
  final String channelId;

  /// Nominal sample rate in Hz. 0 indicates event-driven (variable rate).
  final double sampleRateHz;

  /// Sample values in physical units. The parser applies the channel registry's
  /// `scale` and `offset` (§5.2) at parse time, so IMU channels come out in g
  /// and dps directly.
  final List<double> samples;

  /// Per-sample timestamps in seconds, for event-driven channels
  /// ([sampleRateHz] == 0) such as HR_RR (one sample per heartbeat),
  /// wheel-pulse, and digital-marker channels. `null` for fixed-rate
  /// channels, whose sample `i` is implicitly at `i / sampleRateHz`.
  ///
  /// Times are relative to session t=0, defined as the earliest record
  /// `timestamp_us` in the file (the first IMU/sensor sample) so event-driven
  /// channels share the same zero as fixed-rate channels and line up under the
  /// synchronized cursor. Without this, an irregular channel plotted at the
  /// fallback 1 Hz is stretched by its mean event rate — e.g. HR_RR at ~120 bpm
  /// would span 2× the real session duration. See §5.7, §15.2, §21.2.
  final List<double>? sampleTimesSecs;

  /// Creates a [ChannelData].
  const ChannelData({
    required this.channelId,
    required this.sampleRateHz,
    required this.samples,
    this.sampleTimesSecs,
  });

  /// Duration of this channel's data in milliseconds.
  ///
  /// Fixed-rate channels: `samples.length / sampleRateHz * 1000`. Event-driven
  /// channels ([sampleRateHz] == 0): the last entry of [sampleTimesSecs] in ms,
  /// or 0 when no per-sample times are available.
  int get durationMs {
    if (sampleRateHz == 0) {
      final times = sampleTimesSecs;
      if (times == null || times.isEmpty) return 0;
      return (times.last * 1000).round();
    }
    return ((samples.length / sampleRateHz) * 1000).round();
  }
}

/// Channel *metadata* for a specific session, bundled for rendering in the
/// Analyze tab. Carries **no samples** — every chart self-sources its bounded
/// view (decimated tiles, Y-bounds, spectrum, lap slice) from the retained
/// `SessionHandle` by [channelId] (§15.3). Pairs [sessionId] with the channel's
/// identity + shape so the chart layer can colour and label each line by session
/// when multiple sessions are overlaid on the same axes. See §14.1 and §14.4.
class SessionChannelData {
  /// UUID of the session this channel belongs to.
  final String sessionId;

  /// Registry/display name — the id each chart decimates by from the handle
  /// (e.g. `IMU0_AccelZ`, a math channel's name, or a lap-sliced `'… (main)'`).
  final String channelId;

  /// Nominal sample rate in Hz. 0 indicates event-driven (variable rate).
  final double sampleRateHz;

  /// Number of samples — for empty-checks and full-range derivation without
  /// holding the sample array in Dart.
  final int length;

  /// True for event-driven channels (per-sample times; [sampleRateHz] == 0).
  final bool isEventDriven;

  /// Creates a [SessionChannelData].
  const SessionChannelData({
    required this.sessionId,
    required this.channelId,
    required this.sampleRateHz,
    required this.length,
    required this.isEventDriven,
  });
}

/// In-memory representation of a downloaded session. See §12.2.
///
/// The `.idl0` file is the source of truth; this object is the parsed view.
/// Lap and sector data are stored in the companion `.idl0w` workspace file.
class Session {
  /// UUID matching the session header in the `.idl0` file.
  final String sessionId;

  /// Device ID, last 4 hex digits of MAC, e.g. `A3F1`.
  final String deviceId;

  /// Session start in UTC milliseconds, GPS-anchored when available.
  final int timestampUtcMs;

  /// JSON-encoded snapshot of the bike profile at recording time.
  ///
  /// Stored as a string so it survives profile edits without losing history.
  final String bikeProfileSnapshot;

  /// CRC32 of `idl0_config.json` at recording time, for drift detection.
  final String configChecksum;

  /// Detected laps. Empty until a start/finish gate is placed.
  final List<Lap> laps;

  /// Parsed channel data, one entry per enabled channel in the session.
  final List<ChannelData> channels;

  /// Creates a [Session].
  const Session({
    required this.sessionId,
    required this.deviceId,
    required this.timestampUtcMs,
    required this.bikeProfileSnapshot,
    required this.configChecksum,
    this.laps = const [],
    this.channels = const [],
  });

  /// Decodes the [bikeProfileSnapshot] back into a [BikeProfile].
  ///
  /// Returns `null` if the snapshot is empty or malformed.
  BikeProfile? get bikeProfile {
    if (bikeProfileSnapshot.isEmpty) return null;
    try {
      return BikeProfile.fromJson(
        jsonDecode(bikeProfileSnapshot) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }
}
