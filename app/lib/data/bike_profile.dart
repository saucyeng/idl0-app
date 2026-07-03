import 'dart:convert';

import 'exceptions.dart';

/// One bike-specific configuration profile. See §23.
///
/// The `config` sub-object is the §8 payload that gets pushed to the device
/// verbatim; the other fields are app-side metadata that stay out of the push.
///
/// Stored as JSON files at `<docs>/profiles/<profile_id>.idl0p`.
class BikeProfile {
  /// Stable UUID identifying this profile across renames.
  final String profileId;

  /// User-facing name shown in the profile picker.
  final String profileName;

  /// Profile creation time, UTC milliseconds since epoch.
  final int createdAtMs;

  /// Last-modified time, UTC milliseconds since epoch. Bumped by every
  /// mutation through [ProfileNotifier.updateConfig].
  final int updatedAtMs;

  /// The §8 config payload — pushed verbatim as `idl0_config.json`.
  final Map<String, dynamic> config;

  /// Creates a [BikeProfile].
  const BikeProfile({
    required this.profileId,
    required this.profileName,
    required this.createdAtMs,
    required this.updatedAtMs,
    required this.config,
  });

  /// Parses a [BikeProfile] from the JSON shape written to disk.
  ///
  /// Throws [ProfileParseException] when `profile_id` is missing or empty,
  /// or when `config` is missing / not a JSON object.
  factory BikeProfile.fromJson(Map<String, dynamic> json) {
    final id = json['profile_id'];
    if (id is! String || id.isEmpty) {
      throw ProfileParseException(
        'profile_id missing or not a non-empty string',
      );
    }
    final cfg = json['config'];
    if (cfg is! Map<String, dynamic>) {
      throw ProfileParseException('config missing or not an object');
    }
    return BikeProfile(
      profileId: id,
      profileName: (json['profile_name'] as String?) ?? '',
      createdAtMs: (json['created_at_ms'] as int?) ?? 0,
      updatedAtMs: (json['updated_at_ms'] as int?) ?? 0,
      config: cfg,
    );
  }

  /// Serialises the profile to the on-disk JSON shape.
  Map<String, dynamic> toJson() => {
        'profile_id': profileId,
        'profile_name': profileName,
        'created_at_ms': createdAtMs,
        'updated_at_ms': updatedAtMs,
        'config': config,
      };

  /// Returns a new [BikeProfile] with the given fields replaced.
  ///
  /// `profileId` and `createdAtMs` are immutable across the lifetime of a
  /// profile — neither can be changed via this method.
  BikeProfile copyWith({
    String? profileName,
    int? updatedAtMs,
    Map<String, dynamic>? config,
  }) =>
      BikeProfile(
        profileId: profileId,
        profileName: profileName ?? this.profileName,
        createdAtMs: createdAtMs,
        updatedAtMs: updatedAtMs ?? this.updatedAtMs,
        config: config ?? this.config,
      );

  /// One-shot migration: bring a legacy §8 config to the new shape.
  ///
  /// Drops `bike_profile.type` and `bike_profile.imu_count`. Converts the
  /// legacy `analog.scaling.{pressure_front, pressure_rear}` map into an
  /// ordered `analog.channels[]` array. Ensures `digital.channels[]` exists.
  /// Idempotent — an already-migrated config returns unchanged.
  static Map<String, dynamic> migrateLegacyConfig(Map<String, dynamic> raw) {
    final out = _deepCopy(raw);

    // Drop bike_profile.type / imu_count.
    final bp = out['bike_profile'];
    if (bp is Map<String, dynamic>) {
      bp.remove('type');
      bp.remove('imu_count');
    }

    // Convert analog.scaling map -> analog.channels[] array.
    final analog = out['analog'];
    if (analog is Map<String, dynamic>) {
      if (analog['scaling'] is Map) {
        final scaling = analog.remove('scaling') as Map<String, dynamic>;
        final frontEnabled = analog.remove('pressure_front_enabled') ?? true;
        final rearEnabled = analog.remove('pressure_rear_enabled') ?? true;
        analog['channels'] = [
          for (final entry in scaling.entries)
            <String, dynamic>{
              'key': entry.key,
              'label': entry.key,
              'adc_pin': 0,
              'units': (entry.value as Map)['units'] ?? '',
              'scale': (entry.value as Map)['scale'] ?? 1.0,
              'offset': (entry.value as Map)['offset'] ?? 0.0,
              'enabled':
                  entry.key == 'pressure_front' ? frontEnabled : rearEnabled,
            },
        ];
      }
      analog.putIfAbsent('channels', () => <Map<String, dynamic>>[]);
    }

    // Ensure digital.channels exists.
    final digital = out['digital'];
    if (digital is Map<String, dynamic>) {
      digital.putIfAbsent('channels', () => <Map<String, dynamic>>[]);
    } else {
      out['digital'] = <String, dynamic>{
        'channels': <Map<String, dynamic>>[],
      };
    }

    return out;
  }

  static Map<String, dynamic> _deepCopy(Map<String, dynamic> input) =>
      jsonDecode(jsonEncode(input)) as Map<String, dynamic>;
}
