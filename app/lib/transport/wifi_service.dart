/// Abstract WiFi transfer service interface and production stub. See §6.
///
/// The real implementation uses [WifiTransfer]. Wired in once the device
/// WiFi endpoint is available (TODO(idl0): §6 TODO #10). Test doubles in
/// `test/helpers/`.
library;

import 'dart:typed_data';

/// A single file entry from the device `/files` endpoint. See §6.
///
/// [name] is the filename on the SD card; [size] is file size in bytes;
/// [sessionId] is the session UUID from the file header (empty if the
/// firmware did not report it).
typedef FileInfo = ({String name, int size, String sessionId});

/// Handle returned by [WifiService.pushFirmware] so a caller can either
/// await completion or cancel an in-flight upload.
///
/// [done] completes when the device acknowledges the OTA push (or throws
/// on error). [cancel] aborts the upload — the underlying HTTP client is
/// closed, [done] then completes with a [DeviceUnreachableException], and
/// the device-side upload times out and is discarded by the firmware.
typedef PushFirmwareHandle = ({
  Future<void> done,
  Future<void> Function() cancel,
});

/// Abstract interface for WiFi file transfer used by [DownloadPanel].
///
/// ## Lifecycle
/// [getFileList] and [downloadFile] assume the process is already bound to
/// the device AP — they do NOT bind/release internally. The owner (the Data
/// tab's file-transfer panel) calls [bind] once when the WiFi scope opens
/// and [release] once when it closes.
///
/// Why panel-scoped rather than per-op: on Android 10+ back-to-back
/// `requestNetwork` / `unregisterNetworkCallback` cycles race the platform
/// state machine — the second `bind` sometimes fires no callback at all
/// and the user sees the 10 s `BIND_TIMEOUT_MS` despite the device AP
/// being up. Holding a single binding for the panel's lifetime sidesteps
/// the race entirely.
abstract class WifiService {
  /// Binds the process network to the device WiFi AP.
  ///
  /// On Android 10+ shows the one-time system permission dialog. On iOS
  /// and Android 9 and below this is a no-op (the user must already be
  /// connected to the AP via system Settings).
  ///
  /// Throws [DeviceUnreachableException] on platform timeout (10 s) or if
  /// the network is unavailable.
  Future<void> bind();

  /// Releases the process-level WiFi binding established by [bind].
  ///
  /// Always completes without throwing — platform errors are swallowed.
  /// Safe to call when [bind] was never invoked.
  Future<void> release();

  /// Returns the list of log files on the device SD card.
  ///
  /// Precondition: [bind] must have been called and not yet released.
  Future<List<FileInfo>> getFileList();

  /// Downloads [name] from the device, yielding progress values 0.0–1.0.
  ///
  /// [size] is the file size in bytes, used to compute progress fraction.
  /// Precondition: [bind] must have been called and not yet released.
  Stream<double> downloadFile(String name, int size);

  /// Streams [bin] to the device's `POST /ota` endpoint.
  ///
  /// Returns a [PushFirmwareHandle] so the caller can cancel mid-upload.
  /// [onProgress] fires with `(sent, total)` as bytes go on the wire.
  ///
  /// Precondition: [bind] must have been called and not yet released, and
  /// the device's WiFi AP must be active (`CMD_WIFI_ON` over BLE).
  ///
  /// The device reboots ~500 ms after responding 200; expect socket errors
  /// on any immediately-following request. See §6.1 OTA contract.
  PushFirmwareHandle pushFirmware(
    Uint8List bin, {
    void Function(int sent, int total)? onProgress,
  });

  /// Pushes [configJson] to the device's `POST /config` endpoint (§6.1, §23.6).
  ///
  /// Precondition: [bind] has been called and not yet released, and
  /// `CMD_WIFI_ON` has been sent over BLE so the AP is up. Lifecycle
  /// stays with the caller — this method does NOT bind/release internally
  /// (binding cycles race the platform `requestNetwork` flow on Android
  /// 10+; the existing long-lived bind is reused).
  ///
  /// Throws [DeviceUnreachableException] on HTTP transport failures.
  Future<void> pushConfig(String configJson);
}

/// Production stub — throws [UnimplementedError] on data ops.
///
/// Used until the device WiFi endpoint is available (TODO(idl0): §6 TODO #10).
/// [bind] / [release] are no-ops so panel-side lifecycle wiring can run
/// against the stub during early development.
class StubWifiService implements WifiService {
  @override
  Future<void> bind() async {}

  @override
  Future<void> release() async {}

  @override
  Future<List<FileInfo>> getFileList() => throw UnimplementedError();

  @override
  Stream<double> downloadFile(String name, int size) =>
      throw UnimplementedError();

  @override
  PushFirmwareHandle pushFirmware(
    Uint8List bin, {
    void Function(int sent, int total)? onProgress,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> pushConfig(String configJson) => throw UnimplementedError();
}
