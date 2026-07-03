import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive_api;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idl0/data/exceptions.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/transport/google_drive_service.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// [GoogleSignIn] subclass whose [signOut] is a no-op so tests don't hit
/// the platform plugin.
class _FakeGoogleSignIn extends GoogleSignIn {
  _FakeGoogleSignIn() : super(scopes: []);

  @override
  Future<GoogleSignInAccount?> signOut() async => null;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Session metadata fixture with a known timestamp, venue, and rider.
SessionMetadata _session({
  String sessionId = 'test-uuid',
  String rider = 'Alice',
  String venueName = 'Whistler',
  // 2025-04-15 00:00 UTC → folder prefix 2025-04-15
  int createdTimestampMs = 1744675200000,
  String? filePath,
  String? workspacePath,
}) =>
    SessionMetadata(
      sessionId: sessionId,
      filePath: filePath ?? '/fake/$sessionId.idl0',
      workspacePath: workspacePath ?? '/fake/$sessionId.idl0w',
      createdTimestampMs: createdTimestampMs,
      fileSizeBytes: 0,
      rider: rider,
      bike: '',
      bikeComment: '',
      venueName: venueName,
      eventName: '',
      eventSession: '',
      shortComment: '',
      longComment: '',
      deviceId: 'A3F1',
    );

/// Builds a [drive_api.DriveApi] whose HTTP layer is intercepted by [handler].
drive_api.DriveApi _apiWith(MockClientHandler handler) =>
    drive_api.DriveApi(MockClient(handler));

/// Standard JSON response headers required by the googleapis decoder.
const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('idl0_drive_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('GoogleDriveService.uploadSessionFile —', () {
    test('correct Drive folder path constructed from session metadata',
        () async {
      // Arrange — capture folder names queried from the GET requests.
      final queriedNames = <String>[];
      var createCount = 0;

      final api = _apiWith((request) async {
        if (request.method == 'GET') {
          final q = request.url.queryParameters['q'] ?? '';
          final match = RegExp(r"name='([^']+)'").firstMatch(q);
          if (match != null) queriedNames.add(match.group(1)!);
          // Return empty file list — trigger folder creation every time.
          return http.Response('{"files":[]}', 200, headers: _jsonHeaders);
        }
        // POST — folder creation or file upload: return a unique id.
        createCount++;
        return http.Response(
          '{"id":"id_$createCount"}',
          200,
          headers: _jsonHeaders,
        );
      });

      // Write a real source file so the service can open it.
      final idl0File = File('${tempDir.path}/test-uuid.idl0')
        ..writeAsBytesSync([0x49, 0x44, 0x4C, 0x30]); // IDL0 magic

      final session = _session(filePath: idl0File.path);
      final service = GoogleDriveService.forTest(
        googleSignIn: _FakeGoogleSignIn(),
        driveApi: api,
      );

      // Act
      await service.uploadSessionFile(session, 'idl0');

      // Assert — IDL0/, sessions/, and session subfolder were all queried.
      expect(queriedNames, containsAll(['IDL0', 'sessions']));
      expect(
        queriedNames,
        contains('2025-04-15_Whistler_Alice'),
        reason: 'session folder name must be YYYY-MM-DD_venue_rider',
      );
    });

    test('throws DriveUploadException on DriveApi error', () async {
      // Arrange — folders succeed; file upload returns 500.
      var createCount = 0;

      final api = _apiWith((request) async {
        if (request.method == 'GET') {
          return http.Response('{"files":[]}', 200, headers: _jsonHeaders);
        }
        createCount++;
        if (request.url.path.contains('/upload/')) {
          // File upload — simulate a Drive API error.
          return http.Response(
            jsonEncode({
              'error': {'code': 500, 'message': 'internal error'},
            }),
            500,
            headers: _jsonHeaders,
          );
        }
        // Folder creation succeeds.
        return http.Response(
          '{"id":"folder_$createCount"}',
          200,
          headers: _jsonHeaders,
        );
      });

      final idl0File = File('${tempDir.path}/test-uuid.idl0')
        ..writeAsBytesSync([1, 2, 3]);

      final session = _session(filePath: idl0File.path);
      final service = GoogleDriveService.forTest(
        googleSignIn: _FakeGoogleSignIn(),
        driveApi: api,
      );

      // Act / Assert
      await expectLater(
        service.uploadSessionFile(session, 'idl0'),
        throwsA(isA<DriveUploadException>()),
      );
    });

    test('throws DriveAuthException when called before sign-in', () async {
      // Arrange — service is not signed in (no driveApi, signedIn: false).
      final service = GoogleDriveService.forTest(
        googleSignIn: _FakeGoogleSignIn(),
        signedIn: false,
      );

      // Act / Assert
      await expectLater(
        service.uploadSessionFile(_session(), 'idl0'),
        throwsA(isA<DriveAuthException>()),
      );
    });
  });

  group('GoogleDriveService.signOut —', () {
    test('clears isSignedIn', () async {
      // Arrange — create a no-op DriveApi (not used by signOut itself).
      final api = _apiWith(
        (_) async => http.Response('{"files":[]}', 200, headers: _jsonHeaders),
      );

      final service = GoogleDriveService.forTest(
        googleSignIn: _FakeGoogleSignIn(),
        driveApi: api,
      );
      expect(service.isSignedIn, isTrue);

      // Act
      await service.signOut();

      // Assert
      expect(service.isSignedIn, isFalse);
      expect(service.accountEmail, isNull);
    });
  });
}
