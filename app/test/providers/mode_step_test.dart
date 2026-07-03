import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/device_provider.dart';
import 'package:idl0/providers/mode_step.dart';
import 'package:idl0/transport/ack.dart';
import 'package:idl0/transport/ble_service.dart';

import '../helpers/mock_ble_service.dart';

void main() {
  late MockBleService mock;
  late ProviderContainer container;
  late StepContext ctx;

  setUp(() async {
    mock = MockBleService();
    container = ProviderContainer(
      overrides: [bleServiceProvider.overrideWithValue(mock)],
    );
    addTearDown(container.dispose);
    await container.read(deviceProvider.notifier).connect();
    ctx = StepContext.fromContainer(
      container,
      confirmTimeout: const Duration(seconds: 2),
    );
  });

  group('WifiOn', () {
    test('ACK 0x00 + status flips → StepOk', () async {
      final fut = const WifiOn().run(ctx);
      await Future.delayed(Duration.zero);
      mock.statusController.add(DeviceStatus.fromString('WiFi: ON'));
      expect(await fut, isA<StepOk>());
      expect(mock.wifiCalls, equals(['on']));
    });

    test('ACK 0x03 → StepRefused', () async {
      mock.nextRefusalCode = kIdl0AckMutexRefused;
      final r = await const WifiOn().run(ctx);
      expect(r, isA<StepRefused>());
      expect((r as StepRefused).attCode, equals(0x03));
    });

    test('ACK 0x00 but status never flips → StepTimedOut', () async {
      final shortCtx = StepContext.fromContainer(
        container,
        confirmTimeout: const Duration(milliseconds: 100),
      );
      expect(await const WifiOn().run(shortCtx), isA<StepTimedOut>());
    });

    test('disconnect mid-await → StepDisconnected', () async {
      final fut = const WifiOn().run(ctx);
      await Future.delayed(const Duration(milliseconds: 50));
      await container.read(deviceProvider.notifier).disconnect();
      expect(await fut, isA<StepDisconnected>());
    });

    test('cancel mid-await → StepCancelled', () async {
      final fut = const WifiOn().run(ctx);
      await Future.delayed(const Duration(milliseconds: 50));
      ctx.cancel();
      expect(await fut, isA<StepCancelled>());
    });
  });
}
