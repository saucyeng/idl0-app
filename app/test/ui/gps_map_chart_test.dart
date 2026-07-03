import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/channel_provider.dart';
import 'package:idl0/src/rust/tracks.dart';
import 'package:idl0/ui/tabs/analyze/gps_map_chart.dart';

/// Shorthand for the [gpsTrackProvider] record value.
typedef _Track = ({List<GpsFixArg> fixes, double startEpochMs});

void main() {
  testWidgets(
    'GpsMapChart — no GPS fixes in session — shows no-GPS message',
    (tester) async {
      // Arrange — engine returns an empty fix list (e.g. an IMU-only session).
      // Overriding gpsTrackProvider keeps the widget off the Rust bridge, which
      // cannot load headless (memory reference-flutter-test-rust).
      // Act
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            gpsTrackProvider('sess-1').overrideWith(
              (ref) async => (fixes: <GpsFixArg>[], startEpochMs: 0.0),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: GpsMapChart(selectedIds: {'sess-1'}),
            ),
          ),
        ),
      );
      await tester.pump();

      // Assert
      expect(
        find.textContaining('No GPS data in this session'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'GpsMapChart — GPS track still loading — shows no-GPS message',
    (tester) async {
      // Arrange — gpsTrackProvider never completes, so the chart sees no fixes.
      // Act
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            gpsTrackProvider('sess-1').overrideWith(
              (ref) => Completer<_Track>().future,
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: GpsMapChart(selectedIds: {'sess-1'}),
            ),
          ),
        ),
      );
      await tester.pump();

      // Assert — loading state produces no polylines → no-GPS message shown.
      expect(
        find.textContaining('No GPS data in this session'),
        findsOneWidget,
      );
    },
  );
}
