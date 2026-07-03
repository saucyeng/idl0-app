// GPS / gate / sector model classes used by the Track entity and workspace.
//
// GPS-fix assembly, lap detection, and track matching all run in the `idl-rs`
// engine now (`idl_rs::gps`, `idl_rs::laps`, `idl_rs::tracks`); this file is the
// Dart home for the stored data classes those features serialize.

/// A single GPS position with timestamp, as decoded from a GPS_FIX record.
class GpsFix {
  /// UTC milliseconds since Unix epoch, GPS-anchored.
  final int timestampMs;

  /// Latitude in decimal degrees (WGS-84).
  final double latitudeDeg;

  /// Longitude in decimal degrees (WGS-84).
  final double longitudeDeg;

  /// Creates a [GpsFix].
  const GpsFix({
    required this.timestampMs,
    required this.latitudeDeg,
    required this.longitudeDeg,
  });

  /// Deserializes from JSON. Used by the Track entity reference polyline.
  factory GpsFix.fromJson(Map<String, dynamic> json) => GpsFix(
        timestampMs: json['timestamp_ms'] as int,
        latitudeDeg: (json['latitude_deg'] as num).toDouble(),
        longitudeDeg: (json['longitude_deg'] as num).toDouble(),
      );

  /// Serializes to JSON. Used by the Track entity reference polyline.
  Map<String, dynamic> toJson() => {
        'timestamp_ms': timestampMs,
        'latitude_deg': latitudeDeg,
        'longitude_deg': longitudeDeg,
      };
}

/// A gate line segment defined by two GPS points. Used for start/finish and
/// sector gates.
///
/// The gate is the straight line between the two posts. A lap or sector
/// boundary is recorded when the GPS track crosses this line.
///
/// Coordinates are stored at the same scale as `GPS_Latitude` /
/// `GPS_Longitude` channel samples — degrees × 1e7 (firmware native i32
/// encoding, see §5.5). This keeps gate / track comparison scale-agnostic.
class LapGate {
  /// Latitude of gate post 1 (degrees × 1e7).
  final double lat1Deg;

  /// Longitude of gate post 1 (degrees × 1e7).
  final double lon1Deg;

  /// Latitude of gate post 2 (degrees × 1e7).
  final double lat2Deg;

  /// Longitude of gate post 2 (degrees × 1e7).
  final double lon2Deg;

  /// Display name for this gate, e.g. `Start/Finish` or `Top of straight`.
  ///
  /// Empty string means "unnamed" — UI surfaces fall back to a default
  /// label (`Start/Finish` for the first lap gate, `S<n>` for sectors).
  /// Added in workspace_version 2; v1 files load with [name] = `''`.
  final String name;

  /// Creates a [LapGate].
  const LapGate({
    required this.lat1Deg,
    required this.lon1Deg,
    required this.lat2Deg,
    required this.lon2Deg,
    this.name = '',
  });

  /// Deserializes from JSON. Tolerates missing `name` (workspace v1 files).
  factory LapGate.fromJson(Map<String, dynamic> json) => LapGate(
        lat1Deg: (json['lat1_deg'] as num).toDouble(),
        lon1Deg: (json['lon1_deg'] as num).toDouble(),
        lat2Deg: (json['lat2_deg'] as num).toDouble(),
        lon2Deg: (json['lon2_deg'] as num).toDouble(),
        name: json['name'] as String? ?? '',
      );

  /// Serializes to JSON. `name` is always emitted (empty string when unset)
  /// so v2 readers always see the field.
  Map<String, dynamic> toJson() => {
        'lat1_deg': lat1Deg,
        'lon1_deg': lon1Deg,
        'lat2_deg': lat2Deg,
        'lon2_deg': lon2Deg,
        'name': name,
      };

  /// Returns a copy of this gate with [name] replaced.
  LapGate withName(String newName) => LapGate(
        lat1Deg: lat1Deg,
        lon1Deg: lon1Deg,
        lat2Deg: lat2Deg,
        lon2Deg: lon2Deg,
        name: newName,
      );
}

/// A named sector gate placed between the start and finish gates. See §14.3.
class SectorGate {
  /// Display name shown in the lap time table, e.g. `S1` or `Rock garden`.
  final String name;

  /// The gate line for this sector boundary.
  final LapGate gate;

  /// Creates a [SectorGate].
  const SectorGate({required this.name, required this.gate});

  /// Deserializes from JSON.
  factory SectorGate.fromJson(Map<String, dynamic> json) => SectorGate(
        name: json['name'] as String,
        gate: LapGate.fromJson(json['gate'] as Map<String, dynamic>),
      );

  /// Serializes to JSON.
  Map<String, dynamic> toJson() => {
        'name': name,
        'gate': gate.toJson(),
      };
}
