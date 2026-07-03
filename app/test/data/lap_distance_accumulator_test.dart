import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/lap_detector.dart';
import 'package:idl0/data/lap_distance_accumulator.dart';

GpsFix _fix(int t, double lat, double lon) =>
    GpsFix(timestampMs: t, latitudeDeg: lat, longitudeDeg: lon);

void main() {
  group('LapDistanceAccumulator.compute', () {
    test(
        'all samples on polyline — normalisedDistance is monotonic + matches polyline arc length',
        () {
      // Arrange — samples drift but project cleanly onto a straight
      // east-going polyline (~10 m between consecutive polyline points,
      // 11 samples ⇒ ~100 m total).
      final polyline = [
        for (var i = 0; i < 11; i++)
          _fix(0, 50.0, -123.0 + i * 0.000139), // ~10 m spacing
      ];
      final samples = [
        for (var i = 0; i < 11; i++) _fix(i * 100, 50.0, -123.0 + i * 0.000139),
      ];

      // Act
      final result = LapDistanceAccumulator.compute(
        samples: samples,
        polyline: polyline,
        speedKmh: List<double>.filled(11, 30.0),
        startGateDistance: 0.0,
        finishGateDistance: null,
        gateCrossings: const [],
      );

      // Assert
      expect(result.normalisedDistance, hasLength(11));
      // Strictly monotonic.
      for (var i = 1; i < result.normalisedDistance.length; i++) {
        expect(
          result.normalisedDistance[i],
          greaterThanOrEqualTo(result.normalisedDistance[i - 1]),
        );
      }
      // Last value approximately equals polyline length (~100 m), within
      // 5 m given flat-earth approximation.
      expect(result.normalisedDistance.last, closeTo(100.0, 5.0));
    });

    test('drift between two confidence anchors — drift redistributed linearly',
        () {
      // Arrange — 5 samples; samples[0] and samples[4] are clean
      // anchors (low residual). samples[1..3] drift sideways. Their
      // raw cumulativeArc would be inflated by the sideways motion;
      // anchor redistribution should pull intermediate normalised
      // distances proportionally between the anchors' polyline
      // distances.
      final polyline = [
        _fix(0, 50.0, -123.0),
        _fix(0, 50.0, -123.0001), // ~7 m east
        _fix(0, 50.0, -123.0002), // ~14 m east
      ];
      final samples = [
        _fix(0, 50.0, -123.0), // anchor at distance 0
        _fix(100, 50.0001, -123.00005), // drifty
        _fix(200, 50.0002, -123.00010), // drifty
        _fix(300, 50.0001, -123.00015), // drifty
        _fix(400, 50.0, -123.0002), // anchor at full length
      ];

      // Act
      final result = LapDistanceAccumulator.compute(
        samples: samples,
        polyline: polyline,
        speedKmh: List<double>.filled(5, 30.0),
        startGateDistance: 0.0,
        finishGateDistance: null,
        gateCrossings: const [],
      );

      // Assert
      expect(result.normalisedDistance.first, closeTo(0.0, 1.0));
      expect(result.normalisedDistance.last, closeTo(14.0, 5.0));
      // Strictly monotonic — drift redistributed proportionally.
      for (var i = 1; i < 5; i++) {
        expect(
          result.normalisedDistance[i],
          greaterThanOrEqualTo(result.normalisedDistance[i - 1]),
        );
      }
    });

    test('no anchors anywhere — falls back to (0, polyline length) endpoints',
        () {
      // Arrange — all samples have huge residual (no confidence
      // anchors qualify); no gates.
      final polyline = [
        _fix(0, 50.0, -123.0),
        _fix(0, 50.0, -123.0002),
      ];
      final samples = [
        _fix(0, 50.5, -123.5), // far from polyline
        _fix(100, 50.6, -123.6),
        _fix(200, 50.7, -123.7),
      ];

      // Act
      final result = LapDistanceAccumulator.compute(
        samples: samples,
        polyline: polyline,
        speedKmh: List<double>.filled(3, 30.0),
        startGateDistance: 0.0,
        finishGateDistance: null,
        gateCrossings: const [],
      );

      // Assert — endpoints anchored by start/finish defaults; middle
      // sample interpolated between them (here, polylineLength = ~14 m,
      // start = 0 m, so middle ≈ 7 m).
      expect(result.normalisedDistance.first, closeTo(0.0, 1.0));
      expect(result.normalisedDistance.last, lessThan(20.0));
    });
  });
}
