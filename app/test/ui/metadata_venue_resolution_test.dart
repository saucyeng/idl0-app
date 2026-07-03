import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/track.dart';
import 'package:idl0/data/workspace.dart';
import 'package:idl0/ui/tabs/data/metadata_editor.dart';

import '../helpers/session_fixtures.dart';

/// Builds a [Track] with the given [id] and [venueName] for resolution tests.
/// `lapTiming` is irrelevant to venue resolution, so it is left unset.
Track _track(String id, String venueName) => Track.create(
      name: 'Track $id',
      venueName: venueName,
      trackId: id,
      now: DateTime(2026),
    );

/// A workspace for session [id] carrying a single visit to [trackId].
Workspace _wsVisiting(String id, String trackId) =>
    Workspace.empty(id).copyWith(
      trackVisits: [
        TrackVisit(
          visitId: 'v1',
          trackId: trackId,
          startTimestampMs: 1000,
          endTimestampMs: 20000,
          laps: const [],
        ),
      ],
      trackVisitsLibraryHash: 'sha1:test',
    );

void main() {
  group('resolveSessionVenue', () {
    test('explicit venueName — returns it and ignores track fallback', () {
      // Arrange
      final meta = sessionMeta('s1').copyWith(venueName: 'Loretta Lynn');
      final ws = _wsVisiting('s1', 'track-A');
      final tracks = [_track('track-A', 'Whistler')];

      // Act
      final venue = resolveSessionVenue(meta, ws, tracks);

      // Assert — explicit metadata wins over the visited track's venue.
      expect(venue, equals('Loretta Lynn'));
    });

    test('empty venueName — falls back to the visited track venue', () {
      // Arrange
      final meta = sessionMeta('s1'); // venueName defaults to ''
      final ws = _wsVisiting('s1', 'track-A');
      final tracks = [_track('track-A', 'Whistler')];

      // Act
      final venue = resolveSessionVenue(meta, ws, tracks);

      // Assert
      expect(venue, equals('Whistler'));
    });

    test('empty venueName + null workspace — returns empty', () {
      // Arrange
      final meta = sessionMeta('s1');
      final tracks = [_track('track-A', 'Whistler')];

      // Act
      final venue = resolveSessionVenue(meta, null, tracks);

      // Assert
      expect(venue, isEmpty);
    });

    test('empty venueName + visit trackId not in library — returns empty', () {
      // Arrange — the workspace visits track-A but the library only knows
      // track-B, so the visit does not resolve (§12.3 skip-on-resolve).
      final meta = sessionMeta('s1');
      final ws = _wsVisiting('s1', 'track-A');
      final tracks = [_track('track-B', 'Whistler')];

      // Act
      final venue = resolveSessionVenue(meta, ws, tracks);

      // Assert
      expect(venue, isEmpty);
    });

    test('empty venueName + visited track has empty venue — returns empty', () {
      // Arrange
      final meta = sessionMeta('s1');
      final ws = _wsVisiting('s1', 'track-A');
      final tracks = [_track('track-A', '')];

      // Act
      final venue = resolveSessionVenue(meta, ws, tracks);

      // Assert
      expect(venue, isEmpty);
    });
  });
}
