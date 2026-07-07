import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/exceptions.dart';
import '../transport/ble_connection.dart';
import '../transport/ble_service.dart';
import 'link_activity.dart';

/// Immutable state for [deviceProvider].
///
/// All fields reflect the last-known device status reported over BLE. See §7.3.
class DeviceState {
  /// Whether a BLE connection to an IDL0 device is currently active.
  final bool isConnected;

  /// BLE advertisement name of the connected device, e.g. `IDL0-A3F2`.
  ///
  /// Null when [isConnected] is false.
  final String? deviceName;

  /// Battery level reported by the device's Status characteristic, in percent
  /// (0–100). Null when [isConnected] is false or not yet received.
  final int? batteryPercent;

  /// Whether the device is currently writing a log session to the SD card.
  final bool isRecording;

  /// Whether the device SoftAP is currently active. See §7.3 `WiFi:` line.
  final bool wifiOn;

  /// Raw §8 config JSON last pushed to or received from the device.
  ///
  /// Null until the user opens the config editor or a config is loaded from
  /// the device.
  final Map<String, dynamic>? currentConfig;

  // TODO(idl0): richer per-peripheral status (hardware-gated). Once the §7.3
  // status string carries them, add fields here — GPS fix-type (2D/3D) +
  // satellite count, SD free space, BLE signal RSSI — and map them in the
  // hero's _PeripheralReadout (already structured to show a longer value,
  // e.g. "GPS 3D · 9 sat", with no layout change).

  /// Last-reported SD state: `OK` | `FULL` | `ERROR` | `ABSENT`. See §7.3.
  /// Null when not yet reported by the device.
  final String? sdState;

  /// Last-reported GPS state: `FIX` | `NOFIX` | `ABSENT`. See §7.3.
  final String? gpsState;

  /// Last-reported IMU state: `OK` | `PARTIAL` | `ERROR` | `ABSENT`. See §7.3.
  final String? imuState;

  /// Running firmware version reported over §7.3 (e.g. `1.5.0`), or null when
  /// the device firmware predates the `Firmware:` status line. Drives the OTA
  /// update check (§27.7).
  final String? firmwareVersion;

  /// True when the device is running an OTA image that has not yet been
  /// confirmed (status string carries `OTA: PENDING_VERIFY`). The Settings
  /// → Update Firmware panel shows the commit/roll-back card while this is
  /// true. See §7.2 CMD_OTA_CONFIRM and §7.3.
  final bool otaPendingVerify;

  /// Raw §7.3 `HR:` line value (e.g. `ABSENT`, `SEARCHING`,
  /// `CONNECTED 142`, `NO_CONTACT 142`, `SUSPENDED`), uppercased. `null`
  /// when the firmware has not emitted an `HR:` line yet.
  final String? hr;

  /// Heart-rate-monitor battery 0–100 % (one-shot read on strap connect).
  /// `null` until the firmware has read the strap's battery.
  final int? hrBatteryPercent;

  /// Creates a [DeviceState]. All fields default to the disconnected/idle values.
  const DeviceState({
    this.isConnected = false,
    this.deviceName,
    this.batteryPercent,
    this.isRecording = false,
    this.wifiOn = false,
    this.currentConfig,
    this.sdState,
    this.gpsState,
    this.imuState,
    this.firmwareVersion,
    this.otaPendingVerify = false,
    this.hr,
    this.hrBatteryPercent,
  });

