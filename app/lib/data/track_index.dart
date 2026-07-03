import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'track.dart';

/// SQLite-backed cache of [Track] entities. See `docs/IDL0_SPEC.md §12.3`.
///
/// This is a cache only — the canonical store is the per-track JSON file in
/// the user's Google Drive (`IDL0/tracks/<trackId>.idl0t`). The cache exists
/// so the app can list and query tracks without a network round-trip; the
/// `TrackNotifier` is responsible for keeping it in sync with Drive.
///
/// The schema deliberately stores the entire serialised Track as a single
/// `full_json` column. Track payloads (gates + reference polyline) are read
/// and written together; splitting them across normalised tables would buy
/// no query power and add migration churn.
class TrackIndex {
  static const _kTable = 'tracks';
  static const _kVersion = 1;

  final Database _db;

  TrackIndex._(this._db);

  /// Opens (or creates) the SQLite database at [path].
  ///
  /// Pass [inMemoryDatabasePath] from sqflite for an in-memory database
  /// (tests). Pass a real file path for persistence across app restarts.
  static Future<TrackIndex> open(String path) async {
    final db = await openDatabase(
      path,
      version: _kVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_kTable (
            track_id      TEXT PRIMARY KEY,
            name          TEXT NOT NULL,
            venue_name    TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            full_json     TEXT NOT NULL
          )
        ''');
      },
    );
    return TrackIndex._(db);
  }

  /// Inserts or replaces the cache entry for [track]. Upsert semantics keyed
  /// on [Track.trackId].
  Future<void> upsert(Track track) async {
    await _db.insert(
      _kTable,
      _toRow(track),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Returns the cached [Track] for [trackId], or `null` if not cached.
  Future<Track?> getById(String trackId) async {
    final rows = await _db.query(
      _kTable,
      where: 'track_id = ?',
      whereArgs: [trackId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Returns all cached tracks ordered by [Track.updatedAtMs] descending
  /// (most recently edited first).
  Future<List<Track>> getAll() async {
    final rows = await _db.query(_kTable, orderBy: 'updated_at_ms DESC');
    return rows.map(_fromRow).toList();
  }

  /// Removes the cache entry for [trackId]. No-op if not present.
  Future<void> delete(String trackId) async {
    await _db.delete(
      _kTable,
      where: 'track_id = ?',
      whereArgs: [trackId],
    );
  }

  /// Closes the underlying database connection.
  Future<void> close() => _db.close();

  static Map<String, Object?> _toRow(Track t) => {
        'track_id': t.trackId,
        'name': t.name,
        'venue_name': t.venueName,
        'created_at_ms': t.createdAtMs,
        'updated_at_ms': t.updatedAtMs,
        'full_json': jsonEncode(t.toJson()),
      };

  static Track _fromRow(Map<String, dynamic> row) {
    final json = jsonDecode(row['full_json'] as String) as Map<String, dynamic>;
    return Track.fromJson(json);
  }
}
