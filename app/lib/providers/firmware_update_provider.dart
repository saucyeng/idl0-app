import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

import '../data/exceptions.dart';
import '../transport/firmware_catalog.dart';
import 'device_provider.dart';
import 'settings_provider.dart';

/// Remote firmware catalog. Overridden with a fake in tests.
final firmwareCatalogProvider = Provider<FirmwareCatalog>(
  (ref) => GitHubReleasesCatalog(http.Client()),
);

/// Result of the firmware update check. See §27.7.
sealed class FirmwareUpdateState {
  const FirmwareUpdateState();
}

/// No check has run yet this session.
class FirmwareIdle extends FirmwareUpdateState {
  /// Creates a [FirmwareIdle].
  const FirmwareIdle();
}

/// A check is in flight.
class FirmwareChecking extends FirmwareUpdateState {
  /// Creates a [FirmwareChecking].
  const FirmwareChecking();
}

/// Device is on the latest published build for its channel.
class FirmwareUpToDate extends FirmwareUpdateState {
  /// The device's current version.
  final Version current;

  /// Creates a [FirmwareUpToDate] for the device's [current] version.
  const FirmwareUpToDate(this.current);
}

/// A newer build is available on the selected channel.
class FirmwareUpdateAvailable extends FirmwareUpdateState {
  /// The device's current version.
  final Version current;

  /// The newer published release.
  final FirmwareRelease release;

  /// Creates a [FirmwareUpdateAvailable] from [current] to [release].
  const FirmwareUpdateAvailable(this.current, this.release);
}

/// The device's running firmware is newer than the latest published build on
/// the selected channel — e.g. a beta image installed while following
/// `stable`, or a channel switch to one that has not yet published a build
/// past what's already on the device.
///
/// Informational only — §27.7 requires this never render as a downgrade
/// prompt. There is no action to take; the device is simply ahead.
class FirmwareAheadOfChannel extends FirmwareUpdateState {
  /// The device's current version.
  final Version current;

  /// The channel's latest published release (older than [current]).
  final FirmwareRelease release;

  /// Creates a [FirmwareAheadOfChannel] for [current] ahead of [release].
  const FirmwareAheadOfChannel(this.current, this.release);
}

/// The check could not complete (offline, device version absent or
/// unparseable). Non-fatal — the manual push path stays available.
class FirmwareCheckUnknown extends FirmwareUpdateState {
  /// Optional human-readable reason for the inline notice.
  final String? reason;

  /// Creates a [FirmwareCheckUnknown] with an optional [reason].
  const FirmwareCheckUnknown([this.reason]);
}

/// Compares the device's running firmware against the hosted latest.
class FirmwareUpdateNotifier extends Notifier<FirmwareUpdateState> {
  @override
  FirmwareUpdateState build() => const FirmwareIdle();

  /// Runs an update check for the user's selected channel. Never throws —
  /// failures resolve to [FirmwareCheckUnknown].
  Future<void> check() async {
    final device = ref.read(deviceProvider);
    final settings = ref.read(settingsProvider);

    final currentStr = device.firmwareVersion;
    if (!device.isConnected || currentStr == null) {
      state = const FirmwareCheckUnknown('device version unknown');
      return;
    }
    final Version current;
    try {
      current = Version.parse(currentStr);
    } on FormatException {
      state = const FirmwareCheckUnknown('device version unparseable');
      return;
    }

    state = const FirmwareChecking();
    try {
      final rel = await ref
          .read(firmwareCatalogProvider)
          .latest(settings.firmwareChannel);
      if (rel == null) {
        state = FirmwareUpToDate(current);
        return;
      }
      if (rel.version > current) {
        state = FirmwareUpdateAvailable(current, rel);
      } else if (rel.version < current) {
        state = FirmwareAheadOfChannel(current, rel);
      } else {
        state = FirmwareUpToDate(current);
      }
    } on TransportException catch (e) {
      state = FirmwareCheckUnknown(e.message);
    }
  }
}

/// Firmware update-check state provider. See §27.7.
final firmwareUpdateProvider =
    NotifierProvider<FirmwareUpdateNotifier, FirmwareUpdateState>(
  FirmwareUpdateNotifier.new,
);
