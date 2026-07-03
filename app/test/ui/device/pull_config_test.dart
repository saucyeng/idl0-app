import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/profile_store.dart';
import 'package:idl0/providers/device_provider.dart' show bleServiceProvider;
import 'package:idl0/providers/profile_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/mock_ble_service.dart';

void main() {
  test('pullConfigBle result becomes a new library profile', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('idl0_pull_');
    addTearDown(() => dir.delete(recursive: true));

    final mock = MockBleService()
      ..lastPushedConfig = {
        'config_version': 1,
        'bike_profile': {'name': 'Pulled Bike'},
      };
    SharedPreferences.setMockInitialValues(const {});

    final container = ProviderContainer(overrides: [
      bleServiceProvider.overrideWithValue(mock),
      profileStoreOverrideProvider.overrideWithValue(ProfileStore(baseDir: dir)),
    ],);
    addTearDown(container.dispose);

    // Seed the library (creates the Default profile on first load).
    final before = (await container.read(profileProvider.future)).profiles.length;

    // The flow the Pull button performs: read live config, create a profile,
    // write the pulled config into it.
    final live = await container.read(bleServiceProvider).pullConfigBle();
    final notifier = container.read(profileProvider.notifier);
    final id = await notifier.create('Pulled');
    await notifier.updateConfig(id, live);

    final lib = await container.read(profileProvider.future);
    expect(lib.profiles.length, before + 1);
    final created = lib.profiles.firstWhere((p) => p.profileId == id);
    expect(created.config['bike_profile'], equals({'name': 'Pulled Bike'}));
  });
}
