import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/ui/widgets/time_format.dart';

void main() {
  group('formatTimeAxisLabel', () {
    test('formatTimeAxisLabel — sub-second — two decimals with s suffix', () {
      // Arrange / Act / Assert
      expect(formatTimeAxisLabel(0.5), equals('0.50s'));
      expect(formatTimeAxisLabel(0.0), equals('0.00s'));
    });

    test('formatTimeAxisLabel — under 10 seconds — one decimal', () {
      // Arrange / Act / Assert
      expect(formatTimeAxisLabel(5.5), equals('5.5s'));
      expect(formatTimeAxisLabel(9.0), equals('9.0s'));
    });

    test('formatTimeAxisLabel — under a minute — integer seconds', () {
      // Arrange / Act / Assert
      expect(formatTimeAxisLabel(45.0), equals('45s'));
      expect(formatTimeAxisLabel(59.4), equals('59s'));
    });

    test(
        'formatTimeAxisLabel — exact minute boundary — switches to M:SS '
        'format', () {
      // Arrange / Act / Assert
      expect(formatTimeAxisLabel(60.0), equals('1:00'));
      expect(formatTimeAxisLabel(120.0), equals('2:00'));
    });

    test('formatTimeAxisLabel — fractional seconds in MM:SS — single decimal',
        () {
      // Arrange / Act / Assert
      expect(formatTimeAxisLabel(125.5), equals('2:05.5'));
      expect(formatTimeAxisLabel(127.5), equals('2:07.5'));
    });

    test('formatTimeAxisLabel — values >= 10 minutes — multi-digit minutes',
        () {
      // Arrange / Act / Assert
      expect(formatTimeAxisLabel(600.0), equals('10:00'));
      // 1 hour 1 minute 1 second: long sessions cross over to H:MM:SS
      // so labels stay compact on tight x-axis spans.
      expect(formatTimeAxisLabel(3661.0), equals('1:01:01'));
    });

    test('formatTimeAxisLabel — negative seconds — leading minus sign', () {
      // Arrange / Act / Assert
      expect(formatTimeAxisLabel(-5.0), equals('-5.0s'));
      expect(formatTimeAxisLabel(-90.0), equals('-1:30'));
    });

    test(
        'formatTimeAxisLabel — interval drives precision so zoomed-in ticks '
        'stay distinct above 10 s', () {
      // Arrange — at a 0.1 s tick interval, 12.1 must not collapse to "12s"
      // (the magnitude heuristic alone would drop the decimal above 10 s).
      // Act / Assert
      expect(formatTimeAxisLabel(12.1, intervalSecs: 0.1), equals('12.1s'));
      expect(formatTimeAxisLabel(12.0, intervalSecs: 0.1), equals('12.0s'));
      // A 0.05 s interval needs two decimals.
      expect(formatTimeAxisLabel(12.05, intervalSecs: 0.05), equals('12.05s'));
    });

    test(
        'formatTimeAxisLabel — interval adds decimals to the MM:SS seconds '
        'field', () {
      // Arrange / Act / Assert — 0.1 s ticks past a minute keep one decimal;
      // a whole value still shows it (so neighbours read 2:05.0 / 2:05.1).
      expect(formatTimeAxisLabel(125.0, intervalSecs: 0.1), equals('2:05.0'));
      expect(formatTimeAxisLabel(125.05, intervalSecs: 0.01), equals('2:05.05'));
    });

    test(
        'formatTimeAxisLabel — interval >= 1 s keeps integer seconds '
        '(no spurious decimals)', () {
      // Arrange / Act / Assert
      expect(formatTimeAxisLabel(45.0, intervalSecs: 5), equals('45s'));
      expect(formatTimeAxisLabel(120.0, intervalSecs: 30), equals('2:00'));
    });
  });

  group('formatTimeReadout', () {
    test('formatTimeReadout — sub-minute — three decimals with s suffix', () {
      // Arrange / Act / Assert
      expect(formatTimeReadout(1.234), equals('1.234 s'));
      expect(formatTimeReadout(0.5), equals('0.500 s'));
    });

    test('formatTimeReadout — over a minute — M:SS.fff with zero-padding',
        () {
      // Arrange / Act / Assert
      expect(formatTimeReadout(83.456), equals('1:23.456'));
      expect(formatTimeReadout(60.0), equals('1:00.000'));
      expect(formatTimeReadout(125.005), equals('2:05.005'));
    });

    test('formatTimeReadout — negative value — leading minus sign', () {
      // Arrange / Act / Assert
      expect(formatTimeReadout(-3.14), equals('-3.140 s'));
      expect(formatTimeReadout(-83.456), equals('-1:23.456'));
    });
  });
}
