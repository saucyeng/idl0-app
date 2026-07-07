import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/exceptions.dart';
import 'package:idl0/providers/device_provider.dart';
import 'package:idl0/providers/firmware_update_provider.dart';
import 'package:idl0/transport/firmware_catalog.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeCatalog implements FirmwareCatalog {
  final FirmwareRelease? result;
  final Object? error;
  _FakeCatalog({this.result, this.error});

  @override
  Future<FirmwareRelease?> latest(FirmwareChannel channel) async {
    if (error != null) throw error!;
    return result;
  }

  @override
  Future<Uint8List> download(
    FirmwareRelease release, {
    void Function(int, int)? onProgress,
  }) async =>
      Uint8List(0);
}

class _StubDeviceNotifier extends DeviceNotifier {
  final DeviceState _initial;
  _StubDeviceNotifier(this._initial);
  @override
  DeviceState build() => _initial;
}

FirmwareRelease _rel(String v) => FirmwareRelease(
      version: Version.parse(v),
      channel: FirmwareChannel.stable,
      binUrl: Uri.parse('https://dl/idl0.bin'),
      sizeBytes: 1,
      sha256Url: null,
      notes: '',
    );

ProviderContainer _container({
  required String? deviceVersion,
  required bool connected,
  FirmwareCatalog? catalog,
}) {
  final c = ProviderContainer(
    overrides: [
      firmwareCatalogProvider
          .overrideWithValue(catalog ?? _FakeCatalog(result: null)),
      deviceProvider.overrideWith(
        () => _StubDeviceNotifier(
          DeviceState(isConnected: connected, firmwareVersion: deviceVersion),
        ),
      ),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('available when hosted version is newer', () async {
    // Arrange
    final c = _container(
      deviceVersion: '1.4.0',
      connected: true,
      catalog: _FakeCatalog(result: _rel('1.5.0')),
    );

    // Act
    await c.read(firmwareUpdateProvider.notifier).check();

    // Assert
    final s = c.read(firmwareUpdateProvider);
    expect(s, isA<FirmwareUpdateAvailable>());
    expect(
      (s as FirmwareUpdateAvailable).release.version,
      equals(Version.parse('1.5.0')),
    );
  });

  test('check — hosted older than device — FirmwareAheadOfChannel with '
      'both versions', () async {
    // Arrange
    final c = _container(
      deviceVersion: '1.6.0',
      connected: true,
      catalog: _FakeCatalog(result: _rel('1.5.0')),
    );

    // Act
    await c.read(firmwareUpdateProvider.notifier).check();

    // Assert
    final s = c.read(firmwareUpdateProvider);
    expect(s, isA<FirmwareAheadOfChannel>());
    expect(
      (s as FirmwareAheadOfChannel).current,
      equals(Version.parse('1.6.0')),
    );
    expect(s.release.version, equals(Version.parse('1.5.0')));
  });

  test('up to date when hosted equals device', () async {
    // Arrange
    final c = _container(
      deviceVersion: '1.5.0',
      connected: true,
      catalog: _FakeCatalog(result: _rel('1.5.0')),
    );

    // Act
    await c.read(firmwareUpdateProvider.notifier).check();

    // Assert
    expect(c.read(firmwareUpdateProvider), isA<FirmwareUpToDate>());
  });

  test('unknown when device version absent', () async {
    // Arrange
    final c = _container(deviceVersion: null, connected: true);

    // Act
    await c.read(firmwareUpdateProvider.notifier).check();

    // Assert
    expect(c.read(firmwareUpdateProvider), isA<FirmwareCheckUnknown>());
  });

  test('unknown when catalog throws', () async {
    // Arrange
    final c = _container(
      deviceVersion: '1.4.0',
      connected: true,
      catalog: _FakeCatalog(error: const FirmwareCatalogException('offline')),
    );

    // Act
    await c.read(firmwareUpdateProvider.notifier).check();

    // Assert
    expect(c.read(firmwareUpdateProvider), isA<FirmwareCheckUnknown>());
  });
}
