import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

/// Spy [WifiNetworkBinder] that also reports a fixed [deviceBaseUrl].
///
/// The [pushFirmware] round-trip / cancel tests run against a real loopback
/// [HttpServer] (via the default transfer factory) rather than a [MockClient],
/// so they need a binder that both points at that server (via [deviceBaseUrl])
/// and records whether bind/release were ever touched.
class _SpyUrlBinder extends WifiNetworkBinder {
  _SpyUrlBinder(this._url) : super(isAndroidPlatform: false);

  final String _url;
  final _calls = <String>[];

  @override
  String get deviceBaseUrl => _url;

  @override
  Future<void> bind(String ssid, String password) async => _calls.add('bind');

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

  group('RealWifiService.pushFirmware —', () {
    // The round-trip / cancel tests exercise real socket behaviour (an
    // in-flight request being aborted by a client close), so they stand up a
    // real loopback HttpServer as the device stand-in. The warmup-retry tests
    // below instead inject a MockClient-backed transfer factory.
    late HttpServer server;

    tearDown(() async {
      await server.close(force: true);
    });

    test('success — does NOT touch the binder (panel owns the bind lifecycle)',
        () async {
      // Arrange — a loopback server that accepts the /ota upload and
      // acknowledges it, mirroring the device's 200 "ok\n" response.
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = 200;
        request.response.write('ok\n');
        await request.response.close();
      });
      final binder = _SpyUrlBinder('http://127.0.0.1:${server.port}');
      final service = RealWifiService(deviceName: 'IDL0-A3F2', binder: binder);

      // Act
      final handle = service.pushFirmware(Uint8List.fromList([1, 2, 3, 4]));
      await handle.done;

      // Assert — no bind/release; the caller (panel) already owns the bind
      // for the duration of the OTA push.
      expect(binder.callLog, isEmpty);
    });

    test('cancel — closes the dedicated client without touching the binder',
        () async {
      // Arrange — a loopback server that receives the /ota upload in full
      // but never responds, holding the push in the awaiting-response phase
      // (the realistic window in which a user taps Cancel: the request is
      // established and in flight). cancel() must force the dedicated
      // client shut; nothing else can settle handle.done here.
      final uploadReceived = Completer<void>();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        uploadReceived.complete();
        // Deliberately never respond — only cancel() can settle the push.
      });
      final binder = _SpyUrlBinder('http://127.0.0.1:${server.port}');
      final service = RealWifiService(deviceName: 'IDL0-A3F2', binder: binder);

      // Act — start the push, wait until the device stand-in has the bytes
      // (push in flight, awaiting the device's response), then cancel.
      final handle =
          service.pushFirmware(Uint8List.fromList(List.filled(2048, 7)));
      await uploadReceived.future;
      await handle.cancel();

      // Assert — closing the current attempt's client aborts the in-flight
      // request: done completes with the doc-promised
      // DeviceUnreachableException instead of hanging, and the binder is
      // never touched.
      await expectLater(
        handle.done,
        throwsA(isA<DeviceUnreachableException>()),
      );
      expect(binder.callLog, isEmpty);
    });

    test('warmup race — first attempt fails, a retry succeeds', () async {
      // Arrange — the OTA push is the first request after the bind, so it eats
      // the post-bind warmup race (proxy device-connect not ready). The first
      // attempt throws; the retry lands on the warm link.
      final service = RealWifiService(
        deviceName: 'IDL0-A3F2',
        binder: _StubUrlBinder('http://192.168.4.1'),
        transferFactory: _flakyThenSuccessTransfer(
          failuresBeforeSuccess: 1,
          onSuccess: http.Response('ok\n', 200),
        ),
        firstRetryDelay: Duration.zero,
      );

      // Act
      final handle = service.pushFirmware(Uint8List.fromList([1, 2, 3, 4]));

      // Assert — the retry absorbs the race; done completes without error.
      await expectLater(handle.done, completes);
    });

    test('device rejects the image (400) — no retry, FirmwarePushException',
        () async {
      // Arrange — a 400 means esp_ota_end rejected the image (SHA mismatch);
      // retrying an already-transferred bad image cannot help.
      var calls = 0;
      final service = RealWifiService(
        deviceName: 'IDL0-A3F2',
        binder: _StubUrlBinder('http://192.168.4.1'),
        transferFactory: _transferWith((_) async {
          calls++;
          return http.Response('image validation failed', 400);
        }),
        firstRetryDelay: Duration.zero,
      );

      // Act / Assert — propagates immediately, uploaded exactly once.
      await expectLater(
        service.pushFirmware(Uint8List.fromList([1, 2, 3, 4])).done,
        throwsA(isA<FirmwarePushException>()),
      );
      expect(calls, 1);
    });

    test('device unreachable on every attempt — fails after exhausting retries',
        () async {
      // Arrange — the AP never becomes reachable; every attempt throws.
      var calls = 0;
      final service = RealWifiService(
        deviceName: 'IDL0-A3F2',
        binder: _StubUrlBinder('http://192.168.4.1'),
        transferFactory: _transferWith((_) async {
          calls++;
          throw const SocketException('AP down');
        }),
        firstRetryDelay: Duration.zero,
      );

      // Act / Assert — surfaces DeviceUnreachableException after retrying.
      await expectLater(
        service.pushFirmware(Uint8List.fromList([1, 2, 3, 4])).done,
        throwsA(isA<DeviceUnreachableException>()),
      );
      expect(calls, greaterThan(1));
    });
  });
}
