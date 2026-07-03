/// Sync screen state model and controller. See §24.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/exceptions.dart';
import '../transport/wifi_service.dart';
import 'runs_provider.dart';
import 'session_provider.dart';
import 'settings_provider.dart';
import 'wifi_bind_controller.dart';

/// Per-file status in the Sync screen checklist.
enum SyncEntryStatus {
  /// Device file whose sessionId is already in the library.
  inLibrary,

  /// Device file not in the library; queued for download.
  newPending,

  /// Currently downloading.
  downloading,

  /// Downloaded and registered this session.
  done,

  /// Download or registration failed.
  error,

  /// Firmware did not report a sessionId — shown as NEW, identity unknown.
  unknownIdentity,
}

/// Overall phase of the Sync screen.
enum SyncPhase {
  /// Listed (or not yet listed); no download running.
  idle,

  /// Fetching and classifying the device file list.
  listing,

  /// Running the sequential download queue.
  syncing,

  /// Queue finished (all selected files processed).
  done,

  /// Listing failed; see [SyncState.listError].
  error,
}

/// One device file plus its sync state.
class SyncEntry {
  /// Device file metadata (name, size, sessionId).
  final FileInfo file;

  /// Current per-file status.
  final SyncEntryStatus status;

  /// Download fraction 0.0–1.0; meaningful while [status] is downloading.
  final double progress;

  /// Whether the user has this file checked for download.
  final bool selected;

  /// Typed failure message when [status] is [SyncEntryStatus.error].
  final String? errorMessage;

  /// Creates a [SyncEntry].
  const SyncEntry({
    required this.file,
    required this.status,
    this.progress = 0.0,
    this.selected = false,
    this.errorMessage,
  });

  /// True when this file is not yet known to be in the library.
  bool get isNew =>
      status == SyncEntryStatus.newPending ||
      status == SyncEntryStatus.unknownIdentity;

  /// Bytes received so far, derived from [progress] and the known size.
  int get receivedBytes => (progress * file.size).round();

  /// Returns a copy with the given overrides.
  SyncEntry copyWith({
    SyncEntryStatus? status,
    double? progress,
    bool? selected,
    String? errorMessage,
  }) =>
      SyncEntry(
        file: file,
        status: status ?? this.status,
        progress: progress ?? this.progress,
        selected: selected ?? this.selected,
        errorMessage: errorMessage ?? this.errorMessage,
      );
}

/// Immutable Sync screen state.
class SyncState {
  /// One entry per device file.
  final List<SyncEntry> entries;

  /// Overall phase.
  final SyncPhase phase;

  /// Error message when listing fails ([SyncPhase.error]).
  final String? listError;

  /// Creates a [SyncState].
  const SyncState({
    this.entries = const [],
    this.phase = SyncPhase.idle,
    this.listError,
  });

  /// True when [e] is selected and still waiting to download.
  static bool _isQueued(SyncEntry e) =>
      e.selected &&
      (e.status == SyncEntryStatus.newPending ||
          e.status == SyncEntryStatus.unknownIdentity);

  /// Count of files not in the library (NEW or unknown identity).
  int get newCount => entries.where((e) => e.isNew).length;

  /// Selected NEW entries still waiting to start.
  int get queuedCount => entries.where(_isQueued).length;

  /// Entries currently downloading.
  int get downloadingCount =>
      entries.where((e) => e.status == SyncEntryStatus.downloading).length;

  /// Entries completed this run.
  int get doneCount =>
      entries.where((e) => e.status == SyncEntryStatus.done).length;

  /// Total files in this sync run (done + in-flight + queued).
  int get batchTotal => doneCount + downloadingCount + queuedCount;

  /// Returns a copy with the given overrides.
  SyncState copyWith({
    List<SyncEntry>? entries,
    SyncPhase? phase,
    String? listError,
  }) =>
      SyncState(
        entries: entries ?? this.entries,
        phase: phase ?? this.phase,
        listError: listError,
      );
}

/// Drives the Sync screen: lists device files, classifies them against the
/// library, and runs the sequential download queue.
class SyncController extends Notifier<SyncState> {
  StreamSubscription<double>? _activeSub;
  bool _cancelled = false;

  @override
  SyncState build() => const SyncState();

  /// Whether the screen should auto-start syncing on open.
  bool get shouldAutoSync => ref.read(settingsProvider).autoSyncOnOpen;

  /// Maximum wait for an in-flight WiFi link to finish converging before
  /// [list] proceeds. Covers the worst link path (45 s request budget is
  /// the binder's; a typical silent re-link lands in ~1-3 s).
  static const _linkWait = Duration(seconds: 20);

  /// Waits while the WiFi link is still converging ([WifiBindPhase.binding])
  /// so auto-sync on screen-open doesn't race the bind and fire its first
  /// `/files` at a dead route. Returns false when the link is known-failed
  /// or did not converge within [_linkWait]; idle/bound pass straight
  /// through (idle = controller inactive: desktop, or tests).
  ///
  /// TODO(idl0): superseded by the P4 ops gate (serialized, link-gated
  /// DeviceOps facade) — delete when P4 lands.
  Future<bool> _awaitLinked() async {
    final snapshot = ref.read(wifiBindControllerProvider);
    if (snapshot.phase != WifiBindPhase.binding) {
      return snapshot.phase != WifiBindPhase.failed;
    }
    final completer = Completer<bool>();
    final sub =
        ref.listen<WifiBindState>(wifiBindControllerProvider, (_, next) {
      if (completer.isCompleted) return;
      if (next.phase == WifiBindPhase.bound ||
          next.phase == WifiBindPhase.idle) {
        completer.complete(true);
      } else if (next.phase == WifiBindPhase.failed) {
        completer.complete(false);
      }
    });
    final timer = Timer(_linkWait, () {
      if (!completer.isCompleted) completer.complete(false);
    });
    try {
      return await completer.future;
    } finally {
      sub.close();
      timer.cancel();
    }
  }

