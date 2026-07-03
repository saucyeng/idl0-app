import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/bike_profile.dart';
import 'package:idl0/data/profile_store.dart';
import 'package:idl0/providers/profile_provider.dart';
import 'package:idl0/ui/tabs/device/channels_table.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('idl0_channels_table_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<ProviderContainer> setupContainer(
    WidgetTester tester, {
    Map<String, dynamic>? extraConfig,
  }) async {
    final container = await tester.runAsync(() async {
      final store = ProfileStore(baseDir: tmp);
      final config = <String, dynamic>{
        'config_version': 1,
        'bike_profile': {'name': 'Bike', 'default_rider': 'Rider'},
        'imu': {
          'sample_rate_hz': 800,
          'imu0': {
            'enabled': true,
            'accel_range_g': 32,
            'gyro_range_dps': 2000,
            'channels': {
              'accel_x': true,
              'accel_y': true,
              'accel_z': true,
              'gyro_x': true,
              'gyro_y': false,
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
            'enabled': false,
            'accel_range_g': 16,
            'gyro_range_dps': 500,
            'channels': {},
          },
        },
        'gps': {'sample_rate_hz': 5},
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
        ...?extraConfig,
      };
      await store.save(BikeProfile(
        profileId: 'fixed-id',
        profileName: 'Default',
        createdAtMs: 1,
        updatedAtMs: 1,
        config: config,
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

  testWidgets(
      'default view — IMU0/1/2 + GPS + Heart Rate Monitor; wheels hidden',
      (tester) async {
    final container = await setupContainer(tester);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ChannelsTable())),
    ),);
    await tester.pump();

    expect(find.text('IMU0 (sprung)'), findsOneWidget);
    expect(find.text('IMU1 (front fork)'), findsOneWidget);
    expect(find.text('IMU2 (rear)'), findsOneWidget);
    expect(find.text('GPS'), findsOneWidget);
    expect(find.text('Heart Rate Monitor'), findsOneWidget,
        reason: 'HRM is hardware-pinned in the table even when unpaired',);
    expect(find.text('Wheel Front'), findsNothing,
        reason: 'wheels default disabled and hidden until user opts in',);
    expect(find.text('Wheel Rear'), findsNothing);
    expect(find.text('+ Add channel…'), findsOneWidget);
  });

  testWidgets('wheel front shows up after enabling via config', (tester) async {
    final container = await setupContainer(tester, extraConfig: {
      'wheel_speed': {
        'front': {
          'enabled': true,
          'points_per_revolution': 12,
          'wheel_circumference_mm': 2300,
        },
        'rear': {
          'enabled': false,
          'points_per_revolution': 12,
          'wheel_circumference_mm': 2300,
        },
      },
    },);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ChannelsTable())),
    ),);
    await tester.pump();

    expect(find.text('Wheel Front'), findsOneWidget);
    expect(find.text('Wheel Rear'), findsNothing);
  });

  testWidgets('expanding IMU0 reveals its 6 axes', (tester) async {
    final container = await setupContainer(tester);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ChannelsTable())),
    ),);
    await tester.pump();

    expect(find.text('IMU0_AccelX'), findsNothing);

    await tester.tap(find.text('IMU0 (sprung)'));
    await tester.pump();

    expect(find.text('IMU0_AccelX'), findsOneWidget);
    expect(find.text('IMU0_AccelY'), findsOneWidget);
    expect(find.text('IMU0_AccelZ'), findsOneWidget);
    expect(find.text('IMU0_GyroX'), findsOneWidget);
    expect(find.text('IMU0_GyroY'), findsOneWidget);
    expect(find.text('IMU0_GyroZ'), findsOneWidget);
  });

  testWidgets(
      'user-added analog and digital channels appear after the hardware sources',
      (tester) async {
    final container = await setupContainer(tester, extraConfig: {
      'analog': {
        'sample_rate_hz': 100,
        'channels': [
          <String, dynamic>{
            'key': 'strain',
            'label': 'Strain',
            'adc_pin': 4,
            'units': 'kN',
            'scale': 0.0123,
            'offset': -1.5,
            'enabled': true,
          },
        ],
      },
      'digital': {
        'channels': [
          <String, dynamic>{
            'key': 'mb',
            'label': 'Marker',
            'kind': 'marker',
            'gpio_pin': 21,
            'active_low': true,
            'debounce_ms': 20,
            'enabled': true,
          },
        ],
      },
    },);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ChannelsTable())),
    ),);
    await tester.pump();

    expect(find.text('Strain'), findsOneWidget);
    expect(find.text('Marker'), findsOneWidget);
  });

  testWidgets('+ Add channel… opens picker with Wheel/Analog/Marker entries',
      (tester) async {
    final container = await setupContainer(tester);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ChannelsTable())),
    ),);
    await tester.pump();

    await tester.tap(find.text('+ Add channel…'));
    await tester.pumpAndSettle();

    expect(find.text('Wheel — front'), findsOneWidget);
    expect(find.text('Wheel — rear'), findsOneWidget);
    expect(find.text('Analog channel'), findsOneWidget);
    expect(find.text('Marker button'), findsOneWidget);
  });

  testWidgets(
      'compact width — channel name keeps its line; calibration moves '
      'to a second metadata line', (tester) async {
    final container = await setupContainer(tester);
    addTearDown(container.dispose);

    // A phone-width surface (< the 560 px compact breakpoint) — the fixed
    // RATE/UNIT/SCALE/OFFSET columns no longer fit, so the row must reflow.
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: Center(child: SizedBox(width: 360, child: ChannelsTable())),
        ),
      ),
    ),);
    await tester.pump();

    await tester.tap(find.text('IMU0 (sprung)'));
    await tester.pump();

    // The bug this layout fixes: at phone width the name used to clip to
    // nothing. It must still render in full.
    expect(find.text('IMU0_AccelX'), findsOneWidget);
    // Scale/offset detail survives on a compact second line rendered as the
    // calibration formula (×scale), not dropped.
    expect(
      find.textContaining('×'),
      findsWidgets,
      reason: 'compact channel rows carry ×scale on their metadata line',
    );
  });
}
