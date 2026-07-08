// Abstract BLE service interface and production stub. See §7.
//
// The real implementation lives in [BleConnection]. It will be wired in
// during the BLE integration pass by overriding [bleServiceProvider].
// Test doubles live in `test/helpers/mock_ble_service.dart`.
import 'dart:convert';

// ---------------------------------------------------------------------------
// DeviceStatus
// ---------------------------------------------------------------------------

/// Parsed snapshot of the IDL0 Status characteristic. See §7.3.
///
/// The characteristic value is UTF-8 text, newline-delimited:
/// ```
/// WiFi: ON
/// Logging: RUNNING
/// Battery: 85%
/// SD: OK
/// GPS: FIX
/// IMU: PARTIAL
/// ```
/// The firmware emits the `WiFi` / `Logging` / `Battery` lines from P4
/// onward; the `SD` / `GPS` / `IMU` sensor lines arrive as those
/// subsystems land (P5–P7). Lines are parsed case-insensitively. Absent
/// lines leave their field at the default (`false` / `0` / `null`), so a
/// partial status update is always safe to use.
class DeviceStatus {
  /// Whether the device WiFi AP is currently active.
  final bool wifiOn;

  /// Whether the device is actively writing a log session.
  final bool loggingRunning;

  /// Battery level 0–100 %. 0 when the field is absent or unparseable.
  final int batteryPercent;

  /// SD-card state per §7.3 (e.g. `OK`, `FULL`, `MISSING`), uppercased.
  /// `null` when the firmware has not emitted an `SD:` line yet.
  final String? sdState;

  /// GPS state per §7.3 (e.g. `FIX`, `NO FIX`, `SEARCHING`), uppercased.
  /// `null` when the firmware has not emitted a `GPS:` line yet.
  final String? gpsState;

  /// IMU state per §7.3 (e.g. `OK`, `PARTIAL`, `FAIL`), uppercased.
  /// `null` when the firmware has not emitted an `IMU:` line yet.
  final String? imuState;

  /// Running firmware version per §7.3 `Firmware:` line (e.g. `1.5.0`).
  /// `null` when the firmware is too old to emit the line. Raw string —
  /// the app parses it as semver where needed (§27.7).
  final String? firmwareVersion;

  /// True when the device boot is awaiting OTA commit.
  ///
  /// Set when the §7.3 status string contains `OTA: PENDING_VERIFY`. The
  /// firmware emits this line only after an OTA boot and drops it once
  /// the app sends `CMD_OTA_CONFIRM`. Any other value for the `OTA:` line
  /// (or no line at all) reads as `false`. See §7.2 and §7.3.
  final bool otaPendingVerify;

  /// Raw `HR:` line value per §7.3 (e.g. `ABSENT`, `SEARCHING`,
  /// `CONNECTED 142`, `NO_CONTACT 142`, `SUSPENDED`), uppercased.
  /// `null` when the firmware has not emitted an `HR:` line yet.
  final String? hr;

  /// Heart-rate-monitor battery level 0–100 %, parsed from the §7.3
  /// `HR_Battery:` line. `null` until the firmware has read the strap's
  /// battery (one-shot read on connect per Spec 2).
  final int? hrBatteryPercent;

  /// Creates a [DeviceStatus].
  const DeviceStatus({
    required this.wifiOn,
    required this.loggingRunning,
    required this.batteryPercent,
    this.sdState,
    this.gpsState,
    this.imuState,
    this.firmwareVersion,
    this.otaPendingVerify = false,
    this.hr,
    this.hrBatteryPercent,
  });

  /// Parses a [DeviceStatus] from the raw bytes of the Status characteristic.
  ///
  /// Bytes are decoded as UTF-8 then split on newlines. Each line is matched
  /// case-insensitively against `WiFi:`, `Logging:`, `Battery:`, `SD:`,
  /// `GPS:`, and `IMU:` prefixes. Unrecognised lines are silently ignored.
  factory DeviceStatus.fromCharacteristicValue(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    return DeviceStatus._parse(text);
  }

  /// Parses a [DeviceStatus] from a plain UTF-8 status string.
  ///
  /// Exposed for unit testing without needing raw bytes.
  factory DeviceStatus.fromString(String text) => DeviceStatus._parse(text);

