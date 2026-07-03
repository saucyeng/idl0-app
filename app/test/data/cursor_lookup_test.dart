import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/cursor_lookup.dart';

void main() {
  group('nearestEpochIndex —', () {
    test('empty input — returns -1', () {
      // Arrange / Act
      final idx = nearestEpochIndex(const [], 100);

      // Assert
      expect(idx, equals(-1));
    });

    test('target before first — clamps to index 0', () {
      // Arrange
      final samples = [1000.0, 2000.0, 3000.0];

      // Act
      final idx = nearestEpochIndex(samples, 0);

      // Assert
      expect(idx, equals(0));
    });

    test('target after last — clamps to last index', () {
      // Arrange
      final samples = [1000.0, 2000.0, 3000.0];

      // Act
      final idx = nearestEpochIndex(samples, 99999);

      // Assert
      expect(idx, equals(2));
    });

    test('target equals a sample — exact hit', () {
      // Arrange
      final samples = [1000.0, 2000.0, 3000.0, 4000.0];

      // Act
      final idx = nearestEpochIndex(samples, 3000);

      // Assert
      expect(idx, equals(2));
    });

    test('target between two samples — picks closer', () {
      // Arrange — target 2200 is closer to 2000 (idx 1) than 3000 (idx 2).
      final samples = [1000.0, 2000.0, 3000.0];

      // Act
      final near1 = nearestEpochIndex(samples, 2200);
      final near2 = nearestEpochIndex(samples, 2700);

      // Assert
      expect(near1, equals(1));
      expect(near2, equals(2));
    });

    test('exact midpoint — picks lower index (tie-breaking)', () {
      // Arrange — target 2500 is equidistant from 2000 (idx 1) and 3000 (idx 2).
      final samples = [1000.0, 2000.0, 3000.0];

      // Act
      final idx = nearestEpochIndex(samples, 2500);

      // Assert — `loDiff <= hiDiff` favours the lower index.
      expect(idx, equals(1));
    });

    test('large monotonic series — O(log N) binary search returns correct idx',
        () {
      // Arrange — 10 000 samples at 100 ms spacing.
      final samples = List<double>.generate(10000, (i) => i * 100.0);

      // Act — target 314 159 ms → nearest sample is index 3142 (314 200 ms).
      final idx = nearestEpochIndex(samples, 314159);

      // Assert
      expect(idx, equals(3142));
    });
  });

  group('cursorEpochMs / cursorSecondsFromEpoch —', () {
    test('round-trip preserves value', () {
      // Arrange
      const sessionStartMs = 1700000000000.0;
      const cursorSeconds = 42.5;

      // Act
      final epoch = cursorEpochMs(
        sessionStartMs: sessionStartMs,
        cursorSeconds: cursorSeconds,
      );
      final back = cursorSecondsFromEpoch(
        sessionStartMs: sessionStartMs,
        sampleEpochMs: epoch,
      );

      // Assert
      expect(epoch, equals(sessionStartMs + 42500));
      expect(back, closeTo(cursorSeconds, 1e-9));
    });
  });
}
