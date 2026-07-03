import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/bike_profile.dart';
import 'package:idl0/data/profile_store.dart';
import 'package:idl0/providers/profile_provider.dart';
import 'package:idl0/ui/tabs/device/config_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('idl0_config_card_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  // File I/O + AsyncNotifier resolution must happen outside the testWidgets
  // fake-async zone, otherwise pump hangs on the loading spinner.
  Future<ProviderContainer> setupContainer(WidgetTester tester) async {
    final container = await tester.runAsync(() async {
      final store = ProfileStore(baseDir: tmp);
      await store.save(const BikeProfile(
        profileId: 'fixed-id',
        profileName: 'Default',
        createdAtMs: 1,
        updatedAtMs: 1,
        config: {
          'config_version': 1,
          'bike_profile': {'name': 'My Bike', 'default_rider': 'Isaac'},
          'analog': {'sample_rate_hz': 100, 'channels': []},
          'digital': {'channels': []},
        },
      ),);
      SharedPreferences.setMockInitialValues(
        const {'idl0.profiles.active_id': 'fixed-id'},
      );
      final c = ProviderContainer(overrides: [
        profileStoreOverrideProvider.overrideWithValue(store),
      ],);
      await c.read(profileProvider.future);
      return c;
    });
    return container!;
  }

  testWidgets('ConfigCard — renders the profile bar', (tester) async {
    final container = await setupContainer(tester);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ConfigCard())),
    ),);
    await tester.pump();

    expect(find.text('Profile:'), findsOneWidget);
  });
}
