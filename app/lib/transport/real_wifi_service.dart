import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../data/exceptions.dart';
import '../data/sessions_paths.dart';
import 'wifi_network_binder.dart';
import 'wifi_service.dart';
import 'wifi_transfer.dart';

/// Production [WifiService] backed by [WifiTransfer] and [WifiNetworkBinder].
///
/// On Android 10+ (API 29+), [bind] requests the device WiFi AP via
/// `WifiNetworkSpecifier` and binds all process traffic to that network so
/// subsequent HTTP requests reach `192.168.4.1` instead of routing to
/// cellular. On Android 9 and below or on iOS the bind is a no-op; the user
/// must connect to the device AP manually in system Settings. See §6.2.
///
/// ## Panel-scoped lifecycle
/// [bind] and [release] are exposed separately from per-op methods so the
/// file-transfer panel can hold the binding for its entire lifetime instead
/// of cycling `requestNetwork` / `unregisterNetworkCallback` between every
/// `/files`, `/download`, and `/delete`. Back-to-back cycles on Android 10+
/// are unreliable — the second `bind` sometimes fires no callback at all
/// and the user sees a 10 s timeout. Holding the binding fixes that.
///
/// [deviceName] is the BLE advertisement name of the connected device, e.g.
/// `IDL0-A3F2`. The WiFi SSID is identical by spec — both derive from the
/// last 4 hex digits of the device MAC. See §6, §7.
///
/// When TODO #16 lands (per-device password), update [_password] here.
class RealWifiService implements WifiService {
  /// WiFi password placeholder. Per-device password not yet implemented.
  ///
  /// Change this one constant when TODO #16 (per-device password) lands.
  static const _password = 'datalogger123';

  final String _ssid;
  final WifiNetworkBinder _binder;

  /// Factory that creates a fresh [WifiTransfer] per operation, pointed at
  /// [baseUrl] (the binder's [WifiNetworkBinder.deviceBaseUrl] — loopback
  /// proxy on Android, direct 192.168.4.1 elsewhere).
  ///
  /// A new instance is constructed per call because [WifiTransfer] owns an
  /// [http.Client] that must be closed after use, and because the proxy
  /// port can change between links. Injectable for tests.
  final WifiTransfer Function(String baseUrl) _transferFactory;

  /// Override for the sessions directory used by [downloadFile].
  ///
  /// Null in production (resolved from [getExternalStorageDirectory], falling
  /// back to [getApplicationDocumentsDirectory]). Injectable for tests to
  /// avoid a real [path_provider] call.
  final Future<Directory> Function()? _sessionsDirOverride;

  /// Delay before the single retry inside [getFileList], and between
  /// [pushFirmware] warmup attempts.
  ///
  /// Production: 500 ms — long enough to absorb the post-bind warmup race
  /// (DHCP / ARP / device-side httpd settling) without making the success
  /// path feel sluggish. Tests inject [Duration.zero].
  final Duration _firstRetryDelay;

  /// How many times [pushFirmware] attempts the upload before giving up.
  ///
  /// The OTA push is the *first* HTTP request after the WiFi bind (unlike a
  /// download, which `getFileList` warms first), so it eats the post-bind
  /// warmup race directly: `onAvailable` fires the instant Android associates
  /// with the AP, but the route to `192.168.4.1` isn't ready for a second or
  /// two. With the loopback proxy's bounded connect (LoopbackProxy.kt) a cold
  /// attempt fails fast rather than hanging; these attempts (spaced by
  /// [_firstRetryDelay]) then land on the warm link. A cold attempt reaches
  /// the device 0 bytes in — `esp_ota_begin` never runs — so retrying is safe.
  static const int _pushWarmupAttempts = 5;

  /// Creates a [RealWifiService].
  ///
  /// [deviceName] is used as the WiFi SSID (spec §6: BLE name and SSID match).
  /// [binder], [transferFactory], and [sessionsDirOverride] are injectable for
  /// tests; production uses the defaults. [firstRetryDelay] tunes the
  /// post-bind warmup retry window (see [getFileList]).
  RealWifiService({
    required String deviceName,
    WifiNetworkBinder? binder,
    WifiTransfer Function(String baseUrl)? transferFactory,
    Future<Directory> Function()? sessionsDirOverride,
    Duration firstRetryDelay = const Duration(milliseconds: 500),
  })  : _ssid = deviceName,
        _binder = binder ?? WifiNetworkBinder(),
        _transferFactory =
            transferFactory ?? ((baseUrl) => WifiTransfer(baseUrl: baseUrl)),
        _sessionsDirOverride = sessionsDirOverride,
        _firstRetryDelay = firstRetryDelay;

  /// Binds the process to the device WiFi AP. See [WifiService.bind].
  ///
  /// Owners (e.g. the Data tab's file-transfer panel) call this once when
  /// they open the WiFi scope, then issue any number of [getFileList] /
  /// [downloadFile] calls without re-binding.
  @override
  Future<void> bind() => _binder.bind(_ssid, _password);

  /// Releases the binding established by [bind]. See [WifiService.release].
  @override
  Future<void> release() => _binder.release();