  static DeviceStatus _parse(String text) {
    var wifiOn = false;
    var loggingRunning = false;
    var batteryPercent = 0;
    String? sdState;
    String? gpsState;
    String? imuState;
    String? firmwareVersion;
    var otaPendingVerify = false;
    String? hr;
    int? hrBatteryPercent;

    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final lower = trimmed.toLowerCase();

      // Order matters: hr_battery: must be checked before hr: since both
      // start with 'hr'.
      if (lower.startsWith('hr_battery:')) {
        final digits = RegExp(r'(\d+)').firstMatch(trimmed);
        if (digits != null) {
          hrBatteryPercent = int.parse(digits.group(1)!).clamp(0, 100);
        }
      } else if (lower.startsWith('hr:')) {
        hr = _lineValue(trimmed);
      } else if (lower.startsWith('wifi:')) {
        wifiOn = lower.contains('on');
      } else if (lower.startsWith('logging:')) {
        loggingRunning = lower.contains('running');
      } else if (lower.startsWith('battery:')) {
        final digits = RegExp(r'(\d+)').firstMatch(trimmed);
        if (digits != null) {
          batteryPercent = int.parse(digits.group(1)!).clamp(0, 100);
        }
      } else if (lower.startsWith('sd:')) {
        sdState = _lineValue(trimmed);
      } else if (lower.startsWith('gps:')) {
        gpsState = _lineValue(trimmed);
      } else if (lower.startsWith('imu:')) {
        imuState = _lineValue(trimmed);
      } else if (lower.startsWith('firmware:')) {
        firmwareVersion = _firmwareLineValue(trimmed);
      } else if (lower.startsWith('ota:')) {
        otaPendingVerify = _lineValue(trimmed) == 'PENDING_VERIFY';
      }
    }

    return DeviceStatus(
      wifiOn: wifiOn,
      loggingRunning: loggingRunning,
      batteryPercent: batteryPercent,
      sdState: sdState,
      gpsState: gpsState,
      imuState: imuState,
      firmwareVersion: firmwareVersion,
      otaPendingVerify: otaPendingVerify,
      hr: hr,
      hrBatteryPercent: hrBatteryPercent,
    );
  }

  /// Extracts the value after the first `:` of a `Key: VALUE` line and
  /// normalises it to uppercase. Returns `null` if the value is empty.
  static String? _lineValue(String trimmedLine) {
    final colon = trimmedLine.indexOf(':');
    if (colon < 0) return null;
    final value = trimmedLine.substring(colon + 1).trim().toUpperCase();
    return value.isEmpty ? null : value;
  }

  /// Extracts the value after the first `:` without changing case — semver
  /// versions are case-sensitive in their pre-release component, so the
  /// uppercasing [_lineValue] would corrupt e.g. `1.6.0-beta.1`.
  ///
  /// Strips a single leading `v` so a local git-describe build — which reports
  /// the tag name verbatim, e.g. `v0.1.0` — normalises to the same semver the
  /// release side compares against: the version of record is the tag with its
  /// `v` stripped (§27.7), and this mirrors the catalog's release-tag parsing.
  /// Keeping the stored value `v`-free also stops the Device-hero readout
  /// (which renders `v$firmwareVersion`, §23.10) from showing a doubled `vv`.
  static String? _firmwareLineValue(String trimmedLine) {
    final colon = trimmedLine.indexOf(':');
    if (colon < 0) return null;
    var value = trimmedLine.substring(colon + 1).trim();
    if (value.startsWith('v')) value = value.substring(1);
    return value.isEmpty ? null : value;
  }

  @override
  String toString() =>
      'DeviceStatus(wifi=$wifiOn, logging=$loggingRunning, '
      'battery=$batteryPercent%, sd=$sdState, gps=$gpsState, imu=$imuState, '
      'otaPendingVerify=$otaPendingVerify)';
}

/// Abstract interface for BLE device operations used by [DeviceNotifier].
///
/// All operations map to BLE Control characteristic commands. See §7.2.
abstract class BleService {
  /// Scans for and connects to the nearest IDL0 device.
  ///
  /// Returns device name (e.g. `IDL0-A3F2`) and battery level (0–100 %).
  /// Throws [DeviceNotFoundException] if no device is found within timeout.
  Future<({String name, int batteryPercent})> connect();

