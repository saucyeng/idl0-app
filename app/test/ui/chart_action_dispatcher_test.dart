import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/cursor_pair.dart';
import 'package:idl0/providers/cursor_provider.dart';
import 'package:idl0/providers/workspace_provider.dart';
import 'package:idl0/ui/widgets/chart_action.dart';

void main() {
  late ProviderContainer container;
  const wsId = 'test-ws';

  // Captures the last Y-scale change the dispatcher requested via
  // [ChartActionContext.onApplyYScale]. The dispatcher is now slot-agnostic —
  // it asks its caller to apply Y changes rather than writing a worksheet slot
  // directly, so the chart can be reused outside a worksheet (math preview).
  ({YScaleMode mode, double? yMin, double? yMax})? lastY;

  void captureY({required YScaleMode mode, double? yMin, double? yMax}) {
    lastY = (mode: mode, yMin: yMin, yMax: yMax);
  }

  setUp(() {
    container = ProviderContainer();
    lastY = null;
  });
  tearDown(() => container.dispose());

  ChartActionContext ctxFor({
    double? cursorTimeSecs,
    (double, double) fullDataRange = (0.0, 100.0),
    (double, double)? currentYRange,
    (double, double)? manualYRange,
  }) =>
      ChartActionContext(
        worksheetId: wsId,
        cursorTimeSecs: cursorTimeSecs,
        fullDataRange: fullDataRange,
        currentYRange: currentYRange,
        manualYRange: manualYRange,
        onApplyYScale: captureY,
        read: container.read,
      );

  test('setCursorAHere — writes cursorTimeSecs to cursor A', () {
    // Arrange
    final ctx = ctxFor(cursorTimeSecs: 4.2);

    // Act
    dispatchChartAction(ChartAction.setCursorAHere, ctx);

    // Assert
    expect(container.read(cursorProvider(wsId)).aSecs, equals(4.2));
  });

  test('setCursorBHere — writes cursorTimeSecs to cursor B', () {
    // Arrange
    final ctx = ctxFor(cursorTimeSecs: 7.0);

    // Act
    dispatchChartAction(ChartAction.setCursorBHere, ctx);

    // Assert
    expect(container.read(cursorProvider(wsId)).bSecs, equals(7.0));
  });

  test('setCursorAHere — null cursorTimeSecs is a no-op', () {
    // Arrange
    final ctx = ctxFor(cursorTimeSecs: null);

    // Act
    dispatchChartAction(ChartAction.setCursorAHere, ctx);

    // Assert
    expect(container.read(cursorProvider(wsId)), equals(const CursorPair()));
  });

  test('clearCursorA — keeps B', () {
    // Arrange
    container.read(cursorProvider(wsId).notifier).setA(1.0);
    container.read(cursorProvider(wsId).notifier).setB(2.0);

    // Act
    dispatchChartAction(ChartAction.clearCursorA, ctxFor());

    // Assert
    final pair = container.read(cursorProvider(wsId));
    expect(pair.aSecs, isNull);
    expect(pair.bSecs, equals(2.0));
  });

  test('clearCursorB — keeps A', () {
    // Arrange
    container.read(cursorProvider(wsId).notifier).setA(1.0);
    container.read(cursorProvider(wsId).notifier).setB(2.0);

    // Act
    dispatchChartAction(ChartAction.clearCursorB, ctxFor());

    // Assert
    final pair = container.read(cursorProvider(wsId));
    expect(pair.aSecs, equals(1.0));
    expect(pair.bSecs, isNull);
  });

  test('clearBothCursors — both null', () {
    // Arrange
    container.read(cursorProvider(wsId).notifier).setA(1.0);
    container.read(cursorProvider(wsId).notifier).setB(2.0);

    // Act
    dispatchChartAction(ChartAction.clearBothCursors, ctxFor());

    // Assert
    expect(container.read(cursorProvider(wsId)), equals(const CursorPair()));
  });

  test('resetView — clears X range and cursors and flips Y to auto', () {
    // Arrange
    container.read(workspaceProvider.notifier).setXAxisRange(wsId, 1.0, 5.0);
    container.read(cursorProvider(wsId).notifier).setA(2.0);
    container.read(cursorProvider(wsId).notifier).setB(3.0);

    // Act
    dispatchChartAction(ChartAction.resetView, ctxFor());

    // Assert — X range and cursors cleared; Y returned to auto via callback.
    expect(container.read(workspaceProvider).worksheetRanges[wsId], isNull);
    expect(container.read(cursorProvider(wsId)), equals(const CursorPair()));
    expect(lastY?.mode, equals(YScaleMode.auto));
  });

  test('hZoomIn — halves span centered on current center', () {
    // Arrange — start with full view 0..100; no range set ⇒ implied 0..100
    final ctx = ctxFor(fullDataRange: (0.0, 100.0));

    // Act — span 100 × 0.5 = 50, center 50 ⇒ 25..75
    dispatchChartAction(ChartAction.hZoomIn, ctx);

    // Assert
    final range = container.read(workspaceProvider).worksheetRanges[wsId]!;
    expect(range.startSecs, closeTo(25.0, 1e-9));
    expect(range.endSecs, closeTo(75.0, 1e-9));
  });

  test('hZoomOut — doubles span centered on current center, clamped', () {
    // Arrange — start with 40..60, full data 0..100
    container.read(workspaceProvider.notifier).setXAxisRange(wsId, 40.0, 60.0);
    final ctx = ctxFor(fullDataRange: (0.0, 100.0));

    // Act — span 20 × 2 = 40, center 50 ⇒ 30..70
    dispatchChartAction(ChartAction.hZoomOut, ctx);

    // Assert
    final range = container.read(workspaceProvider).worksheetRanges[wsId]!;
    expect(range.startSecs, closeTo(30.0, 1e-9));
    expect(range.endSecs, closeTo(70.0, 1e-9));
  });

  test('hZoomOut — clamps at full data extent', () {
    // Arrange — small range near right edge
    container.read(workspaceProvider.notifier).setXAxisRange(wsId, 80.0, 90.0);
    final ctx = ctxFor(fullDataRange: (0.0, 100.0));

    // Act — span 10 × 2 = 20, center 85 ⇒ 75..95 (no clamp triggered)
    dispatchChartAction(ChartAction.hZoomOut, ctx);

    // Assert
    final range = container.read(workspaceProvider).worksheetRanges[wsId]!;
    expect(range.startSecs, closeTo(75.0, 1e-9));
    expect(range.endSecs, closeTo(95.0, 1e-9));
  });

  test('hZoomFullOut — clears the range', () {
    // Arrange
    container.read(workspaceProvider.notifier).setXAxisRange(wsId, 1.0, 5.0);

    // Act
    dispatchChartAction(ChartAction.hZoomFullOut, ctxFor());

    // Assert
    expect(container.read(workspaceProvider).worksheetRanges[wsId], isNull);
  });

  test('panRight — shifts right by 25% of span', () {
    // Arrange — range 40..60, full 0..100
    container.read(workspaceProvider.notifier).setXAxisRange(wsId, 40.0, 60.0);
    final ctx = ctxFor(fullDataRange: (0.0, 100.0));

    // Act — span 20, 25% = 5, shift right ⇒ 45..65
    dispatchChartAction(ChartAction.panRight, ctx);

    // Assert
    final range = container.read(workspaceProvider).worksheetRanges[wsId]!;
    expect(range.startSecs, closeTo(45.0, 1e-9));
    expect(range.endSecs, closeTo(65.0, 1e-9));
  });

  test('panLeft — clamps at start when shift would go negative', () {
    // Arrange — range 0..20
    container.read(workspaceProvider.notifier).setXAxisRange(wsId, 0.0, 20.0);
    final ctx = ctxFor(fullDataRange: (0.0, 100.0));

    // Act — already at left edge, span 20, shift left would be -5..15
    dispatchChartAction(ChartAction.panLeft, ctx);

    // Assert — clamped to 0..20 (no movement)
    final range = container.read(workspaceProvider).worksheetRanges[wsId]!;
    expect(range.startSecs, closeTo(0.0, 1e-9));
    expect(range.endSecs, closeTo(20.0, 1e-9));
  });

  test('vZoomIn — halves Y range and applies manual via onApplyYScale', () {
    // Arrange — basis from the chart's rendered range
    final ctx = ctxFor(currentYRange: (0.0, 100.0));

    // Act — span 100 × 0.5 = 50, center 50 ⇒ 25..75
    dispatchChartAction(ChartAction.vZoomIn, ctx);

    // Assert
    expect(lastY?.mode, equals(YScaleMode.manual));
    expect(lastY?.yMin, closeTo(25.0, 1e-9));
    expect(lastY?.yMax, closeTo(75.0, 1e-9));
  });

  test('vZoomOut — doubles Y range from currentYRange', () {
    // Arrange
    final ctx = ctxFor(currentYRange: (10.0, 30.0));

    // Act — span 20 × 2 = 40, center 20 ⇒ 0..40
    dispatchChartAction(ChartAction.vZoomOut, ctx);

    // Assert
    expect(lastY?.yMin, closeTo(0.0, 1e-9));
    expect(lastY?.yMax, closeTo(40.0, 1e-9));
  });

  test('vZoomIn — prefers manualYRange over currentYRange as the basis', () {
    // Arrange — already-manual chart; the manual range is the zoom basis
    final ctx = ctxFor(manualYRange: (0.0, 40.0), currentYRange: (0.0, 100.0));

    // Act — basis 0..40, span 40 × 0.5 = 20, center 20 ⇒ 10..30
    dispatchChartAction(ChartAction.vZoomIn, ctx);

    // Assert
    expect(lastY?.yMin, closeTo(10.0, 1e-9));
    expect(lastY?.yMax, closeTo(30.0, 1e-9));
  });

  test('vZoomFullOut — applies auto via onApplyYScale', () {
    // Arrange / Act
    dispatchChartAction(ChartAction.vZoomFullOut, ctxFor());

    // Assert
    expect(lastY?.mode, equals(YScaleMode.auto));
  });

  test('vZoomIn — no manual or current Y range — no-op', () {
    // Arrange — no Y basis available
    final ctx = ctxFor();

    // Act
    dispatchChartAction(ChartAction.vZoomIn, ctx);

    // Assert — nothing applied
    expect(lastY, isNull);
  });

  test('vZoomIn — null onApplyYScale callback — no-op (no Y control)', () {
    // Arrange — chart with a basis but no Y-apply callback (e.g. fixed Y axis)
    final ctx = ChartActionContext(
      worksheetId: wsId,
      read: container.read,
      currentYRange: (0.0, 100.0),
    );

    // Act / Assert — does not throw, applies nothing
    dispatchChartAction(ChartAction.vZoomIn, ctx);
  });

  test('panUp — shifts manual Y up by 25% of span via onApplyYScale', () {
    // Arrange
    final ctx = ctxFor(currentYRange: (0.0, 100.0));

    // Act — span 100 × 0.25 = 25 ⇒ 25..125
    dispatchChartAction(ChartAction.panUp, ctx);

    // Assert
    expect(lastY?.mode, equals(YScaleMode.manual));
    expect(lastY?.yMin, closeTo(25.0, 1e-9));
    expect(lastY?.yMax, closeTo(125.0, 1e-9));
  });

  test('panDown — shifts manual Y down by 25% of span', () {
    // Arrange
    final ctx = ctxFor(currentYRange: (0.0, 100.0));

    // Act — span 100 × 0.25 = 25 ⇒ -25..75
    dispatchChartAction(ChartAction.panDown, ctx);

    // Assert
    expect(lastY?.yMin, closeTo(-25.0, 1e-9));
    expect(lastY?.yMax, closeTo(75.0, 1e-9));
  });

  test('zoomToCursors — both cursors set — sets X range to (min, max)', () {
    // Arrange
    container.read(cursorProvider(wsId).notifier).setA(7.0);
    container.read(cursorProvider(wsId).notifier).setB(3.0);
    final ctx = ctxFor(fullDataRange: (0.0, 100.0));

    // Act
    dispatchChartAction(ChartAction.zoomToCursors, ctx);

    // Assert — order normalized
    final range = container.read(workspaceProvider).worksheetRanges[wsId]!;
    expect(range.startSecs, equals(3.0));
    expect(range.endSecs, equals(7.0));
  });

  test('zoomToCursors — A unset — no-op', () {
    // Arrange
    container.read(cursorProvider(wsId).notifier).setB(7.0);
    final ctx = ctxFor();

    // Act
    dispatchChartAction(ChartAction.zoomToCursors, ctx);

    // Assert
    expect(container.read(workspaceProvider).worksheetRanges[wsId], isNull);
  });

  test('zoomToCursors — B unset — no-op', () {
    // Arrange
    container.read(cursorProvider(wsId).notifier).setA(7.0);
    final ctx = ctxFor();

    // Act
    dispatchChartAction(ChartAction.zoomToCursors, ctx);

    // Assert
    expect(container.read(workspaceProvider).worksheetRanges[wsId], isNull);
  });

  test('openProperties — invokes callback when set', () {
    // Arrange
    var calls = 0;
    final ctx = ChartActionContext(
      worksheetId: wsId,
      read: container.read,
      onOpenProperties: () => calls++,
    );

    // Act
    dispatchChartAction(ChartAction.openProperties, ctx);

    // Assert
    expect(calls, equals(1));
  });

  test('openProperties — null callback — no-op', () {
    // Arrange / Act
    dispatchChartAction(ChartAction.openProperties, ctxFor());
    // No throw expected; nothing else to assert.
  });

  test('copyCursorValues — invokes callback when set', () {
    // Arrange
    var calls = 0;
    final ctx = ChartActionContext(
      worksheetId: wsId,
      read: container.read,
      onCopyCursorValues: () => calls++,
    );

    // Act
    dispatchChartAction(ChartAction.copyCursorValues, ctx);

    // Assert
    expect(calls, equals(1));
  });
}
