import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SingleActivator, VoidCallback;
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderListenable;
import 'package:idl0/providers/cursor_provider.dart';
import 'package:idl0/providers/workspace_provider.dart';

/// Discrete action emitted by [ChartContextMenu] when a user invokes a
/// menu item, gesture, or keybinding. The dispatcher translates each value
/// into provider calls.
enum ChartAction {
  /// Place cursor A at the current pointer time (or no-op when invoked by
  /// keyboard with no pointer-time available).
  setCursorAHere,

  /// Place cursor B at the current pointer time.
  setCursorBHere,

  /// Remove cursor A; cursor B is unchanged.
  clearCursorA,

  /// Remove cursor B; cursor A is unchanged.
  clearCursorB,

  /// Remove both cursors A and B.
  clearBothCursors,

  /// Begin a drag-rectangle zoom window. Gesture-driven; the chart wrapper
  /// applies the X+Y range from the rectangle on release.
  zoomWindow,

  /// Set the X range to span between cursors A and B (no-op if either is
  /// unset).
  zoomToCursors,

  /// Halve the visible X span around its current center.
  hZoomIn,

  /// Double the visible X span around its current center, clamped to
  /// data extent.
  hZoomOut,

  /// Restore the full X data range (clear the worksheet's manual range).
  hZoomFullOut,

  /// Halve the visible Y span around its current center; flips the slot
  /// to manual Y mode.
  vZoomIn,

  /// Double the visible Y span around its current center; flips the slot
  /// to manual Y mode.
  vZoomOut,

  /// Flip the slot back to auto Y mode (yMin/yMax retained for the next
  /// manual flip; matches the properties dialog's existing behavior).
  vZoomFullOut,

  /// Shift the X view by 25% of the current span toward earlier time.
  panLeft,

  /// Shift the X view by 25% of the current span toward later time.
  panRight,

  /// Shift the Y view by 25% of the current span upward (manual Y).
  panUp,

  /// Shift the Y view by 25% of the current span downward (manual Y).
  panDown,

  /// Clear the worksheet's X range, both cursors, and the slot's manual
  /// Y range so the chart returns to its default auto-fit view.
  resetView,

  /// Copy the cursor's time and per-channel values to the clipboard.
  copyCursorValues,

  /// Open the chart's properties dialog.
  openProperties,

  /// Swap the active cursor (A) and datum cursor (B). Bound to `X` —
  /// matches the i2 Pro convention where X promotes the current datum
  /// to the live cursor while parking the live cursor as the new datum.
  /// No-op when both cursors are null; when only one is set, the
  /// remaining slot becomes null and the set slot moves to the other.
  swapCursors,
}

/// How a modifier + mouse-wheel event over a chart is interpreted. Single
/// source of truth for the desktop wheel scheme (SPEC §26):
///
/// - **Ctrl + wheel** → [WheelMode.zoom] the X axis at the cursor.
/// - **Shift + wheel** → [WheelMode.pan] the X axis.
/// - **No modifier** → [WheelMode.none]; the wheel scrolls the worksheet list.
///
/// Ctrl wins when both are held. Alt is intentionally NOT a wheel trigger:
/// holding Alt during an Alt+Tab window switch can leave Alt "stuck pressed"
/// in [HardwareKeyboard] after the missed key-up, which previously made every
/// plain wheel zoom unexpectedly. Keeping the wheel off Alt removes that
/// failure mode.
enum WheelMode {
  /// Plain wheel — not claimed by the chart; the worksheet list scrolls.
  none,

  /// Ctrl + wheel — zoom the shared X range around the cursor.
  zoom,

  /// Shift + wheel — pan the shared X range.
  pan,
}

/// Maps the currently-held modifier keys to a [WheelMode] for a chart wheel
/// event. Pure — the single source of truth for the wheel scheme so the
/// gesture handler and the Settings reference table agree.
WheelMode wheelModeFor({required bool ctrl, required bool shift}) {
  if (ctrl) return WheelMode.zoom;
  if (shift) return WheelMode.pan;
  return WheelMode.none;
}

/// Step factor for `hZoomIn` / `vZoomIn` — new span = current × 0.5.
const double kChartZoomInFactor = 0.5;

