import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idl0/data/exceptions.dart';
import 'package:idl0/transport/real_wifi_service.dart';
import 'package:idl0/transport/wifi_network_binder.dart';
import 'package:idl0/transport/wifi_transfer.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Binder stub reporting a fixed [deviceBaseUrl]; bind/release are no-ops.
class _StubUrlBinder extends WifiNetworkBinder {
  final String _url;
  _StubUrlBinder(this._url) : super(isAndroidPlatform: false);
  @override
  String get deviceBaseUrl => _url;
}

/// Spy [WifiNetworkBinder] that records call order without touching the channel.
class _SpyBinder extends WifiNetworkBinder {
  final _calls = <String>[];

  /// When true, [bind] throws [DeviceUnreachableException].
  bool bindThrows = false;

  @override
  Future<void> bind(String ssid, String password) async {
    _calls.add('bind');
    if (bindThrows) {
      throw const DeviceUnreachableException('bind rejected for test');
    }
  }

  @override
  Future<void> release() async => _calls.add('release');

  /// Ordered log of calls made so far.
  List<String> get callLog => List.unmodifiable(_calls);
}

/// Builds a [WifiTransfer] factory backed by [handler]. The factory uses
/// the [baseUrl] the service passes in (the binder's `deviceBaseUrl`), so
/// URL-propagation tests can assert against the requested host/port.
WifiTransfer Function(String baseUrl) _transferWith(
  MockClientHandler handler,
) =>
    (baseUrl) => WifiTransfer(
          baseUrl: baseUrl,
          httpClient: MockClient(handler),
        );

/// Returns a factory whose handler returns a valid empty JSON file list.
WifiTransfer Function(String baseUrl) _emptyListTransfer() =>
    _transferWith((_) async => http.Response('[]', 200));

/// Returns a factory whose handler returns a single-file JSON file list.
WifiTransfer Function(String baseUrl) _oneFileTransfer() => _transferWith(
      (_) async => http.Response(
        jsonEncode([
          {'name': 'session_001.idl0', 'size': 1048576, 'session_id': 'aa01'},
        ]),
        200,
      ),
    );

/// Returns a factory whose handler throws [SocketException] on the first
/// [failuresBeforeSuccess] HTTP calls, then returns the supplied
/// successful response on every call after.
///
/// Used to simulate the post-bind warmup race: the first GET /files after
/// `bindProcessToNetwork` fails (DHCP / ARP / device-side HTTP server
/// hasn't settled) but a retry a few hundred ms later succeeds.
WifiTransfer Function(String baseUrl) _flakyThenSuccessTransfer({
  required int failuresBeforeSuccess,
  required http.Response onSuccess,
}) {
  var calls = 0;
  return _transferWith((_) async {
    calls++;
    if (calls <= failuresBeforeSuccess) {
      throw const SocketException('first-call race');
    }
    return onSuccess;
  });
}

/// Returns a factory whose handler returns a small binary payload with
/// [contentLength] set — allows [downloadFileTo] progress to be computed.
WifiTransfer Function(String baseUrl) _downloadTransfer() => _transferWith(
      (_) async => http.Response.bytes(
        List.generate(256, (i) => i & 0xFF),
        200,
      ),
    );

