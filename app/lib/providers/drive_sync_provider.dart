import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/exceptions.dart';
import '../data/session_model.dart';
import '../transport/drive_service.dart';
import '../transport/google_drive_service.dart';

// ---------------------------------------------------------------------------
// SyncStatus
// ---------------------------------------------------------------------------

/// Drive sync state for a single file. See §13.
///
/// States: not uploaded → queued → uploading → synced; error on failure.
enum SyncStatus {
  /// File has not been uploaded to Drive.
  notUploaded,

  /// Upload is queued, waiting for an active Drive session.
  queued,

  /// Upload is in progress.
  uploading,

  /// File is present and current in Drive.
  synced,

  /// Upload failed; the user may retry by triggering another import/download.
  error,
}

// ---------------------------------------------------------------------------
// DriveSyncState
// ---------------------------------------------------------------------------

/// Immutable state for [driveSyncProvider]. See §13.
class DriveSyncState {
  /// Whether a Google account is currently signed in with Drive scope.
  final bool isSignedIn;

  /// Email of the signed-in account, or `null` when not signed in.
  final String? accountEmail;

  /// `true` while the interactive sign-in flow is in progress.
  final bool isSigningIn;

  /// Message from the most recent [DriveAuthException], or `null` if no error.
  final String? lastError;

  /// Drive sync status per session UUID → file type.
  ///
  /// Keys: session UUID → `{'idl0', 'idl0w', 'csv', 'fit'}` → [SyncStatus].
  /// Missing keys default to [SyncStatus.notUploaded] at the read site.
  final Map<String, Map<String, SyncStatus>> syncStatus;

  // Sentinel used by [copyWith] so callers can explicitly null nullable fields.
  static const _absent = Object();

  /// Creates a [DriveSyncState].
  const DriveSyncState({
    required this.isSignedIn,
    this.accountEmail,
    required this.isSigningIn,
    this.lastError,
    this.syncStatus = const {},
  });

  /// Returns a copy with the given fields replaced.
  ///
  /// Pass `accountEmail: null` or `lastError: null` to explicitly clear those
  /// nullable fields (omitting them preserves the current value).
  DriveSyncState copyWith({
    bool? isSignedIn,
    Object? accountEmail = _absent,
    bool? isSigningIn,
    Object? lastError = _absent,
    Map<String, Map<String, SyncStatus>>? syncStatus,
  }) =>
      DriveSyncState(
        isSignedIn: isSignedIn ?? this.isSignedIn,
        accountEmail: identical(accountEmail, _absent)
            ? this.accountEmail
            : accountEmail as String?,
        isSigningIn: isSigningIn ?? this.isSigningIn,
        lastError: identical(lastError, _absent)
            ? this.lastError
            : lastError as String?,
        syncStatus: syncStatus ?? this.syncStatus,
      );
}

// ---------------------------------------------------------------------------
// DriveSyncNotifier
// ---------------------------------------------------------------------------

/// Manages Drive authentication state and per-session file sync status.
///
/// Reads [driveServiceProvider] for the underlying [DriveService]. Override
/// [driveServiceProvider] in tests to inject a [FakeDriveService].
class DriveSyncNotifier extends Notifier<DriveSyncState> {
  @override
  DriveSyncState build() {
    final service = ref.read(driveServiceProvider);

    // TODO(idl0): wire Part B when workspace_provider persists to disk and
    // per-session workspace ownership is resolved for multi-session overlays.

    return DriveSyncState(
      isSignedIn: service.isSignedIn,
      accountEmail: service.accountEmail,
      isSigningIn: false,
    );
  }

  /// Starts the interactive Google Sign-In flow.
  ///
  /// Sets [DriveSyncState.isSigningIn] to `true` for the duration. On
  /// [DriveAuthException], surfaces the error message via
  /// [DriveSyncState.lastError] and leaves [isSignedIn] as `false`.
  Future<void> signIn() async {
    state = state.copyWith(isSigningIn: true);
    final service = ref.read(driveServiceProvider);
    try {
      await service.signIn();
      state = DriveSyncState(
        isSignedIn: service.isSignedIn,
        accountEmail: service.accountEmail,
        isSigningIn: false,
        lastError: null,
        syncStatus: state.syncStatus,
      );
    } on DriveAuthException catch (e) {
      state = DriveSyncState(
        isSignedIn: false,
        accountEmail: null,
        isSigningIn: false,
        lastError: e.message,
        syncStatus: state.syncStatus,
      );
    }
  }

