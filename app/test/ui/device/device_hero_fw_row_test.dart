import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/device_provider.dart';
import 'package:idl0/ui/tabs/device/device_hero_card.dart';

/// A connected device with an optional [firmwareVersion], used to drive the
/// hero's `_PeripheralReadout` firmware row without touching real BLE state.
class _ConnectedDevice extends DeviceNotifier {
  _ConnectedDevice({this.firmwareVersion});
  final String? firmwareVersion;

  @override
  DeviceState build() => DeviceState(
        isConnected: true,
        deviceName: 'IDL0-A3F2',
        firmwareVersion: firmwareVersion,
      );
}

void main() {
  testWidgets('_PeripheralReadout — firmwareVersion present — FW row shows v<version>',
      (tester) async {
    // Arrange
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceProvider.overrideWith(
            () => _ConnectedDevice(firmwareVersion: '1.5.0'),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: DeviceHeroCard())),
      ),
    );

    // Act
    await tester.pump();

    // Assert
    expect(find.text('FW v1.5.0'), findsOneWidget);
  });

  testWidgets('_PeripheralReadout — firmwareVersion null — FW row absent',
      (tester) async {
    // Arrange
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceProvider.overrideWith(() => _ConnectedDevice()),
        ],
        child: const MaterialApp(home: Scaffold(body: DeviceHeroCard())),
      ),
    );

    // Act
    await tester.pump();

    // Assert
    expect(find.textContaining('FW'), findsNothing);
  });
}
