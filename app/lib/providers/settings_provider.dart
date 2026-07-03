import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/app_settings.dart';
import '../transport/firmware_catalog.dart';

// ---------------------------------------------------------------------------
// shared_preferences keys
// ---------------------------------------------------------------------------

const _kRiderName = 'rider_name';
const _kUnitSystem = 'unit_system';
const _kAutoSync = 'auto_sync_on_download';
const _kWifiOnly = 'sync_on_wifi_only';
const _kAutoSyncOnOpen = 'auto_sync_on_open';
const _kFirmwareChannel = 'firmware_channel';
const _kAutoCheckFirmware = 'auto_check_firmware';

// ---------------------------------------------------------------------------
// SettingsNotifier
// ---------------------------------------------------------------------------

/// Manages persistent user preferences backed by shared_preferences. See §24.
///
/// State starts at [AppSettings.defaults] immediately and is updated once
/// the stored values are loaded asynchronously on construction.
class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    _load();
    return AppSettings.defaults();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final systemIndex = prefs.getInt(_kUnitSystem) ?? 0;
    state = AppSettings(
      riderName: prefs.getString(_kRiderName) ?? '',
      unitSystem:
          UnitSystem.values[systemIndex.clamp(0, UnitSystem.values.length - 1)],
      autoSyncOnDownload: prefs.getBool(_kAutoSync) ?? true,
      syncOnWifiOnly: prefs.getBool(_kWifiOnly) ?? true,
      autoSyncOnOpen: prefs.getBool(_kAutoSyncOnOpen) ?? false,
      firmwareChannel: FirmwareChannel.values[
          (prefs.getInt(_kFirmwareChannel) ?? 0)
              .clamp(0, FirmwareChannel.values.length - 1)],
      autoCheckFirmware: prefs.getBool(_kAutoCheckFirmware) ?? true,
    );
  }

  /// Updates the rider name and persists it immediately.
  Future<void> setRiderName(String name) async {
    state = state.copyWith(riderName: name);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRiderName, name);
  }

  /// Updates the unit system preference and persists it immediately.
  Future<void> setUnitSystem(UnitSystem system) async {
    state = state.copyWith(unitSystem: system);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kUnitSystem, system.index);
  }

  /// Updates the auto-sync preference and persists it immediately.
  Future<void> setAutoSyncOnDownload(bool value) async {
    state = state.copyWith(autoSyncOnDownload: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoSync, value);
  }

  /// Updates the WiFi-only sync preference and persists it immediately.
  Future<void> setSyncOnWifiOnly(bool value) async {
    state = state.copyWith(syncOnWifiOnly: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kWifiOnly, value);
  }

  /// Persists [value] for whether the Sync screen auto-starts downloads.
  Future<void> setAutoSyncOnOpen(bool value) async {
    state = state.copyWith(autoSyncOnOpen: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoSyncOnOpen, value);
  }

  /// Persists the OTA firmware [channel] and updates state immediately.
  Future<void> setFirmwareChannel(FirmwareChannel channel) async {
    state = state.copyWith(firmwareChannel: channel);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kFirmwareChannel, channel.index);
  }

  /// Persists whether the app auto-checks for firmware updates.
  Future<void> setAutoCheckFirmware(bool value) async {
    state = state.copyWith(autoCheckFirmware: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoCheckFirmware, value);
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// User preferences provider. See §24 and §17.
final settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
