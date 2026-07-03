import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/exceptions.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/data/track.dart';
import 'package:idl0/data/workbook.dart';
import 'package:idl0/data/workbook_index.dart';
import 'package:idl0/providers/drive_sync_provider.dart';
import 'package:idl0/providers/workbook_provider.dart';
import 'package:idl0/transport/drive_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

// ---------------------------------------------------------------------------
// Fake DriveService — captures uploads, lets tests stage remote workbooks.
// ---------------------------------------------------------------------------

class _FakeDriveService implements DriveService {
  bool _signedIn;
  final List<Workbook> uploadedWorkbooks = [];
  final List<String> deletedWorkbookIds = [];

  // Programmable responses
  List<DriveWorkbookFile> workbookList = const [];
  Map<String, Workbook> workbookDownloads = const {};

  _FakeDriveService({bool signedIn = false}) : _signedIn = signedIn;

  @override
  bool get isSignedIn => _signedIn;

  @override
  String? get accountEmail => _signedIn ? 'fake@example.com' : null;

  @override
  Future<void> signIn() async => _signedIn = true;

  @override
  Future<void> signOut() async => _signedIn = false;

  @override
  Future<void> uploadSessionFile(SessionMetadata session, String fileType) =>
      throw UnimplementedError();

  @override
  Future<List<DriveWorkbookFile>> listWorkbooks() async => workbookList;

  @override
  Future<Workbook> downloadWorkbook(String id) async {
    final w = workbookDownloads[id];
    if (w == null) throw DriveUploadException('not found: $id');
    return w;
  }

  @override
  Future<void> uploadWorkbook(Workbook wb) async {
    uploadedWorkbooks.add(wb);
  }

  @override
  Future<void> deleteWorkbook(String id) async {
    deletedWorkbookIds.add(id);
  }

  // Track methods — not exercised here, return defaults.
  @override
  Future<List<DriveTrackFile>> listTracks() async => const [];

  @override
  Future<Track> downloadTrack(String trackId) => throw UnimplementedError();

  @override
  Future<void> uploadTrack(Track track) async {}

