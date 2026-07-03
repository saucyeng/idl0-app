import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/data/workspace.dart';
import 'package:idl0/providers/lap_provider.dart';
import 'package:idl0/providers/selection_provider.dart';
import 'package:idl0/providers/session_provider.dart';
import 'package:idl0/providers/session_workspace_provider.dart';
import 'package:idl0/ui/tabs/analyze/lap_progression_chart.dart';

/// Stubs [SessionWorkspaceNotifier] so widget tests can supply a
/// [Workspace] (with `ignoredLapNumbers` etc.) without disk I/O.
class _StubSessionWorkspaceNotifier extends SessionWorkspaceNotifier {
  _StubSessionWorkspaceNotifier(this._initial);
  final Workspace _initial;

  @override
  Future<Workspace> build(String sessionId) async => _initial;
}

SessionMetadata _meta(String id) => SessionMetadata(
      sessionId: id,
      filePath: '/sessions/$id.idl0',
      workspacePath: '/sessions/$id.idl0w',
      createdTimestampMs:
          DateTime.utc(2026, 4, 20, 10, 30).millisecondsSinceEpoch,
      fileSizeBytes: 0,
      rider: '',
      bike: '',
      bikeComment: '',
      venueName: '',
      eventName: '',
      eventSession: '',
      shortComment: '',
      longComment: '',
      deviceId: '',
    );

/// Helper: synthetic Lap list with [count] laps, each [seconds] long, starting
/// at t=0 and chained back-to-back.
List<Lap> _laps({required int count, required List<int> secondsPerLap}) {
  assert(secondsPerLap.length == count);
  final laps = <Lap>[];
  var t = 0;
  for (var i = 0; i < count; i++) {
    laps.add(Lap(
      lapNumber: i + 1,
      startTimestampMs: t,
      endTimestampMs: t + secondsPerLap[i] * 1000,
      rawElapsedMs: secondsPerLap[i] * 1000,
      lapTimeMs: secondsPerLap[i] * 1000,
    ),);
    t += secondsPerLap[i] * 1000;
  }
  return laps;
}

