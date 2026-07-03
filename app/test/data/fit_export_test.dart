import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/fit_export.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/data/workspace.dart';

Lap _lap(int n, int startMs, int endMs, int lapMs) => Lap(
      lapNumber: n,
      startTimestampMs: startMs,
      endTimestampMs: endMs,
      rawElapsedMs: endMs - startMs,
      lapTimeMs: lapMs,
    );

TrackVisit _visit(String id, String trackId, List<Lap> laps) => TrackVisit(
      visitId: id,
      trackId: trackId,
      startTimestampMs: laps.first.startTimestampMs,
      endTimestampMs: laps.last.endTimestampMs,
      laps: laps,
    );

SessionMetadata _meta({required int createdMs, required String venue}) =>
    SessionMetadata(
      sessionId: 's',
      filePath: '/tmp/s.idl0',
      workspacePath: '/tmp/s.idl0w',
      createdTimestampMs: createdMs,
      fileSizeBytes: 0,
      rider: '',
      bike: '',
      bikeComment: '',
      venueName: venue,
      eventName: '',
      eventSession: '',
      shortComment: '',
      longComment: '',
      deviceId: '',
    );

void main() {
  group('collectFitLaps', () {
    test(
        'collectFitLaps — multiple visits — flattens chronologically and maps fields',
        () {
      // Arrange — two visits, listed out of chronological order.
      final ws = Workspace.empty('s').copyWith(trackVisits: [
        _visit('v2', 'b', [_lap(1, 3000, 3500, 480), _lap(2, 3500, 4000, 510)]),
        _visit('v1', 'a', [_lap(1, 1000, 1500, 495)]),
      ]);

      // Act
      final laps = collectFitLaps(ws);

      // Assert — sorted by start; effective lap time mapped to elapsedMs.
      expect(laps.map((l) => l.startMs).toList(), [1000, 3000, 3500]);
      expect(laps.first.endMs, 1500);
      expect(laps.first.elapsedMs, 495);
    });

    test('collectFitLaps — no track visits — returns empty', () {
      // Arrange
      final ws = Workspace.empty('s');

      // Act + Assert
      expect(collectFitLaps(ws), isEmpty);
    });
  });

  group('fitExportFileName', () {
    test('fitExportFileName — venue present — YYYY-MM-DD_venue.fit', () {
      // Arrange — a 2026 timestamp.
      final meta = _meta(createdMs: 1781000000000, venue: 'Thunder Hill');

      // Act + Assert — spaces become underscores.
      expect(fitExportFileName(meta, 'Thunder Hill'),
          matches(r'^\d{4}-\d{2}-\d{2}_Thunder_Hill\.fit$'));
    });

    test('fitExportFileName — blank venue — falls back to date_HHMM', () {
      // Arrange
      final meta = _meta(createdMs: 1781000000000, venue: '');

      // Act + Assert — no "unknown"; local time disambiguates.
      expect(fitExportFileName(meta, ''),
          matches(r'^\d{4}-\d{2}-\d{2}_\d{4}\.fit$'));
    });
  });
}
