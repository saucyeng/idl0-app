import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/app_settings.dart';
import 'package:idl0/providers/settings_provider.dart';
import 'package:idl0/transport/firmware_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  ProviderContainer makeContainer() => ProviderContainer();

  group('SettingsNotifier — defaults —', () {
    // 1
    test('riderName defaults to empty string', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      // Act — read initial state (before async _load completes)
      final settings = container.read(settingsProvider);

      // Assert
      expect(settings.riderName, equals(''));
    });

    // 2
    test('unitSystem defaults to imperial', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      final settings = container.read(settingsProvider);

      expect(settings.unitSystem, equals(UnitSystem.imperial));
    });

    // 3
    test('autoSyncOnDownload defaults to true', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      final settings = container.read(settingsProvider);

      expect(settings.autoSyncOnDownload, isTrue);
    });

    // 4
    test('syncOnWifiOnly defaults to true', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      final settings = container.read(settingsProvider);

      expect(settings.syncOnWifiOnly, isTrue);
    });
  });

  group('SettingsNotifier — setRiderName persistence —', () {
    // 5
    test(
        'setRiderName — updates state and round-trips through shared_preferences',
        () async {
      // Arrange
      final container = makeContainer();
      addTearDown(container.dispose);

      // Act
      await container.read(settingsProvider.notifier).setRiderName('Alice');

      // Assert — in-memory state updated
      expect(container.read(settingsProvider).riderName, equals('Alice'));

      // Assert — value round-trips: new container reads persisted value
      final container2 = makeContainer();
      addTearDown(container2.dispose);
      // Trigger load and wait for it
      container2.read(settingsProvider);
      await Future<void>.delayed(Duration.zero);

      expect(container2.read(settingsProvider).riderName, equals('Alice'));
    });
  });

  group('SettingsNotifier — setUnitSystem persistence —', () {
    // 6
    test(
        'setUnitSystem metric — updates state and round-trips through shared_preferences',
        () async {
      // Arrange
      final container = makeContainer();
      addTearDown(container.dispose);

      // Act
      await container
          .read(settingsProvider.notifier)
          .setUnitSystem(UnitSystem.metric);

      // Assert — in-memory state updated immediately
      expect(
        container.read(settingsProvider).unitSystem,
        equals(UnitSystem.metric),
      );

      // Assert — value round-trips: second container reads persisted value
      final container2 = makeContainer();
      addTearDown(container2.dispose);
      container2.read(settingsProvider);
      await Future<void>.delayed(Duration.zero);

      expect(
        container2.read(settingsProvider).unitSystem,
        equals(UnitSystem.metric),
      );
    });

    // 7
    test('setUnitSystem imperial — persists index 0', () async {
      // Arrange — pre-seed metric so we confirm the write back to imperial works
      SharedPreferences.setMockInitialValues({'unit_system': 1});
      final container = makeContainer();
      addTearDown(container.dispose);

      // Act
      await container
          .read(settingsProvider.notifier)
          .setUnitSystem(UnitSystem.imperial);

      // Assert
      expect(
        container.read(settingsProvider).unitSystem,
        equals(UnitSystem.imperial),
      );

      final container2 = makeContainer();
      addTearDown(container2.dispose);
      container2.read(settingsProvider);
      await Future<void>.delayed(Duration.zero);

      expect(
        container2.read(settingsProvider).unitSystem,
        equals(UnitSystem.imperial),
      );
    });
  });

  group('SettingsNotifier — firmware OTA settings —', () {
    test('firmwareChannel defaults to stable, autoCheckFirmware to true', () {
      // Arrange / Act
      final settings = AppSettings.defaults();

      // Assert
      expect(settings.firmwareChannel, equals(FirmwareChannel.stable));
      expect(settings.autoCheckFirmware, isTrue);
    });

    test('setFirmwareChannel — updates state and persists the index', () async {
      // Arrange
      final container = makeContainer();
      addTearDown(container.dispose);

      // Act
      await container
          .read(settingsProvider.notifier)
          .setFirmwareChannel(FirmwareChannel.beta);

      // Assert
      expect(
        container.read(settingsProvider).firmwareChannel,
        equals(FirmwareChannel.beta),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getInt('firmware_channel'),
        equals(FirmwareChannel.beta.index),
      );
    });

    test('setAutoCheckFirmware — updates state and persists', () async {
      // Arrange
      final container = makeContainer();
      addTearDown(container.dispose);

      // Act
      await container
          .read(settingsProvider.notifier)
          .setAutoCheckFirmware(false);

      // Assert
      expect(container.read(settingsProvider).autoCheckFirmware, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('auto_check_firmware'), isFalse);
    });
  });

  group('SettingsNotifier — autoSyncOnOpen —', () {
    // 8
    test('autoSyncOnOpen defaults to false', () async {
      // Arrange
      final container = makeContainer();
      addTearDown(container.dispose);

      // Act
      final settings = container.read(settingsProvider);

      // Assert
      expect(settings.autoSyncOnOpen, isFalse);
    });

    // 9
    test(
        'setAutoSyncOnOpen — updates state and round-trips through shared_preferences',
        () async {
      // Arrange
      final container = makeContainer();
      addTearDown(container.dispose);

      // Act
      await container.read(settingsProvider.notifier).setAutoSyncOnOpen(true);

      // Assert — in-memory state updated immediately
      expect(container.read(settingsProvider).autoSyncOnOpen, isTrue);

      // Assert — value round-trips and the raw key is written
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('auto_sync_on_open'), isTrue);

      final container2 = makeContainer();
      addTearDown(container2.dispose);
      container2.read(settingsProvider);
      await Future<void>.delayed(Duration.zero);

      expect(container2.read(settingsProvider).autoSyncOnOpen, isTrue);
    });
  });
}
