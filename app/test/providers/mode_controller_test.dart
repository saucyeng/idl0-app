import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/device_provider.dart';
import 'package:idl0/providers/mode.dart';
import 'package:idl0/providers/mode_controller.dart';
import 'package:idl0/transport/ack.dart';
import 'package:idl0/transport/ble_service.dart';

import '../helpers/mock_ble_service.dart';

void main() {
  group('ModeController.switchTo', () {
    late MockBleService mock;
    late ProviderContainer container;

    setUp(() async {
      mock = MockBleService();
      container = ProviderContainer(
        overrides: [bleServiceProvider.overrideWithValue(mock)],
      );
      addTearDown(container.dispose);
      await container.read(deviceProvider.notifier).connect();
    });

    test('idle → wifi — Ok', () async {
      final fut =
          container.read(modeControllerProvider.notifier).switchTo(Mode.wifi);
      await Future.delayed(Duration.zero);
      mock.statusController.add(DeviceStatus.fromString('WiFi: ON'));
      expect(await fut, isA<Ok>());
    });

    test('idle → recording (HR connected) — Ok', () async {
      mock.statusController.add(
        DeviceStatus.fromString(
          'WiFi: OFF\nLogging: STOPPED\nHR: CONNECTED 142',
        ),
      );
      await Future.delayed(Duration.zero);
      final fut = container
          .read(modeControllerProvider.notifier)
          .switchTo(Mode.recording);
      await Future.delayed(Duration.zero);
      mock.statusController.add(
        DeviceStatus.fromString(
          'WiFi: OFF\nLogging: RUNNING\nHR: CONNECTED 142',
        ),
      );
      expect(await fut, isA<Ok>());
    });

    test('recording → wifi — RefusedByPolicy, no command sent', () async {
      mock.statusController
          .add(DeviceStatus.fromString('WiFi: OFF\nLogging: RUNNING'));
      await Future.delayed(Duration.zero);
      mock.wifiCalls.clear();

      final r = await container
          .read(modeControllerProvider.notifier)
          .switchTo(Mode.wifi);
      expect(r, isA<RefusedByPolicy>());
      expect(mock.wifiCalls, isEmpty);
    });

    test('idle → wifi but firmware refuses → RefusedByFirmware', () async {
      mock.nextRefusalCode = kIdl0AckMutexRefused;
      final r = await container
          .read(modeControllerProvider.notifier)
          .switchTo(Mode.wifi);
      expect(r, isA<RefusedByFirmware>());
      expect((r as RefusedByFirmware).attCode, equals(0x03));
    });

    test('any → same → Ok immediately, no command sent', () async {
      mock.statusController.add(DeviceStatus.fromString('WiFi: OFF'));
      await Future.delayed(Duration.zero);
      mock.wifiCalls.clear();
      expect(
        await container
            .read(modeControllerProvider.notifier)
            .switchTo(Mode.idle),
        isA<Ok>(),
      );
      expect(mock.wifiCalls, isEmpty);
    });

    test('not connected → RefusedByPolicy, no command sent', () async {
      // A mode switch with no live BLE link must refuse cleanly rather than
      // letting WifiOn throw a raw "device not connected" exception (the spam
      // seen when switching mode right after a device reboot drops the link).
      await container.read(deviceProvider.notifier).disconnect();
      mock.wifiCalls.clear();

      final r = await container
          .read(modeControllerProvider.notifier)
          .switchTo(Mode.wifi);

      expect(r, isA<RefusedByPolicy>());
      expect((r as RefusedByPolicy).reason, contains('Connect'));
      expect(mock.wifiCalls, isEmpty);
    });

    test('wifi → wifi — Ok via short-circuit, no command sent', () async {
      // Re-entering wifi is a transition no-op (no CMD_WIFI_ON). The process
      // bind is maintained separately by WifiBindController (it follows mode
      // state), so this short-circuit does not drop the bind.
      mock.statusController.add(DeviceStatus.fromString('WiFi: ON'));
      await Future.delayed(Duration.zero);
      mock.wifiCalls.clear();

      final r = await container
          .read(modeControllerProvider.notifier)
          .switchTo(Mode.wifi);

      expect(r, isA<Ok>());
      expect(mock.wifiCalls, isEmpty);
    });
  });

  group('Transition table coverage', () {
    test('every (from, to) cell is in the table or RefusedByPolicy', () {
      final real = [Mode.idle, Mode.wifi, Mode.recording];
      for (final from in real) {
        for (final to in real) {
          if (from == to) continue;
          final hasTable = ModeController.transitionFor(from, to) != null;
          final isExplicitlyRefused =
              (from == Mode.recording && to == Mode.wifi);
          expect(
            hasTable || isExplicitlyRefused,
            isTrue,
            reason:
                '($from → $to) is neither in the table nor an explicit refusal',
          );
        }
      }
    });
  });
}
