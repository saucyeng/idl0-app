import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/lap_detector.dart';
import 'package:idl0/data/lap_timing.dart';
import 'package:idl0/data/track.dart';
import 'package:idl0/data/track_index.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _kSfGate = LapGate(
  lat1Deg: 1,
  lon1Deg: 2,
  lat2Deg: 3,
  lon2Deg: 4,
  name: 'S/F',
);

Track _track({
  required String id,
  String name = 'Track',
  int updatedAtMs = 1000,
}) =>
    Track(
      trackId: id,
      name: name,
      venueName: 'Whistler',
      lapTiming: const Circuit(startFinish: _kSfGate),
      sectorGates: const [],
      neutralZones: const [],
      referencePolyline: const [
        GpsFix(timestampMs: 1000, latitudeDeg: 49.18, longitudeDeg: -123.0),
      ],
      createdAtMs: 0,
      updatedAtMs: updatedAtMs,
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('TrackIndex —', () {
    late TrackIndex index;

    setUp(() async {
      index = await TrackIndex.open(inMemoryDatabasePath);
    });

    tearDown(() async => index.close());

    test('upsert + getById — round-trips a Track including polyline', () async {
      // Arrange
      final t = _track(id: 'aaaa', name: 'A-Line');

      // Act
      await index.upsert(t);
      final got = await index.getById('aaaa');

      // Assert
      expect(got, isNotNull);
      expect(got!.trackId, equals('aaaa'));
      expect(got.name, equals('A-Line'));
      expect((got.lapTiming as Circuit).startFinish.name, equals('S/F'));
      expect(got.referencePolyline.length, equals(1));
      expect(got.referencePolyline.first.latitudeDeg, closeTo(49.18, 1e-9));
    });

    test('getById — unknown id — returns null', () async {
      expect(await index.getById('missing'), isNull);
    });

    test('getAll — orders by updatedAtMs descending', () async {
      // Arrange
      await index.upsert(_track(id: 'old', updatedAtMs: 100));
      await index.upsert(_track(id: 'newest', updatedAtMs: 9000));
      await index.upsert(_track(id: 'mid', updatedAtMs: 500));

      // Act
      final all = await index.getAll();

      // Assert
      expect(all.map((t) => t.trackId), equals(['newest', 'mid', 'old']));
    });

    test('upsert — second write replaces the first (no duplicates)', () async {
      // Arrange
      await index.upsert(_track(id: 'dup', name: 'Original'));

      // Act
      await index.upsert(_track(id: 'dup', name: 'Updated'));
      final all = await index.getAll();

      // Assert
      expect(all.length, equals(1));
      expect(all.first.name, equals('Updated'));
    });

    test('delete — removes the entry', () async {
      // Arrange
      await index.upsert(_track(id: 'kill'));
      expect(await index.getById('kill'), isNotNull);

      // Act
      await index.delete('kill');

      // Assert
      expect(await index.getById('kill'), isNull);
    });
  });
}
