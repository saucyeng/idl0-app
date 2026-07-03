import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/gate_geometry.dart';
import 'package:idl0/data/lap_detector.dart';

/// Whistler-area test point for sane lon-scale arithmetic.
/// Coordinates at the firmware × 1e7 scale.
const double _baseLat = 50.1163 * 1e7;
const double _baseLon = -122.9574 * 1e7;
const double _mPerDeg = 111320.0;

/// Builds a [GpsFix] at offset (latMetres, lonMetres) from the base point,
/// using the same flat-earth approximation the gate generator uses.
GpsFix _fixAt(double latMetres, double lonMetres) {
  final lonScale = _mPerDeg * math.cos(50.1163 * math.pi / 180.0).abs();
  return GpsFix(
    timestampMs: 0,
    latitudeDeg: _baseLat + (latMetres / _mPerDeg) * 1e7,
    longitudeDeg: _baseLon + (lonMetres / lonScale) * 1e7,
  );
}

/// Distance in metres between two × 1e7-scale fixes via flat-earth.
double _distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  final lonScale = _mPerDeg * math.cos(50.1163 * math.pi / 180.0).abs();
  final dLatM = (lat2 - lat1) / 1e7 * _mPerDeg;
  final dLonM = (lon2 - lon1) / 1e7 * lonScale;
  return math.sqrt(dLatM * dLatM + dLonM * dLonM);
}

void main() {
  group('GateGeometry.endpointGates —', () {
    test('two-point polyline running due north — gates run east-west', () {
      // Arrange — two fixes 100 m apart along the latitude (north).
      final polyline = [_fixAt(0, 0), _fixAt(100, 0)];

      // Act
      final gates = GateGeometry.endpointGates(polyline);

      // Assert — both gates produced
      expect(gates, isNotNull);
      final start = gates!.start;
      final finish = gates.finish;

      // Start gate is centred at fix 0, total length 20 m.
      final startLen = _distanceMeters(
        start.lat1Deg,
        start.lon1Deg,
        start.lat2Deg,
        start.lon2Deg,
      );
      expect(startLen, closeTo(20.0, 0.05));

      // North-running track → perpendicular runs east-west, so the two gate
      // posts share the same latitude (within the projection's precision).
      expect(start.lat1Deg, closeTo(start.lat2Deg, 1.0));

      // Names per docstring contract.
      expect(start.name, equals('Start'));
      expect(finish.name, equals('Finish'));
    });

    test('custom width — 50 m gate is 50 m end-to-end', () {
      // Arrange
      final polyline = [_fixAt(0, 0), _fixAt(100, 0)];

      // Act
      final gates = GateGeometry.endpointGates(polyline, gateWidthMeters: 50.0);

      // Assert
      expect(gates, isNotNull);
      final len = _distanceMeters(
        gates!.start.lat1Deg,
        gates.start.lon1Deg,
        gates.start.lat2Deg,
        gates.start.lon2Deg,
      );
      expect(len, closeTo(50.0, 0.1));
    });

    test('finish gate is centred on last fix, not an interior fix', () {
      // Arrange — three points along east-going line.
      final polyline = [
        _fixAt(0, 0),
        _fixAt(0, 50),
        _fixAt(0, 100),
      ];

      // Act
      final gates = GateGeometry.endpointGates(polyline);

      // Assert — finish-gate midpoint is at (0, 100).
      expect(gates, isNotNull);
      final f = gates!.finish;
      final midLat = (f.lat1Deg + f.lat2Deg) / 2;
      final midLon = (f.lon1Deg + f.lon2Deg) / 2;
      expect(midLat, closeTo(_fixAt(0, 100).latitudeDeg, 1.0));
      expect(midLon, closeTo(_fixAt(0, 100).longitudeDeg, 1.0));
    });

    test('polyline with fewer than 2 fixes returns null', () {
      expect(GateGeometry.endpointGates(const []), isNull);
      expect(GateGeometry.endpointGates([_fixAt(0, 0)]), isNull);
    });

    test(
        'degenerate polyline (identical first two fixes) — start gate is '
        'zero-length, no crash', () {
      // Arrange — two fixes at exactly the same point.
      final polyline = [_fixAt(0, 0), _fixAt(0, 0), _fixAt(50, 0)];

      // Act
      final gates = GateGeometry.endpointGates(polyline);

      // Assert — start gate collapses to a point. Finish remains valid.
      expect(gates, isNotNull);
      expect(gates!.start.lat1Deg, equals(gates.start.lat2Deg));
      expect(gates.start.lon1Deg, equals(gates.start.lon2Deg));
      // Finish gate (between (0,0) and (50,0)) is full width.
      final finishLen = _distanceMeters(
        gates.finish.lat1Deg,
        gates.finish.lon1Deg,
        gates.finish.lat2Deg,
        gates.finish.lon2Deg,
      );
      expect(finishLen, closeTo(20.0, 0.05));
    });
  });
}
