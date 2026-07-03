import '../data/exceptions.dart';
import '../data/session_model.dart';
import '../data/track.dart';
import '../data/workbook.dart';

/// Drive metadata for a Track JSON file discovered in `IDL0/tracks/`.
///
/// Returned by [DriveService.listTracks]; the full Track payload is fetched
/// only when the local cache is older than [modifiedTimeMs] — see
/// `TrackNotifier` for the conflict-resolution policy.
class DriveTrackFile {
  /// UUID parsed from the file's basename (`<trackId>.idl0t`).
  final String trackId;

  /// Drive `modifiedTime` in UTC milliseconds since Unix epoch.
  ///
  /// Compared against [Track.updatedAtMs] for last-write-wins reconciliation.
  final int modifiedTimeMs;

  /// Creates a [DriveTrackFile].
  const DriveTrackFile({
    required this.trackId,
    required this.modifiedTimeMs,
  });
}

/// Drive metadata for a Workbook JSON file discovered in `IDL0/workbooks/`.
///
/// Returned by [DriveService.listWorkbooks]; the full Workbook payload is
/// fetched only when the local cache is older than [modifiedTimeMs] — see
/// `WorkbookNotifier` for the conflict-resolution policy.
class DriveWorkbookFile {
  /// UUID parsed from the file's basename (`<workbookId>.idl0wb`).
  final String workbookId;

  /// Drive `modifiedTime` in UTC milliseconds since Unix epoch.
  ///
  /// Compared against [Workbook.updatedAtMs] for last-write-wins
  /// reconciliation.
  final int modifiedTimeMs;

  /// Creates a [DriveWorkbookFile].
  const DriveWorkbookFile({
    required this.workbookId,
    required this.modifiedTimeMs,
  });
}

/// Abstract interface for Google Drive file operations. See §13, §12.3.
///
/// Implementations must call [signIn] before [uploadSessionFile],
/// [listTracks], [downloadTrack], or [uploadTrack]. All methods are safe to
/// call from any isolate; implementations must not perform UI operations
/// directly.
abstract class DriveService {
  /// Whether a Google account is currently signed in and the Drive scope
  /// has been granted.
  bool get isSignedIn;

  /// Email of the signed-in account, or `null` when not signed in.
  String? get accountEmail;

  /// Starts the interactive Google Sign-In flow and requests the
  /// `drive.file` scope.
  ///
  /// Throws [DriveAuthException] if the user cancels or the scope is denied.
  Future<void> signIn();

  /// Signs out the current account and clears the cached Drive client.
  Future<void> signOut();

  /// Uploads the file identified by [fileType] for [session] to Drive.
  ///
  /// [fileType] must be `'idl0'`, `'idl0w'`, or `'gpx'`. Creates the
  /// `IDL0/sessions/YYYY-MM-DD_venue_rider/` folder hierarchy on demand using
  /// the Drive Files API. See §13 for folder structure.
  ///
  /// Throws [DriveAuthException] if [isSignedIn] is `false`.
  /// Throws [DriveUploadException] on Drive API HTTP errors or I/O failures
  /// reading the source file from disk.
  Future<void> uploadSessionFile(SessionMetadata session, String fileType);

  /// Lists every `*.idl0t` file in `IDL0/tracks/`, parsing each filename's
  /// UUID prefix into [DriveTrackFile.trackId]. Files whose basename does
  /// not parse as `<UUID>.idl0t` are skipped.
  ///
  /// Returns an empty list when the `tracks` folder does not yet exist.
  /// Throws [DriveAuthException] if [isSignedIn] is `false`.
  /// Throws [DriveUploadException] on Drive API HTTP errors.
  Future<List<DriveTrackFile>> listTracks();

  /// Downloads and parses the Track with [trackId] from `IDL0/tracks/`.
  ///
  /// Throws [DriveAuthException] if [isSignedIn] is `false`.
  /// Throws [DriveUploadException] when the file is missing, the JSON is
  /// malformed, or the Drive API returns an HTTP error.
  Future<Track> downloadTrack(String trackId);

  /// Uploads [track] to `IDL0/tracks/<trackId>.idl0t`. Updates the existing
  /// file when one is found at that path; creates a new file otherwise.
  ///
  /// Throws [DriveAuthException] if [isSignedIn] is `false`.
  /// Throws [DriveUploadException] on Drive API HTTP errors.
  Future<void> uploadTrack(Track track);

  /// Lists every `*.idl0wb` file in `IDL0/workbooks/`, parsing each
  /// filename's UUID prefix into [DriveWorkbookFile.workbookId]. Files whose
  /// basename does not parse as `<UUID>.idl0wb` are skipped.
  ///
  /// Returns an empty list when the `workbooks` folder does not yet exist.
  /// Throws [DriveAuthException] if [isSignedIn] is `false`.
  /// Throws [DriveUploadException] on Drive API HTTP errors.
  Future<List<DriveWorkbookFile>> listWorkbooks();

  /// Downloads and parses the Workbook with [workbookId] from
  /// `IDL0/workbooks/`.
  ///
  /// Throws [DriveAuthException] if [isSignedIn] is `false`.
  /// Throws [DriveUploadException] when the file is missing, the JSON is
  /// malformed, or the Drive API returns an HTTP error.
  Future<Workbook> downloadWorkbook(String workbookId);

  /// Uploads [workbook] to `IDL0/workbooks/<workbookId>.idl0wb`. Updates the
  /// existing file when one is found at that path; creates a new file
  /// otherwise.
  ///
  /// Throws [DriveAuthException] if [isSignedIn] is `false`.
  /// Throws [DriveUploadException] on Drive API HTTP errors.
  Future<void> uploadWorkbook(Workbook workbook);

  /// Deletes the Drive copy of the workbook with [workbookId]. A 404 on the
  /// individual delete is treated as success (file already gone). No-op when
  /// the `workbooks` folder or the file is absent.
  ///
  /// Throws [DriveAuthException] if [isSignedIn] is `false`.
  /// Throws [DriveUploadException] on Drive API HTTP errors other than 404.
  Future<void> deleteWorkbook(String workbookId);

  /// Deletes the Drive copy of the session source file (.idl0 or .gpx) and
  /// its companion `.idl0w` workspace from `IDL0/sessions/<...>/`.
  ///
  /// No-op if no Drive copy exists.
  ///
  /// Throws [DriveAuthException] if [isSignedIn] is `false`.
  /// Throws [DriveUploadException] on Drive API HTTP errors.
  Future<void> deleteRemote(String sessionId);
}
