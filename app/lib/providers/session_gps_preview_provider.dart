import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/lap_detector.dart' show GpsFix;
import '../data/track_matching_bridge.dart';
import '../src/rust/tracks.dart' as rust;
import 'channel_provider.dart';

/// The session's reference GPS polyline as a list of [GpsFix] (latitude /
/// longitude stored as degrees × 1e7), for the Data-tab detail-card map
/// preview (SPEC §24).
///
/// Parses the session via [sessionHandleProvider] — the handle is pinned and
/// cached by the residency byte-budget and shared with Analyze, so the preview
/// does not re-parse a session that is already warm — then asks the engine for
/// the polyline (`rust.gpsTrack`, which reads GPS straight from the handle).
/// Resolves to an empty list when the session has no GPS. `autoDispose` so the
/// parse is releasable once the detail card closes (subject to residency).
final sessionGpsPreviewProvider = FutureProvider.autoDispose
    .family<List<GpsFix>, String>((ref, sessionId) async {
  final handle = await ref.watch(sessionHandleProvider(sessionId).future);
  final fixes = await rust.gpsTrack(handle: handle);
  return [for (final f in fixes) gpsFixFromArg(f)];
});
