import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart';

import '../data/database_paths.dart';
import '../data/gpx_parser.dart';
import '../data/lap_detection_bridge.dart';
import '../data/session_filename.dart';
import '../data/session_index.dart';
import '../data/session_model.dart';
import '../data/sessions_paths.dart';
import '../data/track.dart';
import '../data/track_matching_bridge.dart';
import '../data/workspace.dart';
import '../src/rust/lib.dart' as rust;
import '../src/rust/session.dart' as rust;
import '../src/rust/tracks.dart' as rust;
import '../transport/real_wifi_service.dart';
import '../transport/wifi_network_binder.dart';
import '../transport/wifi_service.dart';
import 'channel_provider.dart';
import 'device_provider.dart';
import 'drive_sync_provider.dart';
import 'session_provider.dart';
import 'session_workspace_provider.dart';
import 'track_provider.dart';

/// Scope for [RunsNotifier.deleteSession].
enum DeleteScope {
  /// Delete local files and index row only. Drive copy preserved.
  appOnly,

  /// Delete local files, index row, and the Drive copy. Drive failure
  /// aborts before any local mutation so the user can retry.
  everywhere,
}

/// Which session the bulk "Rescan visits" pass is currently scanning.
///
/// Held in its own tiny provider so a session row can show a spinner while it
/// is being parsed by watching `rescanProgressProvider.select((p) =>
/// p.isScanning(id))` — only the row whose status flips rebuilds, instead of
/// the whole results list refreshing once per session.
class RescanProgress {
  /// The session id currently being recomputed, or null when idle.
  final String? currentSessionId;

  /// Creates a [RescanProgress].
  const RescanProgress({this.currentSessionId});

  /// `true` while [sessionId] is the session being scanned.
  bool isScanning(String sessionId) => currentSessionId == sessionId;
}

/// Owns [RescanProgress]. Mutated only by [RunsNotifier.rescanAllTrackVisits].
class RescanProgressNotifier extends Notifier<RescanProgress> {
  @override
  RescanProgress build() => const RescanProgress();

  /// Marks [sessionId] as the one currently being scanned.
  void start(String sessionId) =>
      state = RescanProgress(currentSessionId: sessionId);

  /// Clears progress (back to idle).
  void clear() => state = const RescanProgress();
}

/// Per-row spinner state for the bulk rescan. See [RescanProgress].
final rescanProgressProvider =
    NotifierProvider<RescanProgressNotifier, RescanProgress>(
  RescanProgressNotifier.new,
);

/// Stateless coordinator for session imports and rescan, exposed via
/// [runsProvider]. Filter / view state has moved to
/// `data_filters_provider.dart` (the Data tab's faceted search), so the
/// runs notifier no longer carries any UI state — it is a thin object
/// hosting the import + rescan methods.
///
/// `state` is an opaque counter that increments after each import or
/// rescan so consumers that want to react to a successful operation can
/// `ref.listen(runsProvider, ...)`. Most callers simply invoke the methods
/// without watching the counter.
class RunsNotifier extends Notifier<int> {
  @override
  int build() => 0;

  /// Opens a file picker and imports the chosen `.idl0` or `.gpx` files.
  /// See `docs/IDL0_SPEC.md §15.6 Path B` and §12.
  ///
  /// Files are copied to `<app documents>/sessions/` for a stable [filePath]
  /// that survives Android cache eviction and Drive-sourced URIs. The original
  /// extension is preserved on disk so the parser dispatch in
  /// [sessionHandleProvider] picks the correct backend.
  ///
  /// Returns `(imported: N, failed: [names...])`. Returns `(0, [])` when the
  /// user cancels without picking.
  Future<({int imported, List<String> failed})> importFiles() async {
    final result = await FilePicker.platform.pickFiles(
      // FileType.any — Android doesn't recognise 'idl0' as a MIME type so a
      // custom-extension filter throws. Parsers validate the file content, so
      // invalid files are caught and reported in the failed list.
      type: FileType.any,
      allowMultiple: true,
      // withData: false — the picker supplies a cached temp-file path
      // (including for Android cloud URIs), so multi-hundred-MB logs never
      // sit in the Dart heap. _importIdl0 stages from that path; bytes are
      // only a fallback for platforms that supply neither.
      withData: false,
    );
    if (result == null || result.files.isEmpty) {
      return (imported: 0, failed: <String>[]);
    }

    final base = await getSessionsBaseDir();
    final sessionsDir = Directory(join(base.path, 'sessions'));
    await sessionsDir.create(recursive: true);

    final dbPath = join(await getStableDatabasesPath(), 'sessions.db');
    final index = await SessionIndex.open(dbPath);

    // Read the Track library once for visit detection. fire-and-forget the
    // sync — we use whatever's in the local cache as of build().
    final tracks = await ref.read(trackProvider.future);
    final libraryHash = trackLibraryHash(tracks);

    int imported = 0;
    final failed = <String>[];

    for (final file in result.files) {
      if (file.path == null && file.bytes == null) {
        failed.add(file.name);
        continue;
      }
      try {
        final ext = file.name.toLowerCase().split('.').last;
        final ({SessionMetadata meta, rust.SessionHandle handle}) parsed;
        if (ext == 'gpx') {
          parsed = await _importGpx(file, sessionsDir);
        } else if (ext == 'idl0') {
          parsed = await _importIdl0(file, sessionsDir);
        } else {
          failed.add(file.name);
          continue;
        }

        try {
          await index.upsert(parsed.meta);
          ref.read(sessionProvider.notifier).addSession(parsed.meta);

          // Run multi-track visit detection and persist the result so the
          // hierarchy view can render this session immediately. See §12.3.
          await _detectAndSaveVisits(
            meta: parsed.meta,
            handle: parsed.handle,
            tracks: tracks,
            libraryHash: libraryHash,
          );

          // Enqueue Drive upload after the session is registered.
          // Fire-and-forget; status is tracked in driveSyncProvider.syncStatus.
          ref.read(driveSyncProvider.notifier).queueUpload(parsed.meta);

          imported++;
        } finally {
          // Import handles are short-lived; free the Rust session now rather
          // than when a GC finalizer eventually runs.
          parsed.handle.dispose();
        }
      } catch (_) {
        failed.add(file.name);
      }
    }

    await index.close();
    if (imported > 0) state = state + 1;
    return (imported: imported, failed: failed);
  }

