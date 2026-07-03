import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../data/bike_profile.dart';
import '../data/profile_store.dart';

/// Default §8 config seed for the first-launch "Default" profile.
///
/// Mirrors the schema in `docs/IDL0_SPEC.md §8`, minus the calibration-managed
/// `imu.orientation` / `imu.bias` fields (those are written by the calibration
/// routine, never by the user). Wheel speed defaults disabled; analog and
/// digital channel arrays start empty so users add channels as they wire up
/// hardware.
const Map<String, dynamic> _kDefaultConfig = {
  'config_version': 1,
  'device_id': '',
  'bike_profile': {'name': '', 'default_rider': ''},
  'imu': {
    'sample_rate_hz': 833,
    'accel_range_g': 32,
    'gyro_range_dps': 2000,
    'low_power_mode': false,
    'high_performance_mode': true,
    'imu0': {
      'enabled': true,
      'accel_range_g': 32,
      'gyro_range_dps': 2000,
      'channels': {
        'accel_x': true,
        'accel_y': true,
        'accel_z': true,
        'gyro_x': true,
        'gyro_y': true,
        'gyro_z': false,
      },
    },
    'imu1': {
      'enabled': true,
      'accel_range_g': 16,
      'gyro_range_dps': 500,
      'channels': {
        'accel_x': true,
        'accel_y': true,
        'accel_z': true,
        'gyro_x': false,
        'gyro_y': false,
        'gyro_z': false,
      },
    },
    'imu2': {
      'enabled': true,
      'accel_range_g': 16,
      'gyro_range_dps': 500,
      'channels': {
        'accel_x': true,
        'accel_y': true,
        'accel_z': true,
        'gyro_x': false,
        'gyro_y': false,
        'gyro_z': false,
      },
    },
  },
  'gps': {
    'sample_rate_hz': 5,
    'dynamic_model': 'automotive',
    'nmea_sentences': ['GGA', 'RMC'],
    'sbas_enabled': true,
  },
  'wheel_speed': {
    'front': {
      'enabled': false,
      'points_per_revolution': 12,
      'wheel_circumference_mm': 2300,
    },
    'rear': {
      'enabled': false,
      'points_per_revolution': 12,
      'wheel_circumference_mm': 2300,
    },
  },
  'analog': {'sample_rate_hz': 100, 'channels': <Map<String, dynamic>>[]},
  'digital': {'channels': <Map<String, dynamic>>[]},
};

/// SharedPreferences key holding the active profile's id.
const _kActivePrefsKey = 'idl0.profiles.active_id';

/// The full profile library plus the currently-active id.
class ProfileLibrary {
  /// Creates a [ProfileLibrary].
  const ProfileLibrary({
    required this.profiles,
    required this.activeProfileId,
  });

  /// All known profiles. Sorted by name (per [ProfileStore.loadAll]).
  final List<BikeProfile> profiles;

  /// The currently active profile id, or `null` if [profiles] is empty.
  final String? activeProfileId;

  /// The [BikeProfile] matching [activeProfileId], or `null` if not found.
  BikeProfile? get activeProfile {
    if (activeProfileId == null) return null;
    for (final p in profiles) {
      if (p.profileId == activeProfileId) return p;
    }
    return null;
  }
}

/// Test seam — provide a custom [ProfileStore] (e.g. backed by a temp dir).
final profileStoreOverrideProvider = Provider<ProfileStore?>((_) => null);

/// Manages the profile library: loads from disk, persists changes, tracks
/// the active profile id.
class ProfileNotifier extends AsyncNotifier<ProfileLibrary> {
  static const _uuid = Uuid();

  late ProfileStore _store;

