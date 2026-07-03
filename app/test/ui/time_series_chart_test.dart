import 'package:fl_chart/fl_chart.dart'
    show FlSpot, LineChart, LineChartBarData;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/providers/cursor_provider.dart';
import 'package:idl0/providers/workspace_provider.dart';
import 'package:idl0/ui/tabs/analyze/chart_tile_cache.dart';
import 'package:idl0/ui/tabs/analyze/time_series_chart.dart';

List<SessionChannelData> _sampleChannels() => const [
      SessionChannelData(
        sessionId: 's1',
        channelId: 'IMU0_AccelX',
        sampleRateHz: 100,
        length: 500,
        isEventDriven: false,
      ),
    ];

void main() {
  testWidgets(
    'TimeSeriesChart — empty data — renders without crash and shows prompt',
    (tester) async {
      // Arrange / Act
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: TimeSeriesChart(
                channels: [],
                xAxisMode: XAxisMode.time,
                worksheetId: 'test-ws',
                slotIndex: 0,
              ),
            ),
          ),
        ),
      );

      // Assert
      expect(find.byType(TimeSeriesChart), findsOneWidget);
      expect(
        find.text('No data — select sessions in the Data tab.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'TimeSeriesChart — wheelDistance mode, no wheel channels — falls back to time and shows warning',
    (tester) async {
      // Arrange — non-wheel channel with real samples
      const channels = [
        SessionChannelData(
          sessionId: 'sess-1',
          channelId: 'IMU0_AccelZ',
          sampleRateHz: 100,
          length: 3,
          isEventDriven: false,
        ),
      ];

      // Act
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: TimeSeriesChart(
                channels: channels,
                xAxisMode: XAxisMode.wheelDistance,
                worksheetId: 'test-ws',
                slotIndex: 0,
              ),
            ),
          ),
        ),
      );

      // Assert — warning visible, empty-state prompt absent (chart renders)
      expect(
        find.textContaining('Wheel speed data unavailable'),
        findsOneWidget,
      );
      expect(
        find.text('No data — select sessions in the Data tab.'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'TimeSeriesChart — gpsDistance mode, no GPS channel — falls back to time and shows warning',
    (tester) async {
      // Arrange
      const channels = [
        SessionChannelData(
          sessionId: 'sess-1',
          channelId: 'IMU0_AccelZ',
          sampleRateHz: 100,
          length: 3,
          isEventDriven: false,
        ),
      ];

      // Act
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: TimeSeriesChart(
                channels: channels,
                xAxisMode: XAxisMode.gpsDistance,
                worksheetId: 'test-ws',
                slotIndex: 0,
              ),
            ),
          ),
        ),
      );

      // Assert
      expect(find.textContaining('GPS data unavailable'), findsOneWidget);
      expect(
        find.text('No data — select sessions in the Data tab.'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'TimeSeriesChart — cursor B set — chart rebuilds without throwing',
    (tester) async {
      // Arrange
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(cursorProvider('test-ws').notifier).setA(0.5);
      container.read(cursorProvider('test-ws').notifier).setB(1.5);

      const channels = [
        SessionChannelData(
          sessionId: 's',
          channelId: 'ch',
          sampleRateHz: 100,
          length: 5,
          isEventDriven: false,
        ),
      ];

      // Act
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: TimeSeriesChart(
                channels: channels,
                xAxisMode: XAxisMode.time,
                worksheetId: 'test-ws',
                slotIndex: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Assert — chart rendered without throwing; cursor pair reflected
      final pair = container.read(cursorProvider('test-ws'));
      expect(pair.aSecs, equals(0.5));
      expect(pair.bSecs, equals(1.5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TimeSeriesChart — only cursor A pinned — A→B chip absent',
    (tester) async {
      // Arrange
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: TimeSeriesChart(
                channels: _sampleChannels(),
                xAxisMode: XAxisMode.time,
                worksheetId: 'ws-test',
                slotIndex: 0,
              ),
            ),
          ),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TimeSeriesChart)),
      );

      // Act
      container.read(cursorProvider('ws-test').notifier).setA(1.0);
      await tester.pump();

      // Assert
      expect(find.textContaining('A → B'), findsNothing);
    },
  );

  testWidgets(
    'TimeSeriesChart — both cursors pinned — A→B chip with delta',
    (tester) async {
      // Arrange
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: TimeSeriesChart(
                channels: _sampleChannels(),
                xAxisMode: XAxisMode.time,
                worksheetId: 'ws-test',
                slotIndex: 0,
              ),
            ),
          ),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TimeSeriesChart)),
      );

      // Act
      container.read(cursorProvider('ws-test').notifier).setA(1.0);
      container.read(cursorProvider('ws-test').notifier).setB(3.5);
      await tester.pump();

      // Assert
      expect(find.textContaining('A → B'), findsOneWidget);
      expect(find.textContaining('Δ'), findsOneWidget);
    },
  );

  testWidgets(
    'TimeSeriesChart — cursor A unset — no tooltip indicators',
    (tester) async {
      // Arrange / Act — pump with no cursor pinned (default state).
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: TimeSeriesChart(
                channels: _sampleChannels(),
                xAxisMode: XAxisMode.time,
                worksheetId: 'ws-test',
                slotIndex: 0,
              ),
            ),
          ),
        ),
      );

      // Assert — LineChartData is our contract surface with fl_chart;
      // an empty showingTooltipIndicators means no pinned spot is drawn.
      final lineChart = tester.widget<LineChart>(find.byType(LineChart));
      expect(lineChart.data.showingTooltipIndicators, isEmpty);
    },
  );

  testWidgets(
    'TimeSeriesChart — non-empty channels — renders a LineChart with at least one bar',
    (tester) async {
      // Arrange / Act
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chartTileCacheProvider.overrideWithValue(ChartTileCache()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: TimeSeriesChart(
                channels: _sampleChannels(),
                xAxisMode: XAxisMode.time,
                worksheetId: 'ws-render',
                slotIndex: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Assert — the chart constructs LineChartData with bars even when
      // tiles are still loading (upscaling fallback gives empty-but-valid).
      final chart = tester.widget<LineChart>(find.byType(LineChart));
      expect(chart.data.lineBarsData, isNotEmpty);
    },
  );

  testWidgets(
    'TimeSeriesChart — Y-zoom focal-point anchor — slot manual Y range '
    'shifts toward focal point not center',
    (tester) async {
      // Arrange / Act
      final result = computeManualYFocal(
        oldMin: 0,
        oldMax: 10,
        focalY: 8.0,
        verticalScale: 2.0,
      );

      // Assert — focal at 8, span 10 → after 2× zoom new span 5,
      // anchored at focal: newMin = 8 - (8-0)*(1/2) = 4; newMax = 8 + (10-8)*(1/2) = 9.
      expect(result.$1, closeTo(4.0, 1e-9));
      expect(result.$2, closeTo(9.0, 1e-9));
    },
  );

  // ── event-driven X mapping (§21.2) ──────────────────────────────────────

  group('sampleXSeconds —', () {
    test('event-driven channel — reads explicit per-sample time', () {
      // Arrange
      const times = [0.5, 1.0, 1.3];

      // Act + Assert
      expect(sampleXSeconds(timesSecs: times, rate: 0, index: 0), 0.5);
      expect(sampleXSeconds(timesSecs: times, rate: 0, index: 1), 1.0);
      expect(sampleXSeconds(timesSecs: times, rate: 0, index: 2), 1.3);
    });

    test('event-driven channel — index out of range clamps to first/last', () {
      // Arrange
      const times = [0.5, 1.0, 1.3];

      // Act + Assert
      expect(sampleXSeconds(timesSecs: times, rate: 0, index: -3), 0.5);
      expect(sampleXSeconds(timesSecs: times, rate: 0, index: 99), 1.3);
    });

    test('fixed-rate channel — falls back to index / rate', () {
      // Arrange / Act / Assert
      expect(sampleXSeconds(timesSecs: null, rate: 100, index: 50), 0.5);
      // Non-positive rate is treated as 1 Hz.
      expect(sampleXSeconds(timesSecs: null, rate: 0, index: 3), 3.0);
    });
  });

  group('sampleIndexAtTime —', () {
    test('event-driven channel — lower-bound binary search on times', () {
      // Arrange
      const times = [0.5, 1.0, 1.3];

      // Act + Assert — first index with time >= x
      expect(sampleIndexAtTime(timesSecs: times, rate: 0, xSecs: 0.0), 0);
      expect(sampleIndexAtTime(timesSecs: times, rate: 0, xSecs: 0.5), 0);
      expect(sampleIndexAtTime(timesSecs: times, rate: 0, xSecs: 0.6), 1);
      expect(sampleIndexAtTime(timesSecs: times, rate: 0, xSecs: 1.0), 1);
      // Past the end returns length (no sample at or after x).
      expect(sampleIndexAtTime(timesSecs: times, rate: 0, xSecs: 1.4), 3);
    });

    test('fixed-rate channel — floor(x * rate)', () {
      // Arrange / Act / Assert
      expect(sampleIndexAtTime(timesSecs: null, rate: 100, xSecs: 0.5), 50);
      // Non-positive rate is treated as 1 Hz.
      expect(sampleIndexAtTime(timesSecs: null, rate: 0, xSecs: 2.5), 2);
    });
  });

  group('TimeSeriesChart.renderableSpots — all-null bar guard', () {
    // Regression for the LateInitializationError crash on opening a multi-series
    // worksheet: a series whose every spot is FlSpot.nullSpot (all decimation
    // tiles still loading on first open, or an all-NaN/gap window) produced a
    // non-empty, all-(NaN,NaN) LineChartBarData. fl_chart's
    // LineChartHelper.calculateMaxAxisValues skips *empty* bars but reads the
    // `late final mostRightSpot` on any *non-empty* bar — and that field is left
    // uninitialized when a bar has no valid spot — so a second, valid series in
    // the same chart made it throw.

    test('every spot null — collapses to the empty list', () {
      // Arrange
      const spots = [FlSpot.nullSpot, FlSpot.nullSpot, FlSpot.nullSpot];

      // Act
      final result = TimeSeriesChart.renderableSpots(spots);

      // Assert
      expect(result, isEmpty);
    });

    test('at least one finite spot — returns the list unchanged', () {
      // Arrange
      const spots = [FlSpot.nullSpot, FlSpot(1, 2), FlSpot.nullSpot];

      // Act
      final result = TimeSeriesChart.renderableSpots(spots);

      // Assert
      expect(result, same(spots));
    });

    test('empty input — stays empty', () {
      // Arrange
      const spots = <FlSpot>[];

      // Act
      final result = TimeSeriesChart.renderableSpots(spots);

      // Assert
      expect(result, isEmpty);
    });

    test(
      'fl_chart reads mostRightSpot on a non-empty all-null bar — confirms the '
      'crash the guard prevents',
      () {
        // Arrange — the exact bar shape the unguarded chart built.
        final allNull = LineChartBarData(
          spots: const [FlSpot.nullSpot, FlSpot.nullSpot],
        );
        final valid = LineChartBarData(spots: const [FlSpot(0, 0), FlSpot(1, 1)]);

        // Act / Assert — a valid bar exposes its extremes; an all-null bar has no
        // initialized mostRightSpot and throws when fl_chart reads it.
        expect(valid.mostRightSpot, const FlSpot(1, 1));
        expect(() => allNull.mostRightSpot, throwsA(isA<Error>()));
      },
    );

    test('guarding the all-null bar yields an empty bar fl_chart skips', () {
      // Arrange — feed the guard output into the bar instead of raw null spots.
      final guarded = LineChartBarData(
        spots: TimeSeriesChart.renderableSpots(
          const [FlSpot.nullSpot, FlSpot.nullSpot],
        ),
      );

      // Assert — empty bars are guarded by calculateMaxAxisValues (spots.isEmpty
      // → continue), so they never reach the uninitialized mostRightSpot read.
      expect(guarded.spots, isEmpty);
    });
  });
}
