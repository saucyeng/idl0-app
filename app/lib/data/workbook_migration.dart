import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../providers/workspace_provider.dart' show WorkbookData;
import 'math_channel.dart' show MathChannel;
import 'workbook.dart';
import 'workbook_index.dart';
import 'workspace.dart';

/// Result of one [WorkbookMigration.run] call.
class WorkbookMigrationResult {
  /// Number of [Workbook] entries created in the [WorkbookIndex] this run.
  final int workbooksCreated;

  /// Number of unique [MathChannel] definitions copied from `.idl0w` files
  /// into the first migrated workbook this run.
  final int mathChannelsAdded;

  /// Creates a [WorkbookMigrationResult].
  const WorkbookMigrationResult({
    required this.workbooksCreated,
    required this.mathChannelsAdded,
  });
}

/// One-shot migration from the legacy `workspace_state` SharedPreferences
/// blob to the new per-workbook `.idl0wb` library.
///
/// Idempotent: subsequent runs after the legacy key is gone return a
/// zero-result and do not touch [WorkbookIndex].
class WorkbookMigration {
  /// SharedPreferences key holding the legacy workbook JSON blob.
  static const String _kLegacyKey = 'workspace_state';

  /// Runs the migration. [sessionsDir] is the directory containing `.idl0w`
  /// session workspace files — the math-channel dedupe pass walks it
  /// recursively to collect `mathChannels`. A missing directory is treated
  /// as "no math channels to migrate".
  static Future<WorkbookMigrationResult> run({
    required WorkbookIndex index,
    required Directory sessionsDir,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLegacyKey);
    if (raw == null) {
      return const WorkbookMigrationResult(
        workbooksCreated: 0,
        mathChannelsAdded: 0,
      );
    }

    final json = jsonDecode(raw) as Map<String, dynamic>;
    final legacyWorkbooks = (json['workbooks'] as List<dynamic>? ?? [])
        .map((wb) => WorkbookData.fromJson(wb as Map<String, dynamic>))
        .toList();

    final dedupedMath = await _collectMathChannels(sessionsDir);

    var created = 0;
    for (var i = 0; i < legacyWorkbooks.length; i++) {
      final legacy = legacyWorkbooks[i];
      final wb = Workbook.create(
        name: legacy.name,
        worksheets: legacy.worksheets,
        // Math channels attach only to the first migrated workbook per the
        // spec; other workbooks start with an empty math channel list.
        mathChannels: i == 0 ? dedupedMath : const [],
      );
      await index.upsert(wb);
      created++;
    }

    await prefs.remove(_kLegacyKey);

    return WorkbookMigrationResult(
      workbooksCreated: created,
      mathChannelsAdded: dedupedMath.length,
    );
  }

  /// Walks [dir] for `*.idl0w` files; reads each via [Workspace.load];
  /// collects every `mathChannels` entry; deduplicates by exact
  /// `(name, expression)` match. Returns an empty list when [dir] is
  /// missing or unreadable. Individual file load failures are skipped —
  /// migration is best-effort.
  static Future<List<MathChannel>> _collectMathChannels(Directory dir) async {
    if (!await dir.exists()) return const [];
    final seen = <String, MathChannel>{};
    await for (final entity in dir.list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.idl0w')) continue;
      try {
        final ws = await Workspace.load(entity.path);
        for (final c in ws.mathChannels) {
          seen['${c.name}|${c.expression}'] = c;
        }
      } catch (_) {
        // Skip unreadable / malformed workspaces — best-effort.
      }
    }
    return seen.values.toList();
  }
}
