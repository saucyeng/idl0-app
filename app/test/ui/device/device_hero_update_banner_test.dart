import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/device_provider.dart';
import 'package:idl0/providers/firmware_update_provider.dart';
import 'package:idl0/transport/firmware_catalog.dart';
import 'package:idl0/ui/shell/adaptive_shell.dart';
import 'package:idl0/ui/tabs/device/device_hero_card.dart';
import 'package:pub_semver/pub_semver.dart';

class _ConnectedDevice extends DeviceNotifier {
  @override
  DeviceState build() =>
      const DeviceState(isConnected: true, deviceName: 'IDL0-A3F2');
}

class _DisconnectedDevice extends DeviceNotifier {
  @override
  DeviceState build() => const DeviceState();
}

class _AvailableUpdate extends FirmwareUpdateNotifier {
  _AvailableUpdate(this._state);
  final FirmwareUpdateState _state;
  @override
  FirmwareUpdateState build() => _state;
  @override
  Future<void> check() async {}
}

FirmwareRelease _release(String v) => FirmwareRelease(
      version: Version.parse(v),
      channel: FirmwareChannel.stable,
      binUrl: Uri.parse('https://dl/idl0.bin'),
      sizeBytes: 1,
      sha256Url: null,
      notes: '',
    );

void main() {
  testWidgets('shows banner when an update is available, routes to Settings',
      (tester) async {
    // Arrange
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceProvider.overrideWith(_ConnectedDevice.new),
          firmwareUpdateProvider.overrideWith(
            () => _AvailableUpdate(
              FirmwareUpdateAvailable(
                Version.parse('1.4.0'),
                _release('1.5.0'),
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: DeviceHeroCard())),
      ),
    );
    await tester.pump();

    // Assert — banner present
    expect(
      find.textContaining('Firmware update available — v1.5.0'),
      findsOneWidget,
    );

    // Act — tap routes to the Settings tab (index 4)
    await tester.tap(find.textContaining('Firmware update available'));
    await tester.pump();

    // Assert
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DeviceHeroCard)),
    );
    expect(container.read(shellIndexProvider), equals(4));
  });

  testWidgets('no banner when up to date', (tester) async {
    // Arrange
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceProvider.overrideWith(_ConnectedDevice.new),
          firmwareUpdateProvider.overrideWith(
            () => _AvailableUpdate(FirmwareUpToDate(Version.parse('1.5.0'))),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: DeviceHeroCard())),
      ),
    );
    await tester.pump();

    // Assert
    expect(find.textContaining('Firmware update available'), findsNothing);
  });

  testWidgets(
      'no banner when disconnected even if the verdict is still Available '
      '(§27.7 — a banner only means anything for a live device)',
      (tester) async {
    // Arrange — an Available verdict paired with a disconnected device, the
    // transient window between a link drop and the provider re-deriving.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceProvider.overrideWith(_DisconnectedDevice.new),
          firmwareUpdateProvider.overrideWith(
            () => _AvailableUpdate(
              FirmwareUpdateAvailable(
                Version.parse('1.4.0'),
                _release('1.5.0'),
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: DeviceHeroCard())),
      ),
    );
    await tester.pump();

    // Assert
    expect(find.textContaining('Firmware update available'), findsNothing);
  });

  testWidgets(
      'no banner when device is ahead of the channel (§27.7 — informational '
      'only, never a downgrade prompt)', (tester) async {
    // Arrange — a NEW sealed state the banner's `is FirmwareUpdateAvailable`
    // check does not match, so it must stay invisible by construction.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceProvider.overrideWith(_ConnectedDevice.new),
          firmwareUpdateProvider.overrideWith(
            () => _AvailableUpdate(
              FirmwareAheadOfChannel(
                Version.parse('1.6.0'),
                _release('1.5.0'),
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: DeviceHeroCard())),
      ),
    );
    await tester.pump();

    // Assert
    expect(find.textContaining('Firmware update available'), findsNothing);
  });
}
