import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/exceptions.dart';
import 'package:idl0/data/lap_detector.dart';
import 'package:idl0/data/lap_timing.dart';
import 'package:idl0/data/track.dart';
import 'package:idl0/data/track_artifact_io.dart';

void main() {
  Track sample() => const Track(
        trackId: 't-1',
        name: 'A-Line',
        venueName: 'Whistler',
        lapTiming: Circuit(
          name: 'S/F',
          startFinish: LapGate(lat1Deg: 1, lon1Deg: 2, lat2Deg: 3, lon2Deg: 4),
        ),
        sectorGates: [],
        neutralZones: [],
        referencePolyline: [
          GpsFix(timestampMs: 0, latitudeDeg: 5, longitudeDeg: 6),
        ],
        createdAtMs: 0,
        updatedAtMs: 0,
      );

  test('encodeTrackArtifact → decodeTrackArtifact round-trips a Track', () {
    // Arrange
    final track = sample();

    // Act
    final json = encodeTrackArtifact(track);
    final back = decodeTrackArtifact(json);

    // Assert — identity + timing + reference preserved.
    expect(back.trackId, equals('t-1'));
    expect(back.name, equals('A-Line'));
    expect(back.lapTiming, isA<Circuit>());
    expect(back.referencePolyline.single.latitudeDeg, equals(5));
  });

  test('decodeTrackArtifact rejects a too-new version', () {
    // Arrange — version above the supported one.
    const json = '{"track_artifact_version": 999, "track": {}}';

    // Act / Assert
    expect(
      () => decodeTrackArtifact(json),
      throwsA(isA<TrackArtifactException>()),
    );
  });

  test('decodeTrackArtifact rejects malformed JSON', () {
    // Act / Assert
    expect(
      () => decodeTrackArtifact('not json'),
      throwsA(isA<TrackArtifactException>()),
    );
  });
}
