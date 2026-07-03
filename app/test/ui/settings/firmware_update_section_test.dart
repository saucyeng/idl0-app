import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/device_provider.dart';
import 'package:idl0/providers/firmware_update_provider.dart';
import 'package:idl0/providers/runs_provider.dart' show wifiServiceProvider;
import 'package:idl0/transport/firmware_catalog.dart';
import 'package:idl0/transport/wifi_service.dart';
import 'package:idl0/ui/brand/quiet_button.dart';
import 'package:idl0/ui/tabs/settings/firmware_update_section.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/mock_ble_service.dart';

/// Finds a [QuietButton] by its original-case [QuietButton.label].
///
/// The brand button renders its glyphs uppercased, so a plain `find.text`
/// against the design-handoff label (mixed case) would miss it. Matching the
/// `label` field keeps the asserted strings in their canonical spec form.
Finder _quietButton(String label) => find.byWidgetPredicate(
      (w) => w is QuietButton && w.label == label,
    );

// ---------------------------------------------------------------------------
// Spy WifiService
// ---------------------------------------------------------------------------

/// [WifiService] spy that records every method call and lets the test
/// control when `pushFirmware` completes (so a "pushing" UI state is
/// observable between `tester.pump` ticks).
class _SpyWifiService implements WifiService {
  final List<String> callLog = [];
  final List<int> lastBytes = [];

  /// Completer the test fires to resolve the in-flight push. Null until
  /// [pushFirmware] is called; reused for subsequent pushes.
  Completer<void>? pendingDone;

  /// Set true when [PushFirmwareHandle.cancel] runs.
  bool cancelInvoked = false;

  @override
  Future<void> bind() async => callLog.add('bind');

  @override
  Future<void> release() async => callLog.add('release');

  @override
  Future<List<FileInfo>> getFileList() async => [];

  @override
  Stream<double> downloadFile(String name, int size) async* {}

  @override
  PushFirmwareHandle pushFirmware(
    Uint8List bin, {
    void Function(int sent, int total)? onProgress,
  }) {
    callLog.add('pushFirmware');
    lastBytes
      ..clear()
      ..addAll(bin);
    final completer = Completer<void>();
    pendingDone = completer;
    // Emit a single mid-flight progress tick so widget tests can see a
    // non-zero progress bar without needing real I/O.
    onProgress?.call(bin.length ~/ 2, bin.length);
    return (
      done: completer.future,
      cancel: () async {
        cancelInvoked = true;
        if (!completer.isCompleted) {
          completer.completeError(StateError('canceled'));
        }
      },
    );
  }

  @override
  Future<void> pushConfig(String configJson) => throw UnimplementedError(
        'not exercised by firmware_update_section tests',
      );
}

// ---------------------------------------------------------------------------
// Fake DeviceNotifier that lets tests drive isConnected + otaPendingVerify
// without touching the real BLE notifier.
// ---------------------------------------------------------------------------

class _FakeDeviceNotifier extends DeviceNotifier {
  _FakeDeviceNotifier(this._initialState);
  final DeviceState _initialState;
  int reconnectCallCount = 0;

  @override
  DeviceState build() => _initialState;

  @override
  Future<void> connect() async {
    reconnectCallCount++;
    state = state.copyWith(isConnected: true, deviceName: 'IDL0-A3F2');
  }

  @override
  Future<void> disconnect() async {
    state = const DeviceState();
  }

  /// Test hook — pushes a new status into state.
  void setOtaPendingVerify(bool value) {
    state = state.copyWith(otaPendingVerify: value);
  }
}

// ---------------------------------------------------------------------------
// Fake firmware catalog + a stub update notifier so widget tests never hit
// the network and can pin the update-available state.
// ---------------------------------------------------------------------------

class _FakeCatalog implements FirmwareCatalog {
  @override
  Future<FirmwareRelease?> latest(FirmwareChannel channel) async => null;

  @override
  Future<Uint8List> download(
    FirmwareRelease release, {
    void Function(int, int)? onProgress,
  }) async {
    onProgress?.call(release.sizeBytes, release.sizeBytes);
    return Uint8List.fromList(
      List.generate(release.sizeBytes, (i) => i & 0xFF),
    );
  }
}