  /// Stream of parsed device status updates. See §7.3.
  ///
  /// Emits whenever the device pushes a Status-characteristic notification,
  /// plus once with the initial value read at connect time.
  Stream<DeviceStatus> get statusStream;

  /// Emits exactly once per unexpected BLE link drop (out of range, device
  /// reset, OTA reboot, etc.). Does NOT emit when the app calls
  /// [disconnect] itself — that's the user-initiated path and there's no
  /// need to surface it.
  ///
  /// Consumers (e.g. [DeviceNotifier]) reset their connection state on
  /// each event. Broadcast stream — safe to listen multiple times.
  Stream<void> get connectionLost;

  /// Disconnects from the currently connected device.
  Future<void> disconnect();

  /// Sends CMD_START_LOGGING (0x03) to the BLE Control characteristic.
  Future<void> startRecording();

  /// Sends CMD_STOP_LOGGING (0x04) to the BLE Control characteristic.
  Future<void> stopRecording();

  /// Pushes [config] as JSON to the device via WiFi POST /config.
  ///
  /// [config] must match the §8 schema. Always user-initiated.
  Future<void> pushConfig(Map<String, dynamic> config);

  /// Pushes [config] to the device entirely over BLE (FF05 + CONFIG_BEGIN/
  /// COMMIT, §7.2), then reboots the device to apply it. No WiFi changeover.
  ///
  /// Preferred over [pushConfig]: BLE is more reliable than the SoftAP and
  /// skips the WiFi-mode overhead. [config] must match the §8 schema. Always
  /// user-initiated. The caller follows up with reconnect-after-reboot.
  Future<void> pushConfigBle(Map<String, dynamic> config);

  /// Reads the device's live `idl0_config.json` back over BLE and decodes it
  /// (FF06 + CONFIG_READ_BEGIN, §7.2). Used to round-trip / verify a push.
  Future<Map<String, dynamic>> pullConfigBle();

  /// Sends CMD_CALIBRATE_IMU (0x05) to the BLE Control characteristic.
  ///
  /// The device collects ~5 s of static samples. See §7.2 and §11.
  Future<void> calibrate();

  /// Sends CMD_WIFI_ON (0x01) to the BLE Control characteristic.
  ///
  /// Activates the device WiFi AP. The Data tab's file-transfer panel calls
  /// this once when it opens so subsequent `/files`, `/download`, and
  /// `/delete` requests reach an AP that is actually up — without this the
  /// panel relies on a prior `pushConfig` having flipped the AP on. See §7.2.
  Future<void> wifiOn();

  /// Sends CMD_WIFI_OFF (0x02) to the BLE Control characteristic.
  ///
  /// Tells the device to tear down its WiFi AP. Paired with [wifiOn] by the
  /// file-transfer panel's disposal path. See §7.2.
  Future<void> wifiOff();

  /// Sends CMD_OTA_CONFIRM (0x06) to the BLE Control characteristic.
  ///
  /// After an OTA boot the new image runs in `PENDING_VERIFY` — the
  /// §7.3 status string carries `OTA: PENDING_VERIFY` until this command
  /// commits the new slot. If the device reboots before this lands, the
  /// bootloader rolls back to the previous slot automatically. See §7.2.
  Future<void> confirmOta();
}

/// Production stub — throws [UnimplementedError] on every method.
///
/// Used until the BLE integration pass wires in the real [BleConnection].
class StubBleService implements BleService {
  @override
  Future<({String name, int batteryPercent})> connect() =>
      throw UnimplementedError();

  @override
  Stream<DeviceStatus> get statusStream => const Stream.empty();

  @override
  Stream<void> get connectionLost => const Stream.empty();

  @override
  Future<void> disconnect() => throw UnimplementedError();

  @override
  Future<void> startRecording() => throw UnimplementedError();

  @override
  Future<void> stopRecording() => throw UnimplementedError();

  @override
  Future<void> pushConfig(Map<String, dynamic> config) =>
      throw UnimplementedError();

  @override
  Future<void> pushConfigBle(Map<String, dynamic> config) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> pullConfigBle() => throw UnimplementedError();

  @override
  Future<void> calibrate() => throw UnimplementedError();

  @override
  Future<void> wifiOn() => throw UnimplementedError();

  @override
  Future<void> wifiOff() => throw UnimplementedError();

  @override
  Future<void> confirmOta() => throw UnimplementedError();
}