  /// Returns a copy with the given fields replaced.
  DeviceState copyWith({
    bool? isConnected,
    String? deviceName,
    int? batteryPercent,
    bool? isRecording,
    bool? wifiOn,
    Map<String, dynamic>? currentConfig,
    String? sdState,
    String? gpsState,
    String? imuState,
    String? firmwareVersion,
    bool? otaPendingVerify,
    String? hr,
    int? hrBatteryPercent,
  }) {
    return DeviceState(
      isConnected: isConnected ?? this.isConnected,
      deviceName: deviceName ?? this.deviceName,
      batteryPercent: batteryPercent ?? this.batteryPercent,
      isRecording: isRecording ?? this.isRecording,
      wifiOn: wifiOn ?? this.wifiOn,
      currentConfig: currentConfig ?? this.currentConfig,
      sdState: sdState ?? this.sdState,
      gpsState: gpsState ?? this.gpsState,
      imuState: imuState ?? this.imuState,
      firmwareVersion: firmwareVersion ?? this.firmwareVersion,
      otaPendingVerify: otaPendingVerify ?? this.otaPendingVerify,
      hr: hr ?? this.hr,
      hrBatteryPercent: hrBatteryPercent ?? this.hrBatteryPercent,
    );
  }
}

/// Manages BLE connection state, recording state, and device config.
///
/// Reads [bleServiceProvider] for all device operations. Swap the provider
/// binding during the BLE integration pass — no changes to this class needed.
class DeviceNotifier extends Notifier<DeviceState> {
  /// Active subscription to the BLE device status stream. Null while
  /// disconnected. See §7.3.
  StreamSubscription<DeviceStatus>? _statusSub;

  /// Active subscription to the BLE link-loss stream. Null while
  /// disconnected. Fires when the BLE link drops unexpectedly (out of
  /// range, device reset, OTA reboot) so the UI can flip back to the
  /// disconnected state without waiting for the next failed command.
  StreamSubscription<void>? _connectionLostSub;

  /// One-shot OTA auto-confirm expectation, armed by [armOtaAutoConfirm].
  ///
  /// Holds the pushed firmware version (no leading `v`) the next
  /// version-bearing status frame is compared against, or null when no
  /// auto-confirm is armed. See §27.7.
  String? _armedOtaVersion;

  @override
  DeviceState build() => const DeviceState();

  /// Arms a one-shot expectation that the device will reconnect running
  /// [version] (no leading `v`, e.g. `1.5.0`) after an OTA push + reboot.
  ///
  /// The first version-bearing status frame received **after the reconnect
  /// completes** (i.e. once [DeviceState.isConnected] is true — see
  /// [_onStatus]) disarms this expectation, whether or not it matches. If
  /// it matches and the frame also reports [DeviceState.otaPendingVerify],
  /// [confirmOta] fires automatically so the just-pushed image is committed
  /// before the bootloader's rollback-on-reboot window can revert it. A
  /// version-bearing frame arriving before the reconnect completes (the
  /// GATT-handshake frame — see [connect]) is ignored entirely: it neither
  /// consumes nor evaluates the arm. See §27.7.
  void armOtaAutoConfirm(String version) {
    _armedOtaVersion = version;
  }

  /// Cancels a pending [armOtaAutoConfirm] expectation without waiting for
  /// the next status frame.
  ///
  /// Called from the manual `.bin` file-picker flow (`FirmwareUpdateSection
  /// ._pickFile`) — picking a file to push abandons any expectation armed
  /// by an earlier catalog-driven update, so a stale armed version can't be
  /// evaluated against this unrelated image's post-reboot status frame. See
  /// §27.7.
  void disarmOtaAutoConfirm() {
    _armedOtaVersion = null;
  }

  /// Scans for and connects to the nearest IDL0 device.
  ///
  /// On success, sets [DeviceState.isConnected] to true and populates
  /// [DeviceState.deviceName] and [DeviceState.batteryPercent]. Subscribes to
  /// the device status stream so SD/GPS/IMU state updates live, and to the
  /// link-loss stream so an unexpected BLE drop clears [DeviceState].
  Future<void> connect() async {
    final service = ref.read(bleServiceProvider);
    ref.read(linkActivityProvider.notifier).pulseTx();
    // Cancel any stale subscriptions from a previous attempt, then subscribe
    // before connect() — the device emits its initial status during the
    // connect handshake and statusStream (broadcast) does not buffer.
    await _statusSub?.cancel();
    await _connectionLostSub?.cancel();
    _statusSub = service.statusStream.listen(_onStatus);
    _connectionLostSub = service.connectionLost.listen((_) => _onLinkLost());
    try {
      final result = await service.connect();
      state = state.copyWith(
        isConnected: true,
        deviceName: result.name,
        batteryPercent: result.batteryPercent,
        isRecording: false,
      );
    } catch (_) {
      await _statusSub?.cancel();
      await _connectionLostSub?.cancel();
      _statusSub = null;
      _connectionLostSub = null;
      rethrow;
    }
  }