class _StubUpdateNotifier extends FirmwareUpdateNotifier {
  _StubUpdateNotifier(this._state);
  final FirmwareUpdateState _state;

  @override
  FirmwareUpdateState build() => _state;

  @override
  Future<void> check() async {} // no-op so the pinned state survives
}

FirmwareRelease _release(String version, {int sizeBytes = 1024}) =>
    FirmwareRelease(
      version: Version.parse(version),
      channel: FirmwareChannel.stable,
      binUrl: Uri.parse('https://dl/idl0.bin'),
      sizeBytes: sizeBytes,
      sha256Url: null,
      notes: 'Release notes',
    );

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Widget _wrap({
  required _SpyWifiService wifi,
  required MockBleService ble,
  required DeviceState initialDevice,
  required _FakeDeviceNotifier notifier,
  FirmwarePicker? picker,
  FirmwareCatalog? catalog,
  FirmwareUpdateState? updateState,
}) {
  return ProviderScope(
    overrides: [
      wifiServiceProvider.overrideWithValue(wifi),
      bleServiceProvider.overrideWithValue(ble),
      deviceProvider.overrideWith(() => notifier),
      firmwareCatalogProvider.overrideWithValue(catalog ?? _FakeCatalog()),
      if (updateState != null)
        firmwareUpdateProvider
            .overrideWith(() => _StubUpdateNotifier(updateState)),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: FirmwareUpdateSection(pickerOverride: picker),
        ),
      ),
    ),
  );
}

