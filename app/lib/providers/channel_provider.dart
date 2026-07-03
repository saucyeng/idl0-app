import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/exceptions.dart';
import '../data/gpx_parser.dart';
import '../src/rust/lib.dart' as rust;
import '../src/rust/session.dart' as rust;
import '../src/rust/tracks.dart' as rust;
import '../ui/tabs/analyze/chart_tile_cache.dart';
import 'handle_residency.dart';
import 'selection_provider.dart';
import 'session_provider.dart';

/// App-lifetime owner of the [HandleResidencyController]. Wires its eviction
/// callback to the chart tile cache and drives it from the active selection so
/// deselected handles fall out of the resident set. See §15.3.
final handleResidencyProvider = Provider<HandleResidencyController>((ref) {
  final controller = HandleResidencyController(
    invalidateTiles: (id) =>
        ref.read(chartTileCacheProvider).invalidateSession(id),
  );
  ref.listen<Set<String>>(
    effectiveSessionIdsProvider,
    (_, ids) => controller.sync(ids),
    fireImmediately: true,
  );
  return controller;
});

/// The retained Rust [rust.SessionHandle] for a session, parsed once and held
/// alive by Riverpod for the session's lifetime. The math evaluator reads
/// channels from it Rust-side (Phase 3a) and the chart will decimate off it
/// (Phase 3c).
///
/// `.idl0` parses via [rust.parseSessionFromPath] — Rust reads the file, so a
/// multi-hundred-MB log never crosses the FFI boundary as a buffer. `.gpx`
/// parses with the Dart [GpxParser] (still a Dart concern until Phase 5), then
/// wraps its channels in a handle via [rust.sessionFromChannels] so this
/// provider has one parse path. `Time`/`Distance` are synthesized in Rust.
///
/// Surfaces a typed [ParseException] on malformed/unreadable input. See §15.
final sessionHandleProvider = FutureProvider.autoDispose
    .family<rust.SessionHandle, String>((ref, sessionId) async {
  // Pin BEFORE the first await. This provider is autoDispose, and a
  // listener-less read — the bulk "Rescan visits" path uses
  // `ref.read(sessionHandleProvider(id).future)`, which keeps no subscription
  // across the parse await — would otherwise let it dispose mid-build, and the
  // build then crashed at `ref.onDispose` below ("Cannot call onDispose after
  // a provider was disposed"). The residency controller takes over releasing
  // this link once the handle is registered; any build failure closes it here
  // so the errored provider frees instead of leaking the pin. §15.3.
  final keepAliveLink = ref.keepAlive();
  try {
    final sessions = ref.read(sessionProvider).sessions;
    final meta = sessions.firstWhere(
      (s) => s.sessionId == sessionId,
      orElse: () =>
          throw StateError('Session $sessionId not in sessionProvider'),
    );
    final rust.SessionHandle handle;
    if (meta.filePath.toLowerCase().endsWith('.gpx')) {
      final bytes = await File(meta.filePath).readAsBytes();
      final s = GpxParser.parse(utf8.decode(bytes)).session;
      handle = await rust.sessionFromChannels(
        meta: rust.SessionMetaInput(
          sessionId: s.sessionId,
          deviceId: s.deviceId,
          timestampUtcMs: s.timestampUtcMs,
          configChecksum: s.configChecksum,
        ),
        channels: [
          for (final c in s.channels)
            rust.ChannelInput(
              channelId: c.channelId,
              sampleRateHz: c.sampleRateHz,
              samples: Float64List.fromList(c.samples),
              sampleTimesSecs: c.sampleTimesSecs == null
                  ? null
                  : Float64List.fromList(c.sampleTimesSecs!),
            ),
        ],
      );
    } else {
      handle = await rust.parseSessionFromPath(path: meta.filePath);
    }
    // Free the Rust session deterministically when this provider is torn down
    // (residency eviction closes the keep-alive link → autodispose → here).
    // Without this, native memory waits on a GC finalizer that feels no
    // pressure from Rust-held bytes. §15.3.
    ref.onDispose(handle.dispose);
    // Hand the keep-alive's release to the residency controller with the
    // engine-reported size, so the warm set is bounded by bytes, not handle
    // count (§15.3, Phase E).
    final residentBytes =
        (await rust.sessionResidentBytes(handle: handle)).toInt();
    ref.read(handleResidencyProvider).register(
          sessionId,
          keepAliveLink.close,
          residentBytes: residentBytes,
        );
    return handle;
  } on rust.ParseFailure catch (e) {
    keepAliveLink.close();
    throw mapRustParseError(e);
  } catch (_) {
    keepAliveLink.close();
    rethrow;
  }
});

