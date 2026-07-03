import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/profile_store.dart';
import 'package:idl0/providers/profile_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('idl0_profile_provider_');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  ProviderContainer makeContainer() => ProviderContainer(overrides: [
        profileStoreOverrideProvider
            .overrideWithValue(ProfileStore(baseDir: tmp)),
      ],);

  group('ProfileNotifier', () {
    test('first launch — creates Default profile and sets it active', () async {
      // Arrange
      final container = makeContainer();
      addTearDown(container.dispose);

      // Act
      final lib = await container.read(profileProvider.future);

      // Assert
      expect(lib.profiles, hasLength(1));
      expect(lib.profiles.single.profileName, 'Default');
      expect(lib.activeProfileId, lib.profiles.single.profileId);
      // The default profile persisted to disk.
      final reloaded = await ProfileStore(baseDir: tmp).loadAll();
      expect(reloaded.single.profileName, 'Default');
    });

    test('first launch — Default profile contains expected §8 keys', () async {
      // Arrange
      final container = makeContainer();
      addTearDown(container.dispose);

      // Act
      final lib = await container.read(profileProvider.future);

      // Assert
      final cfg = lib.profiles.single.config;
      expect(cfg, containsPair('config_version', 1));
      expect(cfg['bike_profile'], isA<Map>());
      expect((cfg['bike_profile'] as Map).containsKey('type'), isFalse,
          reason: 'type is dropped from §8',);
      expect((cfg['bike_profile'] as Map).containsKey('imu_count'), isFalse,
          reason: 'imu_count is dropped from §8',);
      expect((cfg['analog'] as Map)['channels'], isEmpty);
      expect((cfg['digital'] as Map)['channels'], isEmpty);
      expect(((cfg['wheel_speed'] as Map)['front'] as Map)['enabled'], isFalse,
          reason: 'wheel front defaults to disabled',);
      expect(((cfg['wheel_speed'] as Map)['rear'] as Map)['enabled'], isFalse,
          reason: 'wheel rear defaults to disabled',);
    });

    test('create — adds a profile and persists it', () async {
      // Arrange
      final container = makeContainer();
      addTearDown(container.dispose);
      await container.read(profileProvider.future);

      // Act
      final newId =
          await container.read(profileProvider.notifier).create('Race day');

      // Assert
      final lib = await container.read(profileProvider.future);
      expect(lib.profiles.map((p) => p.profileName),
          containsAll(['Default', 'Race day']),);
      final created = lib.profiles.firstWhere((p) => p.profileId == newId);
      expect(created.profileName, 'Race day');
      // Persisted.
      final reloaded = await ProfileStore(baseDir: tmp).loadAll();
      expect(reloaded.map((p) => p.profileName),
          containsAll(['Default', 'Race day']),);
    });

    test('create with duplicateOfId — copies the source config', () async {
      // Arrange
      final container = makeContainer();
      addTearDown(container.dispose);
      final lib = await container.read(profileProvider.future);
      final notifier = container.read(profileProvider.notifier);
      await notifier.updateConfig(
        lib.activeProfileId!,
        {
          'config_version': 1,
          'bike_profile': {'name': 'My Bike'},
        },
      );

      // Act
      final newId =
          await notifier.create('Copy', duplicateOfId: lib.activeProfileId);

      // Assert
      final after = await container.read(profileProvider.future);
      final copy = after.profiles.firstWhere((p) => p.profileId == newId);
      expect((copy.config['bike_profile'] as Map)['name'], 'My Bike');
    });

    test('setActive — persists to SharedPreferences', () async {
      // Arrange
      final container = makeContainer();
      addTearDown(container.dispose);
      await container.read(profileProvider.future);
      final notifier = container.read(profileProvider.notifier);
      final newId = await notifier.create('Race day');

      // Act
      await notifier.setActive(newId);

      // Assert
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('idl0.profiles.active_id'), newId);
      final lib = await container.read(profileProvider.future);
      expect(lib.activeProfileId, newId);
    });

    test('updateConfig — replaces config and bumps updatedAtMs', () async {
      // Arrange
      final container = makeContainer();
      addTearDown(container.dispose);
      final libBefore = await container.read(profileProvider.future);
      final id = libBefore.profiles.single.profileId;
      final originalUpdatedAt = libBefore.profiles.single.updatedAtMs;
      // Sleep briefly so the new timestamp is guaranteed to differ.
      await Future<void>.delayed(const Duration(milliseconds: 5));

      // Act
      await container
          .read(profileProvider.notifier)
          .updateConfig(id, {'config_version': 99});

      // Assert
      final libAfter = await container.read(profileProvider.future);
      final p = libAfter.profiles.firstWhere((x) => x.profileId == id);
      expect(p.config['config_version'], 99);
      expect(p.updatedAtMs, greaterThan(originalUpdatedAt));
    });

    test('rename — changes the name', () async {
      // Arrange
      final container = makeContainer();
      addTearDown(container.dispose);
      final lib = await container.read(profileProvider.future);
      final id = lib.profiles.single.profileId;

      // Act
      await container.read(profileProvider.notifier).rename(id, 'New name');

      // Assert
      final after = await container.read(profileProvider.future);
      expect(after.profiles.single.profileName, 'New name');
    });

    test('delete — refuses to remove the last remaining profile', () async {
      // Arrange
      final container = makeContainer();
      addTearDown(container.dispose);
      final lib = await container.read(profileProvider.future);
      final notifier = container.read(profileProvider.notifier);

      // Act + Assert
      await expectLater(
        notifier.delete(lib.profiles.single.profileId),
        throwsA(isA<StateError>()),
      );
      final after = await container.read(profileProvider.future);
      expect(after.profiles, hasLength(1));
    });

    test('delete — when active deleted, active switches to next profile',
        () async {
      // Arrange
      final container = makeContainer();
      addTearDown(container.dispose);
      final initial = await container.read(profileProvider.future);
      final firstId = initial.profiles.single.profileId;
      final notifier = container.read(profileProvider.notifier);
      final secondId = await notifier.create('Second');
      expect((await container.read(profileProvider.future)).activeProfileId,
          firstId,
          reason: 'first profile is still active by default',);

      // Act
      await notifier.delete(firstId);

      // Assert
      final after = await container.read(profileProvider.future);
      expect(after.profiles, hasLength(1));
      expect(after.activeProfileId, secondId);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('idl0.profiles.active_id'), secondId);
    });

    test('build — migrates legacy on-disk configs and re-saves them', () async {
      // Arrange — write a legacy-shape profile directly to disk before the
      // notifier runs first-launch.
      final legacy = <String, dynamic>{
        'profile_id': 'legacy-1',
        'profile_name': 'Legacy',
        'created_at_ms': 1,
        'updated_at_ms': 1,
        'config': {
          'config_version': 1,
          'bike_profile': {
            'name': 'B',
            'type': 'full_suspension',
            'imu_count': 3,
            'default_rider': 'R',
          },
          'analog': {
            'sample_rate_hz': 100,
            'scaling': {
              'pressure_front': {'units': 'bar', 'scale': 0.5, 'offset': -1.0},
            },
          },
        },
      };
      await File('${tmp.path}/legacy-1.idl0p').writeAsString(
        const JsonEncoder.withIndent('  ').convert(legacy),
      );
      final container = makeContainer();
      addTearDown(container.dispose);

      // Act
      final lib = await container.read(profileProvider.future);

      // Assert — in-memory copy is migrated.
      final loaded = lib.profiles.firstWhere((p) => p.profileId == 'legacy-1');
      expect((loaded.config['bike_profile'] as Map).containsKey('type'), isFalse);
      expect(
          (loaded.config['bike_profile'] as Map).containsKey('imu_count'),
          isFalse,);
      expect((loaded.config['analog'] as Map)['channels'], isA<List>());
      expect((loaded.config['analog'] as Map).containsKey('scaling'), isFalse);
      expect((loaded.config['digital'] as Map)['channels'], isA<List>());

      // Assert — disk file was re-saved with the migrated shape.
      final reloaded = await ProfileStore(baseDir: tmp).loadAll();
      final reloadedLegacy =
          reloaded.firstWhere((p) => p.profileId == 'legacy-1');
      expect((reloadedLegacy.config['bike_profile'] as Map).containsKey('type'),
          isFalse,);
    });
  });
}