/// Step factor for `hZoomOut` / `vZoomOut` — new span = current × 2.0.
const double kChartZoomOutFactor = 2.0;

/// Pan step as a fraction of the current visible span (X or Y).
const double kChartPanStepFraction = 0.25;

/// Default keyboard shortcut for each [ChartAction]. Settings-backed
/// override is a v2 follow-up; in v1 this map is the source of truth.
///
/// Direction convention:
/// - Pan: arrow direction = view shifts toward the arrow
/// - Zoom: Up/Right = zoom in (more magnification), Down/Left = zoom out
final Map<ChartAction, List<SingleActivator>> kDefaultChartBindings = {
  ChartAction.panLeft: [
    const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true),
  ],
  ChartAction.panRight: [
    const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true),
  ],
  ChartAction.panUp: [
    const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true),
  ],
  ChartAction.panDown: [
    const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true),
  ],
  ChartAction.hZoomIn: [
    const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true),
  ],
  ChartAction.hZoomOut: [
    const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true),
  ],
  ChartAction.vZoomIn: [
    const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true),
  ],
  ChartAction.vZoomOut: [
    const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true),
  ],
  ChartAction.hZoomFullOut: [
    const SingleActivator(LogicalKeyboardKey.f2),
  ],
  ChartAction.vZoomFullOut: [
    const SingleActivator(LogicalKeyboardKey.f2, alt: true),
  ],
  ChartAction.zoomToCursors: [
    const SingleActivator(LogicalKeyboardKey.keyZ),
  ],
  ChartAction.swapCursors: [
    const SingleActivator(LogicalKeyboardKey.keyX),
  ],
  ChartAction.copyCursorValues: [
    const SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true),
  ],
  ChartAction.openProperties: [
    const SingleActivator(LogicalKeyboardKey.f5),
  ],
};

/// Typed reader function accepted by [ChartActionContext.read].
///
/// Matches the signature of both `WidgetRef.read` (production) and
/// `ProviderContainer.read` (tests), so the dispatcher is testable without
/// a widget tree.
typedef ChartReader = T Function<T>(ProviderListenable<T> provider);

/// Applies a Y-scale change to the chart the action was triggered on.
///
/// [mode] flips the chart between auto and manual Y. When [yMin]/[yMax] are
/// non-null they set the manual bounds; null leaves the existing bounds
/// untouched (so flipping to auto retains them for the next manual flip).
///
/// The dispatcher calls this instead of mutating a worksheet slot directly, so
/// the same vertical-zoom logic drives both a worksheet chart (callback writes
/// the slot) and the math-editor preview (callback writes local state). A null
/// callback means the chart has no adjustable Y axis — vertical zoom no-ops.
typedef ApplyYScale = void Function({
  required YScaleMode mode,
  double? yMin,
  double? yMax,
});

/// Builds an [ApplyYScale] that writes the chart slot at [slotIndex] in the
/// active worksheet. This is the shared slot-backing used by every Analyze
/// worksheet chart; the math-editor preview supplies its own [ApplyYScale]
/// over local state instead. A null yMin/yMax retains the existing bound (so
/// flipping to auto keeps the values). Out-of-range [slotIndex] is a safe
/// no-op. [read] is a [ChartReader] (`ref.read` / `container.read`).
ApplyYScale slotYScaleWriter(ChartReader read, int slotIndex) {
  return ({required YScaleMode mode, double? yMin, double? yMax}) {
    final ws = read(workspaceProvider).activeWorksheet;
    if (slotIndex < 0 || slotIndex >= ws.charts.length) return;
    final slot = ws.charts[slotIndex];
    read(workspaceProvider.notifier).updateChartProperties(
      slotIndex,
      slot.copyWith(
        yScaleMode: mode,
        yMin: yMin ?? slot.yMin,
        yMax: yMax ?? slot.yMax,
      ),
    );
  };
}

/// The manual Y range (yMin, yMax) of the worksheet chart slot at [slotIndex]
/// when it is in [YScaleMode.manual]; null in auto mode or when [slotIndex]
/// is out of range. The slot-backed counterpart to a preview's local manual
/// range, fed to [ChartActionContext.manualYRange].
(double, double)? slotManualYRange(ChartReader read, int slotIndex) {
  final ws = read(workspaceProvider).activeWorksheet;
  if (slotIndex < 0 || slotIndex >= ws.charts.length) return null;
  final slot = ws.charts[slotIndex];
  if (slot.yScaleMode == YScaleMode.manual &&
      slot.yMin != null &&
      slot.yMax != null) {
    return (slot.yMin!, slot.yMax!);
  }
  return null;
}