/// Maps the generated Rust [rust.ParseFailure] onto the app's typed exception
/// hierarchy (§16) so error surfacing (§17) is unchanged.
IdlException mapRustParseError(rust.ParseFailure e) {
  return switch (e.kind) {
    rust.ParseErrorKind.invalidMagicBytes =>
      InvalidMagicBytesException(e.message),
    rust.ParseErrorKind.unsupportedSchemaVersion =>
      UnsupportedSchemaVersionException(e.message),
    rust.ParseErrorKind.truncatedRecord => TruncatedRecordException(e.message),
    rust.ParseErrorKind.io => FileReadException(e.message),
  };
}

/// Channel metadata for a session — id / rate / length / event-driven /
/// synthesized, with NO samples. The Analyze charts build their
/// [SessionChannelData] list from this and self-source each bounded view
/// (tiles, bounds, spectrum, slice) from the handle by id — no Dart-side copy of
/// the samples. Reads [rust.sessionChannels] off the retained
/// [sessionHandleProvider]. See §17.
final sessionChannelMetaProvider = FutureProvider.autoDispose
    .family<List<rust.ChannelMeta>, String>((ref, sessionId) async {
  final handle = await ref.watch(sessionHandleProvider(sessionId).future);
  return rust.sessionChannels(handle: handle);
});

/// GPS polyline + session-start epoch for [sessionId], sourced entirely from the
/// retained [sessionHandleProvider]. The record's `fixes` is the engine fix list
/// (lat/lon at the raw degrees × 1e7 channel scale, with `(0,0)` no-fix sentinels
/// already dropped), each fix carrying its `timestampMs`. `startEpochMs` is the
/// raw first `GPS_EpochMs` sample — i.e. GPS sample index 0, the
/// session-relative-seconds origin the time-series x-axis and the shared cursor
/// both use. It is read via a single-sample [rust.materializeF64] window so no
/// full channel array crosses FFI; `0.0` when the session has no GPS epoch
/// channel. `autoDispose` so it frees with the chart (§15.3).
final gpsTrackProvider = FutureProvider.autoDispose
    .family<({List<rust.GpsFixArg> fixes, double startEpochMs}), String>(
        (ref, sessionId) async {
  final handle = await ref.watch(sessionHandleProvider(sessionId).future);
  final fixes = await rust.gpsTrack(handle: handle);
  final firstEpoch = await rust.materializeF64(
    handle: handle,
    channelId: 'GPS_EpochMs',
    start: 0,
    end: 1,
  );
  return (
    fixes: fixes,
    startEpochMs: firstEpoch.isEmpty ? 0.0 : firstEpoch.first,
  );
});

/// Per-GPS-fix values of [channelId] for [sessionId] — one value per fix, in
/// the same order as [gpsTrackProvider]'s fix list, resampled engine-side
/// ([rust.gpsChannelValues]). `NaN` where the channel has no sample at a fix.
/// Drives the GPS trace heatmap. autoDispose; keyed by (sessionId, channelId).
final gpsChannelValuesProvider = FutureProvider.autoDispose
    .family<Float64List, ({String sessionId, String channelId})>(
        (ref, key) async {
  final handle = await ref.watch(sessionHandleProvider(key.sessionId).future);
  return rust.gpsChannelValues(handle: handle, channelId: key.channelId);
});

/// Session-start epoch in milliseconds for [sessionId] — the raw first
/// `GPS_EpochMs` sample (GPS sample index 0), read via a single-sample
/// [rust.materializeF64] window so no full array crosses FFI. `null` when the
/// session has no GPS epoch channel, so callers fall back (e.g. to a lap's own
/// start). The session-relative-seconds origin lap windows are measured from.
/// autoDispose (§15.3).
final sessionStartMsProvider =
    FutureProvider.autoDispose.family<double?, String>((ref, sessionId) async {
  final handle = await ref.watch(sessionHandleProvider(sessionId).future);
  final firstEpoch = await rust.materializeF64(
    handle: handle,
    channelId: 'GPS_EpochMs',
    start: 0,
    end: 1,
  );
  return firstEpoch.isEmpty ? null : firstEpoch.first;
});

