import '../transport/firmware_catalog.dart';

/// Preferred unit system for the entire app. See §24.
///
/// Controls the default unit applied when the user picks a [MathQuantity]
/// in the Maths tab. Does not retroactively convert existing channel values.
enum UnitSystem {
  /// Imperial conventions: mph, ft/mi, psi, °F, lbf, hp, lb/in.
  imperial,

  /// Metric (SI) conventions: km/h, m/km, kPa, °C, N, W, N/mm.
  metric,
}

/// Immutable user preferences persisted via shared_preferences. See §24.
class AppSettings {
  /// Rider display name pre-filled into new session metadata. Default: `''`.
  final String riderName;

  /// Preferred unit system — controls default units for new math channels.
  /// Default: [UnitSystem.imperial].
  final UnitSystem unitSystem;

  /// When `true`, Drive upload is queued automatically after each download.
  /// Default: `true`.
  final bool autoSyncOnDownload;

  /// When `true`, Drive sync is restricted to WiFi connections only.
  /// Default: `true`.
  final bool syncOnWifiOnly;

  /// "Connect and forget": when `true`, opening the Sync screen downloads all
  /// new files automatically. Default `false` — the screen opens as an
  /// unchecked file picker so a fresh device doesn't pull everything at once.
  final bool autoSyncOnOpen;

  /// Firmware release channel the OTA update check follows. Default
  /// [FirmwareChannel.stable]. See §27.7.
  final FirmwareChannel firmwareChannel;

  /// When `true`, the app checks for a newer firmware build on connect / open
  /// and shows the update banner. Default `true`. See §27.7.
  final bool autoCheckFirmware;

  /// Creates an [AppSettings].
  const AppSettings({
    required this.riderName,
    required this.unitSystem,
    required this.autoSyncOnDownload,
    required this.syncOnWifiOnly,
    required this.autoSyncOnOpen,
    this.firmwareChannel = FirmwareChannel.stable,
    this.autoCheckFirmware = true,
  });

  /// Returns the out-of-the-box defaults used before the user changes anything.
  factory AppSettings.defaults() => const AppSettings(
        riderName: '',
        unitSystem: UnitSystem.imperial,
        autoSyncOnDownload: true,
        syncOnWifiOnly: true,
        autoSyncOnOpen: false,
        firmwareChannel: FirmwareChannel.stable,
        autoCheckFirmware: true,
      );

  /// Returns a copy with the given fields replaced.
  AppSettings copyWith({
    String? riderName,
    UnitSystem? unitSystem,
    bool? autoSyncOnDownload,
    bool? syncOnWifiOnly,
    bool? autoSyncOnOpen,
    FirmwareChannel? firmwareChannel,
    bool? autoCheckFirmware,
  }) =>
      AppSettings(
        riderName: riderName ?? this.riderName,
        unitSystem: unitSystem ?? this.unitSystem,
        autoSyncOnDownload: autoSyncOnDownload ?? this.autoSyncOnDownload,
        syncOnWifiOnly: syncOnWifiOnly ?? this.syncOnWifiOnly,
        autoSyncOnOpen: autoSyncOnOpen ?? this.autoSyncOnOpen,
        firmwareChannel: firmwareChannel ?? this.firmwareChannel,
        autoCheckFirmware: autoCheckFirmware ?? this.autoCheckFirmware,
      );
}
