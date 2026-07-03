import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/lap_timing.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/data/track.dart';
import 'package:idl0/data/track_index.dart';
import 'package:idl0/providers/drive_sync_provider.dart';
import 'package:idl0/providers/track_provider.dart';
import 'package:idl0/transport/drive_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_drive_workbook_ops.dart';

// ---------------------------------------------------------------------------
// Fake DriveService — captures uploads, lets tests stage remote tracks.
// ---------------------------------------------------------------------------

class _FakeDriveService with FakeDriveWorkbookOps implements DriveService {
  bool _signedIn;
  final List<Track> uploaded = [];
  final Map<String, Track> remote = {};
  // Wall-clock timestamps to feed [DriveTrackFile.modifiedTimeMs] without
  // forcing tests to chase real time.
  final Map<String, int> remoteModifiedMs = {};

  _FakeDriveService({bool signedIn = true}) : _signedIn = signedIn;

  @override
  bool get isSignedIn => _signedIn;

  @override
  String? get accountEmail => _signedIn ? 'test@example.com' : null;

  @override
  Future<void> signIn() async => _signedIn = true;

  @override
  Future<void> signOut() async => _signedIn = false;

  @override
  Future<void> uploadSessionFile(SessionMetadata session, String fileType) =>
      throw UnimplementedError();

  @override
  Future<List<DriveTrackFile>> listTracks() async => [
        for (final t in remote.values)
          DriveTrackFile(
            trackId: t.trackId,
            modifiedTimeMs: remoteModifiedMs[t.trackId] ?? t.updatedAtMs,
          ),
      ];

  @override
  Future<Track> downloadTrack(String trackId) async {
    final t = remote[trackId];
    if (t == null) throw StateError('not found: $trackId');
    return t;
  }

  @override
  Future<void> uploadTrack(Track track) async {
    uploaded.add(track);
    remote[track.trackId] = track;
    remoteModifiedMs[track.trackId] = track.updatedAtMs;
  }

