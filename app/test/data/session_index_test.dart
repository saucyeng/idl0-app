import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/session_index.dart';
import 'package:idl0/data/session_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

/// Builds a minimal [SessionMetadata] with only the fields under test varied.
SessionMetadata _makeSession({
  String sessionId = 'aaaa-0001',
  String filePath = '/sessions/aaaa-0001.idl0',
  String rider = 'Alice',
  String venueName = 'Whistler Bike Park',
  int? lapCount,
  int? durationMs,
  String tag = '',
}) =>
    SessionMetadata(
      sessionId: sessionId,
      filePath: filePath,
      workspacePath: '/sessions/$sessionId.idl0w',
      createdTimestampMs: 1_700_000_000_000,
      fileSizeBytes: 10240,
      rider: rider,
      bike: 'Trek Session 2024',
      bikeComment: '',
      venueName: venueName,
      eventName: '',
      eventSession: '',
      shortComment: '',
      longComment: '',
      deviceId: 'A3F1',
      lapCount: lapCount,
      durationMs: durationMs,
      tag: tag,
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('SessionIndex —', () {
    late SessionIndex index;

    setUp(() async {
      index = await SessionIndex.open(inMemoryDatabasePath);
    });

    tearDown(() async {
      await index.close();
    });

    test('insert session — retrieve by UUID — returns correct metadata',
        () async {
      // Arrange
      final session = _makeSession(
        sessionId: 'bbbb-0001',
        rider: 'Bob',
        venueName: 'Whistler Bike Park',
        lapCount: 5,
        durationMs: 300000,
      );

      // Act
      await index.upsert(session);
      final retrieved = await index.getById('bbbb-0001');

      // Assert
      expect(retrieved, isNotNull);
      expect(retrieved!.sessionId, equals('bbbb-0001'));
      expect(retrieved.rider, equals('Bob'));
      expect(retrieved.bike, equals('Trek Session 2024'));
      expect(retrieved.venueName, equals('Whistler Bike Park'));
      expect(retrieved.deviceId, equals('A3F1'));
      expect(retrieved.lapCount, equals(5));
      expect(retrieved.durationMs, equals(300000));
      expect(retrieved.fileSizeBytes, equals(10240));
    });

    test('update metadata fields — verify persisted', () async {
      // Arrange
      await index.upsert(_makeSession(sessionId: 'upd-0001', rider: 'Alice'));

      // Act — upsert with same UUID but different fields
      await index.upsert(
        _makeSession(
          sessionId: 'upd-0001',
          rider: 'Carol',
          venueName: 'Finale Ligure',
          lapCount: 3,
        ),
      );
      final retrieved = await index.getById('upd-0001');

      // Assert
      expect(retrieved, isNotNull);
      expect(retrieved!.rider, equals('Carol'));
      expect(retrieved.venueName, equals('Finale Ligure'));
      expect(retrieved.lapCount, equals(3));
    });

    test('delete session — verify removed', () async {
      // Arrange
      await index.upsert(_makeSession(sessionId: 'del-0001'));
      expect(await index.getById('del-0001'), isNotNull);

      // Act
      await index.delete('del-0001');

      // Assert
      expect(await index.getById('del-0001'), isNull);
    });

    test('rebuildFromSessions — three .idl0 paths — count and fields correct',
        () async {
      // Arrange — metadata derived from three .idl0 files on a folder scan
      final sessions = [
        _makeSession(
          sessionId: 'scan-0001',
          filePath: '/sessions/scan-0001.idl0',
          rider: 'Dave',
        ),
        _makeSession(
          sessionId: 'scan-0002',
          filePath: '/sessions/scan-0002.idl0',
          rider: 'Eve',
        ),
        _makeSession(
          sessionId: 'scan-0003',
          filePath: '/sessions/scan-0003.idl0',
          rider: 'Frank',
        ),
      ];

      // Act
      await index.rebuildFromSessions(sessions);
      final all = await index.getAll();

      // Assert — count
      expect(all.length, equals(3));

      // Assert — UUIDs present
      expect(
        all.map((s) => s.sessionId),
        containsAll(['scan-0001', 'scan-0002', 'scan-0003']),
      );

      // Assert — spot-check fields on first session
      final dave = all.firstWhere((s) => s.sessionId == 'scan-0001');
      expect(dave.rider, equals('Dave'));
      expect(dave.filePath, equals('/sessions/scan-0001.idl0'));
    });

    test('rebuildFromSessions — replaces stale entries from previous scan',
        () async {
      // Arrange — initial index has two sessions
      await index.rebuildFromSessions([
        _makeSession(sessionId: 'old-0001'),
        _makeSession(sessionId: 'old-0002'),
      ]);

      // Act — rescan finds only one file (other was deleted from disk)
      await index.rebuildFromSessions([
        _makeSession(sessionId: 'old-0001'),
      ]);
      final all = await index.getAll();

      // Assert — stale entry removed
      expect(all.length, equals(1));
      expect(all.first.sessionId, equals('old-0001'));
    });

    test('duplicate UUID — upsert updates existing entry, no error', () async {
      // Arrange
      await index
          .upsert(_makeSession(sessionId: 'dup-0001', rider: 'Original'));

      // Act
      await index.upsert(_makeSession(sessionId: 'dup-0001', rider: 'Updated'));
      final all = await index.getAll();

      // Assert — exactly one row, updated value
      expect(all.where((s) => s.sessionId == 'dup-0001').length, equals(1));
      expect(all.first.rider, equals('Updated'));
    });

    test('getById — unknown UUID — returns null', () async {
      // Arrange — empty index

      // Act
      final result = await index.getById('does-not-exist');

      // Assert
      expect(result, isNull);
    });

    test('nullable fields — lapCount and durationMs round-trip as null',
        () async {
      // Arrange
      final session = _makeSession(sessionId: 'null-0001');

      // Act
      await index.upsert(session);
      final retrieved = await index.getById('null-0001');

      // Assert
      expect(retrieved!.lapCount, isNull);
      expect(retrieved.durationMs, isNull);
    });

    test('tag — round-trips through SQLite (v4)', () async {
      // Arrange — session with a tag
      await index.upsert(
        _makeSession(sessionId: 'tag-0001', tag: 'Race run'),
      );

      // Act
      final got = await index.getById('tag-0001');

      // Assert
      expect(got, isNotNull);
      expect(got!.tag, equals('Race run'));

      // Act — overwrite with empty tag
      await index.upsert(got.copyWith(tag: ''));
      final cleared = await index.getById('tag-0001');

      // Assert — tag rows are not null; default to empty string.
      expect(cleared!.tag, equals(''));
    });

    test('default tag is empty string — rows pre-tag load unchanged', () async {
      // Arrange — _makeSession defaults tag = ''.
      await index.upsert(_makeSession(sessionId: 'plain-0001'));

      // Act
      final got = await index.getById('plain-0001');

      // Assert
      expect(got!.tag, equals(''));
    });
  });

  group('SessionIndex — persistence —', () {
    test(
        'survives app restart — write index, re-open database, verify data intact',
        () async {
      // Arrange — use a real temp file to simulate app restart
      final dbFile = File(
        '${Directory.systemTemp.path}/idl0_test_${DateTime.now().millisecondsSinceEpoch}.db',
      );

      try {
        // Write — first "app session"
        final index1 = await SessionIndex.open(dbFile.path);
        await index1.upsert(
          _makeSession(
            sessionId: 'persist-0001',
            rider: 'Greta',
            lapCount: 7,
            durationMs: 420000,
          ),
        );
        await index1.close();

        // Re-open — simulates app restart
        final index2 = await SessionIndex.open(dbFile.path);
        final retrieved = await index2.getById('persist-0001');
        await index2.close();

        // Assert — all fields intact after re-open
        expect(retrieved, isNotNull);
        expect(retrieved!.sessionId, equals('persist-0001'));
        expect(retrieved.rider, equals('Greta'));
        expect(retrieved.lapCount, equals(7));
        expect(retrieved.durationMs, equals(420000));
        expect(retrieved.bike, equals('Trek Session 2024'));
        expect(retrieved.deviceId, equals('A3F1'));
      } finally {
        if (dbFile.existsSync()) dbFile.deleteSync();
      }
    });
  });
}
