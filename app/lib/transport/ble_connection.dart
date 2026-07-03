import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/exceptions.dart';
import 'ack.dart';
import 'ble_service.dart';
import 'wifi_transfer.dart';

// ---------------------------------------------------------------------------
// BleConnection
// ---------------------------------------------------------------------------

/// BLE client for an IDL0 device. Implements [BleService]. See §7.
///
/// ## Typical usage
/// ```dart
/// // 1. Construct once and keep alive for the session.
/// final ble = BleConnection();
///
/// // 2. Optionally subscribe to status updates before connecting.
/// ble.statusStream.listen((s) => print(s));
///
/// // 3. Scan for and connect to the nearest IDL0 device (§7.4 sequence).
/// final info = await ble.connect();          // BleService interface
/// print('${info.name} @ ${info.batteryPercent}%');
///
/// // 4. Send control commands.
/// await ble.startRecording();                // BleService interface
/// await ble.calibrate();                     // BleService interface
///
/// // 5. Disconnect when done.
/// await ble.disconnect();
/// ```
///
/// ## Lower-level usage (connect to a pre-scanned device)
/// ```dart
/// final device = await BleConnection.scan().first;
/// await FlutterBluePlus.stopScan();
/// await ble.connectToDevice(device);         // lower-level; skips scan
/// ```
///
/// ## pushConfig transport
/// [pushConfig] sends `CMD_WIFI_ON` (0x01) over BLE to activate the device
/// AP, then calls `POST /config` via [WifiTransfer] per spec §8 and §23.
///
/// ## Unit testing
/// The flutter_blue_plus types (`BluetoothDevice`, `BluetoothCharacteristic`)
/// are final platform classes and cannot be mocked in unit tests. Integration
/// with a real device is required to verify [connect], [disconnect], and the
/// control commands. Test [DeviceStatus] parsing independently via
/// [DeviceStatus.fromString].
class BleConnection implements BleService {
  // UUIDs from §7.1. The `...` shorthand in the spec expands to the same
  // base suffix as the service UUID: `-0000-1000-8000-00805f9b34fb`.
  static const String _serviceUuid = '000000ff-0000-1000-8000-00805f9b34fb';
  static const String _controlUuid = '0000ff03-0000-1000-8000-00805f9b34fb';
  static const String _statusUuid = '0000ff04-0000-1000-8000-00805f9b34fb';
  static const String _configRxUuid = '0000ff05-0000-1000-8000-00805f9b34fb';
  static const String _configTxUuid = '0000ff06-0000-1000-8000-00805f9b34fb';

  /// Anchored regex for extracting the ATT status byte from a
  /// FlutterBluePlusException description string. Compiled once at class
  /// load — `\batt` requires a word boundary so platform messages like
  /// "attempted ... 0xDEADBEEF" cannot match.
  static final RegExp _kAttRegex = RegExp(
    r'\batt\s*(?:status|code|result|error)?\s*[:=]?\s*0x([0-9a-f]{2})\b',
  );

  // Control command bytes from §7.2.
  static const int _cmdWifiOn = 0x01;
  static const int _cmdWifiOff = 0x02;
  static const int _cmdStartLogging = 0x03;
  static const int _cmdStopLogging = 0x04;
  static const int _cmdCalibrateImu = 0x05;
  static const int _cmdOtaConfirm = 0x06;
  static const int _cmdConfigBegin = 0x07;
  static const int _cmdConfigCommit = 0x08;
  static const int _cmdConfigReadBegin = 0x09;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _control;
  BluetoothCharacteristic? _configRx;
  BluetoothCharacteristic? _configTx;
  StreamSubscription<List<int>>? _statusSub;
  StreamSubscription<BluetoothConnectionState>? _connStateSub;
  final _statusController = StreamController<DeviceStatus>.broadcast();
  final _connectionLostController = StreamController<void>.broadcast();

  /// Stream of parsed status updates from the device Status characteristic.
  ///
  /// Emits whenever the device pushes a notification. Subscribe before
  /// calling [connect] to avoid missing the initial status read in step 4
  /// of the §7.4 connection sequence.
  @override
  Stream<DeviceStatus> get statusStream => _statusController.stream;

  /// Emits exactly once per unexpected BLE link drop. See
  /// [BleService.connectionLost]. The platform observer is unsubscribed
  /// at the start of [disconnect], so user-initiated disconnects do not
  /// fire this stream.
  @override
  Stream<void> get connectionLost => _connectionLostController.stream;

