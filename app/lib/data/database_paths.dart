import 'dart:io' show Directory, File, Platform;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

/// Returns the directory under which all SQLite databases live (the four
/// indices: `sessions.db`, `tracks.db`, `workbooks.db`, `idl0_math.db`).
///
/// **Why this exists.** On desktop, `sqflite_common_ffi.getDatabasesPath()`
/// defaults to `<cwd>/.dart_tool/sqflite_common_ffi/databases/` — which
/// sits inside the build tree. `flutter clean` wipes `.dart_tool/` and
/// every index along with it (sessions disappear from the Data tab,
/// tracks/workbooks/math channels are gone). User data must never live
/// under the build tree.
///
/// **Where data lives now.** All platforms use
/// `getApplicationSupportDirectory()` + `/databases/`:
/// - Windows: `%APPDATA%\com.saucy.idl0\databases\`
/// - macOS:   `~/Library/Application Support/com.saucy.idl0/databases/`
/// - Linux:   `~/.local/share/com.saucy.idl0/databases/`
/// - Android: `/data/data/<pkg>/files/databases/` (survives app updates;
///            wiped only on uninstall or explicit "clear data")
/// - iOS:     `<app-bundle>/Library/Application Support/databases/`
///
/// **One-time migration.** If the legacy `.dart_tool/sqflite_common_ffi/
/// databases/<name>.db` exists at startup and the new stable location
/// does not yet have `<name>.db`, the file is moved across. This runs
/// once per database per machine on the first app launch after the
/// upgrade, then no-ops forever.
Future<String> getStableDatabasesPath() async {
  final supportDir = await getApplicationSupportDirectory();
  final dbDir = Directory(p.join(supportDir.path, 'databases'));
  if (!dbDir.existsSync()) {
    await dbDir.create(recursive: true);
  }
  await _migrateLegacyDatabasesOnce(dbDir);
  return dbDir.path;
}

/// Internal flag so the migration sweep only runs once per process. The
/// expensive part is the per-file `Directory.exists` + `File.rename`
/// calls — cheap individually but worth skipping on every
/// `getStableDatabasesPath()` call.
bool _migrationRan = false;

/// Moves any of the four well-known DB files from
/// `<cwd>/.dart_tool/sqflite_common_ffi/databases/` into [stableDir],
/// unless [stableDir] already has its own copy (in which case the legacy
/// file is left in place — the user's already running on the new
/// location and we don't want to clobber newer data).
///
/// Renames rather than copies so the file moves atomically. Failures
/// are swallowed: if the legacy file is locked or permissions deny the
/// rename, the app still boots and creates a fresh DB at the stable
/// location.
Future<void> _migrateLegacyDatabasesOnce(Directory stableDir) async {
  if (_migrationRan) return;
  _migrationRan = true;
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    return;
  }
  final legacyDir = Directory(
    p.join(
      Directory.current.path,
      '.dart_tool',
      'sqflite_common_ffi',
      'databases',
    ),
  );
  if (!legacyDir.existsSync()) return;
  const knownDbs = [
    'sessions.db',
    'tracks.db',
    'workbooks.db',
    'idl0_math.db',
  ];
  for (final name in knownDbs) {
    final src = File(p.join(legacyDir.path, name));
    final dst = File(p.join(stableDir.path, name));
    if (!src.existsSync()) continue;
    if (dst.existsSync()) continue;
    try {
      await src.rename(dst.path);
    } on Object {
      // Lock contention or permission denied — let the platform create a
      // fresh DB at the stable location and skip the legacy file.
    }
  }
}

/// Installs [getStableDatabasesPath]'s location as the default
/// `getDatabasesPath()` for both `sqflite` and `sqflite_common_ffi`.
///
/// Call once from `main()` after `sqfliteFfiInit()`. Subsequent calls
/// to `getDatabasesPath()` anywhere in the app return the stable
/// directory transparently.
Future<void> installStableDatabasePath() async {
  final dir = await getStableDatabasesPath();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await ffi.databaseFactoryFfi.setDatabasesPath(dir);
  } else {
    await sqflite.databaseFactory.setDatabasesPath(dir);
  }
}
