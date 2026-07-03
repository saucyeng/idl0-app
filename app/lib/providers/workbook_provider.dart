import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../data/database_paths.dart';
import '../data/sessions_paths.dart';
import '../data/workbook.dart';
import '../data/workbook_index.dart';
import '../data/workbook_migration.dart';
import 'drive_sync_provider.dart';

/// Conflict policy when [WorkbookNotifier.importFromFile] finds a local
/// workbook with the same UUID as the imported file.
enum ImportConflictPolicy {
  /// Overwrite the local copy with the imported one (last-write-wins
  /// timestamps applied verbatim if newer; otherwise bumped to now).
  replace,

  /// Assign a fresh UUID to the imported workbook; append " (Copy)" to
  /// the name.
  copy,
}

/// Provider that opens (or creates) the SQLite [WorkbookIndex] cache.
///
/// Tests override this provider with an in-memory [WorkbookIndex] via
/// [ProviderScope] overrides — see `workbook_provider_test.dart`.
final workbookIndexProvider = FutureProvider<WorkbookIndex>((ref) async {
  final dbPath = await getStableDatabasesPath();
  return WorkbookIndex.open(join(dbPath, 'workbooks.db'));
});

/// Provider that resolves the directory under which `.idl0w` files live.
///
/// Used by the one-shot SharedPreferences migration (see [WorkbookMigration])
/// to scan for math channels. Tests override this provider with a temporary
/// directory.
final workbookMigrationSessionsDirProvider =
    FutureProvider<Directory>((ref) async {
  final base = await getSessionsBaseDir();
  return Directory(join(base.path, 'sessions'));
});

/// Manages the in-memory list of [Workbook]s, the [WorkbookIndex] SQLite
/// cache, and the Drive-side `IDL0/workbooks/` folder.
///
/// **Sync model.** [build] returns the local cache immediately so the UI is
/// responsive even when offline; a fire-and-forget [_syncWithDrive] runs in
/// the background and updates [state] as Drive responds. Conflict policy is
/// last-write-wins by [Workbook.updatedAtMs] — a Drive copy wins iff its
/// `modifiedTime` exceeds the local row's `updated_at_ms`, and the local
/// copy is uploaded otherwise.
///
/// Tests override [workbookIndexProvider] and [driveServiceProvider] to
/// substitute in-memory backends.
class WorkbookNotifier extends AsyncNotifier<List<Workbook>> {
  /// Resolves when the most recent background sync started by [build]
  /// completes. Tests await this to assert post-sync state without flaking
  /// on event-loop timing.
  Future<void> get debugSyncCompletion => _syncCompletion;
  Future<void> _syncCompletion = Future<void>.value();

  /// Pending debounce timers, keyed by workbookId.
  final Map<String, Timer> _pendingUploads = {};

  /// Latest workbook snapshot for each pending upload. Updated atomically
  /// with [_pendingUploads] so [flushPendingUploads] always sends the most
  /// recent payload even after back-to-back mutations.
  final Map<String, Workbook> _pendingWorkbooks = {};

  /// Schedules a debounced Drive upload for [wb]. Cancels any existing
  /// pending upload for the same workbookId — back-to-back mutations
  /// coalesce into a single upload that fires after
  /// [WorkbookSyncConfig.debounceMs]. Does nothing when sync is disabled
  /// for this workbook.
  void _scheduleUpload(Workbook wb) {
    final config = ref.read(workbookSyncConfigProvider(wb.workbookId));
    if (!config.enabled) return;
    _pendingUploads[wb.workbookId]?.cancel();
    _pendingWorkbooks[wb.workbookId] = wb;
    _pendingUploads[wb.workbookId] = Timer(
      Duration(milliseconds: config.debounceMs),
      () {
        final pending = _pendingWorkbooks.remove(wb.workbookId);
        _pendingUploads.remove(wb.workbookId);
        if (pending != null) unawaited(_uploadIgnoringErrors(pending));
      },
    );
  }

  /// Fires every pending debounced upload immediately. Used by "Force sync
  /// now" and by app pause/close to flush before suspend.
  Future<void> flushPendingUploads() async {
    final snapshot = Map<String, Workbook>.from(_pendingWorkbooks);
    for (final t in _pendingUploads.values) {
      t.cancel();
    }
    _pendingUploads.clear();
    _pendingWorkbooks.clear();
    for (final wb in snapshot.values) {
      await _uploadIgnoringErrors(wb);
    }
  }

