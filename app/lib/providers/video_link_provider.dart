/// Link-time video flow (SPEC §33.3, phase 2): stat the file, estimate the
/// sync offset engine-side, and assemble the [VideoLink] the workspace
/// persists. The UI (picker, nudge controls, playback) is phase 3.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/exceptions.dart';
import '../data/workspace.dart';
import '../src/rust/video.dart' as rust_video;
import 'channel_provider.dart';

/// Assembles a [VideoLink] from file stats plus an optional engine sync
/// estimate. Pure: no I/O, no bridge. `estimate == null` (no anchor in the
/// container) means a manual sync at offset 0 seconds with null confidence,
/// for the user to nudge in phase 3.
VideoLink buildVideoLink({
  required String id,
  required String path,
  required int fileSizeBytes,
  required int fileMtimeMs,
  ({double offsetS, double confidence, String method})? estimate,
  String? label,
}) =>
    VideoLink(
      id: id,
      path: path,
      fileSizeBytes: fileSizeBytes,
      fileMtimeMs: fileMtimeMs,
      syncOffsetS: estimate?.offsetS ?? 0.0,
      syncMethod: estimate?.method ?? 'manual',
      syncConfidence: estimate?.confidence,
      label: label,
    );

/// Impure edge of the link flow: file stat + bridge calls. Kept thin so
/// everything above it ([buildVideoLink], the workspace mutators) is
/// testable without the native library.
class VideoLinker {
  /// Creates a [VideoLinker] reading through [_ref].
  VideoLinker(this._ref);

  final Ref _ref;

  /// Builds a ready-to-persist [VideoLink] for [videoPath] against the
  /// session's handle. GPMF/creation-time estimation happens engine-side
  /// (SPEC §33.3); a Parse failure (no usable anchor) degrades to a manual
  /// sync at offset 0.
  ///
  /// Throws [VideoLinkException] when the file is missing or unreadable.
  /// Throws [VideoSyncMismatchException] when the video's time range does
  /// not overlap the session (footage from a different ride) — surfaced,
  /// not stored.
  Future<VideoLink> link({
    required String sessionId,
    required String videoPath,
    String? label,
  }) async {
    final stat = await File(videoPath).stat();
    if (stat.type == FileSystemEntityType.notFound) {
      throw VideoLinkException('video file not found: $videoPath');
    }
    final handle = await _ref.read(sessionHandleProvider(sessionId).future);

    ({double offsetS, double confidence, String method})? estimate;
    try {
      final est = await rust_video.estimateVideoSync(
        handle: handle,
        videoPath: videoPath,
      );
      estimate = (
        offsetS: est.offsetS,
        confidence: est.confidence,
        method: switch (est.method) {
          rust_video.VideoSyncMethod.gpmf => 'gpmf',
          rust_video.VideoSyncMethod.creationTime => 'creation_time',
        },
      );
    } on rust_video.VideoFailure catch (e) {
      switch (e.kind) {
        case rust_video.VideoFailureKind.noOverlap:
          throw VideoSyncMismatchException(e.message);
        case rust_video.VideoFailureKind.parse:
          estimate = null; // no anchor — manual sync, user nudges in phase 3
        case rust_video.VideoFailureKind.io:
        case rust_video.VideoFailureKind.noGpmf:
        case rust_video.VideoFailureKind.export_:
          throw VideoLinkException(e.message);
      }
    }

    return buildVideoLink(
      id: const Uuid().v4(),
      path: videoPath,
      fileSizeBytes: stat.size,
      fileMtimeMs: stat.modified.millisecondsSinceEpoch,
      estimate: estimate,
      label: label,
    );
  }
}

/// The app-wide [VideoLinker]. Overridable in tests (the real one needs the
/// native bridge library).
final videoLinkerProvider = Provider<VideoLinker>(VideoLinker.new);