/// Context for a single dispatched action. Carries the worksheet identity,
/// the slot the action was triggered on, the data-space cursor time at the
/// pointer (null for keyboard-driven invocations that have no pointer
/// position), and a [ChartReader] the dispatcher uses to access providers.
class ChartActionContext {
  /// Stable UUID of the worksheet whose shared X range and cursors are
  /// affected by horizontal/cursor actions. Charts that are not worksheet
  /// slots (the math-editor preview) pass a private synthetic id so their
  /// X range and cursors stay isolated.
  final String worksheetId;

  /// Data-space cursor time in seconds at the pointer location, or null
  /// when the action was keyboard-triggered.
  final double? cursorTimeSecs;

  /// Full data extent of the active worksheet's longest channel, in
  /// seconds. Used to clamp pan/zoom at boundaries and to initialize the
  /// X range when none has been set.
  final (double, double) fullDataRange;

  /// Provider reader used by the dispatcher. Pass `ref.read` from a
  /// [WidgetRef] in production, or `container.read` from a
  /// [ProviderContainer] in tests. Both satisfy [ChartReader].
  final ChartReader read;

  /// Current rendered Y range (yMin, yMax) of the chart. The auto-fit
  /// fallback basis for vertical zoom when the chart is in [YScaleMode.auto]
  /// — the chart is the only authority for the auto-fit values. Null when the
  /// chart has not yet rendered or has no meaningful Y axis (e.g. lap
  /// progression's value axis is fixed); vertical zoom no-ops in that case.
  final (double, double)? currentYRange;

  /// Current manual Y override (yMin, yMax) when the chart is in
  /// [YScaleMode.manual]; null when it is in auto mode. Takes precedence over
  /// [currentYRange] as the vertical-zoom/pan basis so repeated steps compound
  /// against the bounds the user is actually looking at.
  final (double, double)? manualYRange;

  /// Applies a Y-scale change for vertical zoom/pan and Reset View. See
  /// [ApplyYScale]. Null = the chart has no adjustable Y axis; vertical zoom
  /// no-ops. The caller backs this with a worksheet slot (real charts) or
  /// local state (the math-editor preview).
  final ApplyYScale? onApplyYScale;

  /// Callback invoked by `ChartAction.openProperties`. The chart wrapper
  /// supplies a closure that opens the existing chart properties dialog
  /// (which lives in `chart_workspace.dart` and needs a `BuildContext`).
  /// Null = no dialog available (e.g. lap-table / lap-progression slots);
  /// the menu item should be hidden in that case.
  final VoidCallback? onOpenProperties;

  /// Callback invoked by `ChartAction.copyCursorValues`. The chart wrapper
  /// supplies a closure that builds the copy string from its currently
  /// rendered channels and writes it to the clipboard. Null = no copy
  /// available for this chart type.
  final VoidCallback? onCopyCursorValues;

  /// Creates a [ChartActionContext].
  const ChartActionContext({
    required this.worksheetId,
    required this.read,
    this.cursorTimeSecs,
    this.fullDataRange = (0.0, 1.0),
    this.currentYRange,
    this.manualYRange,
    this.onApplyYScale,
    this.onOpenProperties,
    this.onCopyCursorValues,
  });
}