  /// Resets state on unexpected BLE link drop. Cancels the status / link-loss
  /// subscriptions so a stale stream doesn't trigger a state update after
  /// the user has been bounced back to disconnected.
  void _onLinkLost() {
    _statusSub?.cancel();
    _connectionLostSub?.cancel();
    _statusSub = null;
    _connectionLostSub = null;
    state = const DeviceState();
  }

  /// Folds a device-pushed [DeviceStatus] into [DeviceState].
  ///
  /// Also services the [armOtaAutoConfirm] one-shot expectation, gated on
  /// [DeviceState.isConnected]: the first version-bearing frame seen while
  /// armed **and connected** disarms it unconditionally (a rolled-back
  /// device reports its old version and must never auto-commit a stale
  /// expectation), then — only if that version matches the armed value and
  /// the frame reports [DeviceState.otaPendingVerify] — fires [confirmOta]
  /// via [_autoConfirmOta].
  ///
  /// The `isConnected` gate matters because [connect] subscribes to
  /// [BleService.statusStream] before awaiting `service.connect()`, so the
  /// very first frame — pushed during the GATT handshake, before
  /// `isConnected` flips true — always carries the post-reboot device's
  /// `Firmware:` + `OTA: PENDING_VERIFY` state. Evaluating the arm against
  /// that frame would consume it before the app is actually connected,
  /// permanently missing the real one-shot opportunity. The firmware's 1 Hz
  /// status notify delivers a second, connected frame right after, so
  /// ignoring the handshake frame costs nothing. See §7.3, §27.7.
  void _onStatus(DeviceStatus status) {
    final armedVersion = _armedOtaVersion;
    final incomingVersion = status.firmwareVersion;
    final evaluateOneShot =
        state.isConnected && armedVersion != null && incomingVersion != null;
    if (evaluateOneShot) {
      _armedOtaVersion = null;
    }

    state = state.copyWith(
      batteryPercent: status.batteryPercent,
      isRecording: status.loggingRunning,
      wifiOn: status.wifiOn,
      sdState: status.sdState,
      gpsState: status.gpsState,
      imuState: status.imuState,
      firmwareVersion: status.firmwareVersion,
      otaPendingVerify: status.otaPendingVerify,
      hr: status.hr,
      hrBatteryPercent: status.hrBatteryPercent,
    );
    // Blink the hero's RX chip — a status frame arrived from the device.
    ref.read(linkActivityProvider.notifier).pulseRx();

    if (evaluateOneShot &&
        incomingVersion == armedVersion &&
        status.otaPendingVerify) {
      unawaited(_autoConfirmOta());
    }
  }

  /// Fires [confirmOta] from the [_onStatus] auto-confirm hook, catching
  /// transport failures so a dropped confirm send never rethrows into the
  /// status-stream listener. On failure, [DeviceState.otaPendingVerify]
  /// stays true and the manual `_PendingVerifyCard` remains the fallback.
  /// See §27.7.
  Future<void> _autoConfirmOta() async {
    try {
      await confirmOta();
    } on TransportException {
      // Single catch type is sufficient — [BleService]'s methods (confirmOta
      // included) are documented to throw only TransportException subtypes
      // (DeviceNotFoundException, CommandRefusedException, etc.), never a
      // bare Exception or Error. Swallow — the manual commit card stays
      // visible as the fallback.
    }
  }

