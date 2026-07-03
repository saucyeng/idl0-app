import 'package:idl0/data/session_model.dart';

/// Builds a minimal [SessionMetadata] for tests, with dummy values for every
/// required field and the given [id] as the sessionId. Keeps sync/provider
/// tests DRY (mirrors the per-test builders elsewhere in the suite).
SessionMetadata sessionMeta(String id, {String deviceId = ''}) =>
    SessionMetadata(
      sessionId: id,
      filePath: '/sessions/$id.idl0',
      workspacePath: '/sessions/$id.idl0w',
      createdTimestampMs: 0,
      fileSizeBytes: 0,
      rider: '',
      bike: '',
      bikeComment: '',
      venueName: '',
      eventName: '',
      eventSession: '',
      shortComment: '',
      longComment: '',
      deviceId: deviceId,
    );
