import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/cached_session_laps.dart';
import 'package:idl0/data/lap_detector.dart';
import 'package:idl0/data/lap_timing.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/data/track.dart';
import 'package:idl0/data/workspace.dart';

Lap _lap(int n, int startMs, int endMs) => Lap(
      lapNumber: n,
      startTimestampMs: startMs,
      endTimestampMs: endMs,
      rawElapsedMs: endMs - startMs,
      lapTimeMs: endMs - startMs,
    );

Track _track(String id) => Track(
      trackId: id,
      name: 'Track $id',
      venueName: 'Venue',
      lapTiming: const Circuit(
        startFinish: LapGate(lat1Deg: 0, lon1Deg: 0, lat2Deg: 1, lon2Deg: 1),
      ),
      sectorGates: const [],
      neutralZones: const [],
      referencePolyline: const [],
      createdAtMs: 0,
      updatedAtMs: 0,
    );

void main() {
  group('cachedSessionLaps —', () {
    test('renumbers per-visit laps 1-based across the whole session', () {
      // Arrange — two visits, each with engine per-visit numbering (1, 2).
      final ws = Workspace.empty('s1').copyWith(
        trackVisits: [
          TrackVisit(
            visitId: 'v1',
            trackId: 'A',
            startTimestampMs: 0,
            endTimestampMs: 10000,
            laps: [_lap(1, 0, 4000), _lap(2, 4000, 9000)],
          ),
          TrackVisit(
            visitId: 'v2',
            trackId: 'B',
            startTimestampMs: 10000,
            endTimestampMs: 20000,
            laps: [_lap(1, 10000, 13000), _lap(2, 13000, 18000)],
          ),
        ],
      );
      final tracksById = {'A': _track('A'), 'B': _track('B')};

      // Act
      final laps = cachedSessionLaps(ws, tracksById);

      // Assert — continuous 1..4 in start-time order, tracks attributed.
      expect(laps.map((e) => e.lap.lapNumber), [1, 2, 3, 4]);
      expect(laps.map((e) => e.track?.trackId), ['A', 'A', 'B', 'B']);
    });

    test('isIgnored is tested against the renumbered session-wide number', () {
      // Arrange — ignore session-wide lap 3 (= visit v2's first lap).
      final ws = Workspace.empty('s1').copyWith(
        trackVisits: [
          TrackVisit(
            visitId: 'v1',
            trackId: 'A',
            startTimestampMs: 0,
            endTimestampMs: 10000,
            laps: [_lap(1, 0, 4000), _lap(2, 4000, 9000)],
          ),
          TrackVisit(
            visitId: 'v2',
            trackId: 'B',
            startTimestampMs: 10000,
            endTimestampMs: 20000,
            laps: [_lap(1, 10000, 13000), _lap(2, 13000, 18000)],
          ),
        ],
        trackVisitsLibraryHash: 'sha1:x',
      ).copyWith(ignoredLapNumbers: const {3});
      final tracksById = {'A': _track('A'), 'B': _track('B')};

      // Act
      final laps = cachedSessionLaps(ws, tracksById);

      // Assert — only lap 3 ignored, not visit v2's locally-numbered "lap 1".
      expect(laps.where((e) => e.isIgnored).map((e) => e.lap.lapNumber), [3]);
    });

    test('unresolved track → null track, lap still kept', () {
      // Arrange — visit references a track not in the library.
      final ws = Workspace.empty('s1').copyWith(
        trackVisits: [
          TrackVisit(
            visitId: 'v1',
            trackId: 'gone',
            startTimestampMs: 0,
            endTimestampMs: 5000,
            laps: [_lap(1, 0, 4000)],
          ),
        ],
      );

      // Act
      final laps = cachedSessionLaps(ws, const {});

      // Assert
      expect(laps, hasLength(1));
      expect(laps.single.track, isNull);
      expect(laps.single.lap.lapNumber, 1);
    });

    test('no visits → empty', () {
      // Arrange / Act / Assert
      expect(cachedSessionLaps(Workspace.empty('s1'), const {}), isEmpty);
    });
  });
}