  /// Fetches `/files` and classifies each entry against the library index.
  ///
  /// Sets [SyncPhase.error] with [SyncState.listError] on transport failure;
  /// never throws (CLAUDE.md §5).
  Future<void> list() async {
    state = state.copyWith(phase: SyncPhase.listing);
    if (!await _awaitLinked()) {
      state = state.copyWith(
        phase: SyncPhase.error,
        listError: 'WiFi link not ready — check the device link and retry.',
      );
      return;
    }
    try {
      final files = await ref.read(wifiServiceProvider).getFileList();
      final libraryIds =
          ref.read(sessionProvider).sessions.map((s) => s.sessionId).toSet();
      final entries = [
        for (final f in files) _classify(f, libraryIds),
      ];
      // Newest-first: filenames follow `YYYY-MM-DD_HH-MM-SS.idl0` (§15.1),
      // so descending name order is chronological newest-first.
      entries.sort((a, b) => b.file.name.compareTo(a.file.name));
      state = state.copyWith(phase: SyncPhase.idle, entries: entries);
    } on TransportException catch (e) {
      state = state.copyWith(phase: SyncPhase.error, listError: e.message);
    }
  }

  SyncEntry _classify(FileInfo f, Set<String> libraryIds) {
    final SyncEntryStatus status;
    if (f.sessionId.isEmpty) {
      status = SyncEntryStatus.unknownIdentity;
    } else if (libraryIds.contains(f.sessionId)) {
      status = SyncEntryStatus.inLibrary;
    } else {
      status = SyncEntryStatus.newPending;
    }
    // Unchecked by default — the screen is a file picker (§24.17). The
    // connect-and-forget path selects all new files via [syncAllNew].
    return SyncEntry(file: f, status: status);
  }

  /// Selects every NEW file and runs the queue — the "connect and forget"
  /// path used by auto-sync and the "Sync all new" action. Distinct from
  /// [sync], which downloads only the files the user checked.
  Future<void> syncAllNew() async {
    final updated = [
      for (final e in state.entries)
        if (e.isNew) e.copyWith(selected: true) else e,
    ];
    state = state.copyWith(entries: updated);
    await sync();
  }

  /// Downloads every selected NEW entry sequentially. The device serves one
  /// HTTP request at a time, so this is intentionally serial (design D7).
  /// A per-file failure marks that entry [SyncEntryStatus.error] and the
  /// queue continues to the next file.
  Future<void> sync() async {
    if (state.phase == SyncPhase.syncing) return;
    _cancelled = false;
    state = state.copyWith(phase: SyncPhase.syncing);

    final pending =
        state.entries.where(SyncState._isQueued).map((e) => e.file).toList();

    for (final file in pending) {
      if (_cancelled) break;
      await _downloadOne(file);
    }

    state = state.copyWith(
      phase: _cancelled ? SyncPhase.idle : SyncPhase.done,
    );
  }

  Future<void> _downloadOne(FileInfo file) async {
    _setEntry(
      file.name,
      (e) => e.copyWith(status: SyncEntryStatus.downloading, progress: 0),
    );
    try {
      final stream =
          ref.read(wifiServiceProvider).downloadFile(file.name, file.size);
      final completer = Completer<void>();
      _activeSub = stream.listen(
        (p) => _setEntry(file.name, (e) => e.copyWith(progress: p)),
        onError: completer.completeError,
        onDone: completer.complete,
        cancelOnError: true,
      );
      await completer.future;

      // Register the downloaded bytes (parse/index/visits/Drive). The data
      // layer resolves the on-disk path from the file name (no I/O here).
      final id = await ref
          .read(runsProvider.notifier)
          .registerDownloadedByName(file.name);

      if (id != null) {
        _setEntry(
          file.name,
          (e) => e.copyWith(status: SyncEntryStatus.done, progress: 1),
        );
      } else {
        _setEntry(
          file.name,
          (e) => e.copyWith(
            status: SyncEntryStatus.error,
            errorMessage: 'Downloaded but could not register; try Import.',
          ),
        );
      }
    } on TransportException catch (e) {
      _setEntry(
        file.name,
        (entry) => entry.copyWith(
          status: SyncEntryStatus.error,
          errorMessage: e.message,
        ),
      );
    } catch (e) {
      _setEntry(
        file.name,
        (entry) => entry.copyWith(
          status: SyncEntryStatus.error,
          errorMessage: e.toString(),
        ),
      );
    } finally {
      await _activeSub?.cancel();
      _activeSub = null;
    }
  }

  /// Cancels the active download and stops the queue.
  Future<void> stop() async {
    _cancelled = true;
    await _activeSub?.cancel();
    _activeSub = null;
    state = state.copyWith(phase: SyncPhase.idle);
  }

  /// Toggles the checkbox for the entry named [name].
  void toggle(String name) =>
      _setEntry(name, (e) => e.copyWith(selected: !e.selected));

  void _setEntry(String name, SyncEntry Function(SyncEntry) update) {
    final updated = [
      for (final e in state.entries)
        if (e.file.name == name) update(e) else e,
    ];
    state = state.copyWith(entries: updated);
  }
}

/// The Sync screen controller. See §24.
final syncControllerProvider =
    NotifierProvider<SyncController, SyncState>(SyncController.new);