/// Dispatches a [ChartAction] by translating it into one or more provider
/// mutations. Pure side-effecting function — never builds widgets, never
/// reads `BuildContext`.
///
/// Cursor and X-range actions write to worksheet-scoped providers keyed by
/// `ctx.worksheetId`. Vertical-zoom and Reset View Y changes go through
/// `ctx.onApplyYScale` so the dispatcher never reaches into a worksheet slot
/// itself — the caller decides where the Y range lives (slot or local state).
void dispatchChartAction(ChartAction action, ChartActionContext ctx) {
  switch (action) {
    case ChartAction.setCursorAHere:
      final t = ctx.cursorTimeSecs;
      if (t == null) return;
      ctx.read(cursorProvider(ctx.worksheetId).notifier).setA(t);
    case ChartAction.setCursorBHere:
      final t = ctx.cursorTimeSecs;
      if (t == null) return;
      ctx.read(cursorProvider(ctx.worksheetId).notifier).setB(t);
    case ChartAction.clearCursorA:
      ctx.read(cursorProvider(ctx.worksheetId).notifier).clearA();
    case ChartAction.clearCursorB:
      ctx.read(cursorProvider(ctx.worksheetId).notifier).clearB();
    case ChartAction.clearBothCursors:
      ctx.read(cursorProvider(ctx.worksheetId).notifier).clearBoth();
    case ChartAction.resetView:
      _resetView(ctx);
    case ChartAction.hZoomIn:
      _hZoom(ctx, kChartZoomInFactor);
    case ChartAction.hZoomOut:
      _hZoom(ctx, kChartZoomOutFactor);
    case ChartAction.hZoomFullOut:
      ctx.read(workspaceProvider.notifier).resetXAxisRange(ctx.worksheetId);
    case ChartAction.panLeft:
      _hPan(ctx, -kChartPanStepFraction);
    case ChartAction.panRight:
      _hPan(ctx, kChartPanStepFraction);
    case ChartAction.vZoomIn:
      _vZoom(ctx, kChartZoomInFactor);
    case ChartAction.vZoomOut:
      _vZoom(ctx, kChartZoomOutFactor);
    case ChartAction.vZoomFullOut:
      _vZoomFullOut(ctx);
    case ChartAction.panUp:
      _vPan(ctx, kChartPanStepFraction);
    case ChartAction.panDown:
      _vPan(ctx, -kChartPanStepFraction);
    case ChartAction.zoomToCursors:
      _zoomToCursors(ctx);
    case ChartAction.copyCursorValues:
      ctx.onCopyCursorValues?.call();
    case ChartAction.openProperties:
      ctx.onOpenProperties?.call();
    case ChartAction.swapCursors:
      _swapCursors(ctx);
    case ChartAction.zoomWindow:
      // Gesture-driven; the chart wrapper handles drag-rectangle directly
      // and applies the result via setXAxisRange + updateChartProperties.
      // No dispatcher work for the menu invocation in v1.
      break;
  }
}

/// Returns the current X range for [ctx]'s worksheet, falling back to
/// [ChartActionContext.fullDataRange] when no manual range has been set.
(double, double) _currentXRange(ChartActionContext ctx) {
  final stored = ctx.read(workspaceProvider).worksheetRanges[ctx.worksheetId];
  if (stored != null) return (stored.startSecs, stored.endSecs);
  return ctx.fullDataRange;
}

/// Zooms the X axis by [factor] (< 1 zooms in, > 1 zooms out), anchored at
/// the center of the current span and clamped to [ChartActionContext.fullDataRange].
void _hZoom(ChartActionContext ctx, double factor) {
  final (start, end) = _currentXRange(ctx);
  final span = end - start;
  final newSpan = span * factor;
  final center = (start + end) / 2.0;
  final newStart = center - newSpan / 2.0;
  final newEnd = center + newSpan / 2.0;
  final (fullStart, fullEnd) = ctx.fullDataRange;
  final clampedStart = newStart.clamp(fullStart, fullEnd - 1e-9);
  final clampedEnd = newEnd.clamp(fullStart + 1e-9, fullEnd);
  ctx
      .read(workspaceProvider.notifier)
      .setXAxisRange(ctx.worksheetId, clampedStart, clampedEnd);
}

/// Pans the X axis by [fractionOfSpan] × current span (negative = left,
/// positive = right). Slides the window without shrinking the span when a
/// boundary is hit — the view stops moving at the [ChartActionContext.fullDataRange] edge.
void _hPan(ChartActionContext ctx, double fractionOfSpan) {
  final (start, end) = _currentXRange(ctx);
  final span = end - start;
  final shift = span * fractionOfSpan;
  final (fullStart, fullEnd) = ctx.fullDataRange;
  var newStart = start + shift;
  var newEnd = end + shift;
  if (newStart < fullStart) {
    newEnd += fullStart - newStart;
    newStart = fullStart;
  }
  if (newEnd > fullEnd) {
    newStart -= newEnd - fullEnd;
    newEnd = fullEnd;
  }
  ctx
      .read(workspaceProvider.notifier)
      .setXAxisRange(ctx.worksheetId, newStart, newEnd);
}

