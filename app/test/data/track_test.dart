import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/lap_detector.dart';
import 'package:idl0/data/lap_timing.dart';
import 'package:idl0/data/track.dart';

LapGate _gate({double offset = 0}) => LapGate(
      lat1Deg: 491800000 + offset,
      lon1Deg: -1230000000 + offset,
      lat2Deg: 491810000 + offset,
      lon2Deg: -1230010000 + offset,
      name: 'Start',
    );

GpsFix _fix(int t, double lat, double lon) =>
    GpsFix(timestampMs: t, latitudeDeg: lat, longitudeDeg: lon);

void main() {
  group('Track —', () {
    test('create — assigns a UUID and matched timestamps', () {
      // Arrange
      final now = DateTime.utc(2026, 5, 1, 12);

      // Act
      final track = Track.create(
        name: 'Whistler A-Line',
        venueName: 'Whistler Bike Park',
        now: now,
      );

      // Assert
      expect(track.trackId, isNotEmpty);
      expect(track.createdAtMs, equals(now.millisecondsSinceEpoch));
      expect(track.updatedAtMs, equals(now.millisecondsSinceEpoch));
      expect(track.name, equals('Whistler A-Line'));
      expect(track.lapTiming, isNull);
      expect(track.referencePolyline, isEmpty);
    });

    test('toJson / fromJson — round-trips all fields including polyline', () {
      // Arrange
      final original = Track.create(
        name: 'Test',
        venueName: 'Test Venue',
        lapTiming: Circuit(startFinish: _gate()),
        sectorGates: [SectorGate(name: 'S1', gate: _gate(offset: 10))],
        referencePolyline: [
          _fix(1000, 49.18, -123.0),
          _fix(2000, 49.19, -123.0),
        ],
        now: DateTime.utc(2026, 5, 1),
      );

      // Act
      final restored = Track.fromJson(original.toJson());

      // Assert
      expect(restored.trackId, equals(original.trackId));
      expect(restored.name, equals(original.name));
      expect(restored.venueName, equals(original.venueName));
      expect(restored.lapTiming, isA<Circuit>());
      expect(
          (restored.lapTiming! as Circuit).startFinish.name, equals('Start'),);
      expect(restored.sectorGates.length, equals(1));
      expect(restored.sectorGates.first.name, equals('S1'));
      expect(restored.referencePolyline.length, equals(2));
      expect(restored.referencePolyline.first.timestampMs, equals(1000));
      expect(
          restored.referencePolyline.first.latitudeDeg, closeTo(49.18, 1e-9),);
      expect(restored.createdAtMs, equals(original.createdAtMs));
      expect(restored.updatedAtMs, equals(original.updatedAtMs));
    });

    test('fromJson — empty polyline allowed (create-from-scratch)', () {
      // Arrange
      final json = {
        'track_id': 'abc',
        'name': 'Empty',
        'venue_name': 'V',
        'lap_gates': <Map<String, dynamic>>[],
        'sector_gates': <Map<String, dynamic>>[],
        'reference_polyline': <Map<String, dynamic>>[],
        'created_at_ms': 1,
        'updated_at_ms': 2,
      };

      // Act
      final track = Track.fromJson(json);

      // Assert
      expect(track.referencePolyline, isEmpty);
      expect(track.lapTiming, isNull);
      expect(track.sectorGates, isEmpty);
    });

    test('copyWith — bumps updatedAtMs when content changes', () {
      // Arrange
      final original = Track.create(
        name: 'A',
        venueName: 'V',
        now: DateTime.utc(2026, 5, 1),
      );
      final later = DateTime.utc(2026, 5, 2);

      // Act
      final renamed = original.copyWith(name: 'B', now: later);

      // Assert
      expect(renamed.name, equals('B'));
      expect(renamed.createdAtMs, equals(original.createdAtMs));
      expect(renamed.updatedAtMs, equals(later.millisecondsSinceEpoch));
    });

    test('copyWith — explicit updatedAtMs overrides bump (Drive download)', () {
      // Arrange
      final original = Track.create(
        name: 'A',
        venueName: 'V',
        now: DateTime.utc(2026, 5, 1),
      );

      // Act — simulate downloading a remote copy that carries its own
      // authoritative updatedAtMs (must not be replaced by wall clock).
      final remote = original.copyWith(name: 'B', updatedAtMs: 999);

      // Assert
      expect(remote.updatedAtMs, equals(999));
    });

    test('copyWith — no-op preserves updatedAtMs', () {
      // Arrange
      final original = Track.create(
        name: 'A',
        venueName: 'V',
        now: DateTime.utc(2026, 5, 1),
      );

      // Act
      final unchanged = original.copyWith();

      // Assert
      expect(unchanged.updatedAtMs, equals(original.updatedAtMs));
    });

    test('Track.fromJson — legacy JSON with polyline fields — fields dropped',
        () {
      // Arrange — pre-rewrite Track JSON with the four removed fields.
      final json = {
        'track_id': 'legacy',
        'name': 'Old Track',
        'venue_name': 'Old Venue',
        'sector_gates': <Map<String, dynamic>>[],
        'neutral_zones': <Map<String, dynamic>>[],
        'reference_polyline': <Map<String, dynamic>>[],
        'created_at_ms': 1700000000000,
        'updated_at_ms': 1700000000000,
        // Dead fields from the 2026-05-08 variance architecture.
        'canonical_polyline': [
          {'timestamp_ms': 0, 'latitude_deg': 50.0, 'longitude_deg': -123.0},
        ],
        'polyline_source_session_id': 'sess-1',
        'polyline_source_lap_count': 5,
        'polyline_derived_at_ms': 1700000000000,
      };

      // Act
      final track = Track.fromJson(json);

      // Assert — the four fields are gone from the class entirely. The
      // test just confirms parsing doesn't throw on the legacy keys.
      expect(track.trackId, equals('legacy'));
      expect(track.referencePolyline, isEmpty);
    });

    test('Track.toJson — does NOT emit polyline-derived keys', () {
      // Arrange
      final track = Track.create(name: 'A', venueName: 'V');

      // Act
      final json = track.toJson();

      // Assert
      expect(json.containsKey('canonical_polyline'), isFalse);
      expect(json.containsKey('polyline_source_session_id'), isFalse);
      expect(json.containsKey('polyline_source_lap_count'), isFalse);
      expect(json.containsKey('polyline_derived_at_ms'), isFalse);
    });
  });
}
