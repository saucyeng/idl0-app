import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:idl0/data/worksheet.dart' show VarianceMode;
import 'package:idl0/providers/channel_provider.dart' show sessionHandleProvider;
import 'package:idl0/providers/comparison_provider.dart';
import 'package:idl0/src/rust/lib.dart' show SessionHandle;
import 'package:idl0/src/rust/session.dart' show varianceTraces;

/// Family key for [varianceTracesProvider]: the channel to compare and the
/// alignment mode.
typedef VarianceTracesKey = ({String channelId, VarianceMode mode});

/// One per-sample delta series per overlay lap (`overlay − Main` at the matching
/// GPS position), in the overlay order of [comparisonLapsProvider]. The Main
/// (reference) lap is `comparisonLapsProvider.laps.first`; the overlays follow.
///
/// Returns an empty list when there are fewer than two comparison laps (nothing
/// to compare). A lap missing GPS yields an all-NaN series (the engine NaNs it),
/// which the chart renders as a "needs GPS" gap rather than an error. The heavy
/// projection + per-sample delta runs in `idl-rs` (`variance_traces`); only the
/// delta buffers cross FFI.
final varianceTracesProvider = FutureProvider.autoDispose
    .family<List<Float64List>, VarianceTracesKey>((ref, key) async {
  final set = ref.watch(comparisonLapsProvider);
  if (set.laps.length < 2) return const [];

  final main = set.laps.first;
  final overlays = set.laps.skip(1).toList();

  final reference = await ref.watch(
    sessionHandleProvider(main.key.sessionId).future,
  );
  final targetHandles = <SessionHandle>[];
  for (final o in overlays) {
    targetHandles.add(
      await ref.watch(sessionHandleProvider(o.key.sessionId).future),
    );
  }

  return varianceTraces(
    reference: reference,
    referenceLapStartMs: main.lap.startTimestampMs.toDouble(),
    referenceLapEndMs: main.lap.endTimestampMs.toDouble(),
    referenceLapStartUniformSec: main.lap.startTimeSecs,
    targetHandles: targetHandles,
    targetLapStartMs: [
      for (final o in overlays) o.lap.startTimestampMs.toDouble(),
    ],
    targetLapEndMs: [for (final o in overlays) o.lap.endTimestampMs.toDouble()],
    targetLapStartUniformSec: [for (final o in overlays) o.lap.startTimeSecs],
    targetWindowStartSec: [for (final o in overlays) o.lap.startTimeSecs],
    targetWindowEndSec: [for (final o in overlays) o.lap.endTimeSecs],
    channelId: key.channelId,
    mode: key.mode == VarianceMode.distance ? 1 : 0,
  );
});
