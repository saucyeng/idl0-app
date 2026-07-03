import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart';

import '../data/database_paths.dart';
import '../data/session_index.dart';
import '../data/session_model.dart';
import 'selection_provider.dart';

/// Immutable state for [sessionProvider].
///
/// [sessions] is the full list of known sessions (populated lazily when the
/// user navigates to the Data tab). Selection state has moved to
/// [selectionProvider] so the Analyze tab and other consumers can read a
/// single, mode-aware (session XOR lap) source of truth.
class SessionState {
  /// All currently loaded [SessionMetadata] records.
  final List<SessionMetadata> sessions;

  /// Creates a [SessionState].
  const SessionState({this.sessions = const []});

  /// Returns a copy with [sessions] replaced.
  SessionState copyWith({List<SessionMetadata>? sessions}) =>
      SessionState(sessions: sessions ?? this.sessions);
}

/// Manages the [SessionState] for the app.
class SessionNotifier extends Notifier<SessionState> {
  @override
  SessionState build() => const SessionState();

  /// Upserts [meta] into the session list, keyed by [SessionMetadata.sessionId].
  ///
  /// If a session with the same sessionId is already present it is replaced
  /// in place; otherwise [meta] is appended. Mirrors the
  /// `ConflictAlgorithm.replace` semantics used by [SessionIndex.upsert] so
  /// both layers agree on duplicate handling, and downstream widget builders
  /// never see two [SessionMetadata] sharing a sessionId (which threw a
  /// rendering-library exception on hardware when the user re-downloaded a
  /// session they already had locally).
  ///
  /// On a true cross-device sessionId collision (different [deviceId] but
  /// matching sessionId — astronomically unlikely with the firmware's
  /// 128-bit UUID), the latest import wins and a debug warning is logged.
  /// The composite-sessionId migration in TASKS.md is the path that would
  /// let us keep both entries.
  void addSession(SessionMetadata meta) {
    final existingIndex =
        state.sessions.indexWhere((s) => s.sessionId == meta.sessionId);
    if (existingIndex < 0) {
      state = state.copyWith(sessions: [...state.sessions, meta]);
      return;
    }
    final existing = state.sessions[existingIndex];
    if (existing.deviceId.isNotEmpty &&
        meta.deviceId.isNotEmpty &&
        existing.deviceId != meta.deviceId) {
      debugPrint(
        'WARN: session UUID collision — ${meta.sessionId} held by both '
        'device ${existing.deviceId} and ${meta.deviceId}; '
        'latest import wins, previous entry is being overwritten in state. '
        'See TASKS.md (composite sessionId) for the proper fix.',
      );
    }
    state = state.copyWith(
      sessions: [
        for (var i = 0; i < state.sessions.length; i++)
          if (i == existingIndex) meta else state.sessions[i],
      ],
    );
  }

  /// Replaces the in-memory entry whose [SessionMetadata.sessionId] equals
  /// `meta.sessionId`. No-op when no matching entry exists.
  ///
  /// SQLite index updates are the caller's responsibility — typically the
  /// MetadataForm save path which already opens the index.
  void updateSession(SessionMetadata meta) {
    state = state.copyWith(
      sessions: [
        for (final s in state.sessions)
          if (s.sessionId == meta.sessionId) meta else s,
      ],
    );
  }

  /// Removes the session with [sessionId] from the list and drops any
  /// references to it from the global [selectionProvider] so the Analyze tab
  /// does not try to render a deleted session.
  void removeSession(String sessionId) {
    state = state.copyWith(
      sessions: state.sessions.where((s) => s.sessionId != sessionId).toList(),
    );
    ref.read(selectionProvider.notifier).removeSessionFromSelection(sessionId);
  }

  /// Replaces the session list with [sessions].
  ///
  /// Called by [sessionIndexLoaderProvider] after it reads all records from
  /// the SQLite index on startup.
  void loadSessions(List<SessionMetadata> sessions) {
    state = state.copyWith(sessions: sessions);
  }
}

/// Provides loaded sessions. Selection lives on [selectionProvider]; see §17.
final sessionProvider =
    NotifierProvider<SessionNotifier, SessionState>(SessionNotifier.new);

/// Loads all [SessionMetadata] records from the SQLite session index and
/// populates [sessionProvider] on first watch.
///
/// Watched in `DataTab.build` to trigger the initial load. Override in tests
/// with a no-op or pre-seeded list to avoid touching the real database.
final sessionIndexLoaderProvider = FutureProvider<void>((ref) async {
  final dbPath = await getStableDatabasesPath();
  final index = await SessionIndex.open(join(dbPath, 'sessions.db'));
  final sessions = await index.getAll();
  ref.read(sessionProvider.notifier).loadSessions(sessions);
});
