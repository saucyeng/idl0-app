import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idl0/data/exceptions.dart';
import 'package:idl0/transport/wifi_transfer.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a [WifiTransfer] whose HTTP calls are handled by [handler].
///
/// [requestTimeout] is short by default so timeout-path tests don't have
/// to wait for the 8 s production default.
WifiTransfer _client(
  MockClientHandler handler, {
  Duration requestTimeout = const Duration(milliseconds: 100),
}) =>
    WifiTransfer(
      baseUrl: 'http://test-device',
      httpClient: MockClient(handler),
      requestTimeout: requestTimeout,
    );

/// Returns a [MockClientHandler] that throws [SocketException] — simulates a
/// device that is powered off or out of WiFi range.
MockClientHandler _unreachableHandler() => (_) async {
      throw const SocketException('Connection refused');
    };

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('WifiTransfer.listFiles —', () {
    test('success — parses JSON array into DeviceFile list', () async {
      // Arrange
      final transfer = _client(
        (_) async => http.Response(
              jsonEncode([
                {'name': 'session_001.idl0', 'size': 1048576, 'session_id': 'aa01'},
                {'name': 'session_002.idl0', 'size': 2097152, 'session_id': 'bb02'},
              ]),
              200,
            ),
      );

      // Act
      final files = await transfer.listFiles();

      // Assert
      expect(files.length, equals(2));
      expect(files[0].name, equals('session_001.idl0'));
      expect(files[0].sizeBytes, equals(1048576));
      expect(files[0].sessionId, equals('aa01'));
      expect(files[1].name, equals('session_002.idl0'));
      expect(files[1].sizeBytes, equals(2097152));
      expect(files[1].sessionId, equals('bb02'));
    });

    test('fromJson — missing session_id — yields empty sessionId', () {
      // Arrange
      final json = {'name': 'session_003.idl0', 'size': 4096};

      // Act
      final file = DeviceFile.fromJson(json);

      // Assert — older firmware omits session_id; tolerate it (CLAUDE.md §5)
      expect(file.name, equals('session_003.idl0'));
      expect(file.sessionId, equals(''));
    });

    test('success — empty array — returns empty list', () async {
      // Arrange
      final transfer = _client((_) async => http.Response('[]', 200));

      // Act
      final files = await transfer.listFiles();

      // Assert
      expect(files, isEmpty);
    });

    test('non-200 response — throws DeviceUnreachableException', () async {
      // Arrange
      final transfer = _client((_) async => http.Response('Server error', 500));

      // Act / Assert
      expect(
        transfer.listFiles,
        throwsA(isA<DeviceUnreachableException>()),
      );
    });

    test('invalid JSON body — throws FileListParseException', () async {
      // Arrange — device still returning HTML (TODO #10)
      final transfer = _client(
        (_) async => http.Response('<html>File list</html>', 200),
      );

      // Act / Assert
      expect(
        transfer.listFiles,
        throwsA(isA<FileListParseException>()),
      );
    });

    test('JSON object instead of array — throws FileListParseException', () async {
      // Arrange
      final transfer = _client(
        (_) async => http.Response('{"error":"not ready"}', 200),
      );

      // Act / Assert
      expect(
        transfer.listFiles,
        throwsA(isA<FileListParseException>()),
      );
    });

    test('connection failure — throws DeviceUnreachableException', () async {
      // Arrange
      final transfer = _client(_unreachableHandler());

      // Act / Assert
      expect(
        transfer.listFiles,
        throwsA(isA<DeviceUnreachableException>()),
      );
    });

    test(
        'device never responds — throws TransferTimeoutException within '
        'the configured request timeout',
        () async {
      // Arrange — a handler whose Future never completes. Without the
      // per-request timeout this would hang forever, freezing the UI on
      // the user's hardware (the symptom that prompted this fix).
      final transfer = _client(
        (_) => Completer<http.Response>().future,
        requestTimeout: const Duration(milliseconds: 50),
      );

      // Act / Assert
      await expectLater(
        transfer.listFiles,
        throwsA(isA<TransferTimeoutException>()),
      );
    });

    test('request targets /files endpoint', () async {
      // Arrange
      Uri? capturedUri;
      final transfer = _client((request) async {
        capturedUri = request.url;
        return http.Response('[]', 200);
      });

      // Act
      await transfer.listFiles();

      // Assert
      expect(capturedUri?.path, equals('/files'));
    });
  });

  group('WifiTransfer.downloadFile —', () {
    test('success — returns raw bytes', () async {
      // Arrange
      final payload = Uint8List.fromList([0x49, 0x44, 0x4C, 0x30]); // "IDL0"
      final transfer = _client(
        (_) async => http.Response.bytes(payload, 200),
      );

      // Act
      final bytes = await transfer.downloadFile('session_001.idl0');

      // Assert
      expect(bytes, equals(payload));
    });

    test('non-200 response — throws TransferTimeoutException', () async {
      // Arrange
      final transfer = _client((_) async => http.Response('Not found', 404));

      // Act / Assert
      expect(
        () => transfer.downloadFile('missing.idl0'),
        throwsA(isA<TransferTimeoutException>()),
      );
    });

    test('connection failure — throws DeviceUnreachableException', () async {
      // Arrange
      final transfer = _client(_unreachableHandler());

      // Act / Assert
      expect(
        () => transfer.downloadFile('session_001.idl0'),
        throwsA(isA<DeviceUnreachableException>()),
      );
    });

    test('request targets /download with correct file query parameter', () async {
      // Arrange
      Uri? capturedUri;
      final transfer = _client((request) async {
        capturedUri = request.url;
        return http.Response.bytes(Uint8List(0), 200);
      });

      // Act
      await transfer.downloadFile('my_session.idl0');

      // Assert
      expect(capturedUri?.path, equals('/download'));
      expect(capturedUri?.queryParameters['file'], equals('my_session.idl0'));
    });
  });

  group('WifiTransfer.downloadFileTo —', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('idl0_wifi_test_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('success — writes bytes to dest path and reports progress', () async {
      // Arrange
      final payload = Uint8List.fromList(List.generate(1024, (i) => i & 0xFF));
      final transfer = _client(
        (_) async => http.Response.bytes(payload, 200),
      );
      final destPath = '${tempDir.path}/out.idl0';
      final progressEvents = <(int, int)>[];

      // Act
      await transfer.downloadFileTo(
        'session_001.idl0',
        destPath,
        onProgress: (recv, total) => progressEvents.add((recv, total)),
      );

      // Assert — file written
      final written = File(destPath).readAsBytesSync();
      expect(written, equals(payload));

      // Assert — at least one progress event fired
      expect(progressEvents, isNotEmpty);
      expect(progressEvents.last.$1, equals(payload.length));
    });

    test('non-200 response — throws TransferTimeoutException, no file created', () async {
      // Arrange
      final transfer = _client((_) async => http.Response('Error', 503));
      final destPath = '${tempDir.path}/out.idl0';

      // Act / Assert
      await expectLater(
        () => transfer.downloadFileTo('session_001.idl0', destPath),
        throwsA(isA<TransferTimeoutException>()),
      );
      expect(File(destPath).existsSync(), isFalse);
    });

    test(
        'device never responds to GET /download — throws '
        'TransferTimeoutException within the configured timeout',
        () async {
      // Arrange — a handler whose response never arrives. Without the
      // initial-response timeout this would hang the entire download
      // stream and (on hardware) freeze the UI.
      final transfer = _client(
        (_) => Completer<http.Response>().future,
        requestTimeout: const Duration(milliseconds: 50),
      );
      final destPath = '${tempDir.path}/out.idl0';

      // Act / Assert
      await expectLater(
        () => transfer.downloadFileTo('session_001.idl0', destPath),
        throwsA(isA<TransferTimeoutException>()),
      );
    });
  });

  group('WifiTransfer.deleteFile —', () {
    test('success — completes without error', () async {
      // Arrange
      final transfer = _client((_) async => http.Response('OK', 200));

      // Act / Assert — no exception
      await expectLater(
        transfer.deleteFile('session_001.idl0'),
        completes,
      );
    });

    test('non-200 response — throws DeviceUnreachableException', () async {
      // Arrange
      final transfer = _client((_) async => http.Response('Error', 500));

      // Act / Assert
      expect(
        () => transfer.deleteFile('session_001.idl0'),
        throwsA(isA<DeviceUnreachableException>()),
      );
    });

    test('connection failure — throws DeviceUnreachableException', () async {
      // Arrange
      final transfer = _client(_unreachableHandler());

      // Act / Assert
      expect(
        () => transfer.deleteFile('session_001.idl0'),
        throwsA(isA<DeviceUnreachableException>()),
      );
    });

    test('request targets /delete with correct file query parameter', () async {
      // Arrange
      Uri? capturedUri;
      final transfer = _client((request) async {
        capturedUri = request.url;
        return http.Response('OK', 200);
      });

      // Act
      await transfer.deleteFile('my_session.idl0');

      // Assert
      expect(capturedUri?.path, equals('/delete'));
      expect(capturedUri?.queryParameters['file'], equals('my_session.idl0'));
    });
  });

  group('WifiTransfer.pushConfig —', () {
    test('success — POSTs JSON body and completes without error', () async {
      // Arrange
      http.Request? captured;
      final transfer = _client((request) async {
        captured = request;
        return http.Response('OK', 200);
      });
      const configJson = '{"config_version":1,"device_id":"AABBCCDD"}';

      // Act
      await transfer.pushConfig(configJson);

      // Assert — correct endpoint, method, content-type, body
      expect(captured?.url.path, equals('/config'));
      expect(captured?.method, equals('POST'));
      expect(captured?.headers['Content-Type'], equals('application/json'));
      expect(captured?.body, equals(configJson));
    });

    test('non-200 response — throws DeviceUnreachableException', () async {
      // Arrange
      final transfer = _client((_) async => http.Response('Error', 500));

      // Act / Assert
      expect(
        () => transfer.pushConfig('{}'),
        throwsA(isA<DeviceUnreachableException>()),
      );
    });

    test('connection failure — throws DeviceUnreachableException', () async {
      // Arrange
      final transfer = _client(_unreachableHandler());

      // Act / Assert
      expect(
        () => transfer.pushConfig('{}'),
        throwsA(isA<DeviceUnreachableException>()),
      );
    });
  });

  group('WifiTransfer.pushFirmware —', () {
    /// 32 KiB of deterministic bytes — large enough to exercise streaming
    /// progress callbacks across more than one chunk if the transport
    /// chunks at all, but small enough not to slow the test.
    Uint8List makeBin([int sizeBytes = 32 * 1024]) =>
        Uint8List.fromList(List.generate(sizeBytes, (i) => i & 0xFF));

    test('success — POSTs raw bytes to /ota with octet-stream content type',
        () async {
      // Arrange
      http.Request? captured;
      final transfer = _client((request) async {
        captured = request;
        return http.Response('ok\n', 200);
      });
      final bin = makeBin(1024);

      // Act
      await transfer.pushFirmware(bin);

      // Assert
      expect(captured?.url.path, equals('/ota'));
      expect(captured?.method, equals('POST'));
      expect(
        captured?.headers['Content-Type'],
        equals('application/octet-stream'),
      );
      expect(captured?.bodyBytes, equals(bin));
      expect(captured?.contentLength, equals(bin.length));
    });

    test(
        'progress callback — invoked with monotonic sent values ending at total',
        () async {
      // Arrange
      final transfer = _client((_) async => http.Response('ok\n', 200));
      final bin = makeBin(8192);
      final progress = <(int, int)>[];

      // Act
      await transfer.pushFirmware(
        bin,
        onProgress: (sent, total) => progress.add((sent, total)),
      );

      // Assert — at least one callback; final callback must hit (total,total)
      expect(progress, isNotEmpty);
      expect(progress.last, equals((bin.length, bin.length)));
      // Monotonic non-decreasing
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i].$1, greaterThanOrEqualTo(progress[i - 1].$1));
        expect(progress[i].$2, equals(bin.length));
      }
    });

    test(
        'HTTP 400 — throws FirmwarePushException with statusCode 400 '
        '(image validation failed)', () async {
      // Arrange — mirrors the device-side response for a bad SHA-256 check
      final transfer = _client(
        (_) async => http.Response('image validation failed', 400),
      );

      // Act / Assert
      try {
        await transfer.pushFirmware(makeBin(64));
        fail('expected FirmwarePushException');
      } on FirmwarePushException catch (e) {
        expect(e.statusCode, equals(400));
      }
    });

    test('HTTP 500 — throws FirmwarePushException with statusCode 500',
        () async {
      // Arrange
      final transfer = _client(
        (_) async => http.Response('flash write error', 500),
      );

      // Act / Assert
      try {
        await transfer.pushFirmware(makeBin(64));
        fail('expected FirmwarePushException');
      } on FirmwarePushException catch (e) {
        expect(e.statusCode, equals(500));
      }
    });

    test(
        'mid-stream socket close — throws DeviceUnreachableException '
        '(network failure, not a device-emitted rejection)', () async {
      // Arrange
      final transfer = _client(_unreachableHandler());

      // Act / Assert
      expect(
        () => transfer.pushFirmware(makeBin(64)),
        throwsA(isA<DeviceUnreachableException>()),
      );
    });
  });
}
