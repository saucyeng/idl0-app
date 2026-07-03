import 'dart:convert';

import 'exceptions.dart';
import 'track.dart';

/// Supported `.idl0t` portable-Track-artifact schema version written/read by
/// this build. The engine (`idl_rs::track_artifact`) bounds the same number.
const int kSupportedTrackArtifactVersion = 1;

/// Serializes [track] to `.idl0t` JSON: a version wrapper around `Track.toJson`.
/// Pretty-printed to match `.idl0wb` on disk.
String encodeTrackArtifact(Track track) =>
    const JsonEncoder.withIndent('  ').convert({
      'track_artifact_version': kSupportedTrackArtifactVersion,
      'track': track.toJson(),
    });

/// Parses `.idl0t` JSON back into a [Track].
///
/// Throws [TrackArtifactException] on malformed JSON, a missing `track` object,
/// or a `track_artifact_version` newer than [kSupportedTrackArtifactVersion].
Track decodeTrackArtifact(String jsonStr) {
  final Object? root;
  try {
    root = jsonDecode(jsonStr);
  } on FormatException catch (e) {
    throw TrackArtifactException('malformed track artifact JSON: ${e.message}');
  }
  if (root is! Map<String, dynamic>) {
    throw const TrackArtifactException('track artifact root is not an object');
  }
  final version = (root['track_artifact_version'] as num?)?.toInt() ?? 0;
  if (version > kSupportedTrackArtifactVersion) {
    throw TrackArtifactException(
      'track artifact version $version exceeds supported $kSupportedTrackArtifactVersion',
    );
  }
  final track = root['track'];
  if (track is! Map<String, dynamic>) {
    throw const TrackArtifactException(
      'track artifact is missing its "track" object',
    );
  }
  try {
    return Track.fromJson(track);
  } catch (e) {
    throw TrackArtifactException('track artifact track object is invalid: $e');
  }
}
