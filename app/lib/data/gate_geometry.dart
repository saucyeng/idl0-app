import 'dart:math' as math;

import 'lap_detector.dart';

/// Geometry helpers that synthesise [LapGate] objects from a reference
/// polyline. Used by GPX-as-Track import (Phase 2) — the user gets two
/// reasonable default gates at the start and finish of the imported
/// polyline, which they can re-place later in the gate-edit panel.
///
/// All inputs and outputs use the firmware × 1e7 coordinate scale (the
/// scale used by [LapGate] and [GpsFix.latitudeDeg] elsewhere).
class GateGeometry {
  GateGeometry._();

  /// Returns two gates derived from the start and end of [polyline] —
  /// each one is a line segment of total length [gateWidthMeters],
  /// centred on the endpoint, oriented perpendicular to the local track
  /// direction.
  ///
  /// `start` is built from `polyline[0]` and `polyline[1]`; `finish`
  /// from `polyline[N-2]` and `polyline[N-1]`. Returns `null` when
  /// [polyline] has fewer than 2 fixes (no direction is defined).
  ///
  /// Default width is 20 m — wide enough to register a crossing under
  /// typical 3–5 m GPS noise, narrow enough to avoid false positives
  /// from a parallel return path.
  static ({LapGate start, LapGate finish})? endpointGates(
    List<GpsFix> polyline, {
    double gateWidthMeters = 20.0,
  }) {
    if (polyline.length < 2) return null;

    final start = _perpendicularGate(
      atIndex: polyline[0],
      towards: polyline[1],
      widthMeters: gateWidthMeters,
      name: 'Start',
    );
    final finish = _perpendicularGate(
      atIndex: polyline[polyline.length - 1],
      towards: polyline[polyline.length - 2],
      widthMeters: gateWidthMeters,
      // Reverse direction at the finish: `towards` is the previous fix
      // (looking back along the track), so the perpendicular swings the
      // same way at finish as at start.
      name: 'Finish',
    );
    return (start: start, finish: finish);
  }

  /// Returns a [LapGate] of total length [widthMeters] centred on
  /// `polyline[index]`, perpendicular to the local tangent at that index.
  ///
  /// The tangent is computed from the segment `polyline[index] →
  /// polyline[index+1]`, except at the last index where the segment
  /// `polyline[index-1] → polyline[index]` is used instead. Throws
  /// [RangeError] if [index] is out of bounds or [polyline] has fewer than
  /// 2 fixes.
  static LapGate perpendicularGateAt({
    required List<GpsFix> polyline,
    required int index,
    double widthMeters = 20.0,
    String name = '',
  }) {
    if (polyline.length < 2) {
      throw RangeError('polyline must contain at least 2 fixes');
    }
    if (index < 0 || index >= polyline.length) {
      throw RangeError('index $index out of bounds for polyline of length '
          '${polyline.length}');
    }
    final at = polyline[index];
    final towards = (index + 1 < polyline.length)
        ? polyline[index + 1]
        : polyline[index - 1];
    return _perpendicularGate(
      atIndex: at,
      towards: towards,
      widthMeters: widthMeters,
      name: name,
    );
  }

  /// Returns the index of the polyline fix whose Euclidean lat/lon distance
  /// to `(latDeg, lonDeg)` is smallest. Coordinates use the same × 1e7
  /// scale as the polyline. Throws [RangeError] for empty polylines.
  static int snapToNearestFix({
    required List<GpsFix> polyline,
    required double latDeg,
    required double lonDeg,
  }) {
    if (polyline.isEmpty) {
      throw RangeError('polyline must not be empty');
    }
    var bestIdx = 0;
    var bestDistSq = double.infinity;
    for (var i = 0; i < polyline.length; i++) {
      final f = polyline[i];
      final dLat = f.latitudeDeg - latDeg;
      final dLon = f.longitudeDeg - lonDeg;
      final distSq = dLat * dLat + dLon * dLon;
      if (distSq < bestDistSq) {
        bestDistSq = distSq;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  /// Builds a [LapGate] of total length [widthMeters] centred on
  /// [atIndex], perpendicular to the segment from [atIndex] toward
  /// [towards]. Coords stay at the × 1e7 scale.
  static LapGate _perpendicularGate({
    required GpsFix atIndex,
    required GpsFix towards,
    required double widthMeters,
    required String name,
  }) {
    // Local-metre conversion factors. Lat: 1° ≈ 111,320 m. Lon: shrinks
    // by cos(lat). Coordinates are at × 1e7, so the constants fold the
    // factor in directly (× 1e7 deg → metres).
    const mPerDegUnits = 111320.0 / 1e7;
    final latDeg = atIndex.latitudeDeg / 1e7;
    final lonScale = mPerDegUnits * math.cos(latDeg * math.pi / 180.0).abs();

    // Direction vector along the track in metric units.
    final dxM = (towards.latitudeDeg - atIndex.latitudeDeg) * mPerDegUnits;
    final dyM = (towards.longitudeDeg - atIndex.longitudeDeg) * lonScale;
    final length = math.sqrt(dxM * dxM + dyM * dyM);
    if (length == 0) {
      // Degenerate: identical points. Return a zero-length gate at the
      // point — caller will recognise it as invalid via lap_detector's
      // existing length check.
      return LapGate(
        lat1Deg: atIndex.latitudeDeg,
        lon1Deg: atIndex.longitudeDeg,
        lat2Deg: atIndex.latitudeDeg,
        lon2Deg: atIndex.longitudeDeg,
        name: name,
      );
    }

    // Perpendicular unit vector in metric units (rotate 90° CCW: (x,y)→(-y,x)).
    final perpDxM = -dyM / length;
    final perpDyM = dxM / length;

    // Half-width offsets, converted back to × 1e7 deg.
    final halfWidth = widthMeters / 2.0;
    final dLatUnits = (perpDxM * halfWidth) / mPerDegUnits;
    final dLonUnits = (perpDyM * halfWidth) / lonScale;

    return LapGate(
      lat1Deg: atIndex.latitudeDeg + dLatUnits,
      lon1Deg: atIndex.longitudeDeg + dLonUnits,
      lat2Deg: atIndex.latitudeDeg - dLatUnits,
      lon2Deg: atIndex.longitudeDeg - dLonUnits,
      name: name,
    );
  }
}
