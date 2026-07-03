import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'workbook.dart';

/// SQLite-backed cache of [Workbook] entities.
///
/// This is a cache only — the canonical store is the per-workbook JSON file
/// in the user's Google Drive (`IDL0/workbooks/<workbookId>.idl0wb`) plus a
/// local file mirror. The index exists so the app can list workbooks
/// quickly without re-reading files; [WorkbookNotifier] keeps it in sync.
///
/// The schema deliberately stores the entire serialised Workbook as a single
/// `full_json` column. Workbooks are read and written as a unit; splitting
/// across normalised tables would buy no query power and add migration
/// churn.
class WorkbookIndex {
  static const _kTable = 'workbooks';
  static const _kVersion = 1;

  final Database _db;

  WorkbookIndex._(this._db);

  /// Opens (or creates) the SQLite database at [path]. Pass
  /// [inMemoryDatabasePath] from `sqflite_common_ffi` for tests; pass a real
  /// file path for persistence across app restarts.
  static Future<WorkbookIndex> open(String path) async {
    final db = await openDatabase(
      path,
      version: _kVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_kTable (
            workbook_id     TEXT PRIMARY KEY,
            name            TEXT NOT NULL,
            created_at_ms   INTEGER NOT NULL,
            updated_at_ms   INTEGER NOT NULL,
            full_json       TEXT NOT NULL
          )
        ''');
      },
    );
    return WorkbookIndex._(db);
  }

  /// Inserts or replaces the cache entry for [workbook]. Upsert semantics
  /// keyed on [Workbook.workbookId].
  Future<void> upsert(Workbook workbook) async {
    await _db.insert(
      _kTable,
      _toRow(workbook),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Returns the cached [Workbook] for [workbookId], or `null` if not cached.
  Future<Workbook?> getById(String workbookId) async {
    final rows = await _db.query(
      _kTable,
      where: 'workbook_id = ?',
      whereArgs: [workbookId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Returns all cached workbooks ordered by [Workbook.updatedAtMs]
  /// descending (most recently edited first).
  Future<List<Workbook>> getAll() async {
    final rows = await _db.query(_kTable, orderBy: 'updated_at_ms DESC');
    return rows.map(_fromRow).toList();
  }

  /// Removes the cache entry for [workbookId]. No-op if not present.
  Future<void> delete(String workbookId) async {
    await _db.delete(
      _kTable,
      where: 'workbook_id = ?',
      whereArgs: [workbookId],
    );
  }

  /// Closes the underlying database connection.
  Future<void> close() => _db.close();

  static Map<String, Object?> _toRow(Workbook w) => {
        'workbook_id': w.workbookId,
        'name': w.name,
        'created_at_ms': w.createdAtMs,
        'updated_at_ms': w.updatedAtMs,
        'full_json': jsonEncode(w.toJson()),
      };

  static Workbook _fromRow(Map<String, dynamic> row) {
    final json = jsonDecode(row['full_json'] as String) as Map<String, dynamic>;
    return Workbook.fromJson(json);
  }
}
