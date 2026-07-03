import 'dart:math' as math;
import 'lap_detector.dart';

/// Per-sample distance map for one lap, normalised to the canonical
/// polyline using confidence-based anchor redistribution. See variance-
/// architecture design doc §4.
class LapDistanceAccumulator {
  /// Per-sample arc length on the canonical polyline, anchor-corrected
  /// so cumulative GPS drift doesn't bias the comparison. Same length
  /// as the input sample list. Strictly monotonic.
  final List<double> normalisedDistance;

  /// Per-sample perpendicular residual from the canonical polyline,
  /// in metres. Useful for diagnostics / variance confidence weighting.
  final List<double> residual;

  /// Per-sample tangent agreement (cosine of angle between the rider's
  /// local direction and the polyline tangent at the projection).
  final List<double> tangentAgreement;

  /// Creates a [LapDistanceAccumulator].
  const LapDistanceAccumulator({
    required this.normalisedDistance,
    required this.residual,
    required this.tangentAgreement,
  });

  /// Metres per degree of latitude (WGS-84 mean). Used together with
  /// `cos(meanLat)` to scale longitude differences to metres.
  static const double _kMetresPerDegLat = 111320.0;

  /// Maximum perpendicular residual (metres) for a sample to qualify
  /// as a confidence anchor.
  static const double _kAnchorResidualMetres = 5.0;

  /// Minimum tangent-agreement cosine (cos(30°) ≈ 0.866) for a sample
  /// to qualify as a confidence anchor.
  static const double _kAnchorTangentCos = 0.866;

  /// Minimum speed (km/h) for a sample to qualify as a confidence
  /// anchor. Below this, GPS direction is unreliable.
  static const double _kAnchorMinSpeedKmh = 5.0;

