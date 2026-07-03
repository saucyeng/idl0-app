import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive_api;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idl0/data/exceptions.dart';
import 'package:idl0/data/workbook.dart';
import 'package:idl0/transport/drive_service.dart';
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

/// Builds a [drive_api.DriveApi] whose HTTP layer is intercepted by [handler].
drive_api.DriveApi _apiWith(MockClientHandler handler) =>
    drive_api.DriveApi(MockClient(handler));

/// Standard JSON response headers required by the googleapis decoder.
const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

/// UUIDv4 used across all workbook tests.
const _kWorkbookId = '550e8400-e29b-41d4-a716-446655440000';

/// Builds a minimal [Workbook] fixture with a known ID and timestamps.
Workbook _workbookFixture() => const Workbook(
      workbookId: _kWorkbookId,
      name: 'Test Workbook',
      worksheets: [],
      mathChannels: [],
      createdAtMs: 1744675200000,
      updatedAtMs: 1744675200000,
      workbookVersion: 1,
    );

/// Returns a handler that:
/// 1. Responds to Drive folder lookups (GET with mimeType filter) by returning
///    [folderId] the first time the IDL0 root is queried and [workbooksFolderId]
///    when the `workbooks` subfolder is queried.
/// 2. Delegates all other requests to [otherwise].
MockClientHandler _folderHandler({
  required String rootFolderId,
  required String workbooksFolderId,
  required MockClientHandler otherwise,
}) =>
    (request) async {
      if (request.method == 'GET') {
        final q = request.url.queryParameters['q'] ?? '';
        if (q.contains("name='IDL0'")) {
          return http.Response(
            jsonEncode({
              'files': [
                {'id': rootFolderId},
              ],
            }),
            200,
            headers: _jsonHeaders,
          );
        }
        if (q.contains("name='workbooks'")) {
          return http.Response(
            jsonEncode({
              'files': [
                {'id': workbooksFolderId},
              ],
            }),
            200,
            headers: _jsonHeaders,
          );
        }
      }
      return otherwise(request);
    };

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('GoogleDriveService — workbook operations —', () {
    // -----------------------------------------------------------------------
    // Auth guard — all four methods
    // -----------------------------------------------------------------------

    group('all four methods — throw DriveAuthException when not signed in —',
        () {
      late GoogleDriveService service;

      setUp(() {
        service = GoogleDriveService.forTest(
          googleSignIn: _FakeGoogleSignIn(),
          signedIn: false,
        );
      });

      test('listWorkbooks', () async {
        // Arrange — already done in setUp (signedIn: false).

        // Act / Assert
        await expectLater(
          service.listWorkbooks(),
          throwsA(isA<DriveAuthException>()),
        );
      });

      test('downloadWorkbook', () async {
        // Arrange — already done in setUp (signedIn: false).

        // Act / Assert
        await expectLater(
          service.downloadWorkbook(_kWorkbookId),
          throwsA(isA<DriveAuthException>()),
        );
      });

      test('uploadWorkbook', () async {
        // Arrange — already done in setUp (signedIn: false).

        // Act / Assert
        await expectLater(
          service.uploadWorkbook(_workbookFixture()),
          throwsA(isA<DriveAuthException>()),
        );
      });

      test('deleteWorkbook', () async {
        // Arrange — already done in setUp (signedIn: false).

        // Act / Assert
        await expectLater(
          service.deleteWorkbook(_kWorkbookId),
          throwsA(isA<DriveAuthException>()),
        );
      });
    });

    // -----------------------------------------------------------------------
    // listWorkbooks
    // -----------------------------------------------------------------------

    group('listWorkbooks —', () {
      test('returns empty list when workbooks folder is absent', () async {
        // Arrange — all folder lookups return empty; folder never exists.
        final api = _apiWith(
          (_) async =>
              http.Response('{"files":[]}', 200, headers: _jsonHeaders),
        );
        final service = GoogleDriveService.forTest(
          googleSignIn: _FakeGoogleSignIn(),
          driveApi: api,
        );

        // Act
        final result = await service.listWorkbooks();

        // Assert
        expect(result, isEmpty);
      });

      test('filters non-UUID basenames; returns only valid UUID entries',
          () async {
        // Arrange — folder exists; the file list contains one UUID file and
        // one junk file.
        const workbooksFolderId = 'wb-folder-id';
        var fileListServed = false;

        final api = _apiWith(_folderHandler(
          rootFolderId: 'root-id',
          workbooksFolderId: workbooksFolderId,
          otherwise: (request) async {
            if (request.method == 'GET' && !fileListServed) {
              fileListServed = true;
              // The files.list for workbooks folder contents.
              return http.Response(
                jsonEncode({
                  'files': [
                    {
                      'id': 'file-junk',
                      'name': 'junk.idl0wb',
                      'modifiedTime': '2025-04-15T00:00:00.000Z',
                    },
                    {
                      'id': 'file-valid',
                      'name': '$_kWorkbookId.idl0wb',
                      'modifiedTime': '2025-04-15T00:00:00.000Z',
                    },
                  ],
                }),
                200,
                headers: _jsonHeaders,
              );
            }
            return http.Response('{"files":[]}', 200, headers: _jsonHeaders);
          },
        ),);

        final service = GoogleDriveService.forTest(
          googleSignIn: _FakeGoogleSignIn(),
          driveApi: api,
        );

        // Act
        final result = await service.listWorkbooks();

        // Assert — only the UUID-named file makes it through.
        expect(result, hasLength(1));
        expect(result.single.workbookId, equals(_kWorkbookId));
        expect(result.single, isA<DriveWorkbookFile>());
      });
    });

    // -----------------------------------------------------------------------
    // downloadWorkbook
    // -----------------------------------------------------------------------

    group('downloadWorkbook —', () {
      test('parses JSON body into a Workbook round-trip', () async {
        // Arrange — folder exists; file content is the fixture serialised.
        const workbooksFolderId = 'wb-folder-id';
        const fileId = 'wb-file-id';
        final workbook = _workbookFixture();
        final workbookJson = jsonEncode(workbook.toJson());

        var fileContentServed = false;

        final api = _apiWith(_folderHandler(
          rootFolderId: 'root-id',
          workbooksFolderId: workbooksFolderId,
          otherwise: (request) async {
            if (request.method == 'GET') {
              final q = request.url.queryParameters['q'] ?? '';
              if (q.contains(_kWorkbookId)) {
                // _findWorkbookFileId query — return the file ID.
                return http.Response(
                  jsonEncode({
                    'files': [
                      {'id': fileId},
                    ],
                  }),
                  200,
                  headers: _jsonHeaders,
                );
              }
              if (!fileContentServed &&
                  request.url.path.contains(fileId)) {
                // files.get with alt=media — return raw JSON bytes.
                fileContentServed = true;
                return http.Response(
                  workbookJson,
                  200,
                  headers: _jsonHeaders,
                );
              }
            }
            return http.Response('{"files":[]}', 200, headers: _jsonHeaders);
          },
        ),);

        final service = GoogleDriveService.forTest(
          googleSignIn: _FakeGoogleSignIn(),
          driveApi: api,
        );

        // Act
        final result = await service.downloadWorkbook(_kWorkbookId);

        // Assert — all scalar fields survive the round-trip.
        expect(result.workbookId, equals(workbook.workbookId));
        expect(result.name, equals(workbook.name));
        expect(result.createdAtMs, equals(workbook.createdAtMs));
        expect(result.updatedAtMs, equals(workbook.updatedAtMs));
        expect(result.workbookVersion, equals(workbook.workbookVersion));
      });
    });

    // -----------------------------------------------------------------------
    // uploadWorkbook
    // -----------------------------------------------------------------------

    group('uploadWorkbook —', () {
      test('creates new file when no existing match', () async {
        // Arrange — folder exists; no existing workbook file found; POST
        // creates successfully.
        const workbooksFolderId = 'wb-folder-id';
        var createCalled = false;

        final api = _apiWith(_folderHandler(
          rootFolderId: 'root-id',
          workbooksFolderId: workbooksFolderId,
          otherwise: (request) async {
            if (request.method == 'GET') {
              // _findWorkbookFileId — return empty (no existing file).
              return http.Response(
                '{"files":[]}',
                200,
                headers: _jsonHeaders,
              );
            }
            if (request.method == 'POST') {
              createCalled = true;
              // Capture body to verify workbook JSON was posted.
              return http.Response(
                '{"id":"new-file-id"}',
                200,
                headers: _jsonHeaders,
              );
            }
            return http.Response('{"files":[]}', 200, headers: _jsonHeaders);
          },
        ),);

        final service = GoogleDriveService.forTest(
          googleSignIn: _FakeGoogleSignIn(),
          driveApi: api,
        );
        final workbook = _workbookFixture();

        // Act
        await service.uploadWorkbook(workbook);

        // Assert — the Drive create call was made.
        expect(createCalled, isTrue);
      });
    });

    // -----------------------------------------------------------------------
    // deleteWorkbook
    // -----------------------------------------------------------------------

    group('deleteWorkbook —', () {
      test('404 from the delete call is treated as success (no rethrow)',
          () async {
        // Arrange — folder + file exist; DELETE returns 404.
        const workbooksFolderId = 'wb-folder-id';
        const fileId = 'wb-file-id';

        final api = _apiWith(_folderHandler(
          rootFolderId: 'root-id',
          workbooksFolderId: workbooksFolderId,
          otherwise: (request) async {
            if (request.method == 'GET') {
              final q = request.url.queryParameters['q'] ?? '';
              if (q.contains(_kWorkbookId)) {
                return http.Response(
                  jsonEncode({
                    'files': [
                      {'id': fileId},
                    ],
                  }),
                  200,
                  headers: _jsonHeaders,
                );
              }
              return http.Response('{"files":[]}', 200, headers: _jsonHeaders);
            }
            if (request.method == 'DELETE') {
              // Simulate file already gone on Drive.
              return http.Response(
                jsonEncode({
                  'error': {'code': 404, 'message': 'File not found.'},
                }),
                404,
                headers: _jsonHeaders,
              );
            }
            return http.Response('{"files":[]}', 200, headers: _jsonHeaders);
          },
        ),);

        final service = GoogleDriveService.forTest(
          googleSignIn: _FakeGoogleSignIn(),
          driveApi: api,
        );

        // Act / Assert — must complete without throwing.
        await expectLater(
          service.deleteWorkbook(_kWorkbookId),
          completes,
        );
      });
    });
  });
}
