import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// A [ScaleGestureRecognizer] tuned for a chart that lives inside a vertical
/// scroll view (the worksheet's chart list).
///
/// A plain [ScaleGestureRecognizer] wins the gesture arena on single-pointer pan
/// slop in *any* direction. Inside a scrolling list that makes a one-finger drag
/// fight the list's vertical-drag recognizer; when that fight is lost *after*
/// the scale gesture has already started, Flutter asserts in `scale.dart`
/// `didStopTrackingLastPointer` — the `started → rejected` transition is illegal
/// and surfaces as "false is not true" at scale.dart:847.
///
/// This recognizer claims the arena only when the gesture is unambiguously the
/// chart's:
///   * **two or more pointers** — a pinch (free-form X/Y zoom), or
///   * **a single pointer travelling predominantly horizontally** — a scrub /
///     pan along the (horizontal) time axis.
///
/// A predominantly *vertical* single-finger drag is never claimed, so it falls
/// through to the enclosing scrollable and the worksheet scrolls. Crucially the
/// recognizer only ever transitions to `started` once it has *won* the arena, so
/// it can never be rejected mid-`started` — the framework assertion can no
/// longer fire.
class ChartZoomScrubGestureRecognizer extends ScaleGestureRecognizer {
  /// Creates a [ChartZoomScrubGestureRecognizer].
  ChartZoomScrubGestureRecognizer({super.debugOwner});

  /// Global position where the (single) pointer first went down this gesture.
  /// Used to classify a one-finger drag as horizontal (claim) or vertical
  /// (yield to the parent scrollable).
  Offset? _downPosition;

  /// Most recent global pointer position seen this gesture.
  Offset? _lastPosition;

  @override
  void handleEvent(PointerEvent event) {
    // Record before delegating: super.handleEvent runs the scale state machine,
    // which may call resolve() synchronously and must see the current position.
    if (event is PointerDownEvent) {
      _downPosition ??= event.position;
      _lastPosition = event.position;
    } else if (event is PointerMoveEvent) {
      _lastPosition = event.position;
    }
    super.handleEvent(event);
  }

  @override
  void resolve(GestureDisposition disposition) {
    if (disposition == GestureDisposition.accepted && pointerCount < 2) {
      final down = _downPosition;
      final last = _lastPosition;
      // Too little travel to classify yet, or a vertical-dominant drag: stay a
      // passive arena member rather than claiming. We do NOT reject — leaving
      // the arena entries intact lets a second finger still escalate this into
      // a pinch, and lets a competing recognizer (parent scroll) evict us
      // cleanly while we are merely `possible`. Ties favour the scrollable.
      if (down == null || last == null) return;
      final delta = last - down;
      if (delta.dy.abs() >= delta.dx.abs()) return;
    }
    super.resolve(disposition);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _downPosition = null;
    _lastPosition = null;
    super.didStopTrackingLastPointer(pointer);
  }
}

/// Wraps [child] with the time-series chart's pointer gesture model, arbitrating
/// cleanly with the enclosing scroll view.
///
/// Built on [RawGestureDetector] (not [GestureDetector]) for two reasons: it
/// needs the customised [ChartZoomScrubGestureRecognizer], and Flutter forbids
/// combining `onScale*` with `onHorizontalDrag*` in a [GestureDetector] anyway.
/// The resulting model on touch:
///   * **vertical one-finger drag** → not claimed; the worksheet scrolls.
///   * **horizontal one-finger drag** → [onScaleStart]/[onScaleUpdate]/
///     [onScaleEnd] with `pointerCount == 1` (scrub cursor / pan X).
///   * **two-finger pinch** → the same scale callbacks with `pointerCount >= 2`
///     (free-form X/Y zoom).
///   * **double tap** → [onReset] (reset view); registered only when non-null.
///
/// Behaviour is [HitTestBehavior.opaque] so the whole chart rectangle is
/// interactive even where the painted line leaves gaps.
class ChartGestureArea extends StatelessWidget {
  /// Creates a [ChartGestureArea].
  const ChartGestureArea({
    super.key,
    required this.child,
    this.onScaleStart,
    this.onScaleUpdate,
    this.onScaleEnd,
    this.onReset,
  });

  /// The chart content to make interactive (the [LineChart] stack).
  final Widget child;

  /// Fired when a scrub (1-finger horizontal) or pinch (2-finger) begins.
  final GestureScaleStartCallback? onScaleStart;

  /// Fired as a scrub or pinch progresses. `details.pointerCount` distinguishes
  /// a 1-finger scrub/pan from a multi-finger zoom.
  final GestureScaleUpdateCallback? onScaleUpdate;

  /// Fired when the scrub/pinch ends.
  final GestureScaleEndCallback? onScaleEnd;

  /// Fired on double-tap (reset view). The double-tap recognizer is omitted
  /// entirely when this is null, so double-taps are not consumed.
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        ChartZoomScrubGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
                ChartZoomScrubGestureRecognizer>(
          () => ChartZoomScrubGestureRecognizer(debugOwner: this),
          (instance) => instance
            ..onStart = onScaleStart
            ..onUpdate = onScaleUpdate
            ..onEnd = onScaleEnd,
        ),
        if (onReset != null)
          DoubleTapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
            () => DoubleTapGestureRecognizer(debugOwner: this),
            (instance) => instance..onDoubleTap = onReset,
          ),
      },
      child: child,
    );
  }
}
