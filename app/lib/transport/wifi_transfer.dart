import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../data/exceptions.dart';

/// Metadata for one file reported by the device's `GET /files` endpoint.
///
/// The device returns a JSON array of these objects. See §6.1.
class DeviceFile {
  /// File name as stored on the SD card, e.g. `session_001.idl0`.
  final String name;

  /// File size in bytes.
  final int sizeBytes;

  /// Session UUID from the file header, as 32-hex lowercase (no dashes),
  /// matching the `idl-rs` engine's rendering. Empty when the device firmware
  /// predates the `session_id` field (TODO #10) — callers treat empty as
  /// "identity unknown" rather than crashing (CLAUDE.md §5).
  final String sessionId;

  /// Creates a [DeviceFile].
  const DeviceFile({
    required this.name,
    required this.sizeBytes,
    this.sessionId = '',
  });

  /// Deserializes from the JSON object in the `/files` response array.
  ///
  /// Expected shape:
  /// `{"name": "session_001.idl0", "size": 1048576, "session_id": "ab12..."}`.
  /// `session_id` is optional for backward compatibility.
  factory DeviceFile.fromJson(Map<String, dynamic> json) => DeviceFile(
        name: json['name'] as String,
        sizeBytes: json['size'] as int,
        sessionId: json['session_id'] as String? ?? '',
      );
}

/// HTTP client for the IDL0 device WiFi access point. See §6.
///
/// The device runs as a WiFi AP at [defaultDeviceIp]. All communication is
/// plain HTTP/1.1 — there is no TLS on the local point-to-point link.
///
/// ## Android network binding
/// On Android 10+, the OS routes all HTTP traffic to the default (cellular)
/// network, even when the phone is connected to the device AP. Requests to
/// `192.168.4.1` silently fail or go nowhere.
///
/// This is resolved by [WifiNetworkBinder] (platform channel `idl0/wifi_network`),
/// which binds the process to the device AP network before any HTTP operations.
/// [RealWifiService] wraps this class and handles the bind/release lifecycle
/// automatically. Use [RealWifiService] in production, not this class directly.
/// TODO #11 is complete — see `app/lib/transport/real_wifi_service.dart`.
///
/// Inject [httpClient] in tests to avoid real network calls.
class WifiTransfer {
  /// Default device IP address when acting as a WiFi AP.
  static const String defaultDeviceIp = '192.168.4.1';

  /// Default per-request timeout. Local AP responses should be sub-second;
  /// 8 s is a deliberately loose cap so an over-loaded device still gets
  /// a chance to respond, while hangs surface as
  /// [TransferTimeoutException] rather than freezing the UI forever.
  static const Duration _defaultRequestTimeout = Duration(seconds: 8);

  /// Backstop for the OTA response wait. The device only answers `POST /ota`
  /// after receiving the whole image and validating its SHA-256, so this is
  /// deliberately loose — a healthy ~1.5 MB upload over the local AP finishes
  /// in a few seconds. It exists only so a device that accepts the connection
  /// then never responds (or a dead proxy link) surfaces as a
  /// [DeviceUnreachableException] the caller can retry, instead of an
  /// infinite `await`. Every other method here already caps its request; this
  /// closes the one gap.
  static const Duration _otaResponseTimeout = Duration(seconds: 45);

  final String _baseUrl;
  final http.Client _client;
  final Duration _requestTimeout;

  /// Creates a [WifiTransfer].
  ///
  /// [baseUrl] overrides the default `http://192.168.4.1` — useful in tests
  /// or for future per-device addressing (TODO #13).
  /// [httpClient] is injected in tests; production uses the default client.
  /// [requestTimeout] caps any single HTTP request (and any stalled chunk
  /// gap on a streamed download); defaults to [_defaultRequestTimeout].
  WifiTransfer({
    String? baseUrl,
    http.Client? httpClient,
    Duration? requestTimeout,
  })  : _baseUrl = baseUrl ?? 'http://$defaultDeviceIp',
        _client = httpClient ?? http.Client(),
        _requestTimeout = requestTimeout ?? _defaultRequestTimeout;