  /// Signs out the current account and clears auth state.
  ///
  /// Existing [syncStatus] entries are preserved so the UI can still show
  /// historical sync badges after sign-out.
  Future<void> signOut() async {
    await ref.read(driveServiceProvider).signOut();
    state = DriveSyncState(
      isSignedIn: false,
      accountEmail: null,
      isSigningIn: false,
      lastError: null,
      syncStatus: state.syncStatus,
    );
  }

  /// Enqueues upload of the source file and `.idl0w` workspace for [session].
  ///
  /// The source file type is `'gpx'` for [SessionSourceType.gpx] sessions
  /// and `'idl0'` otherwise. If the user is not signed in, both file types
  /// are immediately set to [SyncStatus.error] and the method returns
  /// without calling the service.
  ///
  /// Uploads are sequential: source file first, then `.idl0w`. Each
  /// transitions through queued → uploading → synced (or error on
  /// [DriveUploadException]).
  Future<void> queueUpload(SessionMetadata session) async {
    final service = ref.read(driveServiceProvider);

    final sourceType =
        session.sourceType == SessionSourceType.gpx ? 'gpx' : 'idl0';
    final fileTypes = [sourceType, 'idl0w'];

    if (!service.isSignedIn) {
      for (final fileType in fileTypes) {
        state =
            _withStatus(state, session.sessionId, fileType, SyncStatus.error);
      }
      return;
    }

    // Mark queued before starting uploads.
    var s = state;
    for (final fileType in fileTypes) {
      s = _withStatus(s, session.sessionId, fileType, SyncStatus.queued);
    }
    state = s;

    for (final fileType in fileTypes) {
      state =
          _withStatus(state, session.sessionId, fileType, SyncStatus.uploading);
      try {
        await service.uploadSessionFile(session, fileType);
        state =
            _withStatus(state, session.sessionId, fileType, SyncStatus.synced);
      } on DriveUploadException {
        state =
            _withStatus(state, session.sessionId, fileType, SyncStatus.error);
      }
    }
  }

  /// Deletes the Drive copies of [sessionId]'s files and clears any
  /// per-session sync-status entries for that session.
  ///
  /// Errors propagate so the caller can abort a "delete everywhere" flow
  /// before deleting local files. See `RunsNotifier.deleteSession`.
  Future<void> deleteRemote(String sessionId) async {
    final service = ref.read(driveServiceProvider);
    await service.deleteRemote(sessionId);
    final updated = {...state.syncStatus}..remove(sessionId);
    state = state.copyWith(syncStatus: updated);
  }

  /// Drops any sync-status entries for [sessionId] without touching Drive.
  ///
  /// Called before a local-only delete so the UI does not keep showing a
  /// stale "synced" badge for a file that no longer exists locally.
  void cancelUpload(String sessionId) {
    // Guard prevents a spurious state rebuild when no entry to remove.
    if (!state.syncStatus.containsKey(sessionId)) return;
    final updated = {...state.syncStatus}..remove(sessionId);
    state = state.copyWith(syncStatus: updated);
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  /// Returns a new [DriveSyncState] with [fileType] for [sessionId] set to
  /// [status], leaving all other entries unchanged.
  static DriveSyncState _withStatus(
    DriveSyncState current,
    String sessionId,
    String fileType,
    SyncStatus status,
  ) {
    final updated = {
      ...current.syncStatus,
      sessionId: {
        ...?current.syncStatus[sessionId],
        fileType: status,
      },
    };
    return current.copyWith(syncStatus: updated);
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// Provides the active [DriveService] implementation.
///
/// Returns [GoogleDriveService] in production. Override in tests via
/// [ProviderScope] to inject a fake implementation.
final driveServiceProvider =
    Provider<DriveService>((_) => GoogleDriveService());

/// Drive authentication state and per-session sync status. See §13 and §17.
final driveSyncProvider =
    NotifierProvider<DriveSyncNotifier, DriveSyncState>(DriveSyncNotifier.new);