void main() {
  testWidgets(
    'LapProgressionChart — no selection — shows empty-state message',
    (tester) async {
      // Arrange / Act
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: LapProgressionChart(slotIndex: 0)),
          ),
        ),
      );

      // Assert
      expect(
        find.textContaining('Select sessions or laps'),
        findsOneWidget,
      );
      expect(find.byType(LineChart), findsNothing);
    },
  );

  testWidgets(
    'LapProgressionChart — 3 sessions × 5 laps — renders LineChart with 3 lines',
    (tester) async {
      // Arrange — three sessions, each with 5 laps of varying duration so the
      // fastest-lap marker has a clear winner per session.
      final sess1Laps = _laps(
        count: 5,
        secondsPerLap: [120, 110, 100, 105, 115],
      );
      final sess2Laps = _laps(
        count: 5,
        secondsPerLap: [130, 125, 120, 118, 122],
      );
      final sess3Laps = _laps(
        count: 5,
        secondsPerLap: [115, 112, 110, 108, 109],
      );

      final container = ProviderContainer(
        overrides: [
          sessionLapsProvider('sess-1').overrideWith(
            (ref) => AsyncData<List<Lap>>(sess1Laps),
          ),
          sessionLapsProvider('sess-2').overrideWith(
            (ref) => AsyncData<List<Lap>>(sess2Laps),
          ),
          sessionLapsProvider('sess-3').overrideWith(
            (ref) => AsyncData<List<Lap>>(sess3Laps),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(sessionProvider.notifier).addSession(_meta('sess-1'));
      container.read(sessionProvider.notifier).addSession(_meta('sess-2'));
      container.read(sessionProvider.notifier).addSession(_meta('sess-3'));
      // Selection mode = session, with all three picked.
      container.read(selectionProvider.notifier).toggleSession('sess-1');
      container.read(selectionProvider.notifier).toggleSession('sess-2');
      container.read(selectionProvider.notifier).toggleSession('sess-3');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: LapProgressionChart(slotIndex: 0)),
          ),
        ),
      );
      await tester.pump();

      // Assert — LineChart renders with three line series.
      expect(find.byType(LineChart), findsOneWidget);
      final chart = tester.widget<LineChart>(find.byType(LineChart));
      expect(chart.data.lineBarsData, hasLength(3));
      // X-axis spans 1..5; each line carries five spots.
      for (final bar in chart.data.lineBarsData) {
        expect(bar.spots, hasLength(5));
        expect(bar.spots.first.x, equals(1.0));
        expect(bar.spots.last.x, equals(5.0));
      }
      // Sanity-check a couple of values: sess-1 lap 3 = 100 s, sess-2 lap 4
      // = 118 s.
      expect(chart.data.lineBarsData[0].spots[2].y, equals(100.0));
      expect(chart.data.lineBarsData[1].spots[3].y, equals(118.0));
    },
  );

  testWidgets(
    'LapProgressionChart — lap-mode selection — same session scope still '
    'renders progression',
    (tester) async {
      // Arrange — selection mode lap, with only one lap pinned. The chart's
      // scope (effectiveSessionIdsProvider) should still resolve the parent
      // session and render its full lap progression.
      final sess1Laps = _laps(count: 3, secondsPerLap: [100, 95, 105]);
      final container = ProviderContainer(
        overrides: [
          sessionLapsProvider('sess-1').overrideWith(
            (ref) => AsyncData<List<Lap>>(sess1Laps),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(sessionProvider.notifier).addSession(_meta('sess-1'));
      container
          .read(selectionProvider.notifier)
          .toggleLap(const LapKey(sessionId: 'sess-1', lapNumber: 2));

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: LapProgressionChart(slotIndex: 0)),
          ),
        ),
      );
      await tester.pump();

      // Assert — chart shows the full progression of sess-1 (all three
      // laps), not just the pinned one.
      expect(find.byType(LineChart), findsOneWidget);
      final chart = tester.widget<LineChart>(find.byType(LineChart));
      expect(chart.data.lineBarsData, hasLength(1));
      expect(chart.data.lineBarsData.first.spots, hasLength(3));
    },
  );

  testWidgets(
    'LapProgressionChart — ignored lap on lap table — excluded from line',
    (tester) async {
      // Arrange — sess-1 has 5 laps; mark lap 3 ignored on its workspace.
      final laps = _laps(
        count: 5,
        secondsPerLap: [120, 110, 100, 105, 115],
      );
      final container = ProviderContainer(
        overrides: [
          sessionLapsProvider('sess-1').overrideWith(
            (ref) => AsyncData<List<Lap>>(laps),
          ),
          sessionWorkspaceProvider.overrideWith(
            () => _StubSessionWorkspaceNotifier(
              Workspace.empty('sess-1').copyWith(ignoredLapNumbers: {3}),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(sessionProvider.notifier).addSession(_meta('sess-1'));
      container.read(selectionProvider.notifier).toggleSession('sess-1');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: LapProgressionChart(slotIndex: 0)),
          ),
        ),
      );
      // Pump twice — first to mount, second to land the AsyncNotifier stub.
      await tester.pump();
      await tester.pump();

      // Assert — line drops the ignored lap; remaining four laps keep
      // their original lap numbers as X coords (1, 2, 4, 5).
      final chart = tester.widget<LineChart>(find.byType(LineChart));
      expect(chart.data.lineBarsData, hasLength(1));
      final spots = chart.data.lineBarsData.first.spots;
      expect(spots, hasLength(4));
      expect(spots.map((s) => s.x).toList(), equals([1.0, 2.0, 4.0, 5.0]));
      // Lap 3 (100 s — the true minimum) was the ignored one; with it
      // out, the new "best" is lap 4 at 105 s.
      expect(spots.any((s) => s.y == 100.0), isFalse);
    },
  );
}