  /// Whether [build] seeds the default workbook into an empty library so the
  /// Analyze tab always opens to a real, persisted workbook (never an in-memory
  /// phantom whose edits never survive a restart). Production leaves this on;
  /// provider tests that assert on empty-library behaviour set it `false`.
  @visibleForTesting
  static bool seedDefaultWhenEmpty = true;

  @override
  Future<List<Workbook>> build() async {
    final index = await ref.watch(workbookIndexProvider.future);
    // Run one-shot legacy migration. Idempotent after the prefs key is gone.
    final sessionsDir =
        await ref.watch(workbookMigrationSessionsDirProvider.future);
    await WorkbookMigration.run(index: index, sessionsDir: sessionsDir);

    var cached = await index.getAll();

    // Invariant: the library always holds at least the default workbook, so the
    // Analyze tab opens to a real persisted workbook rather than an in-memory
    // phantom whose edits never survive a restart. When **offline** (no Drive
    // to wait for) seed it now; when signed in, defer to the post-sync check
    // below so the seed never races — and clobbers — a download of the user's
    // real workbooks.
    final drive = ref.read(driveServiceProvider);
    if (seedDefaultWhenEmpty && cached.isEmpty && !drive.isSignedIn) {
      final def = Workbook.createDefault();
      await index.upsert(def);
      cached = [def];
    }

    // Fire-and-forget Drive reconciliation. Errors are surfaced via
    // [state] only when no cached data is available; if we already have a
    // cache we prefer to keep the UI responsive.
    _syncCompletion = Future<void>(() async {
      try {
        await _syncWithDrive(index);
      } catch (_) {
        // Background sync failures are non-fatal — the next call will
        // retry. Surfacing them as state errors would clobber the cached
        // list the user is currently looking at.
      }
      // Still empty after the sync pass (signed in but Drive had nothing, or
      // sync failed): seed the default now so the library is never empty.
      if (seedDefaultWhenEmpty && (await index.getAll()).isEmpty) {
        final def = Workbook.createDefault();
        await index.upsert(def);
        state = AsyncData([def]);
      }
    });
    return cached;
  }

  /// The current workbook list, or empty while [build] is still loading.
  ///
  /// A public read accessor so a collaborating notifier (e.g.
  /// [MathChannelNotifier], which mutates the active workbook through
  /// [updateWorkbook]) can read the latest list without `ref.read`. After
  /// [updateWorkbook] emits, the collaborator's own provider is mid-rebuild —
  /// any `ref.read` from it then throws Riverpod's `_didChangeDependency`
  /// assertion. Reading this getter touches only *this* notifier's element.
  List<Workbook> get currentWorkbooks => state.valueOrNull ?? const [];

  /// Creates a new [Workbook] with [name], persists it locally, uploads to
  /// Drive fire-and-forget, and prepends it to [state].
  Future<Workbook> createWorkbook({required String name}) async {
    // "New workbook" is a blank slate (one empty sheet) — a prefilled start
    // comes from a template or by duplicating the default workbook.
    final workbook = Workbook.createBlank(name: name);
    final index = await ref.read(workbookIndexProvider.future);
    await index.upsert(workbook);
    state = AsyncData([workbook, ...(state.value ?? const [])]);
    _scheduleUpload(workbook);
    return workbook;
  }

  /// Persists changes to [workbook] (e.g. renamed, worksheets updated).
  /// Caller is responsible for bumping [Workbook.updatedAtMs] (typically by
  /// going through [Workbook.copyWith] without an explicit `updatedAtMs`).
  Future<void> updateWorkbook(Workbook workbook) async {
    final index = await ref.read(workbookIndexProvider.future);
    await index.upsert(workbook);
    final current = state.value ?? const <Workbook>[];
    state = AsyncData([
      for (final w in current)
        if (w.workbookId == workbook.workbookId) workbook else w,
      // Insert if it wasn't present (e.g. a Workbook created on another device).
      if (!current.any((w) => w.workbookId == workbook.workbookId)) workbook,
    ]);
    _scheduleUpload(workbook);
  }

  /// Removes the [Workbook] with [workbookId] from the local cache and Drive.
  Future<void> deleteWorkbook(String workbookId) async {
    final index = await ref.read(workbookIndexProvider.future);
    await index.delete(workbookId);
    state = AsyncData([
      for (final w in (state.value ?? const <Workbook>[]))
        if (w.workbookId != workbookId) w,
    ]);
    unawaited(_deleteFromDriveIgnoringErrors(workbookId));
  }