  /// Disconnects from the current device and resets all connection state.
  Future<void> disconnect() async {
    final service = ref.read(bleServiceProvider);
    ref.read(linkActivityProvider.notifier).pulseTx();
    await _statusSub?.cancel();
    await _connectionLostSub?.cancel();
    _statusSub = null;
    _connectionLostSub = null;
    await service.disconnect();
    state = const DeviceState();
  }

  /// Re-establishes the BLE link after the device reboots — e.g. to apply a
  /// pushed config (`POST /config` restarts the device, §6.1). Tears down the
  /// stale pre-reboot handles, waits for the device to come back advertising,
  /// then retries [connect] until it succeeds. On success the device is back
  /// in idle mode (it boots WiFi-off / no session) ready to log.
  ///
  /// Returns true once reconnected, false if every attempt was exhausted. The
  /// delays are injectable for tests; the production defaults cover ESP32 boot
  /// plus BLE advertising latency.
  Future<bool> reconnectAfterReboot({
    Duration bootDelay = const Duration(seconds: 4),
    Duration retryDelay = const Duration(seconds: 2),
    int maxAttempts = 3,
  }) async {
    // Drop the stale link / subscriptions from before the reboot.
    await disconnect();
    await Future<void>.delayed(bootDelay);
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        await connect();
        return true;
      } on TransportException {
        if (attempt < maxAttempts - 1) {
          await Future<void>.delayed(retryDelay);
        }
      }
    }
    return false;
  }

  /// Sends CMD_START_LOGGING to the device.
  ///
  /// No-op if [DeviceState.isConnected] is false — recording requires an
  /// active BLE connection to the device.
  Future<void> startRecording() async {
    if (!state.isConnected) return;
    final service = ref.read(bleServiceProvider);
    await service.startRecording();
    state = state.copyWith(isRecording: true);
  }

  /// Sends CMD_STOP_LOGGING to the device.
  Future<void> stopRecording() async {
    final service = ref.read(bleServiceProvider);
    await service.stopRecording();
    state = state.copyWith(isRecording: false);
  }

  /// Pushes [config] to the device and stores it as [DeviceState.currentConfig].
  ///
  /// Never called automatically — always user-initiated via the "Push Config"
  /// button. See §8 and §19.2.
  Future<void> pushConfig(Map<String, dynamic> config) async {
    final service = ref.read(bleServiceProvider);
    ref.read(linkActivityProvider.notifier).pulseTx();
    await service.pushConfig(config);
    state = state.copyWith(currentConfig: config);
  }

  /// Sends CMD_CALIBRATE_IMU to the device.
  ///
  /// The device collects ~5 s of static samples and writes the resulting
  /// rotation matrices and bias vectors into `idl0_config.json`. No-op if
  /// not connected. See §11.
  ///
  /// TODO(idl0): On completion, re-read currentConfig from device so rotation
  /// matrices and bias reflect the new calibration result.
  Future<void> calibrate() async {
    if (!state.isConnected) return;
    final service = ref.read(bleServiceProvider);
    ref.read(linkActivityProvider.notifier).pulseTx();
    await service.calibrate();
  }

  /// Commits the running OTA image via CMD_OTA_CONFIRM.
  ///
  /// No-op if not connected or if the device is not currently flagged as
  /// `otaPendingVerify`. After the device acknowledges, optimistically
  /// clears the local pending-verify flag so the panel's commit card
  /// closes — the device's next status emit will confirm.
  Future<void> confirmOta() async {
    if (!state.isConnected) return;
    if (!state.otaPendingVerify) return;
    final service = ref.read(bleServiceProvider);
    await service.confirmOta();
    state = state.copyWith(otaPendingVerify: false);
  }
}

/// Provides the active [BleService] implementation. See §17.
///
/// Production binding uses [BleConnection]. Override with [MockBleService]
/// in tests via [ProviderScope] overrides.
final bleServiceProvider = Provider<BleService>((ref) => BleConnection());

/// Provides [DeviceState] and the [DeviceNotifier] business logic. See §17.
final deviceProvider =
    NotifierProvider<DeviceNotifier, DeviceState>(DeviceNotifier.new);
