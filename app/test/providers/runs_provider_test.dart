import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/lap_timing.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/data/track.dart';
import 'package:idl0/data/workspace.dart';
import 'package:idl0/providers/drive_sync_provider.dart';
import 'package:idl0/providers/track_provider.dart';
import 'package:idl0/transport/drive_service.dart';
import 'package:idl0/ui/tabs/data/metadata_editor.dart';

import '../support/fake_drive_workbook_ops.dart';

SessionMetadata _meta(
  String id, {
  String rider = '',
  String venueName = '',
}) =>
    SessionMetadata(
      sessionId: id,
      filePath: '/sessions/$id.idl0',
      workspacePath: '/sessions/$id.idl0w',
      createdTimestampMs: DateTime(2026, 4, 20).millisecondsSinceEpoch,
      fileSizeBytes: 0,
      rider: rider,
      bike: '',
      bikeComment: '',
      venueName: venueName,
      eventName: '',
      eventSession: '',
      shortComment: '',
      longComment: '',
      deviceId: '',
    );

/// Spy that records whether [save] was called without touching the filesystem.
class _SpyWorkspaceSaver implements WorkspaceSaver {
  int callCount = 0;

  @override
  Future<void> save(Workspace workspace) async => callCount++;
}

/// Inert [DriveService] used by metadata-editor widget tests so that the
/// background `trackProvider` sync neither hits the network nor touches a
/// real account. Marked as signed-out so `_syncWithDrive` returns
/// immediately.
class _OfflineDriveService with FakeDriveWorkbookOps implements DriveService {
  @override
  bool get isSignedIn => false;

  @override
  String? get accountEmail => null;

  @override
  Future<void> signIn() async {}

  @override
  Future<void> signOut() async {}

  @override
  Future<void> uploadSessionFile(SessionMetadata session, String fileType) =>
      throw UnimplementedError();

  @override
  Future<List<DriveTrackFile>> listTracks() async => const [];

  @override
  Future<Track> downloadTrack(String trackId) => throw UnimplementedError();

  @override
  Future<void> uploadTrack(Track track) async {}

  @override
  Future<void> deleteRemote(String sessionId) async {}
}

/// Common provider overrides for metadata-editor widget tests.
///
/// - In-memory `trackProvider` seeded with [tracks].
/// - Offline DriveService so the background sync is a no-op.
///
/// The editor's auto-detect path now reads GPS from the retained session handle
/// (`gpsTrack`), not a Dart channel list; with no session registered it finds no
/// GPS and hence no match — the behaviour these tests exercise — without an
/// injection override.
List<Override> _editorOverrides({
  List<Track> tracks = const [],
  String sessionId = '',
}) =>
    [
      driveServiceProvider.overrideWithValue(_OfflineDriveService()),
      trackProvider.overrideWith(() => _StaticTrackNotifier(tracks)),
    ];

/// AsyncNotifier that returns a fixed Track list and records calls so
/// widget tests can assert which provider methods fired.
class _StaticTrackNotifier extends TrackNotifier {
  _StaticTrackNotifier(this._initial);

  final List<Track> _initial;
  final List<String> createNames = [];

  @override
  Future<List<Track>> build() async => _initial;

  @override
  Future<Track> createTrack({
    required String name,
    required String venueName,
    LapTiming? lapTiming,
    List sectorGates = const [],
    List neutralZones = const [],
    List referencePolyline = const [],
  }) async {
    createNames.add(name);
    final t = Track.create(name: name, venueName: venueName);
    state = AsyncData([t, ...(state.value ?? const [])]);
    return t;
  }
}

void main() {
  group('metadata_editor', () {
    testWidgets('save — calls WorkspaceSaver.save', (tester) async {
      // Arrange
      final meta = _meta('e1');
      final workspace = Workspace.empty(meta.sessionId);
      final saver = _SpyWorkspaceSaver();

      await tester.pumpWidget(
        ProviderScope(
          overrides: _editorOverrides(sessionId: meta.sessionId),
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: ctx,
                    builder: (_) => MetadataEditor(
                      meta: meta,
                      workspace: workspace,
                      saver: saver,
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      // Act — open the dialog then tap Save
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Assert
      expect(saver.callCount, equals(1));
    });

    testWidgets(
        'Tracks visited row — empty visits — shows "No tracks visited yet"',
        (tester) async {
      // Arrange — empty workspace, no detected visits.
      final meta = _meta('e2');
      final workspace = Workspace.empty(meta.sessionId);

      await tester.pumpWidget(
        ProviderScope(
          overrides: _editorOverrides(sessionId: meta.sessionId),
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: ctx,
                    builder: (_) => MetadataEditor(
                      meta: meta,
                      workspace: workspace,
                      saver: _SpyWorkspaceSaver(),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Assert
      expect(find.text('Tracks visited'), findsOneWidget);
      expect(find.text('No tracks visited yet.'), findsOneWidget);
    });

    testWidgets(
        'Tracks visited row — multiple visits to same Track — shows count',
        (tester) async {
      // Arrange — workspace with three visits to Track A and one to Track B.
      final trackA = Track.create(name: 'A-Line', venueName: 'Whistler');
      final trackB =
          Track.create(name: 'Top of the World', venueName: 'Whistler');
      final meta = _meta('e3');
      final workspace = Workspace.empty(meta.sessionId).copyWith(
        trackVisits: [
          TrackVisit(
            visitId: 'v1',
            trackId: trackA.trackId,
            startTimestampMs: 1000,
            endTimestampMs: 2000,
          ),
          TrackVisit(
            visitId: 'v2',
            trackId: trackB.trackId,
            startTimestampMs: 3000,
            endTimestampMs: 4000,
          ),
          TrackVisit(
            visitId: 'v3',
            trackId: trackA.trackId,
            startTimestampMs: 5000,
            endTimestampMs: 6000,
          ),
          TrackVisit(
            visitId: 'v4',
            trackId: trackA.trackId,
            startTimestampMs: 7000,
            endTimestampMs: 8000,
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: _editorOverrides(
            sessionId: meta.sessionId,
            tracks: [trackA, trackB],
          ),
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: ctx,
                    builder: (_) => MetadataEditor(
                      meta: meta,
                      workspace: workspace,
                      saver: _SpyWorkspaceSaver(),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Assert — each track renders on its own tappable row.
      expect(find.text('A-Line (3 visits)'), findsOneWidget);
      expect(find.text('Top of the World (1 visit)'), findsOneWidget);
    });
  });
}