  /// Creates a copy of [source] with a fresh UUID, name
  /// `'${source.name} (Copy)'`, and the same worksheets and mathChannels.
  /// Persists locally, uploads to Drive fire-and-forget, and prepends to
  /// [state].
  Future<Workbook> duplicateWorkbook(Workbook source) async {
    final copy = Workbook.create(
      workbookId: const Uuid().v4(),
      name: '${source.name} (Copy)',
      worksheets: source.worksheets,
      mathChannels: source.mathChannels,
    );
    final index = await ref.read(workbookIndexProvider.future);
    await index.upsert(copy);
    state = AsyncData([copy, ...(state.value ?? const [])]);
    _scheduleUpload(copy);
    return copy;
  }

  /// Writes the JSON for [workbookId] to [destPath]. Pretty-printed.
  ///
  /// Throws [ArgumentError] when no workbook with [workbookId] exists locally.
  /// Throws [FileSystemException] when the destination is not writable.
  Future<void> exportToFile(String workbookId, String destPath) async {
    final wbs = state.value ?? const <Workbook>[];
    final wb = wbs.firstWhere(
      (w) => w.workbookId == workbookId,
      orElse: () => throw ArgumentError('Workbook not found: $workbookId'),
    );
    final json = const JsonEncoder.withIndent('  ').convert(wb.toJson());
    await File(destPath).writeAsString(json);
  }

  /// Imports the `.idl0wb` at [path]. Per spec §4.6:
  ///
  /// - **No local UUID match**: imports as-is (preserves UUID), prepends to
  ///   state, and triggers Drive upload.
  /// - **Local match**: caller must supply [conflictPolicy]. Throws
  ///   [StateError] if omitted.
  ///   - [ImportConflictPolicy.replace] — local copy is overwritten (timestamps
  ///     from the file are preserved verbatim).
  ///   - [ImportConflictPolicy.copy] — fresh UUID, name suffixed " (Copy)".
  ///
  /// Returns the workbook as it landed in state.
  Future<Workbook> importFromFile(
    String path, {
    ImportConflictPolicy? conflictPolicy,
  }) async {
    final raw = await File(path).readAsString();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final imported = Workbook.fromJson(json);

    final existing = (state.value ?? const <Workbook>[])
        .where((w) => w.workbookId == imported.workbookId)
        .cast<Workbook?>()
        .firstWhere((w) => w != null, orElse: () => null);

    Workbook toStore;
    if (existing == null) {
      toStore = imported;
    } else {
      if (conflictPolicy == null) {
        throw StateError(
          'importFromFile: workbookId "${imported.workbookId}" already '
          'exists locally; pass conflictPolicy=replace or copy.',
        );
      }
      if (conflictPolicy == ImportConflictPolicy.replace) {
        toStore = imported;
      } else {
        // copy — fresh UUID + " (Copy)" suffix. Build by hand because
        // Workbook has no public copyWith for workbookId.
        final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
        toStore = Workbook(
          workbookId: const Uuid().v4(),
          name: '${imported.name} (Copy)',
          worksheets: imported.worksheets,
          mathChannels: imported.mathChannels,
          createdAtMs: nowMs,
          updatedAtMs: nowMs,
          workbookVersion: imported.workbookVersion,
        );
      }
    }

    final index = await ref.read(workbookIndexProvider.future);
    await index.upsert(toStore);
    final current = state.value ?? const <Workbook>[];
    state = AsyncData([
      toStore,
      for (final w in current)
        if (w.workbookId != toStore.workbookId) w,
    ]);
    _scheduleUpload(toStore);
    return toStore;
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  Future<void> _syncWithDrive(WorkbookIndex index) async {
    final drive = ref.read(driveServiceProvider);
    if (!drive.isSignedIn) return;
    final remoteFiles = await drive.listWorkbooks();
    final cached = await index.getAll();
    final cachedById = {for (final w in cached) w.workbookId: w};
    final remoteIds = <String>{};

    for (final remote in remoteFiles) {
      remoteIds.add(remote.workbookId);
      final local = cachedById[remote.workbookId];
      if (local == null || remote.modifiedTimeMs > local.updatedAtMs) {
        try {
          final downloaded = await drive.downloadWorkbook(remote.workbookId);
          await index.upsert(downloaded);
        } catch (_) {
          // Skip individual Workbook failures so one bad payload does not
          // block the rest of the reconciliation pass.
        }
      }
    }

    for (final local in cached) {
      if (!remoteIds.contains(local.workbookId)) {
        // Local row not yet on Drive — push it.
        try {
          await drive.uploadWorkbook(local);
        } catch (_) {/* skip */}
      }
    }

    // Refresh state with the post-sync cache.
    final fresh = await index.getAll();
    state = AsyncData(fresh);
  }

  Future<void> _uploadIgnoringErrors(Workbook workbook) async {
    final drive = ref.read(driveServiceProvider);
    if (!drive.isSignedIn) return;
    try {
      await drive.uploadWorkbook(workbook);
    } catch (_) {
      // Background upload failures are non-fatal. The next [build] cycle's
      // [_syncWithDrive] will detect the local-newer Workbook and retry.
    }
  }

  Future<void> _deleteFromDriveIgnoringErrors(String workbookId) async {
    final drive = ref.read(driveServiceProvider);
    if (!drive.isSignedIn) return;
    try {
      await drive.deleteWorkbook(workbookId);
    } catch (_) {
      // Background delete failures are non-fatal.
    }
  }
}

/// Provider exposing the user's [Workbook] list.
final workbookProvider =
    AsyncNotifierProvider<WorkbookNotifier, List<Workbook>>(
  WorkbookNotifier.new,
);

// ---------------------------------------------------------------------------
// Per-workbook sync configuration
// ---------------------------------------------------------------------------

/// Per-workbook sync configuration. Stored in [SharedPreferences] keyed by
/// `workbookId` — local view state, not part of the `.idl0wb` payload.
///
/// Defaults: `enabled = true`, `debounceMs = 30000` (30 s) per spec §4.7.
class WorkbookSyncConfig {
  /// When false, this workbook's mutations do NOT upload to Drive.
  final bool enabled;