  /// Runs engine visit detection (`rust.detectVisits`) for [handle] against the
  /// current Track library and writes the result to a fresh `Workspace.empty`
  /// at [SessionMetadata.workspacePath]. Used by the bulk [importFiles] path
  /// and the WiFi-download path so the cache is populated atomically with
  /// session creation. Failures are swallowed — a missing or stale workspace
  /// is recoverable via [rescanTrackVisits].
  Future<void> _detectAndSaveVisits({
    required SessionMetadata meta,
    required rust.SessionHandle handle,
    required List<Track> tracks,
    required String libraryHash,
  }) async {
    try {
      final windows = await rust.detectVisits(
        handle: handle,
        tracks: [for (final t in tracks) trackArg(t)],
      );
      final visits = await _visitsWithLaps(handle, windows, tracks);
      final ws = Workspace.empty(meta.sessionId).copyWith(
        trackVisits: visits,
        trackVisitsLibraryHash: libraryHash,
      );
      await ws.save(meta.workspacePath);
    } catch (_) {
      // Detection / persist failures are non-fatal — the session is still
      // imported, just without cached visits. Rescan recovers it.
    }
  }

  /// Maps engine visit [windows] to [TrackVisit]s, detecting and caching the
  /// laps within each window (§17.4) so the Data tab never has to parse the
  /// session on open. Resolves each window's Track from [tracks]; a missing or
  /// timing-less Track yields a visit with empty laps. Per-visit lap-detection
  /// failure is swallowed (empty laps cached) — a later rescan recovers it.
  /// Shared by [_detectAndSaveVisits] (import paths) and [rescanTrackVisits].
  Future<List<TrackVisit>> _visitsWithLaps(
    rust.SessionHandle handle,
    List<rust.VisitWindow> windows,
    List<Track> tracks,
  ) async {
    final tracksById = {for (final t in tracks) t.trackId: t};
    final visits = <TrackVisit>[];
    for (final w in windows) {
      final base = visitFromWindow(w);
      final track = tracksById[base.trackId];
      var laps = const <Lap>[];
      if (track != null) {
        try {
          laps = await detectLapsForVisit(
            handle: handle,
            track: track,
            visit: base,
          );
        } catch (_) {
          // Non-fatal — cache empty laps; the next rescan recovers them.
        }
      }
      visits.add(laps.isEmpty ? base : visitFromWindow(w, laps: laps));
    }
    return visits;
  }

