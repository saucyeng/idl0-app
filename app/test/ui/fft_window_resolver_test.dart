import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/ui/tabs/analyze/fft_window_resolver.dart';

void main() {
  group('resolveFftWindows', () {
    test('resolveFftWindows — session-mode unzoomed — one full-session request per channel', () {
      // Arrange
      final result = resolveFftWindows(
        channels: [(sessionId: 's1', channelId: 'Fork')],
        lapMode: false,
        lapsBySession: const {},
        selectedLaps: const {},
        zoom: null,
        sessionDurationSecs: (_) => 120.0,
      );

      // Act / Assert — window is [0, duration].
      expect(result.requests.length, 1);
      expect(result.requests.first.t0Secs, 0.0);
      expect(result.requests.first.t1Secs, 120.0);
      expect(result.requests.first.label, 'Fork');
      expect(result.truncated, isFalse);
    });

    test('resolveFftWindows — session-mode zoomed — window is the zoom span', () {
      // Arrange / Act
      final result = resolveFftWindows(
        channels: [(sessionId: 's1', channelId: 'Fork')],
        lapMode: false,
        lapsBySession: const {},
        selectedLaps: const {},
        zoom: (startSecs: 10.0, endSecs: 25.0),
        sessionDurationSecs: (_) => 120.0,
      );

      // Assert
      expect(result.requests.single.t0Secs, 10.0);
      expect(result.requests.single.t1Secs, 25.0);
    });

    test('resolveFftWindows — lap-mode — one request per (channel x selected lap)', () {
      // Arrange — two laps selected, one channel.
      final result = resolveFftWindows(
        channels: [(sessionId: 's1', channelId: 'Fork')],
        lapMode: true,
        lapsBySession: {
          's1': [(lapNumber: 1, startSecs: 5.0, endSecs: 95.0), (lapNumber: 2, startSecs: 95.0, endSecs: 188.0)],
        },
        selectedLaps: {(sessionId: 's1', lapNumber: 1), (sessionId: 's1', lapNumber: 2)},
        zoom: null,
        sessionDurationSecs: (_) => 200.0,
      );

      // Assert — two labelled lap windows.
      expect(result.requests.length, 2);
      expect(result.requests.map((r) => r.label), containsAll(['Fork · Lap 1', 'Fork · Lap 2']));
      final lap1 = result.requests.firstWhere((r) => r.label == 'Fork · Lap 1');
      expect(lap1.t0Secs, 5.0);
      expect(lap1.t1Secs, 95.0);
    });

    test('resolveFftWindows — over cap — truncates to kMaxFftSpectra and flags it', () {
      // Arrange — 12 laps selected, one channel.
      final laps = [for (var i = 1; i <= 12; i++) (lapNumber: i, startSecs: i * 10.0, endSecs: i * 10.0 + 9.0)];
      final result = resolveFftWindows(
        channels: [(sessionId: 's1', channelId: 'Fork')],
        lapMode: true,
        lapsBySession: {'s1': laps},
        selectedLaps: {for (var i = 1; i <= 12; i++) (sessionId: 's1', lapNumber: i)},
        zoom: null,
        sessionDurationSecs: (_) => 200.0,
      );

      // Assert
      expect(result.requests.length, kMaxFftSpectra);
      expect(result.truncated, isTrue);
    });
  });
}