  @override
  Future<ProfileLibrary> build() async {
    _store = ref.read(profileStoreOverrideProvider) ??
        ProfileStore(baseDir: await _defaultProfilesDir());
    final loaded = await _store.loadAll();
    final prefs = await SharedPreferences.getInstance();

    if (loaded.isEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final created = BikeProfile(
        profileId: _uuid.v4(),
        profileName: 'Default',
        createdAtMs: now,
        updatedAtMs: now,
        config: _cloneJson(_kDefaultConfig),
      );
      await _store.save(created);
      await prefs.setString(_kActivePrefsKey, created.profileId);
      return ProfileLibrary(
        profiles: [created],
        activeProfileId: created.profileId,
      );
    }

    // Migrate any legacy-shape configs on load and re-save when changed.
    final out = <BikeProfile>[];
    for (final p in loaded) {
      final migrated = BikeProfile.migrateLegacyConfig(p.config);
      if (!_jsonEqual(migrated, p.config)) {
        final updated = p.copyWith(
          config: migrated,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
        await _store.save(updated);
        out.add(updated);
      } else {
        out.add(p);
      }
    }

    var active = prefs.getString(_kActivePrefsKey);
    if (active == null || !out.any((p) => p.profileId == active)) {
      active = out.first.profileId;
      await prefs.setString(_kActivePrefsKey, active);
    }
    return ProfileLibrary(profiles: out, activeProfileId: active);
  }

  /// Creates a new profile and persists it.
  ///
  /// If [duplicateOfId] is provided, the new profile's `config` is a deep
  /// copy of that source profile's config. Otherwise it's seeded from the
  /// spec defaults.
  ///
  /// Returns the new profile's id. Does **not** automatically set the new
  /// profile active — callers do that explicitly via [setActive] when
  /// appropriate.
  Future<String> create(String name, {String? duplicateOfId}) async {
    final lib = await future;
    final now = DateTime.now().millisecondsSinceEpoch;
    final sourceConfig = duplicateOfId == null
        ? _kDefaultConfig
        : lib.profiles.firstWhere((p) => p.profileId == duplicateOfId).config;
    final profile = BikeProfile(
      profileId: _uuid.v4(),
      profileName: name,
      createdAtMs: now,
      updatedAtMs: now,
      config: _cloneJson(sourceConfig),
    );
    await _store.save(profile);
    state = AsyncData(
      ProfileLibrary(
        profiles: [...lib.profiles, profile],
        activeProfileId: lib.activeProfileId,
      ),
    );
    return profile.profileId;
  }

  /// Renames the profile [id] to [name] and persists.
  Future<void> rename(String id, String name) async {
    final lib = await future;
    final updated = lib.profiles.firstWhere((p) => p.profileId == id).copyWith(
          profileName: name,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
    await _store.save(updated);
    state = AsyncData(
      ProfileLibrary(
        profiles:
            lib.profiles.map((p) => p.profileId == id ? updated : p).toList(),
        activeProfileId: lib.activeProfileId,
      ),
    );
  }

  /// Deletes the profile [id]. Throws [StateError] if this would remove
  /// the last remaining profile.
  ///
  /// If [id] is currently active, the active pointer moves to the first
  /// remaining profile (alphabetical order from [ProfileStore]).
  Future<void> delete(String id) async {
    final lib = await future;
    if (lib.profiles.length <= 1) {
      throw StateError('Cannot delete the last profile');
    }
    await _store.delete(id);
    final remaining = lib.profiles.where((p) => p.profileId != id).toList();
    var newActive = lib.activeProfileId;
    if (newActive == id) {
      newActive = remaining.first.profileId;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kActivePrefsKey, newActive);
    }
    state = AsyncData(
      ProfileLibrary(profiles: remaining, activeProfileId: newActive),
    );
  }

  /// Sets [id] as the active profile and persists the choice.
  Future<void> setActive(String id) async {
    final lib = await future;
    if (!lib.profiles.any((p) => p.profileId == id)) {
      throw ArgumentError('No profile with id $id');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kActivePrefsKey, id);
    state =
        AsyncData(ProfileLibrary(profiles: lib.profiles, activeProfileId: id));
  }

  /// Replaces the config of profile [id] and bumps `updatedAtMs`. Persists.
  Future<void> updateConfig(String id, Map<String, dynamic> config) async {
    final lib = await future;
    final updated = lib.profiles.firstWhere((p) => p.profileId == id).copyWith(
          config: _cloneJson(config),
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
    await _store.save(updated);
    state = AsyncData(
      ProfileLibrary(
        profiles:
            lib.profiles.map((p) => p.profileId == id ? updated : p).toList(),
        activeProfileId: lib.activeProfileId,
      ),
    );
  }

  /// Imports a `.idl0p` (or plain JSON) profile file from [path]. Adds it to
  /// the library, replacing any existing entry with the same `profile_id`.
  Future<void> importFromFile(String path) async {
    final lib = await future;
    final text = await File(path).readAsString();
    final raw = jsonDecode(text) as Map<String, dynamic>;
    final imported = BikeProfile.fromJson(raw).copyWith(
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _store.save(imported);
    final without =
        lib.profiles.where((p) => p.profileId != imported.profileId).toList();
    state = AsyncData(
      ProfileLibrary(
        profiles: [...without, imported],
        activeProfileId: lib.activeProfileId,
      ),
    );
  }

  /// Exports profile [id] to [path] as `.idl0p` JSON.
  Future<void> exportToFile(String id, String path) async {
    final lib = await future;
    final p = lib.profiles.firstWhere((x) => x.profileId == id);
    await File(path).writeAsString(
      const JsonEncoder.withIndent('  ').convert(p.toJson()),
    );
  }

  static Future<Directory> _defaultProfilesDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/profiles');
  }

  /// Deep-copies a JSON map via encode/decode. Cheap and safe for the
  /// small (~1-2 KB) config payloads we deal with.
  static Map<String, dynamic> _cloneJson(Map<String, dynamic> input) =>
      jsonDecode(jsonEncode(input)) as Map<String, dynamic>;

  /// Structural JSON equality via canonical encoding.
  static bool _jsonEqual(Map<String, dynamic> a, Map<String, dynamic> b) =>
      jsonEncode(a) == jsonEncode(b);
}

/// The profile library — `AsyncNotifierProvider`.
final profileProvider =
    AsyncNotifierProvider<ProfileNotifier, ProfileLibrary>(ProfileNotifier.new);
