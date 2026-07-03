import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/workbook_index.dart';
import 'package:idl0/data/workbook_migration.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('WorkbookMigration —', () {
    late Directory tmp;
    late WorkbookIndex index;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('idl0_mig_');
      index = await WorkbookIndex.open(inMemoryDatabasePath);
    });

    tearDown(() async {
      await index.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('no legacy prefs — no-op', () async {
      SharedPreferences.setMockInitialValues({});

      final result = await WorkbookMigration.run(
        index: index,
        sessionsDir: tmp,
      );

      expect(result.workbooksCreated, 0);
      expect(await index.getAll(), isEmpty);
    });

    test('one legacy workbook + two .idl0w files — dedupes math channels',
        () async {
      final legacyWb = {
        'name': 'Workbook 1',
        'worksheets': [
          {'id': 'ws-1', 'name': 'Sheet 1', 'charts': []},
        ],
      };
      SharedPreferences.setMockInitialValues({
        'workspace_state': jsonEncode({
          'workbooks': [legacyWb],
          'activeWorkbookIndex': 0,
          'activeWorksheetIndex': 0,
        }),
      });

      // Write v5 JSON directly so math_channels is present on disk.
      // Workspace.save() emits v6 schema (no math_channels), so fixtures that
      // need the migration to collect channels must bypass save().
      const v5ws1 = '''{
  "workspace_version": 5,
  "session_id": "sess-1",
  "lap_gates": [],
  "sector_gates": [],
  "math_channels": [
    {"name": "ForkVel", "expression": "differentiate(F)", "quantity": "velocity", "units": "m/s", "sample_rate_hz": 0, "decimal_places": 2, "color": "#FF0000"}
  ],
  "workbook_layout": {"worksheets": []}
}''';
      const v5ws2 = '''{
  "workspace_version": 5,
  "session_id": "sess-2",
  "lap_gates": [],
  "sector_gates": [],
  "math_channels": [
    {"name": "ForkVel", "expression": "differentiate(F)", "quantity": "velocity", "units": "m/s", "sample_rate_hz": 0, "decimal_places": 2, "color": "#FF0000"},
    {"name": "ShockVel", "expression": "differentiate(S)", "quantity": "velocity", "units": "m/s", "sample_rate_hz": 0, "decimal_places": 2, "color": "#00FF00"}
  ],
  "workbook_layout": {"worksheets": []}
}''';
      await File('${tmp.path}/sess-1.idl0w').writeAsString(v5ws1);
      await File('${tmp.path}/sess-2.idl0w').writeAsString(v5ws2);

      final result = await WorkbookMigration.run(
        index: index,
        sessionsDir: tmp,
      );

      expect(result.workbooksCreated, 1);
      expect(result.mathChannelsAdded, 2);

      final stored = await index.getAll();
      expect(stored.length, 1);
      expect(stored.first.mathChannels.length, 2);
      expect(
        stored.first.mathChannels.map((c) => c.name).toSet(),
        {'ForkVel', 'ShockVel'},
      );
    });

    test('two legacy workbooks — only first gets math channels', () async {
      SharedPreferences.setMockInitialValues({
        'workspace_state': jsonEncode({
          'workbooks': [
            {
              'name': 'First',
              'worksheets': [
                {'id': 'a', 'name': 'S', 'charts': []},
              ],
            },
            {
              'name': 'Second',
              'worksheets': [
                {'id': 'b', 'name': 'S', 'charts': []},
              ],
            },
          ],
          'activeWorkbookIndex': 0,
          'activeWorksheetIndex': 0,
        }),
      });
      // Write v5 JSON directly — Workspace.save() now emits v6 (no math_channels).
      const v5ws = '''{
  "workspace_version": 5,
  "session_id": "sess",
  "lap_gates": [],
  "sector_gates": [],
  "math_channels": [
    {"name": "F", "expression": "x", "quantity": "v", "units": "m/s", "sample_rate_hz": 0, "decimal_places": 2, "color": "#FFF"}
  ],
  "workbook_layout": {"worksheets": []}
}''';
      await File('${tmp.path}/x.idl0w').writeAsString(v5ws);

      await WorkbookMigration.run(index: index, sessionsDir: tmp);

      final stored = await index.getAll();
      expect(stored.length, 2);
      // After "updated_at_ms DESC" ordering, the most recently upserted is
      // first — which workbook gets the channel is a name match.
      final first = stored.firstWhere((w) => w.name == 'First');
      final second = stored.firstWhere((w) => w.name == 'Second');
      expect(first.mathChannels.length, 1);
      expect(second.mathChannels, isEmpty);
    });

    test('migration deletes the legacy prefs key on success', () async {
      SharedPreferences.setMockInitialValues({
        'workspace_state': jsonEncode({
          'workbooks': [
            {
              'name': 'wb',
              'worksheets': [
                {'id': 'x', 'name': 's', 'charts': []},
              ],
            },
          ],
          'activeWorkbookIndex': 0,
          'activeWorksheetIndex': 0,
        }),
      });

      await WorkbookMigration.run(index: index, sessionsDir: tmp);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('workspace_state'), isFalse);
    });

    test('subsequent run after key removal — no-op', () async {
      SharedPreferences.setMockInitialValues({});

      await WorkbookMigration.run(index: index, sessionsDir: tmp);
      final result = await WorkbookMigration.run(
        index: index,
        sessionsDir: tmp,
      );

      expect(result.workbooksCreated, 0);
      expect(result.mathChannelsAdded, 0);
    });

    test('non-existent sessionsDir — handled gracefully', () async {
      SharedPreferences.setMockInitialValues({
        'workspace_state': jsonEncode({
          'workbooks': [
            {
              'name': 'wb',
              'worksheets': [
                {'id': 'x', 'name': 's', 'charts': []},
              ],
            },
          ],
          'activeWorkbookIndex': 0,
          'activeWorksheetIndex': 0,
        }),
      });
      final missing = Directory('${tmp.path}/does/not/exist');

      final result = await WorkbookMigration.run(
        index: index,
        sessionsDir: missing,
      );

      expect(result.workbooksCreated, 1);
      expect(result.mathChannelsAdded, 0);
    });
  });
}