  @override
  Future<void> deleteRemote(String sessionId) async {}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Returns a fresh temp directory that is cleaned up at the end of the test.
///
/// Sqflite's default `singleInstance: true` means two `openDatabase(":memory:")`
/// calls share state — even across different DB classes. Tests sidestep this
/// by giving each [TrackIndex] its own file path under a temp directory.
Directory _testTempDir() {
  final dir = Directory.systemTemp.createTempSync('idl0_track_test_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

Future<TrackIndex> _openTrackIndex([Directory? dir]) async {
  final base = dir ?? _testTempDir();
  final ti = await TrackIndex.open(p.join(base.path, 'tracks.db'));
  addTearDown(ti.close);
  return ti;
}

Future<({ProviderContainer container, _FakeDriveService drive})>
    _buildContainer({
  TrackIndex? trackIndex,
  _FakeDriveService? drive,
}) async {
  final ti = trackIndex ?? await _openTrackIndex();
  final fake = drive ?? _FakeDriveService();
  final container = ProviderContainer(
    overrides: [
      trackIndexProvider.overrideWith((_) async => ti),
      driveServiceProvider.overrideWithValue(fake),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, drive: fake);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('TrackNotifier —', () {
    test('createTrack — persists local + uploads + prepends to state',
        () async {
      // Arrange
      final ti = await _openTrackIndex();
      final ctx = await _buildContainer(trackIndex: ti);

      // Wait for build() and its background sync to settle so we don't
      // race with a redundant local-only-upload pass on the new Track.
      await ctx.container.read(trackProvider.future);
      await ctx.container.read(trackProvider.notifier).debugSyncCompletion;

      // Act
      final created =
          await ctx.container.read(trackProvider.notifier).createTrack(
                name: 'A-Line',
                venueName: 'Whistler',
              );

      // Assert — local cache populated
      final cached = await ti.getAll();
      expect(cached.length, equals(1));
      expect(cached.first.trackId, equals(created.trackId));

      // State reflects new track
      final state = ctx.container.read(trackProvider).value!;
      expect(state.length, equals(1));
      expect(state.first.name, equals('A-Line'));

      // Drive upload happened (fire-and-forget; awaited via microtask flush).
      await Future<void>.delayed(Duration.zero);
      expect(
        ctx.drive.uploaded.map((t) => t.trackId),
        contains(created.trackId),
      );
    });

    test('build() — returns local cache immediately even when offline',
        () async {
      // Arrange — pre-seed cache, simulate offline (signedIn=false).
      final ti = await _openTrackIndex();
      await ti.upsert(
        Track.create(
          name: 'Cached',
          venueName: 'V',
          now: DateTime.utc(2026, 1, 1),
        ),
      );
      final ctx = await _buildContainer(
        trackIndex: ti,
        drive: _FakeDriveService(signedIn: false),
      );

      // Act
      final tracks = await ctx.container.read(trackProvider.future);

      // Assert — cached track surfaced even though Drive is unavailable.
      expect(tracks.length, equals(1));
      expect(tracks.first.name, equals('Cached'));
    });

    test('background sync — remote-newer Track is downloaded into cache',
        () async {
      // Arrange — local cache has v1, Drive has a newer v2.
      final ti = await _openTrackIndex();
      final old = Track.create(
        name: 'Old',
        venueName: 'V',
        now: DateTime.utc(2026, 1, 1),
        trackId: 'shared-uuid',
      );
      await ti.upsert(old);

      final fake = _FakeDriveService();
      final newer = old.copyWith(name: 'New', updatedAtMs: old.updatedAtMs + 1);
      fake.remote['shared-uuid'] = newer;
      fake.remoteModifiedMs['shared-uuid'] = newer.updatedAtMs;

      final ctx = await _buildContainer(trackIndex: ti, drive: fake);

      // Act — initial build returns cached (Old); wait for background sync
      // to surface the downloaded copy via state.
      await ctx.container.read(trackProvider.future);
      await ctx.container.read(trackProvider.notifier).debugSyncCompletion;

      // Assert
      final state = ctx.container.read(trackProvider).value!;
      expect(state.length, equals(1));
      expect(state.first.name, equals('New'));
      // Local cache was updated, not just in-memory state.
      final cached = await ti.getAll();
      expect(cached.first.name, equals('New'));
    });

    test('background sync — local-only Track is uploaded to Drive', () async {
      // Arrange — Track in cache, nothing on Drive.
      final ti = await _openTrackIndex();
      final t = Track.create(
        name: 'LocalOnly',
        venueName: 'V',
        now: DateTime.utc(2026, 1, 1),
      );
      await ti.upsert(t);
      final ctx = await _buildContainer(trackIndex: ti);

      // Act
      await ctx.container.read(trackProvider.future);
      await ctx.container.read(trackProvider.notifier).debugSyncCompletion;

      // Assert — Drive received the local Track.
      expect(ctx.drive.uploaded.any((u) => u.trackId == t.trackId), isTrue);
    });

    test(
        'importTrackFromGpx — parses GPX, auto-generates endpoint gates, '
        'persists Track + uploads', () async {
      // Arrange — minimal GPX with three trkpts running due north.
      const gpx = '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
  <metadata><name>Trailforks export</name></metadata>
  <trk>
    <trkseg>
      <trkpt lat="50.1163" lon="-122.9574">
        <ele>650</ele>
        <time>2026-04-01T10:00:00Z</time>
      </trkpt>
      <trkpt lat="50.1172" lon="-122.9574">
        <ele>640</ele>
        <time>2026-04-01T10:00:30Z</time>
      </trkpt>
      <trkpt lat="50.1181" lon="-122.9574">
        <ele>630</ele>
        <time>2026-04-01T10:01:00Z</time>
      </trkpt>
    </trkseg>
  </trk>
</gpx>''';
      final ctx = await _buildContainer();
      await ctx.container.read(trackProvider.future);
      await ctx.container.read(trackProvider.notifier).debugSyncCompletion;
      ctx.drive.uploaded.clear();

      // Act
      final track =
          await ctx.container.read(trackProvider.notifier).importTrackFromGpx(
                bytes: Uint8List.fromList(gpx.codeUnits),
                name: 'A-Line',
                venueName: 'Whistler',
              );

      // Assert — Track stored with reference polyline + PointToPoint lap timing.
      expect(track.name, equals('A-Line'));
      expect(track.venueName, equals('Whistler'));
      expect(track.referencePolyline.length, equals(3));
      expect(track.lapTiming, isA<PointToPoint>());
      final ptp = track.lapTiming as PointToPoint;
      expect(ptp.start.name, equals('Start'));
      expect(ptp.finish.name, equals('Finish'));

      // State + Drive both reflect the new Track.
      final state = ctx.container.read(trackProvider).value!;
      expect(state.any((t) => t.trackId == track.trackId), isTrue);
      // Fire-and-forget upload — flush microtasks.
      await Future<void>.delayed(Duration.zero);
      expect(
        ctx.drive.uploaded.any((u) => u.trackId == track.trackId),
        isTrue,
      );
    });

    test('importTrackFromGpx — bad GPX throws', () async {
      // Arrange
      final ctx = await _buildContainer();
      await ctx.container.read(trackProvider.future);

      // Act / Assert
      expect(
        () => ctx.container.read(trackProvider.notifier).importTrackFromGpx(
              bytes: Uint8List.fromList('<not-gpx/>'.codeUnits),
              name: 'X',
              venueName: '',
            ),
        throwsA(anything),
      );
    });

    test('deleteTrack — removes from cache and in-memory state', () async {
      // Arrange — Track in cache + Drive.
      final ti = await _openTrackIndex();
      final t = Track.create(
        name: 'Doomed',
        venueName: 'V',
        now: DateTime.utc(2026, 1, 1),
      );
      await ti.upsert(t);

      final ctx = await _buildContainer(trackIndex: ti);
      await ctx.container.read(trackProvider.future);

      // Act
      await ctx.container.read(trackProvider.notifier).deleteTrack(t.trackId);

      // Assert — Track gone from local cache and provider state.
      expect(await ti.getById(t.trackId), isNull);
      expect(ctx.container.read(trackProvider).value, isEmpty);
    });
  });
}
