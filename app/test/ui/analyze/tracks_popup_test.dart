import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/track.dart';
import 'package:idl0/ui/tabs/analyze/tracks_popup.dart';

void main() {
  testWidgets('empty state renders Create-new button only', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () =>
                  TracksPopup.show(ctx, tracksWithLapCounts: const []),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No tracks detected'), findsOneWidget);
    expect(
      find.textContaining('Create new Track from segment'),
      findsOneWidget,
    );
  });

  testWidgets('non-empty state renders one row per Track', (tester) async {
    final t1 = Track.create(name: 'A-Line', venueName: 'V');
    final t2 = Track.create(name: 'Schleyer', venueName: 'V');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => TracksPopup.show(
                ctx,
                tracksWithLapCounts: [
                  (track: t1, lapCount: 18),
                  (track: t2, lapCount: 4),
                ],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('A-Line'), findsOneWidget);
    expect(find.text('Schleyer'), findsOneWidget);
    expect(find.textContaining('18 laps'), findsOneWidget);
    expect(find.textContaining('4 laps'), findsOneWidget);
  });
}