PickedFirmware _fakeFirmware([int sizeBytes = 1024]) => PickedFirmware(
      name: 'idl0_v2.bin',
      bytes: Uint8List.fromList(List.generate(sizeBytes, (i) => i & 0xFF)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('FirmwareUpdateSection — auto-update —', () {
    testWidgets('update-available state — card shows the target version',
        (tester) async {
      // Arrange — pin the provider to an available update.
      final wifi = _SpyWifiService();
      final ble = MockBleService();
      const initial = DeviceState(isConnected: true, deviceName: 'IDL0-A3F2');
      final notifier = _FakeDeviceNotifier(initial);
      await tester.pumpWidget(
        _wrap(
          wifi: wifi,
          ble: ble,
          initialDevice: initial,
          notifier: notifier,
          updateState: FirmwareUpdateAvailable(
            Version.parse('1.4.0'),
            _release('1.5.0'),
          ),
        ),
      );
      await tester.pump();

      // Assert — the card and its Update button render with the new version.
      expect(find.textContaining('1.4.0'), findsWidgets);
      expect(_quietButton('Update to v1.5.0'), findsOneWidget);
    });

    testWidgets('channel picker + auto-check controls always render',
        (tester) async {
      // Arrange
      final wifi = _SpyWifiService();
      final ble = MockBleService();
      const initial = DeviceState(isConnected: true, deviceName: 'IDL0-A3F2');
      final notifier = _FakeDeviceNotifier(initial);
      await tester.pumpWidget(
        _wrap(
          wifi: wifi,
          ble: ble,
          initialDevice: initial,
          notifier: notifier,
        ),
      );
      await tester.pump();

      // Assert
      expect(_quietButton('Check now'), findsOneWidget);
      expect(find.byType(SegmentedButton<FirmwareChannel>), findsOneWidget);
      expect(find.text('Check for updates automatically'), findsOneWidget);
    });
  });

  group('FirmwareUpdateSection — precondition gate —', () {
    testWidgets('BLE disconnected — Push button is absent, helper text shown',
        (tester) async {
      // Arrange
      final wifi = _SpyWifiService();
      final ble = MockBleService();
      final notifier = _FakeDeviceNotifier(const DeviceState());
      await tester.pumpWidget(
        _wrap(
          wifi: wifi,
          ble: ble,
          initialDevice: const DeviceState(),
          notifier: notifier,
          picker: () async => _fakeFirmware(),
        ),
      );
      await tester.pump();

      // Assert — disabled state, helper text
      expect(find.text('Connect to device first'), findsOneWidget);
      expect(_quietButton('Push to Device'), findsNothing);
    });

    testWidgets(
        'BLE connected, no file picked — Choose button visible, no Push button',
        (tester) async {
      // Arrange
      final wifi = _SpyWifiService();
      final ble = MockBleService();
      final notifier = _FakeDeviceNotifier(
        const DeviceState(isConnected: true, deviceName: 'IDL0-A3F2'),
      );
      await tester.pumpWidget(
        _wrap(
          wifi: wifi,
          ble: ble,
          initialDevice:
              const DeviceState(isConnected: true, deviceName: 'IDL0-A3F2'),
          notifier: notifier,
        ),
      );
      await tester.pump();

      // Assert
      expect(_quietButton('Choose firmware file…'), findsOneWidget);
      expect(_quietButton('Push to Device'), findsNothing);
    });
  });

  group('FirmwareUpdateSection — push flow —', () {
    testWidgets('Choose then Push — pushFirmware called with file bytes',
        (tester) async {
      // Arrange — connected AND in WiFi mode (Mode.wifi requires wifiOn: true).
      final wifi = _SpyWifiService();
      final ble = MockBleService();
      const initial = DeviceState(
        isConnected: true,
        deviceName: 'IDL0-A3F2',
        wifiOn: true,
      );
      final notifier = _FakeDeviceNotifier(initial);
      await tester.pumpWidget(
        _wrap(
          wifi: wifi,
          ble: ble,
          initialDevice: initial,
          notifier: notifier,
          picker: () async => _fakeFirmware(2048),
        ),
      );
      await tester.pump();

      // Act — choose the file
      await tester.tap(_quietButton('Choose firmware file…'));
      await tester.pumpAndSettle();

      // Assert — file metadata visible; Push button enabled
      expect(find.text('idl0_v2.bin'), findsOneWidget);
      expect(_quietButton('Push to Device'), findsOneWidget);

      // Act — push
      await tester.tap(_quietButton('Push to Device'));
      await tester.pump(); // start the push
      await tester.pump(const Duration(milliseconds: 10));

      // Assert — pushFirmware called with the picked bytes
      expect(wifi.callLog, contains('pushFirmware'));
      expect(wifi.lastBytes.length, equals(2048));
      // UI must not drive the WiFi lifecycle — that's owned by the
      // Device-tab ModePicker now.
      expect(ble.wifiCalls, isEmpty);
      expect(wifi.callLog, isNot(contains('bind')));
      expect(wifi.callLog, isNot(contains('release')));
      // Progress bar visible (sent/total)
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      // Cancel button available during push
      expect(_quietButton('Cancel'), findsOneWidget);

      // Cleanup — resolve the push so disposal doesn't see a dangling future
      wifi.pendingDone?.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    });

    testWidgets(
        'Cancel during push — handle.cancel runs, UI returns to file-picked state',
        (tester) async {
      // Arrange — connected AND in WiFi mode.
      final wifi = _SpyWifiService();
      final ble = MockBleService();
      const initial = DeviceState(
        isConnected: true,
        deviceName: 'IDL0-A3F2',
        wifiOn: true,
      );
      final notifier = _FakeDeviceNotifier(initial);
      await tester.pumpWidget(
        _wrap(
          wifi: wifi,
          ble: ble,
          initialDevice: initial,
          notifier: notifier,
          picker: () async => _fakeFirmware(),
        ),
      );
      await tester.pump();
      await tester.tap(_quietButton('Choose firmware file…'));
      await tester.pumpAndSettle();
      await tester.tap(_quietButton('Push to Device'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(_quietButton('Cancel'), findsOneWidget);

      // Act — cancel
      await tester.tap(_quietButton('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Assert
      expect(wifi.cancelInvoked, isTrue);
      // After cancel, the Push button is back (still have the file selected)
      expect(_quietButton('Push to Device'), findsOneWidget);
    });
  });

  group('FirmwareUpdateSection — connectivity gate —', () {
    testWidgets(
        'BLE connected (any mode) — Push button enabled, no WiFi-mode hint',
        (tester) async {
      // Arrange — connected, WiFi OFF (Mode.idle). Mode is automatic now (§23):
      // the Push button enables on connectivity and _push drives WiFi itself,
      // so there is no manual "switch to WiFi mode" gate.
      final wifi = _SpyWifiService();
      final ble = MockBleService();
      const initial = DeviceState(
        isConnected: true,
        deviceName: 'IDL0-A3F2',
        // wifiOn defaults to false → Mode.idle
      );
      final notifier = _FakeDeviceNotifier(initial);
      await tester.pumpWidget(
        _wrap(
          wifi: wifi,
          ble: ble,
          initialDevice: initial,
          notifier: notifier,
          picker: () async => _fakeFirmware(),
        ),
      );
      await tester.pump();

      // Act — choose the file so the Push button renders.
      await tester.tap(_quietButton('Choose firmware file…'));
      await tester.pumpAndSettle();

      // Assert — Push button is enabled and the old WiFi-mode hint is gone.
      expect(_quietButton('Push to Device'), findsOneWidget);
      expect(
        find.text('Switch to WiFi mode in the Device tab'),
        findsNothing,
      );
      final pushBtn = tester.widget<QuietButton>(
        _quietButton('Push to Device'),
      );
      expect(pushBtn.onPressed, isNotNull);
    });
  });

  group('FirmwareUpdateSection — OTA confirm card —', () {
    testWidgets(
        'otaPendingVerify true — commit card visible with Confirm + Roll back',
        (tester) async {
      // Arrange
      final wifi = _SpyWifiService();
      final ble = MockBleService();
      final notifier = _FakeDeviceNotifier(
        const DeviceState(
          isConnected: true,
          deviceName: 'IDL0-A3F2',
          otaPendingVerify: true,
        ),
      );
      await tester.pumpWidget(
        _wrap(
          wifi: wifi,
          ble: ble,
          initialDevice: const DeviceState(
            isConnected: true,
            deviceName: 'IDL0-A3F2',
            otaPendingVerify: true,
          ),
          notifier: notifier,
        ),
      );
      await tester.pump();

      // Assert — card visible
      expect(_quietButton('Confirm'), findsOneWidget);
      expect(_quietButton('Roll back'), findsOneWidget);
      expect(
        find.textContaining('New firmware is running'),
        findsOneWidget,
      );
    });

    testWidgets('Confirm tapped — calls deviceNotifier.confirmOta',
        (tester) async {
      // Arrange
      final wifi = _SpyWifiService();
      final ble = MockBleService();
      final notifier = _FakeDeviceNotifier(
        const DeviceState(
          isConnected: true,
          deviceName: 'IDL0-A3F2',
          otaPendingVerify: true,
        ),
      );
      await tester.pumpWidget(
        _wrap(
          wifi: wifi,
          ble: ble,
          initialDevice: const DeviceState(
            isConnected: true,
            deviceName: 'IDL0-A3F2',
            otaPendingVerify: true,
          ),
          notifier: notifier,
        ),
      );
      await tester.pump();

      // Act
      await tester.tap(_quietButton('Confirm'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Assert
      expect(ble.confirmOtaCallCount, equals(1));
    });

    testWidgets('otaPendingVerify false — no commit card', (tester) async {
      // Arrange
      final wifi = _SpyWifiService();
      final ble = MockBleService();
      final notifier = _FakeDeviceNotifier(
        const DeviceState(isConnected: true, deviceName: 'IDL0-A3F2'),
      );
      await tester.pumpWidget(
        _wrap(
          wifi: wifi,
          ble: ble,
          initialDevice:
              const DeviceState(isConnected: true, deviceName: 'IDL0-A3F2'),
          notifier: notifier,
        ),
      );
      await tester.pump();

      // Assert
      expect(_quietButton('Confirm'), findsNothing);
      expect(_quietButton('Roll back'), findsNothing);
    });
  });
}