  /// Milliseconds the upload timer waits after the last mutation before
  /// firing. Clamped to `[1_000, 600_000]` (1 s to 10 min) by the dialog.
  final int debounceMs;

  /// Creates a [WorkbookSyncConfig].
  const WorkbookSyncConfig({
    required this.enabled,
    required this.debounceMs,
  });

  /// Default config used when no entry exists yet for a given workbook.
  static const defaults = WorkbookSyncConfig(
    enabled: true,
    debounceMs: 30000,
  );
}

/// Per-workbook sync configuration notifier. One [WorkbookSyncConfig] per
/// `workbookId`. Initial state is the persisted value from
/// [SharedPreferences], or [WorkbookSyncConfig.defaults] when absent.
class WorkbookSyncConfigNotifier
    extends FamilyNotifier<WorkbookSyncConfig, String> {
  static const _kDebounceMsPrefix = 'workbook_sync_debounce_';
  static const _kEnabledPrefix = 'workbook_sync_enabled_';

  @override
  WorkbookSyncConfig build(String workbookId) {
    // Synchronously return defaults; load async and update if different.
    // Riverpod tolerates state mutation right after build() returns.
    _hydrate(workbookId);
    return WorkbookSyncConfig.defaults;
  }

  Future<void> _hydrate(String workbookId) async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('$_kEnabledPrefix$workbookId');
    final debounce = prefs.getInt('$_kDebounceMsPrefix$workbookId');
    if (enabled != null || debounce != null) {
      state = WorkbookSyncConfig(
        enabled: enabled ?? WorkbookSyncConfig.defaults.enabled,
        debounceMs: debounce ?? WorkbookSyncConfig.defaults.debounceMs,
      );
    }
  }

  /// Sets [WorkbookSyncConfig.enabled] and persists.
  Future<void> setEnabled(bool value) async {
    state = WorkbookSyncConfig(enabled: value, debounceMs: state.debounceMs);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_kEnabledPrefix$arg', value);
  }

  /// Sets [WorkbookSyncConfig.debounceMs] and persists. Caller is
  /// responsible for clamping to a sensible range.
  Future<void> setDebounceMs(int value) async {
    state = WorkbookSyncConfig(enabled: state.enabled, debounceMs: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('$_kDebounceMsPrefix$arg', value);
  }
}

/// Per-workbook sync config provider, keyed by `workbookId`.
final workbookSyncConfigProvider = NotifierProvider.family<
    WorkbookSyncConfigNotifier,
    WorkbookSyncConfig,
    String>(WorkbookSyncConfigNotifier.new);

// ---------------------------------------------------------------------------
// Local helpers
// ---------------------------------------------------------------------------

/// Runs [future] and silently swallows any thrown error.
///
/// Mirrors `package:async`'s `unawaited` (which only marks the linter, not
/// the rejection) and gives us a single canonical name for fire-and-forget
/// background work.
void unawaited(Future<void> future) {
  // ignore: unawaited_futures
  future.then<void>((_) {}, onError: (_) {});
}
