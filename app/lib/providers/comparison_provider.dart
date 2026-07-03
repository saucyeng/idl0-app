import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/session_model.dart';
import 'lap_provider.dart' show sessionLapsProvider;
import 'selection_provider.dart';

/// Max overlay laps compared against Main (10 laps total). Bounded for chart
/// legibility and the fixed colour palette.
const int kMaxOverlayLaps = 9;

/// One lap in the comparison set, resolved to its [Lap] and Main flag.
class ComparisonLap {
  /// The lap's selection key.
  final LapKey key;

  /// The resolved lap (window, lap time, sectors).
  final Lap lap;

  /// Whether this is the Main (reference) lap.
  final bool isMain;

  /// Creates a [ComparisonLap].
  const ComparisonLap({required this.key, required this.lap, required this.isMain});
}

/// The ordered comparison set: Main first, then overlays by lap time ascending,
/// truncated to [kMaxOverlayLaps].
class ComparisonSet {
  /// `laps[0]` is the effective Main; the rest are overlays.
  final List<ComparisonLap> laps;

  /// Overlays selected beyond [kMaxOverlayLaps] and therefore not shown.
  final int hiddenOverlayCount;

  /// Creates a [ComparisonSet].
  const ComparisonSet({required this.laps, required this.hiddenOverlayCount});

  /// Empty set — nothing comparable selected.
  static const empty = ComparisonSet(laps: [], hiddenOverlayCount: 0);
}

/// Derives the N-lap comparison set from the shared selection. Effective Main is
/// `selection.mainLapKey` when pinned and still selected, else the fastest
/// selected lap. Overlays are the remaining selected laps ordered by lap time;
/// any beyond [kMaxOverlayLaps] are dropped and counted in [hiddenOverlayCount].
final comparisonLapsProvider = Provider<ComparisonSet>((ref) {
  final keys = ref.watch(effectiveLapKeysProvider);
  if (keys.isEmpty) return ComparisonSet.empty;
  final pinnedMain = ref.watch(selectionProvider).mainLapKey;

  // Resolve each key to its Lap via the per-session lap cache.
  final resolved = <({LapKey key, Lap lap})>[];
  for (final k in keys) {
    final laps = ref.watch(sessionLapsProvider(k.sessionId)).valueOrNull;
    if (laps == null) continue;
    Lap? match;
    for (final l in laps) {
      if (l.lapNumber == k.lapNumber) {
        match = l;
        break;
      }
    }
    if (match != null) resolved.add((key: k, lap: match));
  }
  if (resolved.isEmpty) return ComparisonSet.empty;

  // Effective Main: pinned (if still present) else fastest by lap time.
  resolved.sort((a, b) => a.lap.lapTimeMs.compareTo(b.lap.lapTimeMs));
  final mainEntry = (pinnedMain != null)
      ? resolved.firstWhere((e) => e.key == pinnedMain, orElse: () => resolved.first)
      : resolved.first;

  final overlays = resolved.where((e) => e.key != mainEntry.key).toList();
  final shown = overlays.take(kMaxOverlayLaps).toList();
  final hidden = overlays.length - shown.length;

  return ComparisonSet(
    laps: [
      ComparisonLap(key: mainEntry.key, lap: mainEntry.lap, isMain: true),
      for (final e in shown) ComparisonLap(key: e.key, lap: e.lap, isMain: false),
    ],
    hiddenOverlayCount: hidden,
  );
});
