import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/gate_geometry.dart';
import 'package:idl0/data/lap_detector.dart';

void main() {
  // Synthetic east-running polyline at the equator. Lat constant; lon
  // increases by 0.0001° per step (~11 m). Internally the model stores
  // these as × 1e7, so multiply.
  List<GpsFix> polyline(int n) {
    return [
      for (var i = 0; i < n; i++)
        GpsFix(
          timestampMs: i * 1000,
          latitudeDeg: 0,
          longitudeDeg: i * 1000.0, // 0.0001° × 1e7 = 1000
        ),
    ];
  }

  test(
      'perpendicularGateAt — middle index produces gate perpendicular to '
      'east-running track', () {
    final poly = polyline(5);
    final gate = GateGeometry.perpendicularGateAt(
      polyline: poly,
      index: 2,
      widthMeters: 20,
    );
    // East-running tangent → perpendicular runs north–south. Both gate
    // posts share the same longitude (centre of index 2) within rounding.
    expect(gate.lon1Deg, closeTo(poly[2].longitudeDeg, 1));
    expect(gate.lon2Deg, closeTo(poly[2].longitudeDeg, 1));
    // Lat posts are offset symmetrically.
    final dLat1 = (gate.lat1Deg - poly[2].latitudeDeg).abs();
    final dLat2 = (gate.lat2Deg - poly[2].latitudeDeg).abs();
    expect(dLat1, closeTo(dLat2, 1));
    expect(dLat1, greaterThan(0));
  });

  test('perpendicularGateAt — at first index uses (0,1) tangent', () {
    final poly = polyline(5);
    final gate = GateGeometry.perpendicularGateAt(
        polyline: poly, index: 0, widthMeters: 20,);
    expect(gate.lon1Deg, closeTo(poly[0].longitudeDeg, 1));
  });

  test('perpendicularGateAt — at last index uses (N-2, N-1) tangent', () {
    final poly = polyline(5);
    final gate = GateGeometry.perpendicularGateAt(
        polyline: poly, index: 4, widthMeters: 20,);
    expect(gate.lon1Deg, closeTo(poly[4].longitudeDeg, 1));
  });

  test('snapToNearestFix returns the closest polyline index', () {
    final poly = polyline(5);
    // Coord halfway between fix 1 and fix 2 — should resolve to either,
    // here the closer one in lex-order is index 1.
    final idx = GateGeometry.snapToNearestFix(
      polyline: poly,
      latDeg: 0,
      lonDeg: 1500,
    );
    expect(idx, anyOf(1, 2));
  });

  test('snapToNearestFix exact match returns that index', () {
    final poly = polyline(5);
    final idx = GateGeometry.snapToNearestFix(
      polyline: poly,
      latDeg: poly[3].latitudeDeg,
      lonDeg: poly[3].longitudeDeg,
    );
    expect(idx, 3);
  });
}
