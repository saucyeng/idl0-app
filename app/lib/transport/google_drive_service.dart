import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive_api;
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../data/exceptions.dart';
import '../data/session_model.dart';
import '../data/track.dart';
import '../data/workbook.dart';
import 'drive_service.dart';

/// Drive folder name at the root of the IDL0 Drive hierarchy.
const _kRootFolder = 'IDL0';

/// Subfolder within [_kRootFolder] that contains per-session subdirectories.
const _kSessionsFolder = 'sessions';

/// Subfolder within [_kRootFolder] that holds Track JSON files. See §12.3.
const _kTracksFolder = 'tracks';

/// File extension for serialised [Track] payloads on Drive.
const _kTrackFileExtension = 'idl0t';

/// Subfolder within [_kRootFolder] that holds Workbook JSON files.
const _kWorkbooksFolder = 'workbooks';

/// File extension for serialised [Workbook] payloads on Drive.
const _kWorkbookFileExtension = 'idl0wb';

/// Regex matching a canonical UUID v4 (lowercase). Used to validate that a
/// `*.idl0t` filename's basename is a true Track ID before reporting it.
final _kUuidRegex = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

// ---------------------------------------------------------------------------
// Auth client
// ---------------------------------------------------------------------------

/// Injects the [GoogleSignIn] auth headers into every outgoing request so
/// the Drive API accepts them without a separate OAuth library. See §13.
///
/// Fresh headers are obtained per upload call (see [GoogleDriveService.uploadSessionFile])
/// so tokens are never stale.
class _AuthenticatedClient extends http.BaseClient {
  final http.Client _inner;
  final Map<String, String> _headers;

  _AuthenticatedClient(this._inner, this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _inner.send(request);
  }
}

// ---------------------------------------------------------------------------
// GoogleDriveService
// ---------------------------------------------------------------------------

/// Implements [DriveService] using [GoogleSignIn] for OAuth and the
/// `googleapis` package for Drive file operations. See §13.
///
/// Call [signIn] once per session to authenticate. Subsequent calls to
/// [uploadSessionFile] obtain fresh auth headers automatically via
/// `account.authHeaders` so expired tokens are never used.
class GoogleDriveService implements DriveService {
  final GoogleSignIn _googleSignIn;

  // Non-null in [forTest] mode — used directly, bypassing live auth flow.
  final drive_api.DriveApi? _testApi;

  // Tracks signed-in state in [forTest] mode; mutated by [signOut].
  bool _testIsSignedIn;

  // Email shown by [accountEmail] in [forTest] mode.
  final String? _testEmail;

  // Live sign-in account. Non-null when the user has completed [signIn].
  GoogleSignInAccount? _account;

  // ---------------------------------------------------------------------------
  // Constructors
  // ---------------------------------------------------------------------------

  /// Production constructor. Attempts a silent sign-in to restore a previous
  /// session so the Drive section reflects the correct state without a manual
  /// tap. The notifier reads [isSignedIn] after the widget tree first builds;
  /// users tap "Sign In" explicitly to guarantee the session is current.
  GoogleDriveService()
      : _googleSignIn = GoogleSignIn(
          scopes: [drive_api.DriveApi.driveFileScope],
        ),
        _testApi = null,
        _testIsSignedIn = false,
        _testEmail = null {
    _googleSignIn.signInSilently().then((account) {
      if (account != null) _account = account;
    }).catchError((_) {
      // Platform does not support google_sign_in (e.g. Windows desktop).
    });
  }

  /// Testing constructor. Injects a pre-built [driveApi] backed by a
  /// [MockClient] so no real network traffic is made. [googleSignIn] should
  /// be a fake subclass whose [GoogleSignIn.signOut] is a no-op.
  ///
  /// When [signedIn] is `false`, [driveApi] is ignored — [uploadSessionFile]
  /// will throw [DriveAuthException] immediately.
  @visibleForTesting
  GoogleDriveService.forTest({
    required GoogleSignIn googleSignIn,
    drive_api.DriveApi? driveApi,
    bool signedIn = true,
    String testEmail = 'test@example.com',
  })  : _googleSignIn = googleSignIn,
        _testApi = driveApi,
        _testIsSignedIn = signedIn,
        _testEmail = signedIn ? testEmail : null;

