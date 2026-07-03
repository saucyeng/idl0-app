// Cursor → GPS-sample lookup helpers used by `GpsMapChart` cursor markers
// and tap-to-set-cursor (see §15.5).
//
// Lifted out of `gps_map_chart.dart` so the binary-search math can be unit
// tested without spinning up a `flutter_map` widget. Pure Dart, side-effect
// free.

/// Returns the index in [epochSamples] whose value is closest to [targetMs].
///
/// [epochSamples] must be monotonically non-decreasing — GPS_EpochMs from the
/// firmware satisfies this. Out-of-range targets clamp to the first or last
/// index. Empty input returns -1.
///
/// O(log N) binary search.
int nearestEpochIndex(List<double> epochSamples, double targetMs) {
  if (epochSamples.isEmpty) return -1;
  if (targetMs <= epochSamples.first) return 0;
  if (targetMs >= epochSamples.last) return epochSamples.length - 1;
  int lo = 0;
  int hi = epochSamples.length - 1;
  while (hi - lo > 1) {
    final mid = (lo + hi) >> 1;
    if (epochSamples[mid] <= targetMs) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  final loDiff = (targetMs - epochSamples[lo]).abs();
  final hiDiff = (epochSamples[hi] - targetMs).abs();
  return loDiff <= hiDiff ? lo : hi;
}

/// Computes the absolute UTC milliseconds at the cursor position for a given
/// session: `sessionStartMs + cursorSeconds * 1000`.
///
/// Pure helper kept here so call sites can stay one-liners.
double cursorEpochMs({
  required double sessionStartMs,
  required double cursorSeconds,
}) =>
    sessionStartMs + cursorSeconds * 1000.0;

/// Inverse of [cursorEpochMs] — converts an absolute epoch back to a
/// session-relative cursor (seconds). Used when a tap on the GPS map maps
/// the closest sample's epoch to a cursor write.
double cursorSecondsFromEpoch({
  required double sessionStartMs,
  required double sampleEpochMs,
}) =>
    (sampleEpochMs - sessionStartMs) / 1000.0;
