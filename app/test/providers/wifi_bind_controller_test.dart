import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/device_provider.dart';
import 'package:idl0/providers/runs_provider.dart' show wifiServiceProvider;
import 'package:idl0/providers/wifi_bind_controller.dart';
import 'package:idl0/transport/ble_service.dart';

import '../helpers/fake_wifi_service.dart';
import '../helpers/mock_ble_service.dart';

/// Flush the Riverpod listener dispatch + the controller's async _sync.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  group('WifiBindController follows Mode state', () {
    late MockBleService ble;
    late FakeWifiService wifi;
    late ProviderContainer container;

    setUp(() async {
      ble = MockBleService();
      wifi = FakeWifiService();
      container = ProviderContainer(
        overrides: [
          bleServiceProvider.overrideWithValue(ble),
          wifiServiceProvider.overrideWithValue(wifi),
        ],
      );
      addTearDown(container.dispose);
      await container.read(deviceProvider.notifier).connect();

      // Activate the controller (Device tab does this via ref.watch). The
      // fireImmediately listener runs _sync(idle) → release; reset the counters
      // afterwards so each test starts from a clean slate.
      container.read(wifiBindControllerProvider);
      await _settle();
      wifi.bindCalls = 0;
      wifi.releaseCalls = 0;
    });

    test('entering wifi mode binds; leaving releases', () async {
      // Arrange / Act — firmware reports the AP up.
      ble.statusController.add(DeviceStatus.fromString('WiFi: ON'));
      await _settle();

      // Assert — bound.
      expect(wifi.bindCalls, equals(1));
      expect(
        container.read(wifiBindControllerProvider).phase,
        equals(WifiBindPhase.bound),
      );

      // Act — AP comes down.
      ble.statusController.add(DeviceStatus.fromString('WiFi: OFF'));
      await _settle();

      // Assert — released.
      expect(wifi.releaseCalls, greaterThanOrEqualTo(1));
      expect(
        container.read(wifiBindControllerProvider).phase,
        equals(WifiBindPhase.idle),
      );
    });

    test('bind failure surfaces as WifiBindPhase.failed with the reason',
        () async {
      // Arrange — the bind will fail (e.g. AP unreachable).
      wifi.bindError = const DummyTransportException('no AP');

      // Act
      ble.statusController.add(DeviceStatus.fromString('WiFi: ON'));
      await _settle();

      // Assert
      final s = container.read(wifiBindControllerProvider);
      expect(s.phase, equals(WifiBindPhase.failed));
      expect(s.error, contains('no AP'));
    });

    test(
        'OTA reboot — BLE link-loss while bound resets DeviceState to '
        'defaults — exactly one release, no dangling bind', () async {
      // Arrange — firmware reports the AP up (as it does while serving
      // POST /ota), so the controller binds.
      ble.statusController.add(DeviceStatus.fromString('WiFi: ON'));
      await _settle();
      expect(wifi.bindCalls, equals(1));
      expect(
        container.read(wifiBindControllerProvider).phase,
        equals(WifiBindPhase.bound),
      );

      // Act — the device's esp_restart() after accepting the OTA image
      // drops the BLE link before any further status frame arrives;
      // DeviceNotifier's link-loss handler resets DeviceState to its
      // defaults (wifiOn: false), which is Mode.idle.
      ble.simulateConnectionLoss();
      await _settle();

      // Assert — released exactly once, no re-bind snuck in, and the
      // controller has followed the mode back to idle.
      expect(wifi.releaseCalls, equals(1));
      expect(wifi.bindCalls, equals(1));
      expect(
        container.read(wifiBindControllerProvider).phase,
        equals(WifiBindPhase.idle),
      );
    });
  });
}