  // ---------------------------------------------------------------------------
  // DriveService interface
  // ---------------------------------------------------------------------------

  @override
  bool get isSignedIn =>
      _testApi != null ? _testIsSignedIn : _account != null;

  @override
  String? get accountEmail => _testApi != null
      ? (_testIsSignedIn ? _testEmail : null)
      : _account?.email;

  @override
  Future<void> signIn() async {
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) {
        throw const DriveAuthException('Sign-in cancelled by user.');
      }
      _account = account;
    } on DriveAuthException {
      rethrow;
    } catch (e) {
      if (e.toString().contains('MissingPluginException')) {
        throw const DriveAuthException(
            'Google Sign-In is not available on this platform. Use an Android device.',
          );
      }
      throw DriveAuthException('Sign-in failed: $e');
    }
  }

  @override
  Future<void> signOut() async {
    await _googleSignIn.signOut();
    _account = null;
    _testIsSignedIn = false;
  }

  /// Uploads [fileType] (`'idl0'`, `'idl0w'`, or `'gpx'`) for [session] to Drive.
  ///
  /// Creates `IDL0/sessions/YYYY-MM-DD_venue_rider/` on demand using the
  /// same query pattern as the Kotlin prototype:
  /// `"mimeType='application/vnd.google-apps.folder' and name='X'
  ///  and 'parentId' in parents and trashed=false"`. See §13.
  ///
  /// Auth headers are refreshed before every upload; [GoogleSignIn] returns
  /// a cached token that is automatically renewed when near expiry.
  @override
  Future<void> uploadSessionFile(SessionMetadata session, String fileType) async {
    if (!isSignedIn) {
      throw const DriveAuthException('Not signed in to Google Drive.');
    }

    try {
      final api = _testApi ?? await _buildLiveApi();

      // Build folder path: IDL0/ → IDL0/sessions/ → IDL0/sessions/<date_venue_rider>/
      final rootId = await _getOrCreateFolder(api, _kRootFolder, 'root');
      final sessionsId = await _getOrCreateFolder(api, _kSessionsFolder, rootId);
      final sessionFolderName = _buildSessionFolderName(session);
      final sessionFolderId = await _getOrCreateFolder(api, sessionFolderName, sessionsId);

      // Locate source file on disk. For `idl0w` use the workspace; for
      // `idl0`/`gpx` use the source log file referenced by [filePath].
      final sourcePath = fileType == 'idl0w'
          ? session.workspacePath
          : session.filePath;
      final ioFile = File(sourcePath);
      if (!ioFile.existsSync()) {
        throw DriveUploadException(
          'Source file not found for upload: $sourcePath',
        );
      }

      final fileLength = ioFile.lengthSync();
      final driveFile = drive_api.File()
        ..name = '${session.sessionId}.$fileType'
        ..parents = [sessionFolderId];

      final media = drive_api.Media(
        ioFile.openRead(),
        fileLength,
        contentType: 'application/octet-stream',
      );

      await api.files.create(driveFile, uploadMedia: media, $fields: 'id');
    } on DriveAuthException {
      rethrow;
    } on DriveUploadException {
      rethrow;
    } catch (e) {
      throw DriveUploadException('Drive upload failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Track operations (§12.3)
  // ---------------------------------------------------------------------------

  @override
  Future<List<DriveTrackFile>> listTracks() async {
    if (!isSignedIn) {
      throw const DriveAuthException('Not signed in to Google Drive.');
    }
    try {
      final api = _testApi ?? await _buildLiveApi();
      final tracksFolderId = await _findTracksFolderId(api);
      if (tracksFolderId == null) return const [];

      final results = <DriveTrackFile>[];
      String? pageToken;
      do {
        final q = "'$tracksFolderId' in parents and trashed=false";
        final result = await api.files.list(
          q: q,
          spaces: 'drive',
          $fields: 'files(id,name,modifiedTime),nextPageToken',
          pageToken: pageToken,
        );
        for (final file in result.files ?? const <drive_api.File>[]) {
          final parsed = _parseTrackFile(file);
          if (parsed != null) results.add(parsed);
        }
        pageToken = result.nextPageToken;
      } while (pageToken != null);
      return results;
    } on DriveAuthException {
      rethrow;
    } catch (e) {
      throw DriveUploadException('Drive list tracks failed: $e');
    }
  }

  @override
  Future<Track> downloadTrack(String trackId) async {
    if (!isSignedIn) {
      throw const DriveAuthException('Not signed in to Google Drive.');
    }
    try {
      final api = _testApi ?? await _buildLiveApi();
      final tracksFolderId = await _findTracksFolderId(api);
      if (tracksFolderId == null) {
        throw DriveUploadException('Track not found in Drive: $trackId');
      }
      final fileId = await _findTrackFileId(api, tracksFolderId, trackId);
      if (fileId == null) {
        throw DriveUploadException('Track not found in Drive: $trackId');
      }

      final media = await api.files.get(
        fileId,
        downloadOptions: drive_api.DownloadOptions.fullMedia,
      ) as drive_api.Media;

      final bytes = await media.stream
          .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      return Track.fromJson(json);
    } on DriveAuthException {
      rethrow;
    } on DriveUploadException {
      rethrow;
    } catch (e) {
      throw DriveUploadException('Drive download track failed: $e');
    }
  }

  @override
  Future<void> uploadTrack(Track track) async {
    if (!isSignedIn) {
      throw const DriveAuthException('Not signed in to Google Drive.');
    }
    try {
      final api = _testApi ?? await _buildLiveApi();
      final rootId = await _getOrCreateFolder(api, _kRootFolder, 'root');
      final tracksFolderId =
          await _getOrCreateFolder(api, _kTracksFolder, rootId);

      final fileName = '${track.trackId}.$_kTrackFileExtension';
      final bodyBytes = utf8.encode(
        const JsonEncoder.withIndent('  ').convert(track.toJson()),
      );
      final media = drive_api.Media(
        Stream<List<int>>.value(bodyBytes),
        bodyBytes.length,
        contentType: 'application/json',
      );

      final existingId =
          await _findTrackFileId(api, tracksFolderId, track.trackId);
      if (existingId == null) {
        final driveFile = drive_api.File()
          ..name = fileName
          ..parents = [tracksFolderId];
        await api.files.create(driveFile, uploadMedia: media, $fields: 'id');
      } else {
        // Update path: cannot send `parents` on update; the file stays in
        // the existing parent folder.
        final driveFile = drive_api.File()..name = fileName;
        await api.files.update(
          driveFile,
          existingId,
          uploadMedia: media,
          $fields: 'id',
        );
      }
    } on DriveAuthException {
      rethrow;
    } catch (e) {
      throw DriveUploadException('Drive upload track failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Workbook operations
  // ---------------------------------------------------------------------------

  @override
  Future<List<DriveWorkbookFile>> listWorkbooks() async {
    if (!isSignedIn) {
      throw const DriveAuthException('Not signed in to Google Drive.');
    }
    try {
      final api = _testApi ?? await _buildLiveApi();
      final workbooksFolderId = await _findWorkbooksFolderId(api);
      if (workbooksFolderId == null) return const [];

      final results = <DriveWorkbookFile>[];
      String? pageToken;
      do {
        final q = "'$workbooksFolderId' in parents and trashed=false";
        final result = await api.files.list(
          q: q,
          spaces: 'drive',
          $fields: 'files(id,name,modifiedTime),nextPageToken',
          pageToken: pageToken,
        );
        for (final file in result.files ?? const <drive_api.File>[]) {
          final parsed = _parseWorkbookFile(file);
          if (parsed != null) results.add(parsed);
        }
        pageToken = result.nextPageToken;
      } while (pageToken != null);
      return results;
    } on DriveAuthException {
      rethrow;
    } catch (e) {
      throw DriveUploadException('Drive list workbooks failed: $e');
    }
  }

  @override
  Future<Workbook> downloadWorkbook(String workbookId) async {
    if (!isSignedIn) {
      throw const DriveAuthException('Not signed in to Google Drive.');
    }
    try {
      final api = _testApi ?? await _buildLiveApi();
      final workbooksFolderId = await _findWorkbooksFolderId(api);
      if (workbooksFolderId == null) {
        throw DriveUploadException('Workbook not found in Drive: $workbookId');
      }
      final fileId =
          await _findWorkbookFileId(api, workbooksFolderId, workbookId);
      if (fileId == null) {
        throw DriveUploadException('Workbook not found in Drive: $workbookId');
      }

      final media = await api.files.get(
        fileId,
        downloadOptions: drive_api.DownloadOptions.fullMedia,
      ) as drive_api.Media;

      final bytes = await media.stream
          .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      return Workbook.fromJson(json);
    } on DriveAuthException {
      rethrow;
    } on DriveUploadException {
      rethrow;
    } catch (e) {
      throw DriveUploadException('Drive download workbook failed: $e');
    }
  }

  @override
  Future<void> uploadWorkbook(Workbook workbook) async {
    if (!isSignedIn) {
      throw const DriveAuthException('Not signed in to Google Drive.');
    }
    try {
      final api = _testApi ?? await _buildLiveApi();
      final rootId = await _getOrCreateFolder(api, _kRootFolder, 'root');
      final workbooksFolderId =
          await _getOrCreateFolder(api, _kWorkbooksFolder, rootId);

      final fileName = '${workbook.workbookId}.$_kWorkbookFileExtension';
      final bodyBytes = utf8.encode(
        const JsonEncoder.withIndent('  ').convert(workbook.toJson()),
      );
      final media = drive_api.Media(
        Stream<List<int>>.value(bodyBytes),
        bodyBytes.length,
        contentType: 'application/json',
      );

      final existingId =
          await _findWorkbookFileId(api, workbooksFolderId, workbook.workbookId);
      if (existingId == null) {
        final driveFile = drive_api.File()
          ..name = fileName
          ..parents = [workbooksFolderId];
        await api.files.create(driveFile, uploadMedia: media, $fields: 'id');
      } else {
        // Update path: cannot send `parents` on update; the file stays in
        // the existing parent folder.
        final driveFile = drive_api.File()..name = fileName;
        await api.files.update(
          driveFile,
          existingId,
          uploadMedia: media,
          $fields: 'id',
        );
      }
    } on DriveAuthException {
      rethrow;
    } catch (e) {
      throw DriveUploadException('Drive upload workbook failed: $e');
    }
  }

  @override
  Future<void> deleteWorkbook(String workbookId) async {
    if (!isSignedIn) {
      throw const DriveAuthException('Not signed in to Google Drive.');
    }
    try {
      final api = _testApi ?? await _buildLiveApi();
      final workbooksFolderId = await _findWorkbooksFolderId(api);
      if (workbooksFolderId == null) return;
      final fileId =
          await _findWorkbookFileId(api, workbooksFolderId, workbookId);
      if (fileId == null) return;
      try {
        await api.files.delete(fileId);
      } on drive_api.DetailedApiRequestError catch (e) {
        if (e.status == 404) return; // already gone — success
        throw DriveUploadException(
          'Drive delete failed: ${e.message ?? e.status?.toString()}',
        );
      }
    } on DriveAuthException {
      rethrow;
    } on DriveUploadException {
      rethrow;
    } catch (e) {
      throw DriveUploadException('Drive delete workbook failed: $e');
    }
  }

  /// Returns the Drive folder ID for `IDL0/workbooks/`, or `null` when either
  /// `IDL0` or `workbooks` does not yet exist (the cluster will be created
  /// lazily by [uploadWorkbook] on first write).
  Future<String?> _findWorkbooksFolderId(drive_api.DriveApi api) async {
    final rootId = await _findFolderId(api, _kRootFolder, 'root');
    if (rootId == null) return null;
    return _findFolderId(api, _kWorkbooksFolder, rootId);
  }

  /// Returns the Drive file ID for `<workbookId>.idl0wb` under [parentId], or
  /// `null` when no such file exists. Used by both [downloadWorkbook] and the
  /// update branch of [uploadWorkbook].
  Future<String?> _findWorkbookFileId(
    drive_api.DriveApi api,
    String parentId,
    String workbookId,
  ) async {
    final fileName = '$workbookId.$_kWorkbookFileExtension';
    final q = "name='$fileName' and '$parentId' in parents and trashed=false";
    final result = await api.files.list(
      q: q,
      spaces: 'drive',
      $fields: 'files(id)',
    );
    final files = result.files;
    if (files == null || files.isEmpty) return null;
    return files.first.id;
  }

  /// Parses a Drive [drive_api.File] result into a [DriveWorkbookFile], or
  /// returns `null` when the filename's basename is not a UUID and therefore
  /// is not a managed Workbook payload.
  DriveWorkbookFile? _parseWorkbookFile(drive_api.File file) {
    final name = file.name;
    if (name == null) return null;
    if (!name.endsWith('.$_kWorkbookFileExtension')) return null;
    final basename = name.substring(
        0, name.length - (_kWorkbookFileExtension.length + 1),);
    if (!_kUuidRegex.hasMatch(basename)) return null;
    final modifiedMs =
        file.modifiedTime?.toUtc().millisecondsSinceEpoch ?? 0;
    return DriveWorkbookFile(workbookId: basename, modifiedTimeMs: modifiedMs);
  }

  /// Returns the Drive folder ID for `IDL0/tracks/`, or `null` when either
  /// `IDL0` or `tracks` does not yet exist (the cluster will be created
  /// lazily by [uploadTrack] on first write).
  Future<String?> _findTracksFolderId(drive_api.DriveApi api) async {
    final rootId = await _findFolderId(api, _kRootFolder, 'root');
    if (rootId == null) return null;
    return _findFolderId(api, _kTracksFolder, rootId);
  }

  /// Looks up a folder by name without creating it. Returns `null` when not
  /// found. Used by read paths (list / download) where missing folders are
  /// expected when no Track has ever been written.
  Future<String?> _findFolderId(
    drive_api.DriveApi api,
    String name,
    String parentId,
  ) async {
    final q = "mimeType='application/vnd.google-apps.folder'"
        " and name='$name'"
        " and '$parentId' in parents"
        ' and trashed=false';
    String? pageToken;
    do {
      final result = await api.files.list(
        q: q,
        spaces: 'drive',
        $fields: 'files(id),nextPageToken',
        pageToken: pageToken,
      );
      final files = result.files;
      if (files != null && files.isNotEmpty) return files.first.id!;
      pageToken = result.nextPageToken;
    } while (pageToken != null);
    return null;
  }

  /// Returns the Drive file ID for `<trackId>.idl0t` under [parentId], or
  /// `null` when no such file exists. Used by both [downloadTrack] and the
  /// update branch of [uploadTrack].
  Future<String?> _findTrackFileId(
    drive_api.DriveApi api,
    String parentId,
    String trackId,
  ) async {
    final fileName = '$trackId.$_kTrackFileExtension';
    final q = "name='$fileName' and '$parentId' in parents and trashed=false";
    final result = await api.files.list(
      q: q,
      spaces: 'drive',
      $fields: 'files(id)',
    );
    final files = result.files;
    if (files == null || files.isEmpty) return null;
    return files.first.id;
  }

  /// Parses a Drive [drive_api.File] result into a [DriveTrackFile], or
  /// returns `null` when the filename's basename is not a UUID and therefore
  /// is not a managed Track payload.
  DriveTrackFile? _parseTrackFile(drive_api.File file) {
    final name = file.name;
    if (name == null) return null;
    if (!name.endsWith('.$_kTrackFileExtension')) return null;
    final basename =
        name.substring(0, name.length - (_kTrackFileExtension.length + 1));
    if (!_kUuidRegex.hasMatch(basename)) return null;
    final modifiedMs =
        file.modifiedTime?.toUtc().millisecondsSinceEpoch ?? 0;
    return DriveTrackFile(trackId: basename, modifiedTimeMs: modifiedMs);
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  /// Builds a [drive_api.DriveApi] with freshly fetched auth headers.
  Future<drive_api.DriveApi> _buildLiveApi() async {
    final account = _account;
    if (account == null) {
      throw const DriveAuthException('Not signed in to Google Drive.');
    }
    final headers = await account.authHeaders;
    return drive_api.DriveApi(_AuthenticatedClient(http.Client(), headers));
  }

  /// Returns the Drive folder ID for [name] under [parentId], creating it if
  /// absent. Uses the query pattern from the Kotlin reference:
  /// `mimeType='...' and name='X' and 'parentId' in parents and trashed=false`.
  Future<String> _getOrCreateFolder(
    drive_api.DriveApi api,
    String name,
    String parentId,
  ) async {
    final q = "mimeType='application/vnd.google-apps.folder'"
        " and name='$name'"
        " and '$parentId' in parents"
        ' and trashed=false';

    String? pageToken;
    do {
      final result = await api.files.list(
        q: q,
        spaces: 'drive',
        $fields: 'files(id),nextPageToken',
        pageToken: pageToken,
      );
      final files = result.files;
      if (files != null && files.isNotEmpty) {
        return files.first.id!;
      }
      pageToken = result.nextPageToken;
    } while (pageToken != null);

    // Folder not found — create it.
    final metadata = drive_api.File()
      ..name = name
      ..mimeType = 'application/vnd.google-apps.folder'
      ..parents = [parentId];

    final created = await api.files.create(metadata, $fields: 'id');
    final id = created.id;
    if (id == null) {
      throw DriveUploadException('Drive folder creation returned no ID: $name');
    }
    return id;
  }

  /// Deletes all Drive files whose name begins with `<sessionId>.` —
  /// covering `.idl0`, `.idl0w`, and `.gpx` artefacts in one list pass.
  ///
  /// A 404 on an individual delete is treated as success (file already gone).
  /// If no matching files exist the call is a no-op.
  ///
  /// Throws [DriveAuthException] when not signed in.
  /// Throws [DriveUploadException] on Drive API errors other than 404.
  @override
  Future<void> deleteRemote(String sessionId) async {
    if (!isSignedIn) {
      throw const DriveAuthException('Not signed in to Google Drive.');
    }

    try {
      final api = _testApi ?? await _buildLiveApi();

      final drive_api.FileList list;
      try {
        list = await api.files.list(
          q: "name contains '$sessionId.' and trashed = false",
          spaces: 'drive',
          $fields: 'files(id, name)',
        );
      } on drive_api.DetailedApiRequestError catch (e) {
        throw DriveUploadException(
          'Drive list failed: ${e.message ?? e.status?.toString()}',
        );
      }

      for (final f in list.files ?? const <drive_api.File>[]) {
        final id = f.id;
        if (id == null) continue;
        try {
          await api.files.delete(id);
        } on drive_api.DetailedApiRequestError catch (e) {
          // 404 means the file is already gone — treat as success.
          if (e.status == 404) continue;
          throw DriveUploadException(
            'Drive delete failed: ${e.message ?? e.status?.toString()}',
          );
        }
      }
    } on DriveAuthException {
      rethrow;
    } on DriveUploadException {
      rethrow;
    } catch (e) {
      throw DriveUploadException('Drive delete failed: $e');
    }
  }

  /// Formats the per-session Drive subfolder name as `YYYY-MM-DD_venue_rider`.
  ///
  /// Empty venue or rider fields are replaced with `'unknown'`; spaces are
  /// replaced with `'_'` so the folder name is filesystem and URL safe.
  String _buildSessionFolderName(SessionMetadata session) {
    // UTC so folder names are consistent regardless of the phone's locale.
    final date = DateFormat('yyyy-MM-dd').format(
      DateTime.fromMillisecondsSinceEpoch(session.createdTimestampMs, isUtc: true),
    );
    final venue = (session.venueName.isEmpty ? 'unknown' : session.venueName)
        .replaceAll(' ', '_');
    final rider =
        (session.rider.isEmpty ? 'unknown' : session.rider).replaceAll(' ', '_');
    return '${date}_${venue}_$rider';
  }
}
