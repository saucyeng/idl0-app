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
  FirmwareUpdateState build() {
    // The update verdict is a function of the *live* device — its reported
    // firmware version and BLE link — not a value that stays true once
    // computed. Re-derive it whenever those inputs change so a verdict can
    // never outlive the state that produced it. Without this the state is a
    // one-shot snapshot from the last [check] that lingers across a
    // disconnect and an OTA reboot, leaving the hero banner offering the
    // very build the device just installed. See §27.7.
    ref.listen(
      deviceProvider.select((d) => (d.isConnected, d.firmwareVersion)),
      (prev, next) {
        final connected = next.$1;
        final version = next.$2;
        if (!connected || version == null) {
          // No connected device with a known version — nothing to offer.
          // Cleared unconditionally (independent of the auto-check setting):
          // a stale verdict must never outlive its device.
          state = const FirmwareIdle();
          return;
        }
        // Connected with a known version. Re-check when the version first
        // appears or changes — e.g. the device returns post-OTA running the
        // new build — gated on the user's auto-check preference, the same
        // gate the Settings panel's initial check uses.
        final versionChanged = prev == null || prev.$2 != version;
        if (versionChanged && ref.read(settingsProvider).autoCheckFirmware) {
          check();
        }
      },
    );
    return const FirmwareIdle();
  }

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