  /// Computes the normalised distance map for one lap.
  ///
  /// [samples] are the lap's GPS fixes in chronological order.
  /// [polyline] is the canonical polyline (typically `Track.canonicalPolyline`,
  /// falling back to `Track.referencePolyline` upstream).
  /// [speedKmh] is the lap's per-sample speed (parallel to `samples`).
  /// [startGateDistance] and [finishGateDistance] are the known polyline
  /// distances of the lap's start and finish gates respectively (null
  /// → use 0 / polylineLength as the implicit endpoints).
  /// [gateCrossings] is a list of `(sampleIndex, knownPolylineDistance)`
  /// pairs for sector gates the lap crosses.
  ///
  /// See spec §4 for algorithm details.
  static LapDistanceAccumulator compute({
    required List<GpsFix> samples,
    required List<GpsFix> polyline,
    required List<double> speedKmh,
    required double? startGateDistance,
    required double? finishGateDistance,
    required List<({int sampleIndex, double knownDistance})> gateCrossings,
  }) {
    final n = samples.length;
    if (n == 0 || polyline.length < 2) {
      return LapDistanceAccumulator(
        normalisedDistance: List<double>.filled(n, 0.0),
        residual: List<double>.filled(n, 0.0),
        tangentAgreement: List<double>.filled(n, 0.0),
      );
    }

    // 1) Per-call mean-latitude scale.
    var latSum = 0.0;
    for (final fix in polyline) {
      latSum += fix.latitudeDeg;
    }
    final meanLatRad = (latSum / polyline.length) * math.pi / 180.0;
    final lonScale = _kMetresPerDegLat * math.cos(meanLatRad);

    // 2) Cumulative arc lengths along the polyline (for projection
    // → polyline-distance conversion).
    final polylineCum = List<double>.filled(polyline.length, 0.0);
    for (var k = 1; k < polyline.length; k++) {
      final dxLon =
          (polyline[k].longitudeDeg - polyline[k - 1].longitudeDeg) * lonScale;
      final dyLat = (polyline[k].latitudeDeg - polyline[k - 1].latitudeDeg) *
          _kMetresPerDegLat;
      polylineCum[k] =
          polylineCum[k - 1] + math.sqrt(dxLon * dxLon + dyLat * dyLat);
    }
    final polylineLength = polylineCum.last;

    // 3) Per-sample projection: closest-point + arc length + residual
    // + tangent agreement.
    final polylineDistance = List<double>.filled(n, 0.0);
    final residual = List<double>.filled(n, 0.0);
    final tangentAgreement = List<double>.filled(n, 0.0);
    for (var i = 0; i < n; i++) {
      final s = samples[i];
      var bestSq = double.infinity;
      var bestK = 0;
      var bestT = 0.0;
      for (var k = 0; k < polyline.length - 1; k++) {
        final a = polyline[k];
        final b = polyline[k + 1];
        final dxLon = (b.longitudeDeg - a.longitudeDeg) * lonScale;
        final dyLat = (b.latitudeDeg - a.latitudeDeg) * _kMetresPerDegLat;
        final lenSq = dxLon * dxLon + dyLat * dyLat;
        double t;
        if (lenSq == 0.0) {
          t = 0.0;
        } else {
          final pxLon = (s.longitudeDeg - a.longitudeDeg) * lonScale;
          final pyLat = (s.latitudeDeg - a.latitudeDeg) * _kMetresPerDegLat;
          t = (pxLon * dxLon + pyLat * dyLat) / lenSq;
          if (t < 0) t = 0;
          if (t > 1) t = 1;
        }
        final cxLon = a.longitudeDeg * lonScale + t * dxLon;
        final cyLat = a.latitudeDeg * _kMetresPerDegLat + t * dyLat;
        final ex = s.longitudeDeg * lonScale - cxLon;
        final ey = s.latitudeDeg * _kMetresPerDegLat - cyLat;
        final distSq = ex * ex + ey * ey;
        if (distSq < bestSq) {
          bestSq = distSq;
          bestK = k;
          bestT = t;
        }
      }
      final segLen = polylineCum[bestK + 1] - polylineCum[bestK];
      polylineDistance[i] = polylineCum[bestK] + bestT * segLen;
      residual[i] = math.sqrt(bestSq);

      // Tangent agreement — local sample tangent vs polyline tangent
      // at the projection segment.
      if (i > 0 && i < n - 1) {
        final stx =
            (samples[i + 1].longitudeDeg - samples[i - 1].longitudeDeg) *
                lonScale;
        final sty = (samples[i + 1].latitudeDeg - samples[i - 1].latitudeDeg) *
            _kMetresPerDegLat;
        final stLen = math.sqrt(stx * stx + sty * sty);
        final ptx =
            (polyline[bestK + 1].longitudeDeg - polyline[bestK].longitudeDeg) *
                lonScale;
        final pty =
            (polyline[bestK + 1].latitudeDeg - polyline[bestK].latitudeDeg) *
                _kMetresPerDegLat;
        final ptLen = math.sqrt(ptx * ptx + pty * pty);
        if (stLen > 1e-6 && ptLen > 1e-6) {
          tangentAgreement[i] = (stx * ptx + sty * pty) / (stLen * ptLen);
        }
      }
    }

    // 4) Cumulative arc length of the lap's raw path (drifty, but its
    // *fractional position* between anchors is what we redistribute).
    final cumulativeArc = List<double>.filled(n, 0.0);
    for (var i = 1; i < n; i++) {
      final dxLon =
          (samples[i].longitudeDeg - samples[i - 1].longitudeDeg) * lonScale;
      final dyLat = (samples[i].latitudeDeg - samples[i - 1].latitudeDeg) *
          _kMetresPerDegLat;
      cumulativeArc[i] =
          cumulativeArc[i - 1] + math.sqrt(dxLon * dxLon + dyLat * dyLat);
    }

    // 5) Build the anchor list: start, finish, gate crossings,
    // confidence-qualifying samples. Sorted by sample index.
    final anchors = <({int idx, double distance})>[
      (idx: 0, distance: startGateDistance ?? 0.0),
    ];
    for (final g in gateCrossings) {
      anchors.add((idx: g.sampleIndex, distance: g.knownDistance));
    }
    for (var i = 0; i < n; i++) {
      if (residual[i] < _kAnchorResidualMetres &&
          tangentAgreement[i] > _kAnchorTangentCos &&
          speedKmh[i] > _kAnchorMinSpeedKmh) {
        anchors.add((idx: i, distance: polylineDistance[i]));
      }
    }
    anchors.add((
      idx: n - 1,
      distance: finishGateDistance ?? polylineLength,
    ),);
    anchors.sort((a, b) => a.idx.compareTo(b.idx));

    // 6) Linear redistribution between consecutive anchor pairs.
    final normalisedDistance = List<double>.filled(n, 0.0);
    for (var a = 0; a < anchors.length - 1; a++) {
      final lo = anchors[a];
      final hi = anchors[a + 1];
      normalisedDistance[lo.idx] = lo.distance;
      if (hi.idx <= lo.idx) continue;
      final span = cumulativeArc[hi.idx] - cumulativeArc[lo.idx];
      for (var k = lo.idx + 1; k <= hi.idx; k++) {
        if (span < 1e-6) {
          normalisedDistance[k] = lo.distance;
        } else {
          final frac = (cumulativeArc[k] - cumulativeArc[lo.idx]) / span;
          normalisedDistance[k] =
              lo.distance + frac * (hi.distance - lo.distance);
        }
      }
    }

    return LapDistanceAccumulator(
      normalisedDistance: normalisedDistance,
      residual: residual,
      tangentAgreement: tangentAgreement,
    );
  }
}
