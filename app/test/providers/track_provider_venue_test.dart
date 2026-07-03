import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/data/track.dart';
import 'package:idl0/data/track_index.dart';
import 'package:idl0/providers/drive_sync_provider.dart';
import 'package:idl0/providers/track_provider.dart';
import 'package:idl0/transport/drive_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_drive_workbook_ops.dart';

class _FakeDriveService with FakeDriveWorkbookOps implements DriveService {
  @override
  bool isSignedIn = false;
  @override
  String? accountEmail;
  @override
  Future<void> signIn() async {}
  @override
  Future<void> signOut() async {}
  @override
  Future<void> uploadSessionFile(SessionMetadata s, String t) async {}
  @override
  Future<List<DriveTrackFile>> listTracks() async => const [];
  @override
  Future<Track> downloadTrack(String trackId) async =>
      throw UnimplementedError();
  @override
  Future<void> uploadTrack(Track track) async {}
  @override
  Future<void> deleteRemote(String sessionId) async {}
}

/// Opens an isolated [TrackIndex] in a temp directory that is deleted after
/// the test. Sqflite's `singleInstance: true` means two `openDatabase(':memory:')`
/// calls share state — temp file paths sidestep this.
Future<TrackIndex> _openIsolatedIndex() async {
  final dir = Directory.systemTemp.createTempSync('idl0_venue_test_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final index = await TrackIndex.open(p.join(dir.path, 'tracks.db'));
  addTearDown(index.close);
  return index;
}

Future<ProviderContainer> seeded(List<Track> tracks) async {
  final index = await _openIsolatedIndex();
  for (final t in tracks) {
    await index.upsert(t);
  }
  final container = ProviderContainer(
    overrides: [
      trackIndexProvider.overrideWith((_) async => index),
      driveServiceProvider.overrideWithValue(_FakeDriveService()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('renameVenue — updates every Track with the old venue name', () async {
    // Arrange
    final t1 = Track.create(name: 'A-Line', venueName: 'Whistler');
    final t2 = Track.create(name: 'Schleyer', venueName: 'Whistler');
    final t3 = Track.create(name: 'Half Nelson', venueName: 'Squamish');

    final c = await seeded([t1, t2, t3]);
    await c.read(trackProvider.future);

    // Act
    final renamed = await c
        .read(trackProvider.notifier)
        .renameVenue('Whistler', 'Whistler Bike Park');

    // Assert
    expect(renamed, 2);
    final after = c.read(trackProvider).value!;
    expect(after.where((t) => t.venueName == 'Whistler Bike Park').length, 2);
    expect(after.where((t) => t.venueName == 'Squamish').length, 1);
    expect(after.where((t) => t.venueName == 'Whistler').length, 0);
  });

  test('renameVenue — same name returns 0 and no-ops', () async {
    // Arrange
    final t1 = Track.create(name: 'A-Line', venueName: 'Whistler');
    final c = await seeded([t1]);
    await c.read(trackProvider.future);

    // Act
    final renamed = await c
        .read(trackProvider.notifier)
        .renameVenue('Whistler', 'Whistler');

    // Assert
    expect(renamed, 0);
  });

  test('deleteVenue — clears venueName on every matching Track', () async {
    // Arrange
    final t1 = Track.create(name: 'A-Line', venueName: 'Whistler');
    final t2 = Track.create(name: 'Half Nelson', venueName: 'Squamish');

    final c = await seeded([t1, t2]);
    await c.read(trackProvider.future);

    // Act
    final cleared =
        await c.read(trackProvider.notifier).deleteVenue('Whistler');

    // Assert
    expect(cleared, 1);
    final after = c.read(trackProvider).value!;
    expect(after.firstWhere((t) => t.name == 'A-Line').venueName, isEmpty);
    expect(
      after.firstWhere((t) => t.name == 'Half Nelson').venueName,
      'Squamish',
    );
  });

  test('deleteVenue — empty venueName returns 0', () async {
    // Arrange
    final c = await seeded(const []);
    await c.read(trackProvider.future);

    // Act / Assert
    expect(await c.read(trackProvider.notifier).deleteVenue(''), 0);
  });
}