/// Builds a transfer whose `/download` streams bytes in two chunks with NO
/// Content-Length — mirroring the firmware, which deliberately omits it under
/// chunked transfer encoding (wifi_server.c §6.1). Used to prove progress is
/// derived from the known file size, not the (absent) HTTP total.
WifiTransfer Function(String baseUrl) _chunkedDownloadTransfer() =>
    (baseUrl) => WifiTransfer(
      baseUrl: baseUrl,
      httpClient: MockClient.streaming((request, bodyStream) async {
        final bytes = List<int>.generate(256, (i) => i & 0xFF);
        final stream = Stream<List<int>>.fromIterable([
          bytes.sublist(0, 128),
          bytes.sublist(128),
        ]);
        return http.StreamedResponse(stream, 200, contentLength: null);
      }),
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('RealWifiService.bind / release —', () {
    test('bind delegates to WifiNetworkBinder.bind', () async {
      // Arrange
      final binder = _SpyBinder();
      final service = RealWifiService(
        deviceName: 'IDL0-A3F2',
        binder: binder,
        transferFactory: _emptyListTransfer(),
      );

      // Act
      await service.bind();

      // Assert
      expect(binder.callLog, equals(['bind']));
    });

    test('release delegates to WifiNetworkBinder.release', () async {
      // Arrange
      final binder = _SpyBinder();
      final service = RealWifiService(
        deviceName: 'IDL0-A3F2',
        binder: binder,
        transferFactory: _emptyListTransfer(),
      );

      // Act
      await service.bind();
      await service.release();

      // Assert — bind then release, in order
      expect(binder.callLog, equals(['bind', 'release']));
    });

    test('bind throws TransportException — propagates DeviceUnreachableException',
        () async {
      // Arrange
      final binder = _SpyBinder()..bindThrows = true;
      final service = RealWifiService(
        deviceName: 'IDL0-A3F2',
        binder: binder,
        transferFactory: _emptyListTransfer(),
      );

      // Act / Assert
      await expectLater(
        service.bind(),
        throwsA(isA<DeviceUnreachableException>()),
      );
    });
  });

  group('RealWifiService base URL —', () {
    test('getFileList — binder reports proxy URL — transfer hits the proxy',
        () async {
      // Arrange — a binder stub reporting a loopback-proxy base URL, and a
      // mock HTTP client recording the requested URI.
      final requested = <Uri>[];
      final client = MockClient((request) async {
        requested.add(request.url);
        return http.Response('[]', 200);
      });
      final service = RealWifiService(
        deviceName: 'IDL0-A3F2',
        binder: _StubUrlBinder('http://127.0.0.1:5151'),
        transferFactory: (baseUrl) =>
            WifiTransfer(baseUrl: baseUrl, httpClient: client),
        firstRetryDelay: Duration.zero,
      );

      // Act
      final files = await service.getFileList();

      // Assert — the request went to the proxy, not the direct device IP.
      expect(files, isEmpty);
      expect(requested.single.host, equals('127.0.0.1'));
      expect(requested.single.port, equals(5151));
    });

    test('getFileList — default binder (unlinked) — hits 192.168.4.1',
        () async {
      // Arrange
      final requested = <Uri>[];
      final client = MockClient((request) async {
        requested.add(request.url);
        return http.Response('[]', 200);
      });
      final service = RealWifiService(
        deviceName: 'IDL0-A3F2',
        binder: _SpyBinder(),
        transferFactory: (baseUrl) =>
            WifiTransfer(baseUrl: baseUrl, httpClient: client),
        firstRetryDelay: Duration.zero,
      );

      // Act
      await service.getFileList();

      // Assert
      expect(requested.single.host, equals('192.168.4.1'));
    });
  });

  group('RealWifiService.getFileList —', () {
    test('success — does NOT touch the binder (panel owns lifecycle)',
        () async {
      // Arrange — caller is expected to have bound the WiFi network already.
      final binder = _SpyBinder();
      final service = RealWifiService(
        deviceName: 'IDL0-A3F2',
        binder: binder,
        transferFactory: _oneFileTransfer(),
      );

      // Act
      final files = await service.getFileList();

      // Assert — no per-op bind/release; panel-scoped lifecycle.
      expect(binder.callLog, isEmpty);
      expect(files.length, equals(1));
      expect(files.first.name, equals('session_001.idl0'));
      expect(files.first.sessionId, equals('aa01'));
    });

    test(
        'listFiles fails on every attempt — propagates after the retry, '
        'binder untouched',
        () async {
      // Arrange — a perpetually-unreachable device. The service retries
      // once internally to absorb the post-bind warmup race; both
      // attempts here fail, so the exception eventually propagates.
      final binder = _SpyBinder();
      var calls = 0;
      final service = RealWifiService(
        deviceName: 'IDL0-A3F2',
        binder: binder,
        transferFactory: _transferWith((_) async {
          calls++;
          throw const SocketException('refused');
        }),
        firstRetryDelay: Duration.zero, // keep tests fast
      );

      // Act / Assert
      await expectLater(
        service.getFileList,
        throwsA(isA<DeviceUnreachableException>()),
      );
      expect(binder.callLog, isEmpty);
      expect(
        calls,
        equals(2),
        reason: 'getFileList must retry once on TransportException',
      );
    });

    test(
        'first /files request fails, retry succeeds — returns the list '
        '(absorbs the post-bind warmup race)',
        () async {
      // Arrange — the Android `bindProcessToNetwork` race we observed
      // on hardware: bind() returns success but the very first HTTP
      // GET to 192.168.4.1 throws (DHCP / ARP / device-side httpd
      // hasn't fully settled). A retry a moment later succeeds. We
      // verify the service absorbs this transparently.
      final binder = _SpyBinder();
      final service = RealWifiService(
        deviceName: 'IDL0-A3F2',
        binder: binder,
        transferFactory: _flakyThenSuccessTransfer(
          failuresBeforeSuccess: 1,
          onSuccess: http.Response(
            jsonEncode([
              {'name': 'session_001.idl0', 'size': 1048576},
            ]),
            200,
          ),
        ),
        firstRetryDelay: Duration.zero,
      );

      // Act
      final files = await service.getFileList();

      // Assert — retry absorbed the first failure; caller sees a clean list.
      expect(files.length, equals(1));
      expect(files.first.name, equals('session_001.idl0'));
      expect(binder.callLog, isEmpty);
    });
  });

  group('RealWifiService.downloadFile —', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('idl0_real_wifi_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('success — does NOT touch the binder (panel owns lifecycle)',
        () async {
      // Arrange
      final binder = _SpyBinder();
      final service = RealWifiService(
        deviceName: 'IDL0-A3F2',
        binder: binder,
        transferFactory: _downloadTransfer(),
        sessionsDirOverride: () async => tempDir,
      );

      // Act
      final progress =
          await service.downloadFile('session_001.idl0', 256).toList();

      // Assert — binder must stay untouched; only the bytes flow.
      expect(binder.callLog, isEmpty);
      expect(progress.last, closeTo(1.0, 0.001));
      expect(File('${tempDir.path}/session_001.idl0').existsSync(), isTrue);
    });

    test('progress — derives fraction from known size when the device omits '
        'Content-Length (chunked)', () async {
      // Arrange — firmware streams chunked with no Content-Length, so the
      // HTTP total is unknown; the 256-byte size is the authoritative total.
      final service = RealWifiService(
        deviceName: 'IDL0-A3F2',
        binder: _SpyBinder(),
        transferFactory: _chunkedDownloadTransfer(),
        sessionsDirOverride: () async => tempDir,
      );

      // Act
      final progress =
          await service.downloadFile('session_001.idl0', 256).toList();

      // Assert — a mid-download fraction (128/256 = 0.5) is emitted, not just
      // the terminal 1.0.
      expect(
        progress.any((p) => (p - 0.5).abs() < 0.01),
        isTrue,
        reason: 'expected mid-download progress, got $progress',
      );
      expect(progress.last, closeTo(1.0, 0.001));
    });
  });
}