  /// Recomputes [Workspace.trackVisits] for [sessionId] against the current
  /// Track library, preserving every other workspace field. Surfaces the
  /// new visit count via the returned record so the UI can show a
  /// confirmation snackbar.
  ///
  /// Returns `(visits: N, hash: '...')` on success, or `null` if the
  /// session isn't loaded or the handle/workspace can't be read/written. A
  /// session with no GPS yields `(visits: 0)` (no visits, not a failure) —
  /// the engine returns an empty window list rather than erroring.
  Future<({int visits, String hash})?> rescanTrackVisits(
    String sessionId,
  ) async {
    final session = ref
        .read(sessionProvider)
        .sessions
        .where((s) => s.sessionId == sessionId)
        .firstOrNull;
    if (session == null) return null;

    try {
      final result = await _recomputeAndSaveVisits(session);
      // Single-session: refresh this session's workspace immediately so its
      // detail card / lap rows update. (The bulk path defers all refreshes to
      // one pass at the end — see [rescanAllTrackVisits].)
      ref.invalidate(sessionWorkspaceProvider(sessionId));
      state = state + 1;
      return result;
    } catch (_) {
      // Single-session callers degrade to a generic "rescan failed" message;
      // the bulk path surfaces the real error (see [rescanAllTrackVisits]).
      return null;
    }
  }

  /// Recomputes and persists [Workspace.trackVisits] for [session] against the
  /// current Track library, preserving every other workspace field. Returns
  /// the new visit count and library hash. **Throws** on any failure (parse,
  /// visit detection, workspace IO) so the caller can surface the cause —
  /// `rescanTrackVisits` swallows it to `null`, while `rescanAllTrackVisits`
  /// reports the first error string.
  ///
  /// The session handle comes from [sessionHandleProvider]: it pins itself with
  /// `ref.keepAlive()` during its own build (registered with the residency
  /// byte-budget), so it stays valid across these awaits even with no UI
  /// listener — there is no need to parse a separate transient handle here, and
  /// doing so would double-parse and bypass the shared residency budget.
  Future<({int visits, String hash})> _recomputeAndSaveVisits(
    SessionMetadata session,
  ) async {
    final handle =
        await ref.read(sessionHandleProvider(session.sessionId).future);
    final tracks = await ref.read(trackProvider.future);
    final libraryHash = trackLibraryHash(tracks);
    final windows = await rust.detectVisits(
      handle: handle,
      tracks: [for (final t in tracks) trackArg(t)],
    );
    final visits = await _visitsWithLaps(handle, windows, tracks);

    // Load existing workspace so user data (gates, math channels, etc.) is
    // preserved; fall back to Workspace.empty if the file is missing.
    Workspace existing;
    try {
      existing = await Workspace.load(session.workspacePath);
    } catch (_) {
      existing = Workspace.empty(session.sessionId);
    }
    final updated = existing.copyWith(
      trackVisits: visits,
      trackVisitsLibraryHash: libraryHash,
    );
    await updated.save(session.workspacePath);

    // NOTE: cache invalidation is the caller's job. Single rescans invalidate
    // immediately; the bulk pass defers to one refresh at the end so the list
    // does not rebuild once per session.
    return (visits: visits.length, hash: libraryHash);
  }

