import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/device_provider.dart';
import 'package:idl0/providers/runs_provider.dart'
    show wifiBinderProvider, wifiServiceProvider;
import 'package:idl0/transport/ble_service.dart';

import '../helpers/mock_ble_service.dart';

/// Regression tests for the proxy-port-loss bug (wifi link P2 field
/// failure, 2026-06-10): `wifiServiceProvider` watched the whole
/// [DeviceState], so every 1 Hz status frame rebuilt the service WITH A
/// FRESH [WifiNetworkBinder] — discarding the loopback-proxy port learned
/// by `bind()`. Ops then fell back to the direct device IP (timeout) or a
/// dead proxy port (connection refused).
void main() {
  late MockBleService ble;
  late ProviderContainer container;

  setUp(() async {
    ble = MockBleService();
    container = ProviderContainer(
      overrides: [bleServiceProvider.overrideWithValue(ble)],
    );
    addTearDown(container.dispose);
    await container.read(deviceProvider.notifier).connect();
  });

  /// Push one §7.3 status frame and let listeners settle.
  Future<void> frame(String status) async {
    ble.statusController.add(DeviceStatus.fromString(status));
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  test('wifiServiceProvider — status frame churn — service instance is stable',
      () async {
    // Arrange
    final before = container.read(wifiServiceProvider);

    // Act — a battery change is a new DeviceState object every frame; it
    // must NOT rebuild the service (deviceName is unchanged).
    await frame('Battery: 90%');
    await frame('Battery: 89%');
    final after = container.read(wifiServiceProvider);

    // Assert
    expect(
      identical(before, after),
      isTrue,
      reason: 'status-frame churn must not recreate RealWifiService — a '
          'fresh instance gets a fresh binder and loses the proxy port',
    );
  });

  test('wifiBinderProvider — singleton — same instance across reads', () async {
    // Arrange / Act
    final first = container.read(wifiBinderProvider);
    await frame('Battery: 42%');
    final second = container.read(wifiBinderProvider);

    // Assert — the binder (which holds the proxy port) lives for the app
    // session regardless of device-state churn.
    expect(identical(first, second), isTrue);
  });
}
