import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/ui/tabs/analyze/chart_gestures.dart';

/// Builds a tall vertical [ListView] whose first item is a [ChartGestureArea]
/// of fixed size, so tests can exercise the chart-vs-scrollable gesture arena
/// exactly as the worksheet hosts it (a chart inside a scrolling list).
Widget _hostedChart({
  required ScrollController controller,
  void Function(ScaleStartDetails)? onScaleStart,
  void Function(ScaleUpdateDetails)? onScaleUpdate,
  void Function(ScaleEndDetails)? onScaleEnd,
  VoidCallback? onReset,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ListView(
        controller: controller,
        children: [
          ChartGestureArea(
            onScaleStart: onScaleStart,
            onScaleUpdate: onScaleUpdate,
            onScaleEnd: onScaleEnd,
            onReset: onReset,
            child: const SizedBox(height: 300, width: 400),
          ),
          // Filler so the list is taller than the viewport and can scroll.
          const SizedBox(height: 2000),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets(
    'ChartGestureArea — single-finger vertical drag — yields to parent scroll '
    'without claiming the chart or throwing',
    (tester) async {
      // Arrange
      final controller = ScrollController();
      var updates = 0;
      await tester.pumpWidget(
        _hostedChart(
          controller: controller,
          onScaleUpdate: (_) => updates++,
        ),
      );

      // Act — a vertical drag on the chart body.
      await tester.drag(find.byType(ChartGestureArea), const Offset(0, -120));
      await tester.pumpAndSettle();

      // Assert — the parent list scrolled, the chart claimed nothing, and the
      // scale recognizer was never driven into the started→rejected transition
      // that throws at scale.dart:847.
      expect(controller.offset, greaterThan(0));
      expect(updates, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ChartGestureArea — single-finger horizontal drag — scrubs the chart '
    '(pointerCount 1) and does not scroll the parent',
    (tester) async {
      // Arrange
      final controller = ScrollController();
      var updates = 0;
      int? lastPointerCount;
      await tester.pumpWidget(
        _hostedChart(
          controller: controller,
          onScaleUpdate: (d) {
            updates++;
            lastPointerCount = d.pointerCount;
          },
        ),
      );

      // Act — a horizontal drag on the chart body.
      await tester.drag(find.byType(ChartGestureArea), const Offset(120, 0));
      await tester.pumpAndSettle();

      // Assert
      expect(updates, greaterThan(0));
      expect(lastPointerCount, 1);
      expect(controller.offset, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ChartGestureArea — two-finger pinch — fires scale with a non-unit '
    'horizontal scale and pointerCount 2',
    (tester) async {
      // Arrange
      final controller = ScrollController();
      double? reportedScale;
      int? lastPointerCount;
      await tester.pumpWidget(
        _hostedChart(
          controller: controller,
          onScaleUpdate: (d) {
            reportedScale = d.horizontalScale;
            lastPointerCount = d.pointerCount;
          },
        ),
      );

      // Act — two pointers on the chart spreading apart horizontally.
      final center = tester.getCenter(find.byType(ChartGestureArea));
      final g1 = await tester.startGesture(center - const Offset(20, 0));
      final g2 = await tester.startGesture(center + const Offset(20, 0));
      await g1.moveBy(const Offset(-60, 0));
      await g2.moveBy(const Offset(60, 0));
      await tester.pump();
      await g1.up();
      await g2.up();
      await tester.pumpAndSettle();

      // Assert — fingers spread → horizontal scale grows past 1.0.
      expect(reportedScale, isNotNull);
      expect(reportedScale, greaterThan(1.0));
      expect(lastPointerCount, 2);
      expect(controller.offset, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ChartGestureArea — double tap — fires onReset',
    (tester) async {
      // Arrange
      final controller = ScrollController();
      var reset = false;
      await tester.pumpWidget(
        _hostedChart(controller: controller, onReset: () => reset = true),
      );

      // Act
      await tester.tap(find.byType(ChartGestureArea));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byType(ChartGestureArea));
      await tester.pumpAndSettle();

      // Assert
      expect(reset, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
