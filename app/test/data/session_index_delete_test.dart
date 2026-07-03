import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/session_index.dart';
import 'package:idl0/data/session_model.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  SessionMetadata fixture(String id) => SessionMetadata(
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

  test('delete — removes the row matching sessionId', () async {
    // Arrange
    final index = await SessionIndex.open(inMemoryDatabasePath);
    await index.upsert(fixture('a'));
    await index.upsert(fixture('b'));

    // Act
    await index.delete('a');

    // Assert
    final remaining = await index.getAll();
    expect(remaining.map((m) => m.sessionId), ['b']);
    await index.close();
  });

  test('delete — no-op when sessionId not present', () async {
    // Arrange
    final index = await SessionIndex.open(inMemoryDatabasePath);
    await index.upsert(fixture('a'));

    // Act
    await index.delete('does-not-exist');

    // Assert
    final remaining = await index.getAll();
    expect(remaining.length, 1);
    await index.close();
  });
}
