import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/lap_detector.dart';
import 'package:idl0/data/lap_timing.dart';
import 'package:idl0/ui/tabs/data/track_editor_lap_timing_tabs.dart';

void main() {
  const g1 = LapGate(lat1Deg: 1, lon1Deg: 2, lat2Deg: 3, lon2Deg: 4);
  const g2 = LapGate(lat1Deg: 5, lon1Deg: 6, lat2Deg: 7, lon2Deg: 8);

  testWidgets('initial Circuit selects Circuit tab', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TrackEditorLapTimingTabs(
            value: const Circuit(startFinish: g1),
            onChanged: (_) {},
            onPlaceCircuit: () {},
            onPlaceStart: () {},
            onPlaceFinish: () {},
          ),
        ),
      ),
    );

    expect(find.text('Circuit'), findsOneWidget);
    expect(find.text('Point-to-Point'), findsOneWidget);
    expect(find.textContaining('Start/Finish'), findsOneWidget);
  });

  testWidgets('switching from Circuit to P2P promotes the gate to Start',
      (tester) async {
    LapTiming? observed = const Circuit(startFinish: g1);
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (ctx, setState) => MaterialApp(
          home: Scaffold(
            body: TrackEditorLapTimingTabs(
              value: observed,
              onChanged: (v) => setState(() => observed = v),
              onPlaceCircuit: () {},
              onPlaceStart: () {},
              onPlaceFinish: () {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Point-to-Point'));
    await tester.pumpAndSettle();

    expect(observed, isA<PointToPoint>());
    final p = observed! as PointToPoint;
    expect(p.start.lat1Deg, g1.lat1Deg);
    // Finish gets a copy of the same gate as a placeholder; UI shows
    // "[+ Place Finish gate]" prompt.
    expect(find.textContaining('Place'), findsOneWidget);
  });

  testWidgets('switching from P2P to Circuit prompts confirmation',
      (tester) async {
    LapTiming? observed = const PointToPoint(start: g1, finish: g2);
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (ctx, setState) => MaterialApp(
          home: Scaffold(
            body: TrackEditorLapTimingTabs(
              value: observed,
              onChanged: (v) => setState(() => observed = v),
              onPlaceCircuit: () {},
              onPlaceStart: () {},
              onPlaceFinish: () {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Circuit'));
    await tester.pumpAndSettle();

    // Confirmation dialog appears.
    expect(find.text('Use Start as Circuit gate?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Cancellation keeps P2P.
    expect(observed, isA<PointToPoint>());
  });

  testWidgets('null timing — both tabs show placement prompts', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TrackEditorLapTimingTabs(
            value: null,
            onChanged: (_) {},
            onPlaceCircuit: () {},
            onPlaceStart: () {},
            onPlaceFinish: () {},
          ),
        ),
      ),
    );

    expect(find.textContaining('Place Circuit gate'), findsOneWidget);
  });
}
