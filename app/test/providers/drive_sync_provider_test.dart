import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/exceptions.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/data/track.dart';
import 'package:idl0/providers/drive_sync_provider.dart';
import 'package:idl0/transport/drive_service.dart';

import '../support/fake_drive_workbook_ops.dart';

// ---------------------------------------------------------------------------
// Fake DriveService
// ---------------------------------------------------------------------------

/// Hand-written [DriveService] test double with configurable behaviour.
class _FakeDriveService with FakeDriveWorkbookOps implements DriveService {
  bool _signedIn;
  String? _email;

  /// When `true`, [uploadSessionFile] throws [DriveUploadException].
  bool shouldThrowOnUpload;

  /// Number of times [uploadSessionFile] was called.
  int uploadCallCount = 0;

  _FakeDriveService({
    bool signedIn = true,
    String? email = 'test@example.com',
    this.shouldThrowOnUpload = false,
  })  : _signedIn = signedIn,
        _email = email;

  @override
  bool get isSignedIn => _signedIn;

  @override
  String? get accountEmail => _email;

  @override
  Future<void> signIn() async {
    _signedIn = true;
    _email = 'test@example.com';
  }

  @override
  Future<void> signOut() async {
    _signedIn = false;
    _email = null;
  }

  @override
  Future<void> uploadSessionFile(
      SessionMetadata session, String fileType,) async {
    uploadCallCount++;
    if (shouldThrowOnUpload) {
      throw const DriveUploadException('upload failed for test');
    }
  }

  // Track operations are not exercised by drive-sync tests; provide inert
  // stubs so [DriveService]'s contract is satisfied.
  @override
  Future<List<DriveTrackFile>> listTracks() async => const [];

  @override
  Future<Track> downloadTrack(String trackId) =>
      throw UnimplementedError('listTracks/downloadTrack not used here');

  @override
  Future<void> uploadTrack(Track track) async {}

  /// Session IDs passed to [deleteRemote], in call order.
  final List<String> deleteRemoteCalls = [];

  /// When `true`, [deleteRemote] throws [DriveUploadException].
  bool deleteRemoteThrows = false;

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

/// Builds a [ProviderContainer] with [driveServiceProvider] overridden by
/// [service].
ProviderContainer _container(_FakeDriveService service) => ProviderContainer(
      overrides: [
        driveServiceProvider.overrideWithValue(service),
      ],
    );

SessionMetadata _meta(String id) => SessionMetadata(
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
      deviceId: '',
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('DriveSyncNotifier.queueUpload —', () {
    test(
        'status transitions notUploaded → queued → uploading → synced '
        'for both idl0 and idl0w', () async {
      // Arrange
      final service = _FakeDriveService();
      final container = _container(service);
      addTearDown(container.dispose);

      final statusHistory = <Map<String, SyncStatus>>[];
      container.listen(
        driveSyncProvider.select((s) => s.syncStatus['session-1'] ?? {}),
        (_, next) => statusHistory.add(Map.from(next)),
        fireImmediately: true,
      );

      // Act
      await container
          .read(driveSyncProvider.notifier)
          .queueUpload(_meta('session-1'));

      // Assert — final state is synced for both file types.
      final finalStatus =
          container.read(driveSyncProvider).syncStatus['session-1']!;
      expect(finalStatus['idl0'], SyncStatus.synced);
      expect(finalStatus['idl0w'], SyncStatus.synced);

      // Assert — intermediate states contain queued and uploading transitions.
      expect(
        statusHistory.any((s) => s['idl0'] == SyncStatus.queued),
        isTrue,
        reason: 'idl0 must pass through queued',
      );
      expect(
        statusHistory.any((s) => s['idl0'] == SyncStatus.uploading),
        isTrue,
        reason: 'idl0 must pass through uploading',
      );
      expect(
        statusHistory.any((s) => s['idl0w'] == SyncStatus.uploading),
        isTrue,
        reason: 'idl0w must pass through uploading',
      );
    });

    test('status transitions to error on DriveUploadException', () async {
      // Arrange
      final service = _FakeDriveService(shouldThrowOnUpload: true);
      final container = _container(service);
      addTearDown(container.dispose);

      // Act
      await container
          .read(driveSyncProvider.notifier)
          .queueUpload(_meta('session-2'));

      // Assert — both file types report error after upload failure.
      final status = container.read(driveSyncProvider).syncStatus['session-2']!;
      expect(status['idl0'], SyncStatus.error);
      expect(status['idl0w'], SyncStatus.error);
    });

    test(
        'when not signed in, sets both to error without calling uploadSessionFile',
        () async {
      // Arrange
      final service = _FakeDriveService(signedIn: false);
      final container = _container(service);
      addTearDown(container.dispose);

      // Act
      await container
          .read(driveSyncProvider.notifier)
          .queueUpload(_meta('session-3'));

      // Assert — both error, service never called.
      final status = container.read(driveSyncProvider).syncStatus['session-3']!;
      expect(status['idl0'], SyncStatus.error);
      expect(status['idl0w'], SyncStatus.error);
      expect(service.uploadCallCount, equals(0));
    });
  });

  group('DriveSyncNotifier.signOut —', () {
    test('isSignedIn becomes false, syncStatus entries unchanged', () async {
      // Arrange — pre-seed a synced status so we can verify it survives.
      final service = _FakeDriveService();
      final container = _container(service);
      addTearDown(container.dispose);

      await container
          .read(driveSyncProvider.notifier)
          .queueUpload(_meta('session-4'));
      final statusBefore =
          container.read(driveSyncProvider).syncStatus['session-4']!;

      // Act
      await container.read(driveSyncProvider.notifier).signOut();

      // Assert — auth state cleared.
      final state = container.read(driveSyncProvider);
      expect(state.isSignedIn, isFalse);
      expect(state.accountEmail, isNull);

      // Assert — sync status entries are preserved after sign-out.
      expect(
        container.read(driveSyncProvider).syncStatus['session-4'],
        equals(statusBefore),
      );
    });
  });
}
