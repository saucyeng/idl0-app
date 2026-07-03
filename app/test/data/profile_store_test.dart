import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/bike_profile.dart';
import 'package:idl0/data/profile_store.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('idl0_profile_store_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('ProfileStore', () {
    test('save then loadAll — round-trips a single profile', () async {
      // Arrange
      final store = ProfileStore(baseDir: tmp);
      const profile = BikeProfile(
        profileId: '550e8400-e29b-41d4-a716-446655440000',
        profileName: 'Default',
        createdAtMs: 1716210000000,
        updatedAtMs: 1716210000000,
        config: {'config_version': 1},
      );

      // Act
      await store.save(profile);
      final loaded = await store.loadAll();

      // Assert
      expect(loaded, hasLength(1));
      expect(loaded.first.profileId, profile.profileId);
      expect(loaded.first.profileName, 'Default');
      expect(loaded.first.config['config_version'], 1);
    });

    test('save — atomic — a half-written .tmp file does not corrupt the .idl0p',
        () async {
      // Arrange
      final store = ProfileStore(baseDir: tmp);
      const original = BikeProfile(
        profileId: 'p1',
        profileName: 'orig',
        createdAtMs: 1,
        updatedAtMs: 1,
        config: {'v': 1},
      );
      await store.save(original);
      // Simulate a half-written prior attempt.
      await File('${tmp.path}/p1.idl0p.tmp').writeAsString('garbage');

      // Act
      final updated = original.copyWith(profileName: 'updated', updatedAtMs: 2);
      await store.save(updated);

      // Assert
      final loaded = await store.loadAll();
      expect(loaded.single.profileName, 'updated');
      expect(File('${tmp.path}/p1.idl0p.tmp').existsSync(), isFalse,
          reason: '.tmp file should be renamed away after a successful save',);
    });

    test('loadAll — skips a malformed file and returns the readable rest',
        () async {
      // Arrange
      final store = ProfileStore(baseDir: tmp);
      const good = BikeProfile(
        profileId: 'good',
        profileName: 'good',
        createdAtMs: 1,
        updatedAtMs: 1,
        config: {'v': 1},
      );
      await store.save(good);
      await File('${tmp.path}/bad.idl0p').writeAsString('{not valid json');

      // Act
      final loaded = await store.loadAll();

      // Assert
      expect(loaded.map((p) => p.profileId).toList(), ['good']);
    });

    test('delete — removes the file', () async {
      // Arrange
      final store = ProfileStore(baseDir: tmp);
      const profile = BikeProfile(
        profileId: 'p1',
        profileName: 'name',
        createdAtMs: 1,
        updatedAtMs: 1,
        config: {'v': 1},
      );
      await store.save(profile);

      // Act
      await store.delete('p1');

      // Assert
      expect(await store.loadAll(), isEmpty);
    });

    test('loadAll — returns empty list when baseDir does not exist', () async {
      // Arrange
      final missing = Directory('${tmp.path}/does_not_exist');
      final store = ProfileStore(baseDir: missing);

      // Act
      final loaded = await store.loadAll();

      // Assert
      expect(loaded, isEmpty);
    });

    test('save — creates baseDir on demand', () async {
      // Arrange
      final newDir = Directory('${tmp.path}/fresh');
      final store = ProfileStore(baseDir: newDir);
      const profile = BikeProfile(
        profileId: 'p1',
        profileName: 'n',
        createdAtMs: 1,
        updatedAtMs: 1,
        config: {'v': 1},
      );

      // Act
      await store.save(profile);

      // Assert
      expect(newDir.existsSync(), isTrue);
      expect(File('${newDir.path}/p1.idl0p').existsSync(), isTrue);
    });

    test('loadAll — sorts profiles by profileName ascending', () async {
      // Arrange
      final store = ProfileStore(baseDir: tmp);
      await store.save(const BikeProfile(
          profileId: 'a',
          profileName: 'Zebra',
          createdAtMs: 1,
          updatedAtMs: 1,
          config: {},),);
      await store.save(const BikeProfile(
          profileId: 'b',
          profileName: 'Alpha',
          createdAtMs: 1,
          updatedAtMs: 1,
          config: {},),);
      await store.save(const BikeProfile(
          profileId: 'c',
          profileName: 'Mike',
          createdAtMs: 1,
          updatedAtMs: 1,
          config: {},),);

      // Act
      final loaded = await store.loadAll();

      // Assert
      expect(loaded.map((p) => p.profileName).toList(),
          ['Alpha', 'Mike', 'Zebra'],);
    });
  });
}
