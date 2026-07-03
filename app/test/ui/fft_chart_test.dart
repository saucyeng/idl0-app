import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/ui/tabs/analyze/fft_chart.dart';

// Render-path coverage (multi-channel legend, event-driven-skipping) lives in
// the integration test suite — the `fft()` Rust bridge cannot be initialised in
// `flutter test`, so widget tests can only cover the early-return paths.
//
// The windowed FftChart is presentational: it takes resolved [requests] plus
// per-channel [renderableMetaById] and renders one of three empty states before
// any spectrum is drawn. These tests pin those three states.
// TODO(idl0): add integration_test for multi-channel FFT rendering.

void main() {
  testWidgets(
    'FftChart — no requests — shows assignment prompt',
    (tester) async {
      // Arrange / Act
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: FftChart(
                requests: [],
                truncated: false,
                renderableMetaById: {},
                worksheetId: 'ws-test',
                slotIndex: 0,
              ),
            ),
          ),
        ),
      );

      // Assert
      expect(find.textContaining('No channel assigned'), findsOneWidget);
    },
  );

  testWidgets(
    'FftChart — request with no fixed-rate metadata — shows fixed-rate message',
    (tester) async {
      // Arrange — an event-driven channel is requested but excluded from the
      // renderable metadata (no fixed sample rate), and no other fixed-rate
      // channel is present, so the most specific message is the fixed-rate one.
      const requests = [
        (
          sessionId: 'sess-1',
          channelId: 'GPS_FixQuality',
          t0Secs: 0.0,
          t1Secs: 1.0,
          label: 'GPS_FixQuality',
        ),
      ];

      // Act
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: FftChart(
                requests: requests,
                truncated: false,
                renderableMetaById: {},
                worksheetId: 'ws-test',
                slotIndex: 0,
              ),
            ),
          ),
        ),
      );

      // Assert
      expect(
        find.textContaining('FFT requires a fixed-rate channel'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'FftChart — fixed-rate channel present but nothing renderable — shows no-data message',
    (tester) async {
      // Arrange — a request references a channel absent from the renderable
      // metadata while a different fixed-rate channel IS present, so the widget
      // reports "no data" rather than "no fixed-rate channel".
      const requests = [
        (
          sessionId: 'sess-1',
          channelId: 'IMU0_AccelZ',
          t0Secs: 0.0,
          t1Secs: 1.0,
          label: 'IMU0_AccelZ',
        ),
      ];
      const meta = {
        'OTHER_CH': SessionChannelData(
          sessionId: 'sess-1',
          channelId: 'OTHER_CH',
          sampleRateHz: 800,
          length: 100,
          isEventDriven: false,
        ),
      };

      // Act
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: FftChart(
                requests: requests,
                truncated: false,
                renderableMetaById: meta,
                worksheetId: 'ws-test',
                slotIndex: 0,
              ),
            ),
          ),
        ),
      );

      // Assert
      expect(find.textContaining('No data'), findsOneWidget);
    },
  );
}