  /// Walks the on-disk sessions directory and re-indexes any session files
  /// not already in the SQLite index. Used to recover after the index has
  /// been wiped (e.g. by a `flutter clean` against the old build-tree
  /// database location, or any other data-loss event where the `.idl0` /
  /// `.gpx` files survived but `sessions.db` did not).
  ///
  /// Returns:
  /// - `added`: number of sessions that were not in the index and have now
  ///   been added.
  /// - `alreadyKnown`: number of files on disk whose sessionId was already
  ///   in the index — skipped, not re-parsed.
  /// - `failed`: number of files that could not be parsed (corrupt header,
  ///   truncated, unreadable). Their paths are left on disk so the user
  ///   can investigate manually.
  ///
  /// The metadata recovered from disk lacks user-edited fields (rider,
  /// bike, venue, comments) — those lived only in `sessions.db` and are
  /// not stored in the `.idl0` binary or `.idl0w` workspace files. Users
  /// re-enter them via the metadata editor.
  Future<({int added, int alreadyKnown, int failed})>
      rescanSessionsFromDisk() async {
    final base = await getSessionsBaseDir();
    final sessionsDir = Directory(join(base.path, 'sessions'));
    if (!sessionsDir.existsSync()) {
      return (added: 0, alreadyKnown: 0, failed: 0);
    }
    final dbPath = join(await getStableDatabasesPath(), 'sessions.db');
    final index = await SessionIndex.open(dbPath);
    var added = 0;
    var alreadyKnown = 0;
    var failed = 0;
    final newMetas = <SessionMetadata>[];
    try {
      final existing = await index.getAll();
      final existingPaths = existing.map((s) => s.filePath).toSet();
      final existingIds = existing.map((s) => s.sessionId).toSet();
      final entries = sessionsDir.listSync(followLinks: false);
      for (final entry in entries) {
        if (entry is! File) continue;
        final ext = extension(entry.path).toLowerCase();
        if (ext != '.idl0' && ext != '.gpx') continue;
        // Dedup by stored path first (no parse). Filenames are the recording
        // timestamp now, not the sessionId, so the old name==sessionId check no
        // longer holds — the sessionId check after parsing (below) catches a
        // known session re-found under a different filename.
        if (existingPaths.contains(entry.path)) {
          alreadyKnown++;
          continue;
        }
        try {
          final baseName = basenameWithoutExtension(entry.path);
          final wsPath = join(sessionsDir.path, '$baseName.idl0w');
          final SessionMetadata meta;
          if (ext == '.idl0') {
            // Probe-parse for metadata only; dispose immediately so the Rust
            // session does not linger until a GC finalizer runs. The file is
            // never read into the Dart heap — Rust reads it, and the catalog
            // size comes from a stat.
            final handle = await rust.parseSessionFromPath(path: entry.path);
            final rust.SessionMeta summary;
            try {
              summary = await rust.sessionMetadata(handle: handle);
            } finally {
              handle.dispose();
            }
            meta = SessionMetadata(
              sessionId: summary.sessionId,
              deviceId: summary.deviceId,
              filePath: entry.path,
              workspacePath: wsPath,
              createdTimestampMs: summary.timestampUtcMs.toInt(),
              fileSizeBytes: await entry.length(),
              rider: '',
              bike: '',
              bikeComment: '',
              venueName: '',
              eventName: '',
              eventSession: '',
              shortComment: '',
              longComment: '',
              lapCount: null,
              durationMs:
                  summary.channelCount == 0 ? null : summary.durationMs.toInt(),
              sourceType: SessionSourceType.idl0,
            );
          } else {
            // GPX files are KB-MB scale; reading them into Dart is fine.
            final bytes = await entry.readAsBytes();
            final parsed = GpxParser.parse(utf8.decode(bytes));
            final session = parsed.session;
            int? durationMs;
            final epoch = session.channels
                .where((c) => c.channelId == 'GPS_EpochMs')
                .firstOrNull;
            if (epoch != null && epoch.samples.length >= 2) {
              durationMs = (epoch.samples.last - epoch.samples.first).round();
            }
            meta = SessionMetadata(
              sessionId: session.sessionId,
              deviceId: session.deviceId,
              filePath: entry.path,
              workspacePath: wsPath,
              createdTimestampMs: session.timestampUtcMs,
              fileSizeBytes: bytes.length,
              rider: '',
              bike: '',
              bikeComment: '',
              venueName: '',
              eventName: '',
              eventSession: '',
              shortComment: '',
              longComment: '',
              lapCount: null,
              durationMs: durationMs,
              sourceType: SessionSourceType.gpx,
            );
          }
          if (existingIds.contains(meta.sessionId)) {
            // Known session re-found under a different filename — don't dup.
            alreadyKnown++;
            continue;
          }
          await index.upsert(meta);
          newMetas.add(meta);
          added++;
        } on Object {
          failed++;
        }
      }
    } finally {
      await index.close();
    }
    // Push every recovered session into the in-memory list so the Data tab
    // updates without a full app reload.
    final sessionNotifier = ref.read(sessionProvider.notifier);
    for (final meta in newMetas) {
      sessionNotifier.addSession(meta);
    }
    if (added > 0) state = state + 1;
    return (added: added, alreadyKnown: alreadyKnown, failed: failed);
  }

