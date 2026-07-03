import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/exceptions.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/data/track.dart';
import 'package:idl0/providers/drive_sync_provider.dart';
import 'package:idl0/providers/runs_provider.dart';
import 'package:idl0/providers/session_provider.dart';
import 'package:idl0/transport/drive_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_drive_workbook_ops.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.tmp);
  final Directory tmp;

  @override
  Future<String?> getApplicationDocumentsPath() async => tmp.path;

  @override
  Future<String?> getApplicationSupportPath() async => tmp.path;

  @override
  Future<String?> getExternalStoragePath() async => tmp.path;
}

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

void main() {
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('idl0_delete_');
    PathProviderPlatform.instance = _FakePathProvider(tmp);
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  SessionMetadata fixture(String id) => SessionMetadata(
        sessionId: id,
        filePath: '${tmp.path}/$id.idl0',
        workspacePath: '${tmp.path}/$id.idl0w',
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

  test(
      'deleteSession appOnly — removes local files, index row, in-memory entry',
      () async {
    // Arrange
    final session = fixture('s1');
    await File(session.filePath).writeAsString('idl0 bytes');
    await File(session.workspacePath).writeAsString('{}');

    final fake = _FakeDriveService();
    final container = ProviderContainer(overrides: [
      driveServiceProvider.overrideWithValue(fake),
    ],);
    addTearDown(container.dispose);
    container.read(sessionProvider.notifier).addSession(session);

    final counterBefore = container.read(runsProvider);

    // Act
    await container.read(runsProvider.notifier).deleteSession(
          session.sessionId,
          scope: DeleteScope.appOnly,
        );

    // Assert
    expect(File(session.filePath).existsSync(), isFalse);
    expect(File(session.workspacePath).existsSync(), isFalse);
    expect(container.read(sessionProvider).sessions, isEmpty);
    expect(fake.deleteRemoteCalls, isEmpty);
    expect(container.read(runsProvider), counterBefore + 1);
  });

  test(
      'deleteSession everywhere — calls Drive deleteRemote then deletes locally',
      () async {
    // Arrange
    final session = fixture('s2');
    await File(session.filePath).writeAsString('x');
    await File(session.workspacePath).writeAsString('{}');

    final fake = _FakeDriveService(isSignedIn: true, accountEmail: 'a@b.com');
    final container = ProviderContainer(overrides: [
      driveServiceProvider.overrideWithValue(fake),
    ],);
    addTearDown(container.dispose);
    container.read(sessionProvider.notifier).addSession(session);

    // Act
    await container.read(runsProvider.notifier).deleteSession(
          session.sessionId,
          scope: DeleteScope.everywhere,
        );

    // Assert
    expect(fake.deleteRemoteCalls, ['s2']);
    expect(File(session.filePath).existsSync(), isFalse);
    expect(container.read(sessionProvider).sessions, isEmpty);
  });

  test('deleteSession everywhere — Drive failure aborts before local delete',
      () async {
    // Arrange
    final session = fixture('s3');
    await File(session.filePath).writeAsString('x');

    final fake = _FakeDriveService(
      isSignedIn: true,
      accountEmail: 'a@b.com',
    )..deleteRemoteThrows = true;
    final container = ProviderContainer(overrides: [
      driveServiceProvider.overrideWithValue(fake),
    ],);
    addTearDown(container.dispose);
    container.read(sessionProvider.notifier).addSession(session);

    final counterBefore = container.read(runsProvider);

    // Act + Assert
    await expectLater(
      container.read(runsProvider.notifier).deleteSession(
            session.sessionId,
            scope: DeleteScope.everywhere,
          ),
      throwsA(isA<DriveUploadException>()),
    );

    expect(File(session.filePath).existsSync(), isTrue);
    expect(container.read(sessionProvider).sessions.length, 1);
    expect(container.read(runsProvider), counterBefore);
  });
}