  @override
  Future<void> deleteRemote(String sessionId) async {}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Returns a fresh temp directory that is cleaned up at the end of the test.
Directory _testTempDir() {
  final dir = Directory.systemTemp.createTempSync('idl0_workbook_test_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

Future<WorkbookIndex> _openWorkbookIndex([Directory? dir]) async {
  final base = dir ?? _testTempDir();
  final wi = await WorkbookIndex.open(p.join(base.path, 'workbooks.db'));
  addTearDown(wi.close);
  return wi;
}

Future<({ProviderContainer container, _FakeDriveService drive})>
    _buildContainer({
  WorkbookIndex? workbookIndex,
  _FakeDriveService? drive,
  Directory? sessionsDir,
}) async {
  // Most tests don't care about the migration; ensure no legacy blob leaks
  // between tests and point the sessions-dir at an empty temp so the
  // path_provider plugin is never invoked.
  SharedPreferences.setMockInitialValues(const {});
  final wi = workbookIndex ?? await _openWorkbookIndex();
  final sessions = sessionsDir ?? _testTempDir();
  final fake = drive ?? _FakeDriveService();
  final container = ProviderContainer(
    overrides: [
      workbookIndexProvider.overrideWith((_) async => wi),
      workbookMigrationSessionsDirProvider.overrideWith((_) async => sessions),
      driveServiceProvider.overrideWithValue(fake),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, drive: fake);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // These tests assert on empty-library behaviour (build returns the cache
    // verbatim, createWorkbook prepends to an empty list, etc.), so disable the
    // production default-workbook seed. The dedicated seed test re-enables it.
    WorkbookNotifier.seedDefaultWhenEmpty = false;
  });

  group('WorkbookNotifier —', () {
    test('build — returns cached workbooks immediately', () async {
      // Arrange — pre-populate index with one workbook.
      final wi = await _openWorkbookIndex();
      final wb = Workbook.create(
        name: 'My Workbook',
        now: DateTime.utc(2026, 1, 1),
      );
      await wi.upsert(wb);

      final ctx = await _buildContainer(workbookIndex: wi);

      // Act
      final workbooks = await ctx.container.read(workbookProvider.future);

      // Assert — cached workbook is surfaced even without Drive.
      expect(workbooks.length, equals(1));
      expect(workbooks.first.workbookId, equals(wb.workbookId));
      expect(workbooks.first.name, equals('My Workbook'));
    });

    test('build — seeds the default workbook into an empty offline library',
        () async {
      // Arrange — empty index, signed out. Enable the production seed for this
      // test only (setUpAll turned it off for the empty-library tests).
      WorkbookNotifier.seedDefaultWhenEmpty = true;
      addTearDown(() => WorkbookNotifier.seedDefaultWhenEmpty = false);
      final wi = await _openWorkbookIndex();
      final ctx = await _buildContainer(
        workbookIndex: wi,
        drive: _FakeDriveService(signedIn: false),
      );

      // Act
      final workbooks = await ctx.container.read(workbookProvider.future);

      // Assert — a default "Workbook 1" (Session + Charts) is seeded AND
      // persisted to the index, so it survives a rebuild / app restart. This is
      // the regression guard: previously an empty library left the Analyze tab
      // on an in-memory phantom that reset on every relaunch.
      expect(workbooks, hasLength(1));
      expect(workbooks.single.name, equals('Workbook 1'));
      expect(workbooks.single.worksheets, hasLength(2));
      final cached = await wi.getAll();
      expect(cached, hasLength(1));
      expect(cached.single.workbookId, equals(workbooks.single.workbookId));
    });

    test('createWorkbook — persists locally and prepends to state', () async {
      // Arrange — empty index, signed-out drive.
      final wi = await _openWorkbookIndex();
      final ctx = await _buildContainer(
        workbookIndex: wi,
        drive: _FakeDriveService(signedIn: false),
      );

      await ctx.container.read(workbookProvider.future);
      await ctx.container.read(workbookProvider.notifier).debugSyncCompletion;

      // Act
      final created = await ctx.container
          .read(workbookProvider.notifier)
          .createWorkbook(name: 'New');

      // Assert — local index has one row.
      final cached = await wi.getAll();
      expect(cached.length, equals(1));
      expect(cached.first.workbookId, equals(created.workbookId));

      // State reflects the new workbook at index 0.
      final state = ctx.container.read(workbookProvider).value!;
      expect(state.length, equals(1));
      expect(state.first.name, equals('New'));
    });

    test('updateWorkbook — replaces existing and uploads', () async {
      // Arrange — index pre-populated, drive signed in.
      final wi = await _openWorkbookIndex();
      final wb = Workbook.create(
        name: 'Original',
        now: DateTime.utc(2026, 1, 1),
        workbookId: 'wb-uuid-1',
      );
      await wi.upsert(wb);

      final fake = _FakeDriveService(signedIn: true);
      final ctx = await _buildContainer(workbookIndex: wi, drive: fake);

      await ctx.container.read(workbookProvider.future);
      await ctx.container.read(workbookProvider.notifier).debugSyncCompletion;
      fake.uploadedWorkbooks.clear();

      // Act
      await ctx.container
          .read(workbookProvider.notifier)
          .updateWorkbook(wb.copyWith(name: 'Renamed'));

      // Flush the debounce timer so the upload fires immediately.
      await ctx.container.read(workbookProvider.notifier).flushPendingUploads();

      // Assert — Drive received an upload for this workbook id.
      expect(
        fake.uploadedWorkbooks.map((w) => w.workbookId),
        contains(wb.workbookId),
      );

      // State reflects the rename.
      final state = ctx.container.read(workbookProvider).value!;
      expect(state.first.name, equals('Renamed'));
    });

    test('deleteWorkbook — removes from index and state', () async {
      // Arrange — pre-populate index, signed-out drive so delete is a no-op.
      final wi = await _openWorkbookIndex();
      final wb = Workbook.create(
        name: 'Doomed',
        now: DateTime.utc(2026, 1, 1),
      );
      await wi.upsert(wb);

      final ctx = await _buildContainer(
        workbookIndex: wi,
        drive: _FakeDriveService(signedIn: false),
      );

      await ctx.container.read(workbookProvider.future);

      // Act
      await ctx.container
          .read(workbookProvider.notifier)
          .deleteWorkbook(wb.workbookId);

      // Assert — index is empty and state has no entry.
      expect(await wi.getAll(), isEmpty);
      expect(ctx.container.read(workbookProvider).value, isEmpty);
    });

    test('duplicateWorkbook — creates a fresh-UUID copy with " (Copy)" suffix',
        () async {
      // Arrange
      final wi = await _openWorkbookIndex();
      final wb = Workbook.create(
        name: 'Source',
        now: DateTime.utc(2026, 1, 1),
        workbookId: 'original-uuid',
      );
      await wi.upsert(wb);

      final ctx = await _buildContainer(
        workbookIndex: wi,
        drive: _FakeDriveService(signedIn: false),
      );

      await ctx.container.read(workbookProvider.future);

      // Act
      final copy = await ctx.container
          .read(workbookProvider.notifier)
          .duplicateWorkbook(wb);

      // Assert — different UUID, correct name suffix, present in state.
      expect(copy.workbookId, isNot(equals(wb.workbookId)));
      expect(copy.name, equals('Source (Copy)'));

      final state = ctx.container.read(workbookProvider).value!;
      expect(state.any((w) => w.workbookId == copy.workbookId), isTrue);
    });

    test('LWW conflict — remote-newer workbook overwrites local cache on sync',
        () async {
      // Arrange — local cache has T, remote has T + 1000.
      final wi = await _openWorkbookIndex();
      final t = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;
      final wb = Workbook(
        workbookId: 'shared-uuid',
        name: 'Local',
        worksheets: const [],
        mathChannels: const [],
        createdAtMs: t,
        updatedAtMs: t,
        workbookVersion: 1,
      );
      await wi.upsert(wb);

      final remoteWb = wb.copyWith(
        name: 'Renamed-Remote',
        updatedAtMs: t + 1000,
      );

      final fake = _FakeDriveService(signedIn: true)
        ..workbookList = [
          DriveWorkbookFile(
            workbookId: wb.workbookId,
            modifiedTimeMs: t + 1000,
          ),
        ]
        ..workbookDownloads = {wb.workbookId: remoteWb};

      final ctx = await _buildContainer(workbookIndex: wi, drive: fake);

      // Act — build returns cached; await sync completion.
      await ctx.container.read(workbookProvider.future);
      await ctx.container.read(workbookProvider.notifier).debugSyncCompletion;

      // Assert — state contains the renamed remote workbook.
      final state = ctx.container.read(workbookProvider).value!;
      expect(state.length, equals(1));
      expect(state.first.name, equals('Renamed-Remote'));
    });

    test('local-only when offline — no upload, no error', () async {
      // Arrange — empty index, offline drive.
      final fake = _FakeDriveService(signedIn: false);
      final ctx = await _buildContainer(drive: fake);

      await ctx.container.read(workbookProvider.future);
      await ctx.container.read(workbookProvider.notifier).debugSyncCompletion;

      // Act
      await ctx.container
          .read(workbookProvider.notifier)
          .createWorkbook(name: 'Offline');

      // Flush microtasks.
      await Future<void>.delayed(Duration.zero);

      // Assert — no upload happened, workbook is in state.
      expect(fake.uploadedWorkbooks, isEmpty);
      final state = ctx.container.read(workbookProvider).value!;
      expect(state.any((w) => w.name == 'Offline'), isTrue);
    });

    test('exportToFile + importFromFile — round-trips a workbook', () async {
      // Arrange
      final tmp = await Directory.systemTemp.createTemp('idl0_exp_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final ctx = await _buildContainer();
      final wb = await ctx.container
          .read(workbookProvider.notifier)
          .createWorkbook(name: 'Export Me');

      // Act — export
      final outPath = '${tmp.path}/exported.idl0wb';
      await ctx.container
          .read(workbookProvider.notifier)
          .exportToFile(wb.workbookId, outPath);

      // Assert — file exists, JSON round-trips
      expect(File(outPath).existsSync(), isTrue);
      final json =
          jsonDecode(File(outPath).readAsStringSync()) as Map<String, dynamic>;
      expect(json['workbook_id'], wb.workbookId);
      expect(json['name'], 'Export Me');
    });

    test('importFromFile — no local match preserves UUID', () async {
      // Arrange — write a .idl0wb whose UUID is not in the local index.
      final tmp = await Directory.systemTemp.createTemp('idl0_imp_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final foreignId = const Uuid().v4();
      final foreign = Workbook.create(name: 'Foreign', workbookId: foreignId);
      final path = '${tmp.path}/foreign.idl0wb';
      await File(path).writeAsString(jsonEncode(foreign.toJson()));

      final ctx = await _buildContainer();
      await ctx.container.read(workbookProvider.future);

      // Act
      final imported = await ctx.container
          .read(workbookProvider.notifier)
          .importFromFile(path);

      // Assert — UUID preserved.
      expect(imported.workbookId, foreignId);
      expect(imported.name, 'Foreign');
    });

    test(
        'importFromFile — local UUID match with copy policy gets fresh UUID + " (Copy)"',
        () async {
      final tmp = await Directory.systemTemp.createTemp('idl0_imp2_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      final ctx = await _buildContainer();
      final mine = await ctx.container
          .read(workbookProvider.notifier)
          .createWorkbook(name: 'Mine');

      // Write the same workbook to a file (same UUID).
      final path = '${tmp.path}/mine.idl0wb';
      await File(path).writeAsString(jsonEncode(mine.toJson()));

      // Act
      final imported = await ctx.container
          .read(workbookProvider.notifier)
          .importFromFile(path, conflictPolicy: ImportConflictPolicy.copy);

      // Assert — fresh UUID + " (Copy)" suffix.
      expect(imported.workbookId, isNot(mine.workbookId));
      expect(imported.name, 'Mine (Copy)');
    });

    test('importFromFile — collision without policy throws StateError',
        () async {
      final tmp = await Directory.systemTemp.createTemp('idl0_imp3_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      final ctx = await _buildContainer();
      final mine = await ctx.container
          .read(workbookProvider.notifier)
          .createWorkbook(name: 'Mine');
      final path = '${tmp.path}/m.idl0wb';
      await File(path).writeAsString(jsonEncode(mine.toJson()));

      await expectLater(
        ctx.container.read(workbookProvider.notifier).importFromFile(path),
        throwsA(isA<StateError>()),
      );
    });

    test('build — runs legacy migration before returning cache', () async {
      // Arrange — legacy prefs blob with one workbook + temp empty sessionsDir.
      final legacy = {
        'workbooks': [
          {
            'name': 'OldWB',
            'worksheets': [
              {'id': 'a', 'name': 'S', 'charts': []},
            ],
          },
        ],
        'activeWorkbookIndex': 0,
        'activeWorksheetIndex': 0,
      };
      SharedPreferences.setMockInitialValues({
        'workspace_state': jsonEncode(legacy),
      });

      final index = await WorkbookIndex.open(inMemoryDatabasePath);
      final tmp = await Directory.systemTemp.createTemp('idl0_mig_b_');
      addTearDown(() async {
        await index.close();
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      final container = ProviderContainer(
        overrides: [
          workbookIndexProvider.overrideWith((ref) async => index),
          workbookMigrationSessionsDirProvider.overrideWith((ref) async => tmp),
          driveServiceProvider
              .overrideWithValue(_FakeDriveService(signedIn: false)),
        ],
      );
      addTearDown(container.dispose);

      // Act
      final wbs = await container.read(workbookProvider.future);

      // Assert
      expect(wbs.length, 1);
      expect(wbs.first.name, 'OldWB');
    });

    test('debounce — coalesces back-to-back mutations into a single upload',
        () async {
      // Arrange — drive signed in, small debounce so the test isn't slow.
      SharedPreferences.setMockInitialValues(const {});
      final wi = await _openWorkbookIndex();
      final fake = _FakeDriveService(signedIn: true);
      final ctx = await _buildContainer(workbookIndex: wi, drive: fake);
      await ctx.container.read(workbookProvider.future);
      await ctx.container.read(workbookProvider.notifier).debugSyncCompletion;
      fake.uploadedWorkbooks.clear();

      // Create the workbook then flush + clear so prior uploads don't count.
      final wb = await ctx.container
          .read(workbookProvider.notifier)
          .createWorkbook(name: 'Bouncy');
      await ctx.container.read(workbookProvider.notifier).flushPendingUploads();
      fake.uploadedWorkbooks.clear();

      // Configure a small debounce so the test doesn't wait 30 s.
      await ctx.container
          .read(workbookSyncConfigProvider(wb.workbookId).notifier)
          .setDebounceMs(100);

      // Act — three rapid mutations in <100 ms.
      await ctx.container
          .read(workbookProvider.notifier)
          .updateWorkbook(wb.copyWith(name: 'a'));
      await ctx.container
          .read(workbookProvider.notifier)
          .updateWorkbook(wb.copyWith(name: 'b'));
      await ctx.container
          .read(workbookProvider.notifier)
          .updateWorkbook(wb.copyWith(name: 'c'));

      // Wait past the debounce window.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Assert — exactly one upload, with the LAST mutation's payload.
      expect(fake.uploadedWorkbooks.length, 1);
      expect(fake.uploadedWorkbooks.single.name, 'c');
    });

    test('flushPendingUploads — fires every pending upload immediately',
        () async {
      // Arrange
      SharedPreferences.setMockInitialValues(const {});
      final wi = await _openWorkbookIndex();
      final fake = _FakeDriveService(signedIn: true);
      final ctx = await _buildContainer(workbookIndex: wi, drive: fake);
      await ctx.container.read(workbookProvider.future);
      await ctx.container.read(workbookProvider.notifier).debugSyncCompletion;

      final wb = await ctx.container
          .read(workbookProvider.notifier)
          .createWorkbook(name: 'Flushy');
      await ctx.container.read(workbookProvider.notifier).flushPendingUploads();
      fake.uploadedWorkbooks.clear();

      // Set a long debounce so without flush nothing would fire.
      await ctx.container
          .read(workbookSyncConfigProvider(wb.workbookId).notifier)
          .setDebounceMs(60000);

      await ctx.container
          .read(workbookProvider.notifier)
          .updateWorkbook(wb.copyWith(name: 'pending'));

      // Act — explicit flush.
      await ctx.container.read(workbookProvider.notifier).flushPendingUploads();

      // Assert — upload fired without waiting 60 s.
      expect(fake.uploadedWorkbooks.length, 1);
      expect(fake.uploadedWorkbooks.single.name, 'pending');
    });

    test('debounce — disabled config skips upload entirely', () async {
      // Arrange
      SharedPreferences.setMockInitialValues(const {});
      final wi = await _openWorkbookIndex();
      final fake = _FakeDriveService(signedIn: true);
      final ctx = await _buildContainer(workbookIndex: wi, drive: fake);
      await ctx.container.read(workbookProvider.future);
      await ctx.container.read(workbookProvider.notifier).debugSyncCompletion;

      final wb = await ctx.container
          .read(workbookProvider.notifier)
          .createWorkbook(name: 'Disabled');
      await ctx.container.read(workbookProvider.notifier).flushPendingUploads();
      fake.uploadedWorkbooks.clear();

      // Disable sync for this workbook.
      await ctx.container
          .read(workbookSyncConfigProvider(wb.workbookId).notifier)
          .setEnabled(false);

      await ctx.container
          .read(workbookProvider.notifier)
          .updateWorkbook(wb.copyWith(name: 'no upload'));

      // Wait + flush — still no upload.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ctx.container.read(workbookProvider.notifier).flushPendingUploads();

      expect(fake.uploadedWorkbooks, isEmpty);
    });
  });
}