  /// One-time repair (SPEC §5.6 / §15): re-derives each indexed session's
  /// recording timestamp — correcting the historical boot-time anchor for
  /// `.idl0` logs — and renames its files to the timestamp-based scheme. Backs
  /// the Data-tab "Repair timestamps & names" action.
  ///
  /// Idempotent: a session already on the new scheme with a correct timestamp is
  /// counted as [unchanged] and skipped. Fault-isolated: a session whose source
  /// file is missing, won't re-parse, or can't be renamed is left exactly as-is
  /// (renames roll back on partial failure) and counted in [failed].
  Future<({int renamed, int retimed, int unchanged, int failed})>
      repairSessionFilenames() async {
    final baseDir = await getSessionsBaseDir();
    final sessionsDir = Directory(join(baseDir.path, 'sessions'));
    final dbPath = join(await getStableDatabasesPath(), 'sessions.db');
    final index = await SessionIndex.open(dbPath);
    var renamed = 0;
    var retimed = 0;
    var unchanged = 0;
    var failed = 0;
    final updated = <SessionMetadata>[];
    try {
      for (final meta in await index.getAll()) {
        try {
          // 1. Re-derive the recording timestamp (.idl0 only — GPX times were
          //    always real). A missing source file keeps the stored time.
          var tsMs = meta.createdTimestampMs;
          if (meta.sourceType == SessionSourceType.idl0 &&
              File(meta.filePath).existsSync()) {
            final handle = await rust.parseSessionFromPath(path: meta.filePath);
            try {
              tsMs = (await rust.sessionMetadata(handle: handle))
                  .timestampUtcMs
                  .toInt();
            } finally {
              handle.dispose();
            }
          }

          // 2. Compute the target filename base (timestamp, local time).
          final oldBase = basenameWithoutExtension(meta.filePath);
          final srcExt = extension(meta.filePath); // '.idl0' or '.gpx'
          final desired = sessionFileBase(tsMs, fallbackBase: meta.sessionId);
          final newBase = desired == oldBase
              ? oldBase
              : uniqueFileBase(
                  desired,
                  (c) =>
                      c != oldBase &&
                      (File(join(sessionsDir.path, '$c$srcExt')).existsSync() ||
                          File(join(sessionsDir.path, '$c.idl0w'))
                              .existsSync()),
                );

          final tsChanged = tsMs != meta.createdTimestampMs;
          final nameChanged = newBase != oldBase;
          if (!tsChanged && !nameChanged) {
            unchanged++;
            continue;
          }

          var newFilePath = meta.filePath;
          var newWsPath = meta.workspacePath;
          if (nameChanged) {
            newFilePath = join(sessionsDir.path, '$newBase$srcExt');
            newWsPath = join(sessionsDir.path, '$newBase.idl0w');
            await File(meta.filePath).rename(newFilePath);
            try {
              final oldWs = File(meta.workspacePath);
              if (oldWs.existsSync()) await oldWs.rename(newWsPath);
            } on Object {
              // Roll back the source rename so the session stays consistent.
              await File(newFilePath).rename(meta.filePath);
              rethrow;
            }
          }

          final newMeta = meta.copyWith(
            createdTimestampMs: tsMs,
            filePath: newFilePath,
            workspacePath: newWsPath,
          );
          try {
            await index.upsert(newMeta);
          } on Object {
            // DB write failed after the renames — undo them so disk and index
            // stay in agreement.
            if (nameChanged) {
              await File(newFilePath).rename(meta.filePath);
              final ws = File(newWsPath);
              if (ws.existsSync()) await ws.rename(meta.workspacePath);
            }
            rethrow;
          }
          updated.add(newMeta);
          if (nameChanged) renamed++;
          if (tsChanged) retimed++;
        } on Object {
          failed++;
        }
      }
    } finally {
      await index.close();
    }
    // Refresh in-memory state so the browser reflects the new times/names.
    final notifier = ref.read(sessionProvider.notifier);
    for (final m in updated) {
      notifier.updateSession(m);
    }
    if (updated.isNotEmpty) state = state + 1;
    return (
      renamed: renamed,
      retimed: retimed,
      unchanged: unchanged,
      failed: failed,
    );
  }

  /// Recomputes track visits for every session in `sessionProvider`. Returns
  /// the success / failure counts plus [firstError] — the type and message of
  /// the first session that threw, so the UI can show *why* the rescan failed
  /// instead of an opaque count (a session with no GPS yields 0 visits and
  /// counts as a success, not a failure). Used by the toolbar's "Rescan visits"
  /// button. The state counter bumps once at the end if anything succeeded.
  Future<({int rescanned, int failed, String? firstError})>
      rescanAllTrackVisits() async {
    final sessions = ref.read(sessionProvider).sessions;
    final progress = ref.read(rescanProgressProvider.notifier);
    var rescanned = 0;
    var failed = 0;
    String? firstError;
    // Sessions whose workspace actually changed — invalidated once at the end
    // so the list rebuilds a single time, not once per session.
    final touched = <String>[];
    try {
      for (final s in sessions) {
        // Spin only this row (rescanProgressProvider is watched per-row via
        // .select), then yield a frame so the spinner paints before the parse.
        progress.start(s.sessionId);
        await Future<void>.delayed(Duration.zero);
        try {
          await _recomputeAndSaveVisits(s);
          rescanned++;
          touched.add(s.sessionId);
        } catch (e) {
          failed++;
          // Capture the first real cause (type + message) for the UI. Truncate
          // the session id so the message stays scannable.
          final shortId = s.sessionId.length > 8
              ? s.sessionId.substring(0, 8)
              : s.sessionId;
          firstError ??= '$shortId: ${e.runtimeType}: $e';
        }
      }
    } finally {
      progress.clear();
    }
    // One batch refresh at the end. Riverpod coalesces these invalidations into
    // a single rebuild of the dependent results providers.
    for (final id in touched) {
      ref.invalidate(sessionWorkspaceProvider(id));
    }
    if (rescanned > 0) state = state + 1;
    return (rescanned: rescanned, failed: failed, firstError: firstError);
  }