  /// Returns the list of log files on the device SD card.
  ///
  /// Precondition: [bind] has been called and not yet released. This method
  /// does NOT bind/release internally — the caller owns the lifecycle so
  /// back-to-back operations share one binding (Android 10+ races the
  /// `requestNetwork`/`unregisterNetworkCallback` cycle otherwise).
  ///
  /// ## Post-bind warmup retry
  /// The very first HTTP request after `bindProcessToNetwork` is racy on
  /// Android: the OS fires `onAvailable` (so the plugin returns success
  /// from [bind]) but DHCP, ARP, and the device-side `esp_http_server`
  /// haven't all settled yet — the first GET to `192.168.4.1` throws
  /// `SocketException`. A single retry after [_firstRetryDelay]
  /// consistently absorbs this in field tests; subsequent calls hit a
  /// warm path and don't need retry.
  ///
  /// Real failures (device powered off, AP genuinely down) still fail —
  /// both attempts throw, the second exception propagates.
  ///
  /// Throws [DeviceUnreachableException] if the device AP is unreachable.
  /// Throws [FileListParseException] if the `/files` response is malformed.
  @override
  Future<List<FileInfo>> getFileList() async {
    try {
      return await _fetchFileList();
    } on TransportException {
      await Future.delayed(_firstRetryDelay);
      return _fetchFileList();
    }
  }

  Future<List<FileInfo>> _fetchFileList() async {
    final transfer = _transferFactory(_binder.deviceBaseUrl);
    try {
      final files = await transfer.listFiles();
      return files
          .map((f) => (name: f.name, size: f.sizeBytes, sessionId: f.sessionId))
          .toList();
    } finally {
      transfer.close();
    }
  }

  /// Downloads [name] from the device SD card to the app sessions directory.
  ///
  /// Yields progress values 0.0–1.0 as chunks arrive. The file is written
  /// to `<app documents>/sessions/[name]`.
  ///
  /// Precondition: [bind] has been called and not yet released. The stream
  /// does NOT bind/release internally — the caller owns the lifecycle.
  ///
  /// Errors are forwarded onto the stream — listen with `await for` inside a
  /// try/catch, or use [Stream.listen] with `onError`.
  ///
  /// Throws [DeviceUnreachableException] via the stream on connection failure.
  /// Throws [TransferTimeoutException] via the stream on non-200 `/download`.
  @override
  Stream<double> downloadFile(String name, int size) {
    final controller = StreamController<double>();
    () async {
      try {
        final transfer = _transferFactory(_binder.deviceBaseUrl);
        try {
          final sessionsDir = await _resolveSessionsDir();
          final destPath = p.join(sessionsDir.path, name);
          await transfer.downloadFileTo(
            name,
            destPath,
            onProgress: (received, total) {
              // The firmware streams chunked and omits Content-Length, so
              // [total] is -1 (see wifi_server.c §6.1). Fall back to the
              // known file [size] from the /files listing so the progress
              // fraction advances during the download instead of staying at
              // 0 until completion.
              final denom = total > 0 ? total : size;
              if (denom > 0) {
                controller.add((received / denom).clamp(0.0, 1.0));
              }
            },
          );
          controller.add(1.0);
        } finally {
          transfer.close();
        }
      } catch (e, st) {
        controller.addError(e, st);
      } finally {
        await controller.close();
      }
    }();
    return controller.stream;
  }

  /// Streams [bin] to the device's `POST /ota` endpoint, retrying the
  /// post-bind warmup race (see [_pushWarmupAttempts]).
  ///
  /// A fresh [WifiTransfer] (and its [http.Client]) is built per attempt via
  /// [_transferFactory], so [PushFirmwareHandle.cancel] can abort the current
  /// attempt by closing its client — the in-flight `send()` then throws and is
  /// surfaced as a [DeviceUnreachableException]. Only connection-level failures
  /// ([DeviceUnreachableException] / [TransferTimeoutException]) are retried; a
  /// [FirmwarePushException] (device rejected the image — 400/500) propagates
  /// immediately, since retrying a bad image cannot help.
  ///
  /// Precondition: the panel scope must already hold a [bind] and have sent
  /// `CMD_WIFI_ON`. See [PushFirmwareHandle] doc for cancel semantics.
  @override
  PushFirmwareHandle pushFirmware(
    Uint8List bin, {
    void Function(int sent, int total)? onProgress,
  }) {
    var canceled = false;
    WifiTransfer? current;

    Future<void> run() async {
      TransportException? lastError;
      for (var attempt = 1; attempt <= _pushWarmupAttempts; attempt++) {
        if (canceled) {
          throw const DeviceUnreachableException('Firmware push canceled');
        }
        if (attempt > 1) await Future.delayed(_firstRetryDelay);
        final transfer = _transferFactory(_binder.deviceBaseUrl);
        current = transfer;
        try {
          await transfer.pushFirmware(bin, onProgress: onProgress);
          return;
        } on FirmwarePushException {
          rethrow; // device rejected the image — a retry cannot help
        } on TransportException catch (e) {
          lastError = e; // warmup race / timeout / canceled — retry
        } finally {
          transfer.close();
        }
      }
      throw lastError ??
          const DeviceUnreachableException('Firmware push failed');
    }

    return (
      done: run(),
      cancel: () async {
        canceled = true;
        current?.close();
      },
    );
  }

  /// Pushes [configJson] to `POST /config` (§6.1, §23.6) over the already-bound
  /// network. Re-uses the caller's bind/wifiOn lifecycle — no internal cycling
  /// of the network request, which is what made the old BleConnection path race.
  @override
  Future<void> pushConfig(String configJson) async {
    final transfer = _transferFactory(_binder.deviceBaseUrl);
    try {
      await transfer.pushConfig(configJson);
    } finally {
      transfer.close();
    }
  }

  Future<Directory> _resolveSessionsDir() async {
    if (_sessionsDirOverride != null) return _sessionsDirOverride();
    final base = await getSessionsBaseDir();
    final sessionsDir = Directory(p.join(base.path, 'sessions'));
    await sessionsDir.create(recursive: true);
    return sessionsDir;
  }
}