  /// Scans for IDL0 devices advertising the IDL0 service UUID.
  ///
  /// Returns a broadcast stream of discovered [BluetoothDevice]s. The caller
  /// is responsible for stopping the scan (call
  /// `FlutterBluePlus.stopScan()`) when a device has been selected.
  ///
  /// Filters by [_serviceUuid] so only IDL0 devices appear.
  static Stream<BluetoothDevice> scan() {
    FlutterBluePlus.startScan(
      withServices: [Guid(_serviceUuid)],
    );
    return FlutterBluePlus.scanResults.expand(
      (results) => results
          .where(
            (r) => r.advertisementData.serviceUuids
                .any((u) => u.str128.toLowerCase() == _serviceUuid),
          )
          .map((r) => r.device),
    );
  }

  /// Connects to [device] and prepares the GATT characteristics. See §7.4.
  ///
  /// Steps performed:
  /// 1. GATT connect + MTU negotiation (flutter_blue_plus handles MTU).
  /// 2. Discover services.
  /// 3. Enable Status characteristic notifications.
  /// 4. Read initial status value and emit it on [statusStream].
  ///
  /// Throws [DeviceNotFoundException] if the IDL0 service or required
  /// characteristics are not found after connecting.
  /// Throws [DeviceUnreachableException] on connection failure.
  ///
  /// Lower-level entry point — for the [BleService] scan-and-connect path
  /// use [connect] instead.
  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      await device.connect();
    } on Exception catch (e) {
      throw DeviceUnreachableException('BLE connect failed: $e');
    }
    _device = device;

    final services = await device.discoverServices();
    final service = services
        .where(
          (s) => s.uuid.str128.toLowerCase() == _serviceUuid,
        )
        .firstOrNull;

    if (service == null) {
      throw DeviceNotFoundException(
        'IDL0 service $_serviceUuid not found on device ${device.remoteId}',
      );
    }

    BluetoothCharacteristic? status;
    for (final c in service.characteristics) {
      final uuid = c.uuid.str128.toLowerCase();
      if (uuid == _controlUuid) _control = c;
      if (uuid == _statusUuid) status = c;
      // FF05/FF06 (config push/read) are optional: older firmware without them
      // still connects; pushConfigBle/pullConfigBle throw a clear error if the
      // characteristic is missing.
      if (uuid == _configRxUuid) _configRx = c;
      if (uuid == _configTxUuid) _configTx = c;
    }

    if (_control == null || status == null) {
      throw DeviceNotFoundException(
        'Required characteristics missing on device ${device.remoteId}',
      );
    }

    // Enable notifications then read current value (§7.4 steps 3–4).
    await status.setNotifyValue(true);
    _statusSub = status.onValueReceived.listen((bytes) {
      _statusController.add(DeviceStatus.fromCharacteristicValue(bytes));
    });
    final initial = await status.read();
    if (initial.isNotEmpty) {
      _statusController.add(DeviceStatus.fromCharacteristicValue(initial));
    }

    // Link-loss observer: subscribe AFTER the connect+discover succeed
    // so we don't react to the brief `connecting` state. [disconnect]
    // cancels this subscription before tearing down the device, so a
    // user-initiated disconnect does not fire [connectionLost].
    _connStateSub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _connectionLostController.add(null);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // BleService interface
  // ---------------------------------------------------------------------------

  /// Scans for the nearest IDL0 device and performs the full §7.4 connection
  /// sequence. Implements [BleService.connect].
  ///
  /// Filters by GATT service UUID `0x00FF`. Takes the first discovered device,
  /// stops the scan, then calls [connectToDevice] to run the §7.4 steps.
  ///
  /// Battery level is read from the initial Status characteristic value
  /// per §7.3. Defaults to `0` if no `Battery:` line is present in the
  /// first notification or the read times out (2 s).
  ///
  /// Throws [DeviceNotFoundException] if no device is found within 10 s or the
  /// IDL0 GATT service/characteristics are absent after connecting.
  /// Throws [DeviceUnreachableException] on GATT connection failure.
  @override
  Future<({String name, int batteryPercent})> connect() async {
    // Precheck: surface "Bluetooth is off" with an actionable message
    // before sinking 10 s into a scan that can never succeed. We read
    // adapterStateNow synchronously; on cold-start (state `unknown`)
    // we wait briefly for the first real state.
    var adapterState = FlutterBluePlus.adapterStateNow;
    if (adapterState == BluetoothAdapterState.unknown) {
      adapterState = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => BluetoothAdapterState.unknown,
          );
    }
    if (adapterState != BluetoothAdapterState.on) {
      throw const DeviceUnreachableException(
        'Bluetooth is off. Enable it and try again.',
      );
    }

    const scanTimeout = Duration(seconds: 10);

    final BluetoothDevice device;
    try {
      device = await BleConnection.scan()
          .timeout(scanTimeout)
          .first
          .onError<StateError>(
            (_, __) => throw const DeviceNotFoundException(
              'No IDL0 device found within scan timeout',
            ),
          );
    } on DeviceNotFoundException {
      rethrow;
    } on Exception catch (e) {
      throw DeviceNotFoundException('BLE scan failed: $e');
    } finally {
      await FlutterBluePlus.stopScan();
    }

    // Capture battery from the initial status emit that connectToDevice triggers.
    var batteryPercent = 0;
    final batteryCompleter = Completer<void>();
    final batterySub = statusStream.listen((s) {
      batteryPercent = s.batteryPercent;
      if (!batteryCompleter.isCompleted) batteryCompleter.complete();
    });

    await connectToDevice(device);

    // Wait briefly for the initial status — connectToDevice reads it
    // synchronously, so this should complete almost immediately.
    await batteryCompleter.future
        .timeout(const Duration(seconds: 2), onTimeout: () {});
    await batterySub.cancel();

    final name = device.platformName.isNotEmpty
        ? device.platformName
        : device.remoteId.toString();
    return (name: name, batteryPercent: batteryPercent);
  }

  /// Disconnects from the device and releases resources.
  ///
  /// Cancels the link-loss observer BEFORE issuing `device.disconnect()`
  /// so the resulting `disconnected` state event is ignored — only
  /// unexpected drops surface via [connectionLost].
  @override
  Future<void> disconnect() async {
    await _connStateSub?.cancel();
    _connStateSub = null;
    await _statusSub?.cancel();
    _statusSub = null;
    _control = null;
    _configRx = null;
    _configTx = null;
    // Best-effort teardown: the platform may throw if the link is already gone
    // (or BLE is unsupported on this desktop). We reset our own state either
    // way, so a failed platform disconnect must not propagate as an uncaught
    // error to the UI.
    try {
      await _device?.disconnect();
    } on Object catch (_) {
      // swallow — teardown is best-effort
    }
    _device = null;
  }

  /// Sends CMD_START_LOGGING (0x03) to the Control characteristic.
  @override
  Future<void> startRecording() => _sendCommand(_cmdStartLogging);

  /// Sends CMD_STOP_LOGGING (0x04) to the Control characteristic.
  @override
  Future<void> stopRecording() => _sendCommand(_cmdStopLogging);

  /// Serialises [config] to JSON and posts it to `http://192.168.4.1/config`
  /// via [WifiTransfer]. See §8, §23.
  ///
  /// Precondition: caller is in [Mode.wifi] — the mode controller's
  /// [WifiOn] step (`mode_step.dart`) has already issued `CMD_WIFI_ON` and
  /// bound the Android process to the device AP. This method is pure HTTP
  /// and does NOT touch the WiFi lifecycle. [PushConfigButton] (T15)
  /// enforces the mode gate at the call site.
  ///
  /// Throws [DeviceUnreachableException] if the HTTP POST fails.
  @override
  Future<void> pushConfig(Map<String, dynamic> config) async {
    final transfer = WifiTransfer();
    try {
      await transfer.pushConfig(jsonEncode(config));
    } finally {
      transfer.close();
    }
  }

  /// Pushes [config] to the device entirely over BLE — no WiFi changeover.
  ///
  /// Wire protocol (§7.2): `CMD_CONFIG_BEGIN` (0x07) opens a reassembly
  /// buffer, the JSON is streamed in MTU-sized chunks to the Config-RX
  /// characteristic (FF05), then `CMD_CONFIG_COMMIT` (0x08) validates and
  /// atomically writes `idl0_config.json` and reboots the device to apply it
  /// (config is read at boot only). The caller follows up with
  /// [DeviceNotifier.reconnectAfterReboot] to re-establish the link.
  ///
  /// Preferred over [pushConfig]: BLE is more reliable than the SoftAP and
  /// avoids the WiFi-mode changeover overhead. The `.json` is a few KB, so
  /// the chunked transfer completes in well under a second.
  ///
  /// Throws [DeviceUnreachableException] if not connected or the device lacks
  /// the FF05 characteristic (firmware too old). Throws
  /// [CommandRefusedException] if the device rejects BEGIN/COMMIT (e.g.
  /// malformed JSON or an SD write error → ack 0x80/0x81).
  @override
  Future<void> pushConfigBle(Map<String, dynamic> config) async {
    final control = _control;
    final configRx = _configRx;
    if (control == null) {
      throw const DeviceUnreachableException(
        'Not connected — call connect() before pushing config',
      );
    }
    if (configRx == null) {
      throw const DeviceUnreachableException(
        'Device firmware does not support BLE config push (no FF05). '
        'Update firmware or use the WiFi push path.',
      );
    }

    final bytes = utf8.encode(jsonEncode(config));

    // Open the reassembly buffer on the device.
    await _sendCommand(_cmdConfigBegin);

    // Stream the JSON in ATT-sized chunks. mtuNow is the negotiated MTU
    // (256 after connect); 3 bytes are ATT write-request overhead. Floor at
    // the BLE default (23 → 20 payload) so this is safe even pre-negotiation.
    final mtu = _device?.mtuNow ?? 23;
    final chunkSize = (mtu - 3).clamp(20, 512);
    try {
      for (var offset = 0; offset < bytes.length; offset += chunkSize) {
        final end = (offset + chunkSize < bytes.length)
            ? offset + chunkSize
            : bytes.length;
        await configRx.write(bytes.sublist(offset, end), withoutResponse: false);
      }
    } on FlutterBluePlusException catch (e) {
      throw DeviceUnreachableException('BLE config chunk write failed: $e');
    } on Exception catch (e) {
      throw DeviceUnreachableException('BLE config chunk write failed: $e');
    }

    // Validate + persist + reboot. A non-OK ack surfaces as
    // CommandRefusedException via _sendCommand.
    await _sendCommand(_cmdConfigCommit);
  }

  /// Reads the device's live `idl0_config.json` back over BLE and decodes it.
  ///
  /// Wire protocol (§7.2): `CMD_CONFIG_READ_BEGIN` (0x09) snapshots the file
  /// on the device and resets a read cursor; the app then reads the Config-TX
  /// characteristic (FF06) repeatedly — each read returns the next chunk and
  /// advances the cursor — until an empty read signals EOF. The accumulated
  /// bytes are UTF-8 decoded and `jsonDecode`d.
  ///
  /// Used to round-trip / verify a push: pull the config back and compare to
  /// what was sent.
  ///
  /// Throws [DeviceUnreachableException] if not connected, the device lacks
  /// FF06 (firmware too old), or the read fails.
  /// Throws [CommandRefusedException] if the device has no config to read
  /// (ack 0x81) or hits a transient error (0x80).
  @override
  Future<Map<String, dynamic>> pullConfigBle() async {
    final configTx = _configTx;
    if (_control == null) {
      throw const DeviceUnreachableException(
        'Not connected — call connect() before reading config',
      );
    }
    if (configTx == null) {
      throw const DeviceUnreachableException(
        'Device firmware does not support BLE config read (no FF06).',
      );
    }

    // Open the snapshot + reset the cursor. A non-OK ack (no config / OOM)
    // surfaces as CommandRefusedException via _sendCommand.
    await _sendCommand(_cmdConfigReadBegin);

    final bytes = <int>[];
    // Guard: at ≥1 byte per non-empty read and an 8 KB device cap, the loop
    // terminates well before this. The bound prevents a misbehaving device
    // from hanging the pull.
    const maxReads = 1024;
    try {
      for (var i = 0; i < maxReads; i++) {
        final chunk = await configTx.read();
        if (chunk.isEmpty) break; // EOF
        bytes.addAll(chunk);
      }
    } on FlutterBluePlusException catch (e) {
      throw DeviceUnreachableException('BLE config read failed: $e');
    } on Exception catch (e) {
      throw DeviceUnreachableException('BLE config read failed: $e');
    }

    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const DeviceUnreachableException(
          'Device returned a non-object config',
        );
      }
      return decoded;
    } on FormatException catch (e) {
      throw DeviceUnreachableException('Device config is not valid JSON: $e');
    }
  }

  /// Sends CMD_CALIBRATE_IMU (0x05) to the Control characteristic.
  ///
  /// The device collects ~5 s of static samples. See §7.2 and §11.
  @override
  Future<void> calibrate() => _sendCommand(_cmdCalibrateImu);

  /// Sends a single-byte control command to the Control characteristic.
  ///
  /// Throws [CommandRefusedException] if the device returned a non-zero ATT
  /// result code (e.g., the WiFi/logging mutex refused the command).
  /// Throws [DeviceUnreachableException] if not connected, the device
  /// disconnected mid-write, or any other transport-level failure occurred.
  Future<void> _sendCommand(int byte) async {
    if (_control == null) {
      throw const DeviceUnreachableException(
        'Not connected — call connect() before sending commands',
      );
    }
    try {
      await _control!.write([byte], withoutResponse: false);
    } on FlutterBluePlusException catch (e) {
      // flutter_blue_plus surfaces the platform error code via `e.code`.
      // On Android, a GATT write failure returns the ATT status byte from
      // onCharacteristicWrite — which is exactly the ack code our firmware
      // emits (see ack.dart for the registered values).
      final att = _extractAttCode(e);
      if (att != null && att != kIdl0AckOk) {
        throw CommandRefusedException(
          attCode: att,
          command: byte,
          reason: defaultAckReason(att, byte),
        );
      }
      throw DeviceUnreachableException('BLE write failed: $e');
    } on Exception catch (e) {
      throw DeviceUnreachableException('BLE write failed: $e');
    }
  }

  /// Parses the ATT result code byte out of a [FlutterBluePlusException].
  ///
  /// Restricts to the registered IDL0_ACK_* set (0x00, 0x03, 0x80, 0x81,
  /// 0x82) on BOTH the structured `e.code` path and the regex fallback.
  /// Without this restriction, generic Android GATT errors that happen to
  /// be in `0..0xFF` (e.g., GATT_INSUFFICIENT_AUTHENTICATION = 0x05,
  /// GATT_INSUFFICIENT_AUTHORIZATION = 0x08, BLE_ERR_REMOTE_USER_TERM =
  /// 0x16) would be misclassified as `CommandRefusedException("Device
  /// refused command (0x05)")` instead of being surfaced as a real
  /// transport error.
  ///
  /// Returns null when the error is not a recognised IDL0 ACK refusal —
  /// the caller then surfaces a [DeviceUnreachableException] instead.
  int? _extractAttCode(FlutterBluePlusException e) {
    // Only writeCharacteristic errors carry ATT result codes.
    if (e.function != 'writeCharacteristic') return null;

    const known = {
      kIdl0AckOk,
      kIdl0AckMutexRefused,
      kIdl0AckBusy,
      kIdl0AckPrecondition,
      kIdl0AckNotImplemented,
    };

    // Primary: structured code from the plugin (Android GATT status byte).
    final code = e.code;
    if (code != null && known.contains(code)) return code;

    // Fallback: regex against the description string (iOS / other platforms
    // where the byte may be embedded in free-form text).
    final desc = e.description?.toLowerCase();
    if (desc == null) return null;
    final match = _kAttRegex.firstMatch(desc);
    if (match == null) return null;
    final parsed = int.parse(match.group(1)!, radix: 16);
    return known.contains(parsed) ? parsed : null;
  }

  /// Turns the device WiFi AP on. See §7.2 CMD_WIFI_ON.
  @override
  Future<void> wifiOn() => _sendCommand(_cmdWifiOn);

  /// Turns the device WiFi AP off. See §7.2 CMD_WIFI_OFF.
  @override
  Future<void> wifiOff() => _sendCommand(_cmdWifiOff);

  /// Commits the running OTA image. See §7.2 CMD_OTA_CONFIRM.
  ///
  /// Sent only after the app has reconnected following an OTA boot AND the
  /// device's status string still shows `OTA: PENDING_VERIFY`. Until this
  /// lands the bootloader will roll back on any reboot.
  @override
  Future<void> confirmOta() => _sendCommand(_cmdOtaConfirm);

  /// Starts a recording session on the device. See §7.2 CMD_START_LOGGING.
  Future<void> startLogging() => _sendCommand(_cmdStartLogging);

  /// Stops the active recording session. See §7.2 CMD_STOP_LOGGING.
  Future<void> stopLogging() => _sendCommand(_cmdStopLogging);

  /// Triggers IMU calibration on the device. See §7.2 CMD_CALIBRATE_IMU.
  ///
  /// Precondition: bike must be stationary and upright (see §11).
  Future<void> calibrateImu() => _sendCommand(_cmdCalibrateImu);

  /// Releases the status + connection-lost streams. Call after [disconnect].
  Future<void> dispose() async {
    await disconnect();
    await _statusController.close();
    await _connectionLostController.close();
  }
}
