import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/providers/comparison_provider.dart';
import 'package:idl0/providers/lap_provider.dart' show sessionLapsProvider;
import 'package:idl0/providers/selection_provider.dart';

Lap lap(int n, int timeMs) => Lap(
      lapNumber: n,
      startTimestampMs: 0,
      endTimestampMs: timeMs,
      rawElapsedMs: timeMs,
      lapTimeMs: timeMs,
      startTimeSecs: 0,
      endTimeSecs: timeMs / 1000.0,
    );

void main() {
  test('comparisonLapsProvider — auto Main is the fastest; overlays sorted', () {
    // Arrange — session s1 laps: #1=90s, #2=80s (fastest), #3=100s. Select all 3.
    final c = ProviderContainer(overrides: [
      sessionLapsProvider('s1').overrideWith(
        (ref) => AsyncData([lap(1, 90000), lap(2, 80000), lap(3, 100000)]),
      ),
    ]);
    addTearDown(c.dispose);
    final sel = c.read(selectionProvider.notifier);
    sel.toggleLap(const LapKey(sessionId: 's1', lapNumber: 1));
    sel.toggleLap(const LapKey(sessionId: 's1', lapNumber: 2));
    sel.toggleLap(const LapKey(sessionId: 's1', lapNumber: 3));

    // Act
    final set = c.read(comparisonLapsProvider);

    // Assert — Main = lap 2 (80s); overlays = lap 1, lap 3 (by time asc).
    expect(set.laps.first.isMain, isTrue);
    expect(set.laps.first.key.lapNumber, 2);
    expect(set.laps.map((l) => l.key.lapNumber).toList(), [2, 1, 3]);
    expect(set.hiddenOverlayCount, 0);
  });

  test('comparisonLapsProvider — pinned Main overrides fastest', () {
    // Arrange — pin lap 3 (slowest) as Main.
    final c = ProviderContainer(overrides: [
      sessionLapsProvider('s1').overrideWith(
        (ref) => AsyncData([lap(1, 90000), lap(2, 80000), lap(3, 100000)]),
      ),
    ]);
    addTearDown(c.dispose);
    final sel = c.read(selectionProvider.notifier);
    sel.toggleLap(const LapKey(sessionId: 's1', lapNumber: 1));
    sel.toggleLap(const LapKey(sessionId: 's1', lapNumber: 2));
    sel.toggleLap(const LapKey(sessionId: 's1', lapNumber: 3));
    sel.setMainLap(const LapKey(sessionId: 's1', lapNumber: 3));

    // Act
    final set = c.read(comparisonLapsProvider);

    // Assert — Main is the pinned lap 3; overlays sorted by time (2, 1).
    expect(set.laps.first.key.lapNumber, 3);
    expect(set.laps.first.isMain, isTrue);
    expect(set.laps.skip(1).map((l) => l.key.lapNumber).toList(), [2, 1]);
  });

  test('comparisonLapsProvider — truncates overlays beyond kMaxOverlayLaps', () {
    // Arrange — 12 laps (1 Main + 11 overlays); cap is 9 overlays.
    final laps = [for (var i = 1; i <= 12; i++) lap(i, 80000 + i * 1000)];
    final c = ProviderContainer(overrides: [
      sessionLapsProvider('s1').overrideWith((ref) => AsyncData(laps)),
    ]);
    addTearDown(c.dispose);
    final sel = c.read(selectionProvider.notifier);
    for (var i = 1; i <= 12; i++) {
      sel.toggleLap(LapKey(sessionId: 's1', lapNumber: i));
    }

    // Act
    final set = c.read(comparisonLapsProvider);

    // Assert — 1 Main + 9 overlays shown; 2 hidden.
    expect(set.laps.length, 1 + kMaxOverlayLaps);
    expect(set.hiddenOverlayCount, 2);
  });
}