  /// Deletes a session per [scope]. See [DeleteScope].
  ///
  /// Order of operations:
  ///   1. Drive delete (if scope == everywhere) — failures abort here so
  ///      local files remain intact and the caller can retry or downgrade to
  ///      [DeleteScope.appOnly].
  ///   2. Cancel any in-flight Drive upload (clears stale sync badges).
  ///   3. Delete the source file ([SessionMetadata.filePath]) and workspace
  ///      ([SessionMetadata.workspacePath]) from disk.
  ///   4. Remove the SQLite index row.
  ///   5. Remove from the in-memory [sessionProvider] (which also drops the
  ///      session from `selectionProvider` via `removeSessionFromSelection`).
  ///
  /// No-op if [sessionId] is not in the loaded session list.
  Future<void> deleteSession(
    String sessionId, {
    required DeleteScope scope,
  }) async {
    final session = ref
        .read(sessionProvider)
        .sessions
        .where((s) => s.sessionId == sessionId)
        .firstOrNull;
    if (session == null) return;

    if (scope == DeleteScope.everywhere) {
      // Throws if the Drive delete fails — local files stay intact so the
      // user can retry or downgrade to appOnly.
      await ref.read(driveSyncProvider.notifier).deleteRemote(sessionId);
    } else {
      ref.read(driveSyncProvider.notifier).cancelUpload(sessionId);
    }

    await _deleteFileIfExists(session.filePath);
    await _deleteFileIfExists(session.workspacePath);

    final dbPath = join(await getStableDatabasesPath(), 'sessions.db');
    final index = await SessionIndex.open(dbPath);
    await index.delete(sessionId);
    await index.close();

    ref.read(sessionProvider.notifier).removeSession(sessionId);
    state = state + 1;
  }

  /// Deletes [path] from disk if it exists. No-op if [path] does not refer
  /// to an existing file.
  static Future<void> _deleteFileIfExists(String path) async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  /// Resolves the on-disk filename base (no extension) for a session written
  /// into [sessionsDir]. See SPEC §15.
  ///
  /// Re-uses an already-known session's existing base (so a re-import of the
  /// same recording overwrites in place rather than spawning a duplicate);
  /// otherwise derives a fresh base from the recording [timestampMs] in local
  /// time, suffixed (`-2`, `-3`, …) to avoid clobbering an unrelated same-second
  /// recording. Falls back to [sessionId] when the recording time is unknown.
  String _resolveSessionBase(
    Directory sessionsDir,
    String sessionId,
    int timestampMs,
  ) {
    for (final s in ref.read(sessionProvider).sessions) {
      if (s.sessionId == sessionId) {
        return basenameWithoutExtension(s.filePath);
      }
    }
    final desired = sessionFileBase(timestampMs, fallbackBase: sessionId);
    return uniqueFileBase(
      desired,
      (c) =>
          File(join(sessionsDir.path, '$c.idl0')).existsSync() ||
          File(join(sessionsDir.path, '$c.idl0w')).existsSync() ||
          File(join(sessionsDir.path, '$c.gpx')).existsSync(),
    );
  }

  Future<({SessionMetadata meta, rust.SessionHandle handle})> _importIdl0(
    PlatformFile file,
    Directory sessionsDir,
  ) async {
    // Stage the picked file into the sessions dir without pulling it through
    // the Dart heap or across FFI: prefer the picker's temp-file path; fall
    // back to bytes when the platform supplies only bytes.
    final stagedPath = join(sessionsDir.path, '.staging_${file.name}');
    if (file.path != null) {
      await File(file.path!).copy(stagedPath);
    } else {
      await File(stagedPath).writeAsBytes(file.bytes!, flush: true);
    }
    try {
      // Tolerates truncated files per §16 — partial session is still useful.
      final handle = await rust.parseSessionFromPath(path: stagedPath);
      final summary = await rust.sessionMetadata(handle: handle);

      // Name the file by its recording timestamp (§15), not the sessionId UUID.
      final tsMs = summary.timestampUtcMs.toInt();
      final base = _resolveSessionBase(sessionsDir, summary.sessionId, tsMs);
      final destPath = join(sessionsDir.path, '$base.idl0');
      // Re-import of a known session reuses its base → replace the old file.
      if (destPath != stagedPath) await _deleteFileIfExists(destPath);
      await File(stagedPath).rename(destPath);

      final wsPath = join(sessionsDir.path, '$base.idl0w');

      final meta = SessionMetadata(
        sessionId: summary.sessionId,
        deviceId: summary.deviceId,
        filePath: destPath,
        workspacePath: wsPath,
        createdTimestampMs: tsMs,
        fileSizeBytes: await File(destPath).length(),
        rider: '',
        bike: '',
        bikeComment: '',
        venueName: '',
        eventName: '',
        eventSession: '',
        shortComment: '',
        longComment: '',
        lapCount: null,
        durationMs:
            summary.channelCount == 0 ? null : summary.durationMs.toInt(),
        sourceType: SessionSourceType.idl0,
      );
      return (meta: meta, handle: handle);
    } catch (_) {
      // Parse failed (or rename raced) — remove the staged copy so retries
      // don't accumulate orphans. Success renamed it away already.
      await _deleteFileIfExists(stagedPath);
      rethrow;
    }
  }

