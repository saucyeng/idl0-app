import 'dart:convert';
import 'dart:io';

import 'bike_profile.dart';

/// File-backed store for bike profiles.
///
/// One JSON file per profile at `<baseDir>/<profile_id>.idl0p`. Atomic
/// writes via `<id>.idl0p.tmp` + rename. Malformed files are skipped on
/// load with a warning rather than failing the whole load.
class ProfileStore {
  /// Directory holding the profile files (created on demand).
  final Directory baseDir;

  /// Creates a [ProfileStore] backed by [baseDir].
  ProfileStore({required this.baseDir});

  static const _ext = '.idl0p';

  /// Loads every `.idl0p` file in [baseDir]. Malformed files are skipped.
  ///
  /// Returns an empty list when [baseDir] does not exist. Results are
  /// sorted by `profileName` ascending so the picker order is stable.
  Future<List<BikeProfile>> loadAll() async {
    if (!await baseDir.exists()) return const [];
    final entries = baseDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith(_ext));
    final out = <BikeProfile>[];
    for (final f in entries) {
      try {
        final text = await f.readAsString();
        final json = jsonDecode(text) as Map<String, dynamic>;
        out.add(BikeProfile.fromJson(json));
      } catch (e) {
        // Skip malformed file; do not throw.
        // ignore: avoid_print
        print('ProfileStore: skipping ${f.path} — $e');
      }
    }
    out.sort((a, b) => a.profileName.compareTo(b.profileName));
    return out;
  }

  /// Writes [profile] atomically to `<baseDir>/<profile_id>.idl0p`.
  ///
  /// Creates [baseDir] if missing. Writes to a `.tmp` sibling first then
  /// renames — a half-written `.tmp` from a prior interrupted save is
  /// overwritten on the next attempt.
  Future<void> save(BikeProfile profile) async {
    if (!await baseDir.exists()) await baseDir.create(recursive: true);
    final target = File('${baseDir.path}/${profile.profileId}$_ext');
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(profile.toJson()),
    );
    await tmp.rename(target.path);
  }

  /// Removes the profile file for [profileId]. No-op when absent.
  Future<void> delete(String profileId) async {
    final f = File('${baseDir.path}/$profileId$_ext');
    if (await f.exists()) await f.delete();
  }
}
