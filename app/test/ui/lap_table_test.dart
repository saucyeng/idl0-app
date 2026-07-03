import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/data/workspace.dart';
import 'package:idl0/providers/lap_provider.dart';
import 'package:idl0/providers/selection_provider.dart';
import 'package:idl0/providers/session_provider.dart';
import 'package:idl0/providers/session_workspace_provider.dart';
import 'package:idl0/ui/tabs/analyze/lap_table.dart';

SessionMetadata _meta(String id) => SessionMetadata(
      sessionId: id,
      filePath: '/sessions/$id.idl0',
      workspacePath: '/sessions/$id.idl0w',
      createdTimestampMs: DateTime.utc(2026, 4, 20, 10, 30).millisecondsSinceEpoch,
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

/// Stubs out [SessionWorkspaceNotifier] so widget tests can inject a fixed
/// [Workspace] without performing file I/O.
class _StubSessionWorkspaceNotifier extends SessionWorkspaceNotifier {
  _StubSessionWorkspaceNotifier(this._initial);
  final Workspace _initial;

  @override
  Future<Workspace> build(String sessionId) async => _initial;
}

void main() {
  testWidgets(
    'LapTable — no sessions selected — renders nothing',
    (tester) async {
      // Arrange / Act
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: Scaffold(body: LapTable())),
        ),
      );

      // Assert — widget renders but is empty (no text)
      expect(find.byType(LapTable), findsOneWidget);
      expect(find.textContaining('No laps detected'), findsNothing);
    },
  );

  testWidgets(
    'LapTable — session selected with empty laps — shows no-laps message',
    (tester) async {
      // Arrange
      final container = ProviderContainer(
        overrides: [
          sessionLapsProvider('sess-1').overrideWith(
            (ref) => const AsyncData<List<Lap>>([]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(sessionProvider.notifier).addSession(_meta('sess-1'));
      container.read(selectionProvider.notifier).toggleSession('sess-1');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: LapTable())),
        ),
      );
      // Pump twice: first to build, second to resolve the FutureProvider.
      await tester.pump();
      await tester.pump();

      // Assert
      expect(
        find.textContaining('No laps detected'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'LapTable — workspace pins lap 2 as reference — flag icon appears on lap 2',
    (tester) async {
      // Arrange — stub the workspace notifier so the table reads
      // referenceLapNumber=2 without touching the filesystem.
      final laps = [
        const Lap(
          lapNumber: 1,
          startTimestampMs: 0,
          endTimestampMs: 95000,
          rawElapsedMs: 95000,
          lapTimeMs: 95000,
        ),
        const Lap(
          lapNumber: 2,
          startTimestampMs: 95000,
          endTimestampMs: 192000,
          rawElapsedMs: 97000,
          lapTimeMs: 97000,
        ),
      ];
      final container = ProviderContainer(
        overrides: [
          sessionLapsProvider('sess-1').overrideWith(
            (ref) => AsyncData<List<Lap>>(laps),
          ),
          sessionWorkspaceProvider.overrideWith(
            () => _StubSessionWorkspaceNotifier(
              Workspace.empty('sess-1').copyWith(referenceLapNumber: 2),
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
          child: const MaterialApp(home: Scaffold(body: LapTable())),
        ),
      );
      // Pump twice — once to mount, once for the AsyncNotifier's stub
      // build to land on the next frame.
      await tester.pump();
      await tester.pump();

      // Assert — flag icon (Icons.flag) renders exactly once (next to lap 2).
      // The ghost compare-arrows column was removed with the ghost-chart
      // wiring; only the reference-lap flag remains.
      expect(find.byIcon(Icons.flag), findsOneWidget);
    },
  );

  testWidgets(
    'LapTable — lap 2 ignored — best is min of 1/3/4, lap 2 row greyed',
    (tester) async {
      // Arrange — four laps, lap 2 is ignored. Lap 2 has the fastest raw
      // time (90s) but should be excluded from best-lap selection. Best
      // becomes lap 3 at 95s.
      final laps = [
        const Lap(
          lapNumber: 1,
          startTimestampMs: 0,
          endTimestampMs: 100000,
          rawElapsedMs: 100000,
          lapTimeMs: 100000,
        ),
        const Lap(
          lapNumber: 2,
          startTimestampMs: 100000,
          endTimestampMs: 190000,
          rawElapsedMs: 90000,
          lapTimeMs: 90000,
        ),
        const Lap(
          lapNumber: 3,
          startTimestampMs: 190000,
          endTimestampMs: 285000,
          rawElapsedMs: 95000,
          lapTimeMs: 95000,
        ),
        const Lap(
          lapNumber: 4,
          startTimestampMs: 285000,
          endTimestampMs: 390000,
          rawElapsedMs: 105000,
          lapTimeMs: 105000,
        ),
      ];
      final container = ProviderContainer(
        overrides: [
          sessionLapsProvider('sess-ignored').overrideWith(
            (ref) => AsyncData<List<Lap>>(laps),
          ),
          sessionWorkspaceProvider.overrideWith(
            () => _StubSessionWorkspaceNotifier(
              Workspace.empty('sess-ignored').copyWith(
                ignoredLapNumbers: const {2},
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(sessionProvider.notifier).addSession(_meta('sess-ignored'));
      container.read(selectionProvider.notifier).toggleSession('sess-ignored');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: LapTable())),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Assert — best non-ignored is lap 3 → exactly one star marker.
      expect(find.byIcon(Icons.star), findsOneWidget);
      // Lap 2's ignore button shows the "unignore" icon (visibility_off);
      // the other 3 rows show the "ignore" (block) icon. The "Show ignored"
      // worksheet header uses Icons.visibility when ON (default), so it
      // does not contribute to either count.
      expect(find.byIcon(Icons.visibility_off), findsOneWidget);
      expect(find.byIcon(Icons.block), findsNWidgets(3));
      // All four lap rows render — ignored laps stay visible by default.
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
    },
  );

  testWidgets(
    'LapTable — session with two laps — renders lap numbers and highlights best',
    (tester) async {
      // Arrange — lap 1 is 95 s (best), lap 2 is 97 s
      final laps = [
        const Lap(
          lapNumber: 1,
          startTimestampMs: 0,
          endTimestampMs: 95000,
          rawElapsedMs: 95000,
          lapTimeMs: 95000,
        ),
        const Lap(
          lapNumber: 2,
          startTimestampMs: 95000,
          endTimestampMs: 192000,
          rawElapsedMs: 97000,
          lapTimeMs: 97000,
        ),
      ];
      final container = ProviderContainer(
        overrides: [
          sessionLapsProvider('sess-1').overrideWith(
            (ref) => AsyncData<List<Lap>>(laps),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(sessionProvider.notifier).addSession(_meta('sess-1'));
      container.read(selectionProvider.notifier).toggleSession('sess-1');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: LapTable())),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Assert — both lap numbers rendered; no-laps message absent
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.textContaining('No laps detected'), findsNothing);
      // Best lap delta shown as em-dash
      expect(find.text('—'), findsOneWidget);
    },
  );

  testWidgets(
    'LapTable — tap session-row checkbox in lap-mode — flips back to '
    'session-mode and toggles that session',
    (tester) async {
      // Arrange — start in lap-mode with one lap pinned; the session-row
      // header checkbox should be muted but still clickable. Tapping it
      // flips to session-mode and selects the parent session.
      final laps = [
        const Lap(
          lapNumber: 1,
          startTimestampMs: 0,
          endTimestampMs: 100000,
          rawElapsedMs: 100000,
          lapTimeMs: 100000,
        ),
      ];
      final container = ProviderContainer(
        overrides: [
          sessionLapsProvider('sess-1').overrideWith(
            (ref) => AsyncData<List<Lap>>(laps),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(sessionProvider.notifier).addSession(_meta('sess-1'));
      container
          .read(selectionProvider.notifier)
          .toggleLap(const LapKey(sessionId: 'sess-1', lapNumber: 1));
      expect(
        container.read(selectionProvider).mode,
        equals(SelectionMode.lap),
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: LapTable())),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Act — the session header's checkbox is muted in lap-mode; tap it.
      final sessionCheckbox =
          find.byTooltip('Tap to switch to session selection');
      expect(sessionCheckbox, findsOneWidget);
      await tester.tap(sessionCheckbox);
      await tester.pump();

      // Assert — flipped to session-mode with sess-1 in the selection.
      final sel = container.read(selectionProvider);
      expect(sel.mode, equals(SelectionMode.session));
      expect(sel.sessionIds, equals({'sess-1'}));
      expect(sel.lapKeys, isEmpty);
    },
  );
}