/// Per-sample times (seconds) for an event-driven channel, read off the
/// retained handle ([rust.channelSampleTimes]). `null` for fixed-rate or absent
/// channels. autoDispose; keyed by (sessionId, channelId). Event-driven channels
/// (HR_RR, wheel pulses, markers) are sparse, so this is a small array — the
/// time-series chart uses it to map decimated buckets to their real X positions.
final channelSampleTimesProvider = FutureProvider.autoDispose
    .family<Float64List?, ({String sessionId, String channelId})>(
        (ref, key) async {
  final handle = await ref.watch(sessionHandleProvider(key.sessionId).future);
  return rust.channelSampleTimes(handle: handle, channelId: key.channelId);
});

/// Finite (min, max) Y-axis bounds for a channel, computed in the engine
/// ([rust.channelMinMax] folds the raw column off the retained handle — no
/// materialization). `null` when the channel is absent or all-non-finite.
/// Keyed by (sessionId, channelId); autoDispose so it frees with the chart
/// (§15.3). Works for base, synthesized, and math-store channels alike.
final channelBoundsProvider = FutureProvider.autoDispose
    .family<rust.ChannelBounds?, ({String sessionId, String channelId})>(
        (ref, key) async {
  final handle = await ref.watch(sessionHandleProvider(key.sessionId).future);
  return rust.channelMinMax(handle: handle, channelId: key.channelId);
});

/// Slices [LapSliceKey.channelId] to a lap window and upserts the rebased trace
/// into the handle's derived store via [rust.sliceLapIntoStore], returning the
/// engine's opaque storage token + length (or `null` when the window covers no
/// sample). The chart decimates the token by id like any other channel; the
/// slice itself never crosses FFI (§15.3). The slice starts at sample 0, giving
/// a lap-relative x-axis. autoDispose; keyed by primitives so the family caches
/// stably.
///
/// [sourceGeneration] is part of the family key but NOT the storage token: when
/// an upstream math channel is edited, [mathChannelProvider] bumps its
/// generation, this family instance is recreated, and the slice is re-cut from
/// fresh data — while the token stays stable, so nothing is orphaned. Base
/// channels never change and always pass generation 0.
final lapSlicedChannelProvider = FutureProvider.autoDispose.family<
    ({String channelId, int length})?,
    ({
      String sessionId,
      String channelId,
      double sampleRateHz,
      double startSec,
      double endSec,
      bool overlay,
      int lap,
      int sourceGeneration,
    })>((ref, k) async {
  final handle = await ref.watch(sessionHandleProvider(k.sessionId).future);
  // The engine slices, sample-0-rebases, and upserts under a typed lap-slice key
  // (source = channelId), returning the opaque token to decimate by.
  final res = await rust.sliceLapIntoStore(
    handle: handle,
    channelId: k.channelId,
    overlay: k.overlay,
    lap: k.lap,
    t0Secs: k.startSec,
    t1Secs: k.endSec,
  );
  if (res.length == 0) return null;
  // The token is stable across generations, so any tiles a prior generation
  // cached under it are now stale — this build just replaced the engine entry.
  // Drop them so the chart re-decimates the fresh slice (a no-op on first build,
  // before any tile for this token exists).
  ref.read(chartTileCacheProvider).invalidateChannel(k.sessionId, res.token);
  return (channelId: res.token, length: res.length);
});

/// Sorted, deduplicated list of channel names available across all currently
/// selected sessions. See §17.
///
/// Reads [effectiveSessionIdsProvider] (so lap-mode and session-mode are both
/// covered transparently) and unions [rust.ChannelMeta.channelId] values from
/// [sessionChannelMetaProvider] for each selected session — metadata only, no
/// sample arrays. Sessions that are still loading or have errored are skipped —
/// the list grows incrementally as sessions finish parsing.
final availableChannelNamesProvider = Provider<List<String>>((ref) {
  final selectedIds = ref.watch(effectiveSessionIdsProvider);
  final names = <String>{};
  for (final id in selectedIds) {
    ref.watch(sessionChannelMetaProvider(id)).whenData((metas) {
      for (final m in metas) {
        names.add(m.channelId);
      }
    });
  }
  return names.toList()..sort();
});