/// Returns the effective Y range to use as the vertical zoom/pan basis — the
/// chart's manual `(yMin, yMax)` from [ChartActionContext.manualYRange] when
/// it is in manual mode, otherwise its rendered auto-fit
/// [ChartActionContext.currentYRange]. Null when neither is available, in
/// which case vertical zoom/pan no-ops.
(double, double)? _yBasis(ChartActionContext ctx) =>
    ctx.manualYRange ?? ctx.currentYRange;

/// Zooms the chart's Y axis by [factor] (< 1 zooms in, > 1 zooms out),
/// anchored at the current center. Flips the chart to [YScaleMode.manual] via
/// [ChartActionContext.onApplyYScale] so the new range sticks. No-ops when the
/// basis is unknown or the chart has no Y control.
void _vZoom(ChartActionContext ctx, double factor) {
  final yRange = _yBasis(ctx);
  final apply = ctx.onApplyYScale;
  if (yRange == null || apply == null) return;
  final (yMin, yMax) = yRange;
  final span = yMax - yMin;
  final newSpan = span * factor;
  final center = (yMin + yMax) / 2.0;
  apply(
    mode: YScaleMode.manual,
    yMin: center - newSpan / 2.0,
    yMax: center + newSpan / 2.0,
  );
}

/// Pans the chart's Y axis by [fractionOfSpan] × current span (positive = up)
/// via [ChartActionContext.onApplyYScale], flipping to [YScaleMode.manual] so
/// the new range applies. No-ops when the basis is unknown or there is no Y
/// control.
void _vPan(ChartActionContext ctx, double fractionOfSpan) {
  final yRange = _yBasis(ctx);
  final apply = ctx.onApplyYScale;
  if (yRange == null || apply == null) return;
  final (yMin, yMax) = yRange;
  final span = yMax - yMin;
  final shift = span * fractionOfSpan;
  apply(mode: YScaleMode.manual, yMin: yMin + shift, yMax: yMax + shift);
}

/// Flips the chart to [YScaleMode.auto] without clearing yMin/yMax — the
/// retained values stick for the next manual flip, matching the properties
/// dialog UX. No-ops when the chart has no Y control.
void _vZoomFullOut(ChartActionContext ctx) {
  ctx.onApplyYScale?.call(mode: YScaleMode.auto);
}

/// Zooms the X axis to span between cursor A and cursor B. No-op when
/// either cursor is unset. Order-independent — the smaller value becomes
/// the new start.
void _zoomToCursors(ChartActionContext ctx) {
  final pair = ctx.read(cursorProvider(ctx.worksheetId));
  final a = pair.aSecs;
  final b = pair.bSecs;
  if (a == null || b == null) return;
  final (start, end) = a < b ? (a, b) : (b, a);
  ctx
      .read(workspaceProvider.notifier)
      .setXAxisRange(ctx.worksheetId, start, end);
}

/// Swaps the active cursor (A) and the datum cursor (B). Reads the current
/// pair, then writes each value back into the other slot via the existing
/// `setA` / `setB` / `clearA` / `clearB` mutators so any provider listener
/// sees a single coherent state transition.
void _swapCursors(ChartActionContext ctx) {
  final pair = ctx.read(cursorProvider(ctx.worksheetId));
  final a = pair.aSecs;
  final b = pair.bSecs;
  if (a == null && b == null) return;
  final notifier = ctx.read(cursorProvider(ctx.worksheetId).notifier);
  if (b == null) {
    notifier.setB(a!);
    notifier.clearA();
  } else if (a == null) {
    notifier.setA(b);
    notifier.clearB();
  } else {
    notifier.setA(b);
    notifier.setB(a);
  }
}

void _resetView(ChartActionContext ctx) {
  ctx.read(workspaceProvider.notifier).resetXAxisRange(ctx.worksheetId);
  ctx.read(cursorProvider(ctx.worksheetId).notifier).clearBoth();
  // Return Y to auto via the caller's seam; retains yMin/yMax for stickiness.
  ctx.onApplyYScale?.call(mode: YScaleMode.auto);
}
