import 'package:sqflite/sqflite.dart';

import 'session_model.dart';

/// SQLite-backed session index cache. See §9.5.
///
/// This is a cache only — the source of truth is always the `.idl0` files on
/// disk. Call [rebuildFromSessions] after any folder scan to bring the index
/// back into sync with the filesystem.
///
/// All writes are upserts keyed on [SessionMetadata.sessionId]. Duplicate
/// UUIDs update the existing row rather than throwing.
class SessionIndex {
  static const _kTable = 'sessions';
  // v2: added `source_type` column for GPX import support. See §12.
  // v3: added nullable `track_id` column for Track binding. See §12.3.
  // v4: dropped `track_id` (multi-track binding moved to
  //     `Workspace.trackVisits`); added free-text `tag` column for the
  //     Runs-tab tag-chip filter. Migration uses recreate-and-copy because
  //     ALTER TABLE … DROP COLUMN requires SQLite ≥ 3.35 which is not
  //     guaranteed on older Android devices.
  static const _kVersion = 4;

  final Database _db;

  SessionIndex._(this._db);

  /// Opens (or creates) the SQLite database at [path].
  ///
  /// Pass [inMemoryDatabasePath] from sqflite for an in-memory database
  /// (tests and ephemeral use). Pass a real file path for persistence across
  /// app restarts.
  static Future<SessionIndex> open(String path) async {
    final db = await openDatabase(
      path,
      version: _kVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_kTable (
            session_id           TEXT PRIMARY KEY,
            file_path            TEXT NOT NULL,
            workspace_path       TEXT NOT NULL,
            created_timestamp_ms INTEGER NOT NULL,
            file_size_bytes      INTEGER NOT NULL,
            rider                TEXT NOT NULL,
            bike                 TEXT NOT NULL,
            bike_comment         TEXT NOT NULL,
            venue_name           TEXT NOT NULL,
            event_name           TEXT NOT NULL,
            event_session        TEXT NOT NULL,
            short_comment        TEXT NOT NULL,
            long_comment         TEXT NOT NULL,
            device_id            TEXT NOT NULL,
            lap_count            INTEGER,
            duration_ms          INTEGER,
            source_type          TEXT NOT NULL DEFAULT 'idl0',
            tag                  TEXT NOT NULL DEFAULT ''
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // v1 → v2: add source_type column. Existing rows pre-date GPX
          // import so they default to 'idl0'.
          await db.execute(
            'ALTER TABLE $_kTable ADD COLUMN source_type TEXT NOT NULL '
            "DEFAULT 'idl0'",
          );
        }
        if (oldVersion < 3) {
          // v2 → v3: add nullable track_id column. (v3 schema is
          // intermediate — v4 drops this column in the recreate below.)
          await db.execute(
            'ALTER TABLE $_kTable ADD COLUMN track_id TEXT',
          );
        }
        if (oldVersion < 4) {
          // v3 → v4: drop `track_id`, add `tag`. Recreate-and-copy because
          // older SQLite lacks DROP COLUMN. Wrapped in a transaction so a
          // mid-migration crash leaves the original table intact.
          await db.transaction((txn) async {
            await txn.execute('''
              CREATE TABLE ${_kTable}_new (
                session_id           TEXT PRIMARY KEY,
                file_path            TEXT NOT NULL,
                workspace_path       TEXT NOT NULL,
                created_timestamp_ms INTEGER NOT NULL,
                file_size_bytes      INTEGER NOT NULL,
                rider                TEXT NOT NULL,
                bike                 TEXT NOT NULL,
                bike_comment         TEXT NOT NULL,
                venue_name           TEXT NOT NULL,
                event_name           TEXT NOT NULL,
                event_session        TEXT NOT NULL,
                short_comment        TEXT NOT NULL,
                long_comment         TEXT NOT NULL,
                device_id            TEXT NOT NULL,
                lap_count            INTEGER,
                duration_ms          INTEGER,
                source_type          TEXT NOT NULL DEFAULT 'idl0',
                tag                  TEXT NOT NULL DEFAULT ''
              )
            ''');
            await txn.execute('''
              INSERT INTO ${_kTable}_new (
                session_id, file_path, workspace_path,
                created_timestamp_ms, file_size_bytes,
                rider, bike, bike_comment, venue_name,
                event_name, event_session, short_comment, long_comment,
                device_id, lap_count, duration_ms, source_type, tag
              )
              SELECT
                session_id, file_path, workspace_path,
                created_timestamp_ms, file_size_bytes,
                rider, bike, bike_comment, venue_name,
                event_name, event_session, short_comment, long_comment,
                device_id, lap_count, duration_ms, source_type, ''
              FROM $_kTable
            ''');
            await txn.execute('DROP TABLE $_kTable');
            await txn.execute('ALTER TABLE ${_kTable}_new RENAME TO $_kTable');
          });
        }
      },
    );
    return SessionIndex._(db);
  }

  /// Inserts or replaces the index entry for [meta].
  ///
  /// If a row with the same [SessionMetadata.sessionId] already exists it is
  /// overwritten in its entirety (upsert semantics).
  Future<void> upsert(SessionMetadata meta) async {
    await _db.insert(
      _kTable,
      _toRow(meta),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Returns the cached [SessionMetadata] for [sessionId], or `null` if the
  /// session is not in the index.
  Future<SessionMetadata?> getById(String sessionId) async {
    final rows = await _db.query(
      _kTable,
      where: 'session_id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Removes the index entry for [sessionId]. No-op if not present.
  Future<void> delete(String sessionId) async {
    await _db.delete(
      _kTable,
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  /// Returns all cached sessions ordered by [SessionMetadata.createdTimestampMs]
  /// descending (most recent first).
  Future<List<SessionMetadata>> getAll() async {
    final rows = await _db.query(
      _kTable,
      orderBy: 'created_timestamp_ms DESC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Replaces the entire index with [sessions] in a single transaction.
  ///
  /// Called after a folder scan once the caller has parsed the `.idl0` headers
  /// into [SessionMetadata] objects. Clears stale entries for files that no
  /// longer exist and adds entries for newly discovered files.
  Future<void> rebuildFromSessions(List<SessionMetadata> sessions) async {
    await _db.transaction((txn) async {
      await txn.delete(_kTable);
      for (final s in sessions) {
        await txn.insert(_kTable, _toRow(s));
      }
    });
  }

  /// Closes the underlying database connection.
  Future<void> close() => _db.close();

  static Map<String, Object?> _toRow(SessionMetadata m) => {
        'session_id': m.sessionId,
        'file_path': m.filePath,
        'workspace_path': m.workspacePath,
        'created_timestamp_ms': m.createdTimestampMs,
        'file_size_bytes': m.fileSizeBytes,
        'rider': m.rider,
        'bike': m.bike,
        'bike_comment': m.bikeComment,
        'venue_name': m.venueName,
        'event_name': m.eventName,
        'event_session': m.eventSession,
        'short_comment': m.shortComment,
        'long_comment': m.longComment,
        'device_id': m.deviceId,
        'lap_count': m.lapCount,
        'duration_ms': m.durationMs,
        'source_type': m.sourceType.name,
        'tag': m.tag,
      };

  static SessionMetadata _fromRow(Map<String, dynamic> row) => SessionMetadata(
        sessionId: row['session_id'] as String,
        filePath: row['file_path'] as String,
        workspacePath: row['workspace_path'] as String,
        createdTimestampMs: row['created_timestamp_ms'] as int,
        fileSizeBytes: row['file_size_bytes'] as int,
        rider: row['rider'] as String,
        bike: row['bike'] as String,
        bikeComment: row['bike_comment'] as String,
        venueName: row['venue_name'] as String,
        eventName: row['event_name'] as String,
        eventSession: row['event_session'] as String,
        shortComment: row['short_comment'] as String,
        longComment: row['long_comment'] as String,
        deviceId: row['device_id'] as String,
        lapCount: row['lap_count'] as int?,
        durationMs: row['duration_ms'] as int?,
        sourceType: _sourceTypeFromRow(row['source_type'] as String?),
        tag: (row['tag'] as String?) ?? '',
      );

  static SessionSourceType _sourceTypeFromRow(String? raw) {
    if (raw == null) return SessionSourceType.idl0;
    for (final t in SessionSourceType.values) {
      if (t.name == raw) return t;
    }
    return SessionSourceType.idl0;
  }
}
