import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/data/workspace.dart';
import 'package:idl0/providers/session_provider.dart';
import 'package:idl0/providers/session_workspace_provider.dart';
import 'package:idl0/providers/video_link_provider.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

SessionMetadata _meta(String id, String workspacePath) => SessionMetadata(
      sessionId: id,
      filePath: '/sessions/$id.idl0',
      workspacePath: workspacePath,
      createdTimestampMs: DateTime(2026, 7, 9).millisecondsSinceEpoch,
      fileSizeBytes: 0,
      rider: '',
      bike: '',
      bikeComment: '',
      venueName: '',
      eventName: '',
      shortComment: '',
      longComment: '',
      deviceId: '',
      eventSession: '',
    );

VideoLink _link(String id, {double offsetS = 0.0, String method = 'manual'}) =>
    VideoLink(
      id: id,
      path: 'C:/rides/$id.mp4',
      fileSizeBytes: 10,
      fileMtimeMs: 20,
      syncOffsetS: offsetS,
      syncMethod: method,
    );

class _NoopSaver implements WorkspaceSaver {
  @override
  Future<void> save(Workspace workspace) async {}
}

Future<String> _writeWorkspace(Workspace workspace, String tag) async {
  final path =
      '${Directory.systemTemp.path}/idl0_vlp_test_${tag}_${DateTime.now().microsecondsSinceEpoch}.idl0w';
  await workspace.save(path);
  return path;
}

void _cleanup(String path) {
  final f = File(path);
  if (f.existsSync()) f.deleteSync();
}

ProviderContainer _container(SessionMetadata meta) => ProviderContainer(
      overrides: [
        workspaceSaverFactoryProvider.overrideWith(
          (_) => (_) => _NoopSaver(),
        ),
      ],
    )..read(sessionProvider.notifier).addSession(meta);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('buildVideoLink —', () {
    test('with estimate — stores engine offset/method/confidence', () {
      // Arrange + Act
      final link = buildVideoLink(
        id: 'v1',
        path: 'C:/rides/a.mp4',
        fileSizeBytes: 10,
        fileMtimeMs: 20,
        estimate: (offsetS: 23.4, confidence: 0.9, method: 'gpmf'),
      );

      // Assert
      expect(link.syncOffsetS, closeTo(23.4, 1e-9));
      expect(link.syncMethod, 'gpmf');
      expect(link.syncConfidence, closeTo(0.9, 1e-9));
    });

    test('without estimate — degrades to manual at offset 0, null confidence',
        () {
      // Arrange + Act
      final link = buildVideoLink(
        id: 'v1',
        path: 'C:/rides/a.mp4',
        fileSizeBytes: 10,
        fileMtimeMs: 20,
        estimate: null,
      );

      // Assert
      expect(link.syncOffsetS, 0.0);
      expect(link.syncMethod, 'manual');
      expect(link.syncConfidence, isNull);
    });
  });

  group('SessionWorkspaceNotifier video mutators —', () {
    test('linkVideo — appends to the videos list', () async {
      // Arrange
      final ws = Workspace.empty('uuid-link');
      final wsPath = await _writeWorkspace(ws, 'link');
      addTearDown(() => _cleanup(wsPath));

      final container = _container(_meta('uuid-link', wsPath));
      addTearDown(container.dispose);
      await container.read(sessionWorkspaceProvider('uuid-link').future);

      final notifier =
          container.read(sessionWorkspaceProvider('uuid-link').notifier);

      // Act
      await notifier.linkVideo(_link('v1'));
      await notifier.linkVideo(_link('v2'));

      // Assert
      final result =
          container.read(sessionWorkspaceProvider('uuid-link')).requireValue;
      expect(result.videos.map((v) => v.id).toList(), ['v1', 'v2']);
    });

    test('unlinkVideo — removes by id, leaves others', () async {
      // Arrange
      final ws = Workspace.empty('uuid-unlink')
          .copyWith(videos: [_link('v1'), _link('v2')]);
      final wsPath = await _writeWorkspace(ws, 'unlink');
      addTearDown(() => _cleanup(wsPath));

      final container = _container(_meta('uuid-unlink', wsPath));
      addTearDown(container.dispose);
      await container.read(sessionWorkspaceProvider('uuid-unlink').future);

      // Act
      await container
          .read(sessionWorkspaceProvider('uuid-unlink').notifier)
          .unlinkVideo('v1');

      // Assert
      final result =
          container.read(sessionWorkspaceProvider('uuid-unlink')).requireValue;
      expect(result.videos.single.id, 'v2');
    });

    test('setVideoSync — rewrites the matching link, others untouched',
        () async {
      // Arrange
      final ws = Workspace.empty('uuid-sync').copyWith(
        videos: [_link('v1'), _link('v2', offsetS: 5.0, method: 'gpmf')],
      );
      final wsPath = await _writeWorkspace(ws, 'sync');
      addTearDown(() => _cleanup(wsPath));

      final container = _container(_meta('uuid-sync', wsPath));
      addTearDown(container.dispose);
      await container.read(sessionWorkspaceProvider('uuid-sync').future);

      // Act
      await container
          .read(sessionWorkspaceProvider('uuid-sync').notifier)
          .setVideoSync(
            'v1',
            offsetS: 7.5,
            method: 'creation_time',
            confidence: 0.3,
          );

      // Assert
      final result =
          container.read(sessionWorkspaceProvider('uuid-sync')).requireValue;
      final v1 = result.videos.firstWhere((v) => v.id == 'v1');
      final v2 = result.videos.firstWhere((v) => v.id == 'v2');
      expect(v1.syncOffsetS, closeTo(7.5, 1e-9));
      expect(v1.syncMethod, 'creation_time');
      expect(v1.syncConfidence, closeTo(0.3, 1e-9));
      expect(v2.syncOffsetS, closeTo(5.0, 1e-9));
      expect(v2.syncMethod, 'gpmf');
    });

    test('setVideoSync — manual method — nulls confidence even when passed',
        () async {
      // Arrange — v1 starts as a gpmf sync with a confidence.
      final ws = Workspace.empty('uuid-manual').copyWith(
        videos: [
          _link('v1', offsetS: 3.0, method: 'gpmf')
              .copyWith(syncConfidence: 0.9),
        ],
      );
      final wsPath = await _writeWorkspace(ws, 'manual');
      addTearDown(() => _cleanup(wsPath));

      final container = _container(_meta('uuid-manual', wsPath));
      addTearDown(container.dispose);
      await container.read(sessionWorkspaceProvider('uuid-manual').future);

      // Act — the user nudges manually; a stale confidence must not survive.
      await container
          .read(sessionWorkspaceProvider('uuid-manual').notifier)
          .setVideoSync('v1', offsetS: 3.25, method: 'manual', confidence: 0.9);

      // Assert
      final result =
          container.read(sessionWorkspaceProvider('uuid-manual')).requireValue;
      expect(result.videos.single.syncOffsetS, closeTo(3.25, 1e-9));
      expect(result.videos.single.syncMethod, 'manual');
      expect(result.videos.single.syncConfidence, isNull);
    });
  });
}
