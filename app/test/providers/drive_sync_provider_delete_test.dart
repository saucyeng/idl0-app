import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/exceptions.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/data/track.dart';
import 'package:idl0/providers/drive_sync_provider.dart';
import 'package:idl0/transport/drive_service.dart';

import '../support/fake_drive_workbook_ops.dart';

// ---------------------------------------------------------------------------
// Inline fake — minimal surface needed for deleteRemote / cancelUpload tests.
// ---------------------------------------------------------------------------

class _FakeDriveService with FakeDriveWorkbookOps implements DriveService {
  _FakeDriveService({this.isSignedIn = false, this.accountEmail});

  @override
  bool isSignedIn;

  @override
  String? accountEmail;

  final List<String> deleteRemoteCalls = [];
  bool deleteRemoteThrows = false;

  @override
  Future<void> signIn() async {}

  @override
  Future<void> signOut() async {
    isSignedIn = false;
    accountEmail = null;
  }

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
  Future<void> deleteRemote(String sessionId) async {
    deleteRemoteCalls.add(sessionId);
    if (deleteRemoteThrows) {
      throw const DriveUploadException('fake delete failure');
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

SessionMetadata _session(String id) => SessionMetadata(
      sessionId: id,
      filePath: '/tmp/$id.idl0',
      workspacePath: '/tmp/$id.idl0w',
      createdTimestampMs: 1700000000000,
      fileSizeBytes: 0,
      rider: '',
      bike: '',
      bikeComment: '',
      venueName: '',
      eventName: '',
      eventSession: '',
      shortComment: '',
      longComment: '',
      deviceId: '',
      tag: '',
      sourceType: SessionSourceType.idl0,
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  test('deleteRemote — calls service and clears syncStatus for sessionId',
      () async {
    // Arrange
    final fake = _FakeDriveService(isSignedIn: true, accountEmail: 'a@b.com');
    final container = ProviderContainer(overrides: [
      driveServiceProvider.overrideWithValue(fake),
    ],);
    addTearDown(container.dispose);
    final notifier = container.read(driveSyncProvider.notifier);
    await notifier.queueUpload(_session('s1'));

    // Act
    await notifier.deleteRemote('s1');

    // Assert
    expect(fake.deleteRemoteCalls, ['s1']);
    expect(
      container.read(driveSyncProvider).syncStatus.containsKey('s1'),
      isFalse,
    );
  });

  test('cancelUpload — drops sync-status entries for sessionId', () async {
    // Arrange
    final fake = _FakeDriveService(isSignedIn: true, accountEmail: 'a@b.com');
    final container = ProviderContainer(overrides: [
      driveServiceProvider.overrideWithValue(fake),
    ],);
    addTearDown(container.dispose);
    final notifier = container.read(driveSyncProvider.notifier);
    await notifier.queueUpload(_session('s1'));

    // Act
    notifier.cancelUpload('s1');

    // Assert
    expect(
      container.read(driveSyncProvider).syncStatus.containsKey('s1'),
      isFalse,
    );
  });

  test(
      'deleteRemote — service throws — exception propagates and syncStatus untouched',
      () async {
    final fake = _FakeDriveService(isSignedIn: true, accountEmail: 'a@b.com')
      ..deleteRemoteThrows = true;
    final container = ProviderContainer(overrides: [
      driveServiceProvider.overrideWithValue(fake),
    ],);
    addTearDown(container.dispose);
    final notifier = container.read(driveSyncProvider.notifier);
    await notifier.queueUpload(_session('s1'));
    final before = container.read(driveSyncProvider).syncStatus;

    await expectLater(
        notifier.deleteRemote('s1'), throwsA(isA<DriveUploadException>()),);

    expect(fake.deleteRemoteCalls, ['s1']);
    expect(
      container.read(driveSyncProvider).syncStatus,
      equals(before),
    );
  });
}