  /// Returns the list of files currently on the device SD card.
  ///
  /// Calls `GET /files`. The device must return a JSON array of
  /// `{"name": "...", "size": N}` objects (see TODO #10 — currently HTML).
  ///
  /// Throws [DeviceUnreachableException] on connection failure or non-200.
  /// Throws [FileListParseException] if the response body is not valid JSON.
  Future<List<DeviceFile>> listFiles() async {
    final uri = Uri.parse('$_baseUrl/files');
    final http.Response response;
    try {
      response = await _client.get(uri).timeout(_requestTimeout);
    } on TimeoutException {
      throw TransferTimeoutException(
        'GET /files timed out after ${_requestTimeout.inSeconds}s',
      );
    } on Exception catch (e) {
      throw DeviceUnreachableException('GET /files failed: $e');
    }
    if (response.statusCode != 200) {
      throw DeviceUnreachableException(
        'GET /files returned HTTP ${response.statusCode}',
      );
    }
    final List<dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as List<dynamic>;
    } on FormatException catch (e) {
      throw FileListParseException(
        'Could not parse /files response as JSON array: $e',
      );
    } on TypeError catch (e) {
      throw FileListParseException(
        'Unexpected /files response shape: $e',
      );
    }
    return decoded
        .cast<Map<String, dynamic>>()
        .map(DeviceFile.fromJson)
        .toList();
  }

  /// Downloads [fileName] from the device SD card and returns its raw bytes.
  ///
  /// Calls `GET /download?file=fileName`.
  ///
  /// For large files prefer [downloadFileTo], which streams directly to disk
  /// without buffering the entire file in memory.
  ///
  /// Throws [DeviceUnreachableException] on connection failure.
  /// Throws [TransferTimeoutException] on non-200 status.
  Future<Uint8List> downloadFile(String fileName) async {
    final uri = Uri.parse('$_baseUrl/download')
        .replace(queryParameters: {'file': fileName});
    final http.Response response;
    try {
      response = await _client.get(uri);
    } on Exception catch (e) {
      throw DeviceUnreachableException('GET /download failed: $e');
    }
    if (response.statusCode != 200) {
      throw TransferTimeoutException(
        'GET /download?file=$fileName returned HTTP ${response.statusCode}',
      );
    }
    return response.bodyBytes;
  }

  /// Downloads [fileName] to [destPath] on disk, streaming by chunk.
  ///
  /// [onProgress] is called after each received chunk.
  /// - [received]: bytes written so far.
  /// - [total]: total file size in bytes, or `-1` if the device did not send
  ///   a `Content-Length` header.
  ///
  /// Throws [DeviceUnreachableException] on connection failure.
  /// Throws [TransferTimeoutException] on non-200 status.
  Future<void> downloadFileTo(
    String fileName,
    String destPath, {
    void Function(int received, int total)? onProgress,
  }) async {
    final uri = Uri.parse('$_baseUrl/download')
        .replace(queryParameters: {'file': fileName});
    final http.StreamedResponse response;
    try {
      response = await _client
          .send(http.Request('GET', uri))
          .timeout(_requestTimeout);
    } on TimeoutException {
      throw TransferTimeoutException(
        'GET /download?file=$fileName timed out waiting for response after '
        '${_requestTimeout.inSeconds}s',
      );
    } on Exception catch (e) {
      throw DeviceUnreachableException('GET /download failed: $e');
    }
    if (response.statusCode != 200) {
      throw TransferTimeoutException(
        'GET /download?file=$fileName returned HTTP ${response.statusCode}',
      );
    }
    final total = response.contentLength ?? -1;
    var received = 0;
    final sink = File(destPath).openWrite();
    try {
      // Stream.timeout resets the timer on each event, so a slow-but-
      // progressing transfer is fine — only a complete stall (no chunk
      // for [_requestTimeout]) trips the timeout.
      await for (final chunk in response.stream.timeout(_requestTimeout)) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
    } on TimeoutException {
      throw TransferTimeoutException(
        'GET /download?file=$fileName stalled — no chunk for '
        '${_requestTimeout.inSeconds}s',
      );
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  /// Deletes [fileName] from the device SD card.
  ///
  /// Calls `GET /delete?file=fileName`. A 200 response indicates success.
  ///
  /// Throws [DeviceUnreachableException] on connection failure or non-200.
  Future<void> deleteFile(String fileName) async {
    final uri = Uri.parse('$_baseUrl/delete')
        .replace(queryParameters: {'file': fileName});
    final http.Response response;
    try {
      response = await _client.get(uri).timeout(_requestTimeout);
    } on TimeoutException {
      throw TransferTimeoutException(
        'GET /delete timed out after ${_requestTimeout.inSeconds}s',
      );
    } on Exception catch (e) {
      throw DeviceUnreachableException('GET /delete failed: $e');
    }
    if (response.statusCode != 200) {
      throw DeviceUnreachableException(
        'GET /delete?file=$fileName returned HTTP ${response.statusCode}',
      );
    }
  }

  /// Pushes [configJson] to the device SD card as `idl0_config.json`.
  ///
  /// Calls `POST /config` with the JSON body. The device writes the file to
  /// the SD card root and uses it on next boot. Must only be called after
  /// explicit user action — never pushed automatically (see §6.1).
  ///
  /// Throws [DeviceUnreachableException] on connection failure or non-200.
  Future<void> pushConfig(String configJson) async {
    final uri = Uri.parse('$_baseUrl/config');
    final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: configJson,
          )
          .timeout(_requestTimeout);
    } on TimeoutException {
      throw TransferTimeoutException(
        'POST /config timed out after ${_requestTimeout.inSeconds}s',
      );
    } on Exception catch (e) {
      throw DeviceUnreachableException('POST /config failed: $e');
    }
    if (response.statusCode != 200) {
      throw DeviceUnreachableException(
        'POST /config returned HTTP ${response.statusCode}',
      );
    }
  }

  /// Streams [bin] to `POST /ota` as the raw firmware image.
  ///
  /// The device must already have its WiFi AP up (see [WifiService.bind] +
  /// `CMD_WIFI_ON` over BLE first). The request body is the raw `.bin` file
  /// with `Content-Type: application/octet-stream`. `Content-Length` is set
  /// from `bin.length` so the device can plan its receive buffer.
  ///
  /// [onProgress] is called with `(sent, total)` byte counts after each
  /// chunk that crosses the wire. `total` is always `bin.length`. The final
  /// callback fires exactly once with `sent == total` after the HTTP
  /// response has been received successfully.
  ///
  /// Device-side contract (§6.1 OTA):
  /// - **200 `ok\n`** — image accepted; device reboots ~500 ms later. A
  ///   `SocketException` on any *next* call within ~5 s is normal and is
  ///   the caller's signal to start polling for BLE reconnect.
  /// - **400** — `esp_ota_end` rejected the image (SHA-256 mismatch /
  ///   truncated upload). Throws [FirmwarePushException] with
  ///   `statusCode == 400` — surface as "Firmware file corrupted, try
  ///   again."
  /// - **500** — flash-write or recv error during the upload. Throws
  ///   [FirmwarePushException] with `statusCode == 500` — surface as
  ///   "Device error during update, try again."
  ///
  /// Connection-level failures (refused, mid-stream socket close, host
  /// unreachable) throw [DeviceUnreachableException] — distinct from the
  /// device-emitted [FirmwarePushException] so the UI can tell "no AP"
  /// from "AP said no".
  Future<void> pushFirmware(
    Uint8List bin, {
    void Function(int sent, int total)? onProgress,
  }) async {
    /// 16 KiB per write — matches the device's lwIP TX buffer tuning
    /// (§P8) so the upload doesn't fragment into a stall pattern.
    const chunkSize = 16 * 1024;

    final uri = Uri.parse('$_baseUrl/ota');
    final request = http.StreamedRequest('POST', uri)
      ..headers['Content-Type'] = 'application/octet-stream'
      ..contentLength = bin.length;

    // Send and write are concurrent: the http client starts pulling from
    // the sink as soon as send() is awaited, so we have to begin sending
    // before we have a response future to await.
    final responseFuture = _client.send(request);

    // Pump chunks. Each chunk that lands in the sink is reported via
    // [onProgress] — the actual network write happens asynchronously
    // behind the client, but for a phone <-> device AP link the buffering
    // is small enough that this maps closely to bytes-on-the-wire.
    var sent = 0;
    while (sent < bin.length) {
      final end = (sent + chunkSize < bin.length) ? sent + chunkSize : bin.length;
      request.sink.add(Uint8List.sublistView(bin, sent, end));
      sent = end;
      onProgress?.call(sent, bin.length);
    }
    await request.sink.close();

    final http.StreamedResponse response;
    try {
      response = await responseFuture.timeout(_otaResponseTimeout);
    } on TimeoutException {
      throw DeviceUnreachableException(
        'POST /ota got no response within ${_otaResponseTimeout.inSeconds}s',
      );
    } on Exception catch (e) {
      throw DeviceUnreachableException('POST /ota failed: $e');
    }

    // Drain the body so the device sees the connection closed cleanly.
    final body = await response.stream.bytesToString().catchError((_) => '');

    if (response.statusCode == 400) {
      throw FirmwarePushException(
        400,
        'POST /ota rejected firmware image: ${body.trim()}',
      );
    }
    if (response.statusCode == 500) {
      throw FirmwarePushException(
        500,
        'POST /ota failed on device: ${body.trim()}',
      );
    }
    if (response.statusCode != 200) {
      throw DeviceUnreachableException(
        'POST /ota returned HTTP ${response.statusCode}',
      );
    }
  }

  /// Releases the underlying HTTP client resources.
  void close() => _client.close();
}