  /// Registers a `.idl0` file that was just downloaded via WiFi as a session.
  ///
  /// Parses [downloadedPath] in-place with the Rust engine, renames the file
  /// to the canonical `<sessions-dir>/<sessionId>.idl0` layout (so paths
  /// match the import path), upserts the [SessionMetadata] into the SQLite
  /// session index, adds it to [sessionProvider], runs multi-track visit
  /// detection, and queues a Drive upload — i.e. the same end-state as
  /// [importFiles] for the file-picker path, but driven by the WiFi
  /// download stream in [DownloadPanel].
  ///
  /// Returns the resulting [SessionMetadata.sessionId] on success, or `null`
  /// when the file can't be read or parsed. Failures are non-fatal — the
  /// raw `.idl0` file remains on disk so the user can retry via "Import".
  Future<String?> registerDownloadedSession(String downloadedPath) async {
    try {
      final srcFile = File(downloadedPath);
      if (!await srcFile.exists()) return null;

      // Parse in place — Rust reads the file; nothing crosses FFI but the
      // handle. Tolerates truncated files per §16 — partial session is still
      // useful.
      final handle = await rust.parseSessionFromPath(path: downloadedPath);
      try {
        final summary = await rust.sessionMetadata(handle: handle);

        final base = await getSessionsBaseDir();
        final sessionsDir = Directory(join(base.path, 'sessions'));
        await sessionsDir.create(recursive: true);

        // Name the file by its recording timestamp (§15), not the sessionId
        // UUID. A re-registration of a known session reuses its existing base
        // (so the source already at that path skips the rename).
        final tsMs = summary.timestampUtcMs.toInt();
        final fileBase =
            _resolveSessionBase(sessionsDir, summary.sessionId, tsMs);
        final destPath = join(sessionsDir.path, '$fileBase.idl0');
        if (downloadedPath != destPath) {
          await _deleteFileIfExists(destPath);
          try {
            await srcFile.rename(destPath);
          } on FileSystemException {
            // Cross-device rename (rare on Android internal storage) — fall
            // back to copy+delete (filesystem copy; no Dart buffer).
            await srcFile.copy(destPath);
            await srcFile.delete();
          }
        }

        final wsPath = join(sessionsDir.path, '$fileBase.idl0w');

        final meta = SessionMetadata(
          sessionId: summary.sessionId,
          deviceId: summary.deviceId,
          filePath: destPath,
          workspacePath: wsPath,
          createdTimestampMs: tsMs,
          fileSizeBytes: await File(destPath).length(),
          rider: '',
          bike: '',
          bikeComment: '',
          venueName: '',
          eventName: '',
          eventSession: '',
          shortComment: '',
          longComment: '',
          lapCount: null,
          durationMs:
              summary.channelCount == 0 ? null : summary.durationMs.toInt(),
          sourceType: SessionSourceType.idl0,
        );

        final dbPath = join(await getStableDatabasesPath(), 'sessions.db');
        final index = await SessionIndex.open(dbPath);
        try {
          await index.upsert(meta);
        } finally {
          await index.close();
        }
        ref.read(sessionProvider.notifier).addSession(meta);

        // Run multi-track visit detection so the hierarchy view can render the
        // new session immediately (parallels the importFiles path).
        final tracks = await ref.read(trackProvider.future);
        final libraryHash = trackLibraryHash(tracks);
        await _detectAndSaveVisits(
          meta: meta,
          handle: handle,
          tracks: tracks,
          libraryHash: libraryHash,
        );

        // Enqueue Drive upload after the session is registered. Fire-and-forget;
        // status is tracked in driveSyncProvider.syncStatus.
        ref.read(driveSyncProvider.notifier).queueUpload(meta);

        state = state + 1;
        return meta.sessionId;
      } finally {
        // Free the Rust session now; registration only needed metadata and
        // visit detection, and GC finalizers feel no native-byte pressure.
        handle.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  /// Registers a freshly-downloaded device file by its on-device [name].
  ///
  /// The bytes must already be written to `<sessions-root>/sessions/[name]`
  /// (as [WifiService.downloadFile] does). Resolves that canonical path and
  /// delegates to [registerDownloadedSession]. Returns the resulting
  /// [SessionMetadata.sessionId] on success, or `null` on parse failure.
  ///
  /// Keeps download-path resolution in the data layer so callers (e.g. the
  /// Sync screen controller) need no filesystem access of their own.
  Future<String?> registerDownloadedByName(String name) async {
    final base = await getSessionsBaseDir();
    final path = join(base.path, 'sessions', name);
    return registerDownloadedSession(path);
  }

  Future<({SessionMetadata meta, rust.SessionHandle handle})> _importGpx(
    PlatformFile file,
    Directory sessionsDir,
  ) async {
    // GPX is KB-MB scale; reading it into Dart is fine. The picker runs with
    // withData: false, so bytes are only populated on platforms that supply
    // no temp-file path.
    final bytes = file.bytes ?? await File(file.path!).readAsBytes();
    final parseResult = GpxParser.parse(utf8.decode(bytes));
    final session = parseResult.session;

    // Name by recording timestamp (§15), not the sessionId UUID.
    final base = _resolveSessionBase(
      sessionsDir,
      session.sessionId,
      session.timestampUtcMs,
    );
    final destPath = join(sessionsDir.path, '$base.gpx');
    await _deleteFileIfExists(destPath);
    await File(destPath).writeAsBytes(bytes, flush: true);

    final wsPath = join(sessionsDir.path, '$base.idl0w');

    // Duration: span of GPS_EpochMs samples (last - first).
    int? durationMs;
    final epoch =
        session.channels.where((c) => c.channelId == 'GPS_EpochMs').firstOrNull;
    if (epoch != null && epoch.samples.length >= 2) {
      durationMs = (epoch.samples.last - epoch.samples.first).round();
    }

    final meta = SessionMetadata(
      sessionId: session.sessionId,
      deviceId: session.deviceId,
      filePath: destPath,
      workspacePath: wsPath,
      createdTimestampMs: session.timestampUtcMs,
      fileSizeBytes: bytes.length,
      rider: '',
      bike: '',
      bikeComment: '',
      venueName: '',
      eventName: '',
      eventSession: '',
      shortComment: '',
      longComment: '',
      lapCount: null,
      durationMs: durationMs,
      sourceType: SessionSourceType.gpx,
    );

    // Wrap the GPX channels in a session handle so visit detection runs off the
    // engine like the .idl0 path (mirrors sessionHandleProvider's GPX wrap).
    final handle = await rust.sessionFromChannels(
      meta: rust.SessionMetaInput(
        sessionId: session.sessionId,
        deviceId: session.deviceId,
        timestampUtcMs: session.timestampUtcMs,
        configChecksum: session.configChecksum,
      ),
      channels: [
        for (final c in session.channels)
          rust.ChannelInput(
            channelId: c.channelId,
            sampleRateHz: c.sampleRateHz,
            samples: Float64List.fromList(c.samples),
            sampleTimesSecs: c.sampleTimesSecs == null
                ? null
                : Float64List.fromList(c.sampleTimesSecs!),
          ),
      ],
    );
    return (meta: meta, handle: handle);
  }
}

/// Coordinator for session imports and rescan. State is an opaque counter —
/// see [RunsNotifier] for usage notes.
final runsProvider = NotifierProvider<RunsNotifier, int>(RunsNotifier.new);

/// Opens the SQLite session index.
///
/// Tests override this provider with an in-memory [SessionIndex] via
/// [ProviderScope] overrides.
final sessionIndexProvider = FutureProvider<SessionIndex>((ref) async {
  final dbPath = await getStableDatabasesPath();
  return SessionIndex.open(join(dbPath, 'sessions.db'));
});

/// App-session singleton [WifiNetworkBinder].
///
/// The binder holds live link state (the loopback-proxy port from the last
/// `available` event), so it must NOT be recreated when [wifiServiceProvider]
/// rebuilds — a fresh binder reads as "unlinked" and ops fall back to the
/// direct device IP, which no longer routes on Android (no process bind
/// since wifi link P2). Override in tests via [ProviderScope] overrides.
final wifiBinderProvider = Provider<WifiNetworkBinder>(
  (ref) => WifiNetworkBinder(),
);

/// Provides the active [WifiService] implementation. See §17.
///
/// Returns a [RealWifiService] whose SSID is derived from the connected
/// device name in [deviceProvider] (spec §6: BLE name and WiFi SSID match).
/// Watches ONLY the device name — watching the whole [DeviceState] would
/// rebuild the service on every 1 Hz status frame (see [wifiBinderProvider]
/// for why churn here is harmful). The shared binder is injected so link
/// state survives rebuilds on connect/disconnect.
/// Override in tests via [ProviderScope] overrides.
final wifiServiceProvider = Provider<WifiService>((ref) {
  final deviceName =
      ref.watch(deviceProvider.select((s) => s.deviceName)) ?? '';
  return RealWifiService(
    deviceName: deviceName,
    binder: ref.watch(wifiBinderProvider),
  );
});
