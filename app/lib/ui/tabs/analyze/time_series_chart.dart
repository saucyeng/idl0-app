import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        kSecondaryMouseButton,
        PointerScrollEvent,
        PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HardwareKeyboard;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/cursor_pair.dart';
import '../../../data/session_model.dart';
import '../../../data/y_scale.dart';
import '../../../providers/channel_provider.dart'
    show
        sessionHandleProvider,
        channelBoundsProvider,
        channelSampleTimesProvider;
import '../../../providers/cursor_provider.dart';
import '../../../providers/selection_provider.dart';
import '../../../providers/workspace_provider.dart';
import '../../../src/rust/chart_decimation.dart' as rust;
import '../../brand/brand.dart';
import '../../widgets/chart_action.dart';
import '../../widgets/chart_context_menu.dart';
import '../../widgets/time_format.dart';
import '../../widgets/value_format.dart';
import 'chart_gestures.dart';
import 'chart_tile_cache.dart';
import 'chart_workspace.dart' show ChartPropertiesDialog, confirmRemoveChart;

/// Returns true if [channels] contains at least one wheel speed channel.
///
/// Checks for exact channel IDs `WheelFront` or `WheelRear` from the
/// channel registry (§5.2).
bool hasWheelData(List<SessionChannelData> channels) => channels.any(
      (c) => c.channelId == 'WheelFront' || c.channelId == 'WheelRear',
    );

/// Returns true if [channels] contains a GPS speed channel.
///
/// Checks for exact channel ID `GPSSpeed` from the channel registry (§5.2).
bool hasGpsData(List<SessionChannelData> channels) =>
    channels.any((c) => c.channelId == 'GPSSpeed');

/// A single time-series chart in the Analyze tab. See §14.1.
///
/// Renders one coloured line per [SessionChannelData] entry. When [channels]
/// is empty the widget shows an instruction prompt instead of a chart.
///
/// [xAxisMode] controls what the X axis represents. When the requested mode
/// requires data that is absent (no wheel or GPS channels), the chart falls
/// back to [XAxisMode.time] and shows a warning banner.
///
/// [worksheetId] is the stable UUID used to look up the shared [cursorProvider]
/// so every chart in the same worksheet keeps its cursor line in sync.
///
/// [slotIndex] is this chart's index in the active worksheet — used by the
/// context menu wrapper to dispatch slot-local actions (vertical zoom,
/// properties).
///
/// Optional [yMin]/[yMax] clip the Y axis; null means auto-scale.
/// [channelColors] maps channel IDs to ARGB ints, overriding palette colours.
///
/// **Zoom/pan:** Gestures go through [ChartGestureArea], which arbitrates with
/// the worksheet's scroll list by axis and pointer count:
///   * **horizontal one-finger drag** → moves cursor A (touch) / pans (desktop),
///   * **two-finger pinch** → free-form zoom (horizontal scale drives X zoom;
///     vertical scale drives Y zoom when the slot is in [YScaleMode.manual]),
///   * **vertical one-finger drag** → not claimed; the worksheet scrolls.
///
/// X-range changes are committed to [workspaceProvider] via
/// [WorkspaceNotifier.setXAxisRange]; all charts in the worksheet share one
/// [XAxisRange], so zooming one chart zooms all. Double-tap dispatches
/// [ChartAction.resetView] which clears X range, both cursors, and the slot's
/// manual Y mode.
///
/// **Context menu:** Right-click (desktop) and long-press (mobile) on the
/// chart canvas open a [ChartContextMenu] with cursor / zoom / pan / reset
/// commands and Properties... shortcut.
class TimeSeriesChart extends ConsumerStatefulWidget {
  /// Creates a [TimeSeriesChart].
  const TimeSeriesChart({
    super.key,
    required this.channels,
    required this.xAxisMode,
    required this.worksheetId,
    required this.slotIndex,
    this.yMin,
    this.yMax,
    this.channelColors = const {},
    this.showZeroLine = false,
    this.yScale = YScale.linear,
    this.onApplyYScale,
    this.manualYRange,
  });

  /// Data series to render — one line per entry.
  final List<SessionChannelData> channels;

  /// Requested X axis mode; falls back to time if the required data is absent.
  final XAxisMode xAxisMode;

  /// Stable UUID of the containing worksheet, used to share cursor state
  /// and X-axis zoom range.
  final String worksheetId;

  /// Index of this chart's slot in the active worksheet — used by the
  /// context menu wrapper to dispatch slot-local actions (vertical zoom,
  /// properties).
  final int slotIndex;

  /// Fixed Y axis minimum in data units. Null = auto-scale.
  final double? yMin;

  /// Fixed Y axis maximum in data units. Null = auto-scale.
  final double? yMax;

  /// Per-channel colour overrides keyed by [ChannelData.channelId], as ARGB
  /// int values. Channels absent from this map use the auto-assigned palette.
  final Map<String, int> channelColors;

  /// Whether to draw a dashed horizontal reference line at Y=0.
  final bool showZeroLine;

  /// Y-axis display scale applied to the rendered spots and axis labels.
  final YScale yScale;

  /// Optional Y-scale writer for hosts that are not a worksheet slot (the
  /// math-editor preview). When null (every Analyze worksheet chart) vertical
  /// zoom/pan and Reset View back onto the slot at [slotIndex] via
  /// [slotYScaleWriter]. See [ApplyYScale].
  final ApplyYScale? onApplyYScale;

  /// The chart's current manual Y override (yMin, yMax) when hosted outside a
  /// worksheet (preview mode); null in auto mode or for worksheet charts
  /// (those read the slot). Paired with [onApplyYScale].
  final (double, double)? manualYRange;

  /// Resolves the rendered colour for [channelId] at palette index
  /// [paletteIndex], honouring [channelColors] ARGB overrides. Public so the
  /// channel-legend overlay can dot-match the chart line colour without
  /// duplicating the palette logic. Defaults cycle the [brandChartPalette].
  static Color resolveLineColor({
    required String channelId,
    required int paletteIndex,
    required Map<String, int> channelColors,
  }) {
    final override = channelColors[channelId];
    if (override != null) return Color(override);
    return brandChartPalette[paletteIndex % brandChartPalette.length];
  }

  /// Sanitises a series' spot list before it becomes a [LineChartBarData],
  /// collapsing an all-[FlSpot.nullSpot] list to `const []`.
  ///
  /// A series is entirely null spots while its decimation tiles are still in
  /// flight on first sheet open ([_TimeSeriesChartState._spotsForChannel] emits
  /// a gap per unloaded tile) or when its whole visible window is NaN (a
  /// lap-aware math channel outside its lap). fl_chart's
  /// `LineChartHelper.calculateMaxAxisValues` skips *empty* bars when
  /// auto-scaling axes, but reads the `late final mostRightSpot` on any
  /// *non-empty* bar — and that field is left uninitialized when a bar has no
  /// non-null spot, throwing a `LateInitializationError`. Its all-null
  /// early-return only covers the *first* non-empty bar, so a second, valid
  /// series in the same chart triggers the crash. Returning the empty list
  /// keeps fl_chart on its guarded path; the bar draws nothing either way.
  ///
  /// Returns [spots] unchanged when it holds at least one non-null spot.
  static List<FlSpot> renderableSpots(List<FlSpot> spots) =>
      spots.any((s) => !s.x.isNaN || !s.y.isNaN) ? spots : const [];

  @override
  ConsumerState<TimeSeriesChart> createState() => _TimeSeriesChartState();
}

class _TimeSeriesChartState extends ConsumerState<TimeSeriesChart> {
  /// Key on the GestureDetector — used to read render width for pixel→data
  /// conversion.
  final GlobalKey _chartKey = GlobalKey();

  /// Last [hoverCursorProvider] write — raw mouse motion fires dozens of
  /// events per 16 ms frame and every write rebuilds every chart on the
  /// worksheet, so hover writes are throttled to ~30 Hz (mirrors the GPS
  /// map's throttle).
  DateTime _lastHoverWrite = DateTime.fromMillisecondsSinceEpoch(0);

  /// Coalesces many near-simultaneous tile arrivals into one repaint —
  /// first paint of a wide viewport lands dozens of tiles within a few ms,
  /// and one setState per tile is a repaint storm.
  Timer? _tileRepaintTimer;

  @override
  void dispose() {
    _tileRepaintTimer?.cancel();
    super.dispose();
  }

  void _scheduleTileRepaint() {
    if (_tileRepaintTimer?.isActive ?? false) return;
    _tileRepaintTimer = Timer(const Duration(milliseconds: 16), () {
      if (mounted) setState(() {});
    });
  }

  // ── Zoom/pan gesture state ─────────────────────────────────────────────

  /// Data-space X range at the start of the current scale gesture.
  double? _gestureRangeStart;
  double? _gestureRangeEnd;

  /// Data-space X value under the focal point at gesture start.
  /// Stays fixed while the user zooms — the point under the fingers
  /// does not drift.
  double? _gestureFocalDataX;

  /// Number of pointers currently on the chart. Drives tooltip
  /// suppression: > 1 means the user is pinching, so we hide the
  /// pinned-cursor tooltip to avoid visual thrash while the focal
  /// point moves.
  int _pointerCount = 0;

  /// Local pan-preview X range, owned by this chart for the duration of
  /// a single drag gesture. When non-null, [_buildChartData] renders against
  /// this value instead of the worksheet-shared `worksheetRanges` provider.
  ///
  /// We never write to the provider mid-drag — that would mark every chart
  /// in the worksheet dirty on every tick. Instead [_onScaleEnd] flushes
  /// the final value, and other charts catch up in one repaint.
  (double, double)? _localPanX;

  /// Bitfield of currently-pressed mouse buttons (from [PointerEvent.buttons]).
  /// Tracked via [Listener] so [_onScaleUpdate] can distinguish a primary
  /// click-drag (pan) from a secondary click-drag (context menu's zoom
  /// rectangle).
  int _activeButtons = 0;

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (widget.channels.isEmpty ||
        widget.channels.every((c) => c.length == 0)) {
      return Center(
        child: Text(
          'No data — select sessions in the Data tab.',
          style: plexMono(fontSize: 12, color: brandFgFaint),
        ),
      );
    }

    // Pinned cursor A wins over hover so a clicked cursor stays put while
    // the user moves the mouse to other charts (e.g. scrolling up to peek
    // at the map). Hover is only a preview when no cursor A has been
    // pinned yet. Cursor B is pinned-only — never tracks hover.
    final pair = ref.watch(cursorProvider(widget.worksheetId));
    final hover = ref.watch(hoverCursorProvider(widget.worksheetId));
    final renderedPair = pair.aSecs == null && hover != null
        ? CursorPair(aSecs: hover, bSecs: pair.bSecs)
        : pair;
    final providerRange = ref.watch(
      workspaceProvider.select(
        (s) => s.worksheetRanges[widget.worksheetId],
      ),
    );
    // During an active drag this chart owns its X range locally — no
    // provider write per tick, so only this chart rebuilds. Other charts
    // catch up when _onScaleEnd flushes _localPanX to the provider.
    final xRange = _localPanX != null
        ? XAxisRange(
            startSecs: _localPanX!.$1,
            endSecs: _localPanX!.$2,
          )
        : providerRange;
    final effectiveMode = _resolveXAxisMode();
    final showWheelFallback = widget.xAxisMode == XAxisMode.wheelDistance &&
        !hasWheelData(widget.channels);
    final showGpsFallback = widget.xAxisMode == XAxisMode.gpsDistance &&
        !hasGpsData(widget.channels);

    final legendEntries = <({String channelId, Color color})>[
      for (var i = 0; i < widget.channels.length; i++)
        (
          channelId: widget.channels[i].channelId,
          color: TimeSeriesChart.resolveLineColor(
            channelId: widget.channels[i].channelId,
            paletteIndex: i,
            channelColors: widget.channelColors,
          ),
        ),
    ];

    // A non-null Y writer means this chart is hosted outside the worksheet
    // (the math-editor preview), so the slot-bound menu items — Properties…
    // and Remove chart — have no valid slot to act on and are suppressed.
    final embedded = widget.onApplyYScale != null;

    return ChartContextMenu(
      worksheetId: widget.worksheetId,
      slotIndex: widget.slotIndex,
      fullDataRange: _fullDataRange(),
      pixelToTimeSecs: (dx) => _localDxToSeconds(dx) ?? 0.0,
      onApplyYScale: widget.onApplyYScale,
      manualYRange: widget.manualYRange,
      onOpenProperties: embedded ? null : () => _openPropertiesDialog(context),
      onCopyCursorValues: _copyCursorValues,
      onRemoveChart: embedded
          ? null
          : () => confirmRemoveChart(context, ref, widget.slotIndex),
      child: Column(
        children: [
          _CursorPairChip(worksheetId: widget.worksheetId),
          if (showWheelFallback)
            const _FallbackBanner(
              'Wheel speed data unavailable — showing time axis',
            ),
          if (showGpsFallback)
            const _FallbackBanner('GPS data unavailable — showing time axis'),
          Expanded(
            child: MouseRegion(
              // Hover updates the worksheet's hoverCursor so other charts
              // and the GPS map preview the same point. onExit clears so
              // the pinned cursor takes over once the mouse leaves. Touch
              // devices never fire these events — pin behaviour is
              // unchanged there.
              onHover: (e) => _moveHoverCursor(e.localPosition.dx),
              onExit: (_) => _clearHoverCursor(),
              child: Listener(
                // Track the active mouse-button bitfield so _onScaleUpdate
                // can skip the desktop pan branch when a right-button drag
                // is in progress — that drag belongs to the context menu's
                // zoom-window painter (right-click + drag a rectangle).
                onPointerDown: (e) => _activeButtons = e.buttons,
                onPointerUp: (_) => _activeButtons = 0,
                onPointerCancel: (_) => _activeButtons = 0,
                // Modifier (Ctrl/Shift/Alt) + wheel → horizontal zoom at the
                // cursor; plain wheel still scrolls the worksheet list.
                onPointerSignal: _onPointerSignal,
                child: ChartGestureArea(
                  key: _chartKey,
                  // A custom scale recognizer ([ChartZoomScrubGestureRecognizer])
                  // claims only horizontal one-finger scrubs and 2-finger
                  // pinches, so a vertical one-finger drag falls through to the
                  // worksheet's scroll list instead of fighting it in the arena
                  // (that fight crashed at scale.dart:847). The scale callbacks
                  // branch on details.pointerCount: 1 = scrub/pan, >=2 = zoom.
                  onScaleStart: _onScaleStart,
                  onScaleUpdate: _onScaleUpdate,
                  onScaleEnd: _onScaleEnd,
                  onReset: _onDoubleTap,
                  child: Stack(
                    children: [
                      LineChart(
                        _buildChartData(renderedPair, effectiveMode, xRange),
                        duration: Duration.zero,
                      ),
                      if (legendEntries.isNotEmpty)
                        Positioned(
                          top: 2,
                          left: 48,
                          child: IgnorePointer(
                            child: _ChannelLegendOverlay(
                              entries: legendEntries,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Tile-based render helpers ──────────────────────────────────────────

  /// Returns the renderable spots for a single channel by collecting tiles
  /// at the picked tier. Spots are two-per-bucket at the same X (min, max),
  /// preserving spike fidelity. Missing tiles trigger async builds and leave
  /// a visual gap until the tile arrives; the spec §9 next-coarser-tier
  /// upscaling fallback is deferred follow-up work.
  List<FlSpot> _spotsForChannel({
    required SessionChannelData ch,
    required List<double>? times,
    required double xStart,
    required double xEnd,
    required double chartPixelWidth,
    required ChartTileCache cache,
    required YScaleTransform yt,
  }) {
    // Event-driven channels (HR_RR, wheel pulses, markers) carry explicit
    // per-sample times; their X comes from those, not index / rate. Decimation
    // itself stays index-bucketed (Rust min/max per bucket is still correct);
    // only the bucket→X mapping and the viewport→sample-range mapping become
    // timestamp-driven. The times are self-sourced from the handle via
    // [channelSampleTimesProvider] by the caller — null for fixed-rate. See §21.2.
    final eventDriven = times != null && times.isNotEmpty;
    final rate = ch.sampleRateHz > 0 ? ch.sampleRateHz : 1.0;

    final samplesInView = eventDriven
        ? (sampleIndexAtTime(timesSecs: times, rate: rate, xSecs: xEnd) -
                sampleIndexAtTime(timesSecs: times, rate: rate, xSecs: xStart))
            .toDouble()
        : (xEnd - xStart) * rate;
    final tier = pickTier(
      samplesInView: samplesInView,
      chartPixelWidth: chartPixelWidth,
    );
    final bucketSamples = tier == 0 ? 1 : _ipow(8, tier);
    final tileCoverRawSamples = ChartTileCache.tileSizeBuckets * bucketSamples;
    final firstTile = eventDriven
        ? (sampleIndexAtTime(timesSecs: times, rate: rate, xSecs: xStart) /
                tileCoverRawSamples)
            .floor()
        : ((xStart * rate) / tileCoverRawSamples).floor();
    final lastTile = eventDriven
        ? (sampleIndexAtTime(timesSecs: times, rate: rate, xSecs: xEnd) /
                tileCoverRawSamples)
            .ceil()
        : ((xEnd * rate) / tileCoverRawSamples).ceil();

    final spots = <FlSpot>[];
    for (var t = firstTile; t <= lastTile; t += 1) {
      if (t < 0) continue;
      final tile = cache.get(ch.sessionId, ch.channelId, tier, t);
      if (tile == null) {
        // Kick off async build; repaint when it lands.
        cache
            .getOrBuild(
              sessionId: ch.sessionId,
              channelId: ch.channelId,
              tier: tier,
              tileIndex: t,
              build: (sId, cId, tr, ti) async {
                final handle =
                    await ref.read(sessionHandleProvider(sId).future);
                return rust.decimateTile(
                  handle: handle,
                  channelId: cId,
                  tier: tr,
                  tileIndex: ti,
                );
              },
            )
            .then(
              (_) => _scheduleTileRepaint(),
              // Swallow Rust init / decimation errors so the frame still
              // renders. The cache cleared its in-flight slot in finally,
              // so the next rebuild can retry once Rust is up.
              onError: (Object _) {},
            );
        // Break the line across the not-yet-loaded span so fl_chart draws a
        // gap (matching the NaN-sample handling below) instead of interpolating
        // a misleading diagonal straight through unrendered data while the tile
        // is still in flight.
        spots.add(FlSpot.nullSpot);
        continue;
      }
      // Emit two FlSpot per bucket: (xBucket, min) and (xBucket, max).
      final tileXStart = (t * tileCoverRawSamples) / rate;
      final dx = bucketSamples / rate;
      for (var b = 0; b < ChartTileCache.tileSizeBuckets; b += 1) {
        final mn = tile[b * 2];
        final mx = tile[b * 2 + 1];
        final double x;
        if (eventDriven) {
          final sampleIdx =
              (t * ChartTileCache.tileSizeBuckets + b) * bucketSamples;
          // Past the last real sample — the rest of this tile is NaN padding.
          if (sampleIdx >= times.length) break;
          x = sampleXSeconds(timesSecs: times, rate: rate, index: sampleIdx);
        } else {
          x = tileXStart + b * dx;
        }
        if (x < xStart) continue;
        if (x > xEnd) break;
        if (mn.isNaN || mx.isNaN) {
          spots.add(FlSpot.nullSpot);
          continue;
        }
        spots.add(FlSpot(x, yt.isIdentity ? mn : yt.forward(mn)));
        // Skip the redundant max spot for flat buckets — fl_chart connects
        // single points cleanly, and we halve spot count on steady spans.
        if (mx != mn) spots.add(FlSpot(x, yt.isIdentity ? mx : yt.forward(mx)));
      }
    }
    return spots;
  }

  /// Returns the chart render width in logical pixels, or a sensible
  /// fallback when the render box has not yet laid out (first build, or
  /// inside a widget test that pumps synchronously). Schedules a rebuild
  /// after the first frame so tile fetches use the real width on the
  /// next pass.
  double _chartPixelWidth() {
    final ro = _chartKey.currentContext?.findRenderObject();
    if (ro is RenderBox && ro.hasSize) {
      return ro.size.width;
    }
    // First build — render box hasn't laid out yet. Return a sane
    // default; the next rebuild (typically triggered by the first
    // tile-build completion, hover, or pan) will use the real width.
    // We intentionally do NOT schedule a post-frame callback here:
    // doing so would loop forever in widget tests where the chart is
    // mounted into a zero-size slot and never gains a layout.
    return 1000.0;
  }

  /// Returns the session-wide (yMin, yMax) covering every channel in
  /// [widget.channels], or null while bounds are still loading or no channel
  /// has finite samples. Each channel's finite min/max is folded in the engine
  /// ([channelBoundsProvider] → `channelMinMax`, no full materialization) and
  /// cached by Riverpod; the union is taken over the resolved bounds. Null →
  /// fl_chart auto-fits, which is the same fallback used before bounds arrive.
  (double, double)? _unionSessionYBounds() {
    double mn = double.infinity;
    double mx = double.negativeInfinity;
    var any = false;
    for (final ch in widget.channels) {
      final bounds = ref
          .watch(
            channelBoundsProvider(
              (sessionId: ch.sessionId, channelId: ch.channelId),
            ),
          )
          .valueOrNull;
      if (bounds == null) continue;
      any = true;
      if (bounds.min < mn) mn = bounds.min;
      if (bounds.max > mx) mx = bounds.max;
    }
    return any ? (mn, mx) : null;
  }

  static int _ipow(int base, int exp) {
    var result = 1;
    for (var i = 0; i < exp; i += 1) {
      result *= base;
    }
    return result;
  }

  // ── Gesture handlers ────────────────────────────────────────────────────

  void _onScaleStart(ScaleStartDetails details) {
    if (details.pointerCount != _pointerCount) {
      setState(() => _pointerCount = details.pointerCount);
    }
    final xRange = ref.read(
      workspaceProvider.select(
        (s) => s.worksheetRanges[widget.worksheetId],
      ),
    );
    final full = _fullDataRange();
    _gestureRangeStart = xRange?.startSecs ?? full.$1;
    _gestureRangeEnd = xRange?.endSecs ?? full.$2;

    // Compute the data-space X value at the focal point, so it stays fixed
    // while the user zooms in/out.
    final frac = _focalFraction(details.localFocalPoint.dx);
    _gestureFocalDataX =
        _gestureRangeStart! + frac * (_gestureRangeEnd! - _gestureRangeStart!);
  }

  /// True when the host platform uses mouse-style input (web or desktop).
  /// Drives a different gesture model: hover scrubs the cursor (via
  /// [MouseRegion.onHover]) and click-drag pans, whereas touch platforms
  /// keep single-finger drag = move cursor A.
  bool get _isDesktop {
    if (kIsWeb) return true;
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount != _pointerCount) {
      setState(() => _pointerCount = details.pointerCount);
    }
    if (details.pointerCount <= 1) {
      // Touch single-finger drag → move cursor A. Touch platforms have
      // no hover, so dragging is the only way to position the cursor.
      if (!_isDesktop) {
        _moveCursor(details.localFocalPoint.dx);
        return;
      }
      // Desktop right-button drag belongs to the context menu's zoom-window
      // painter — do NOT pan. Hover already drives the unpinned cursor.
      if (_activeButtons & kSecondaryMouseButton != 0) {
        return;
      }
      // Desktop primary-button drag falls through to the pan math below;
      // with horizontalScale=1.0 it pans without zooming.
    }
    // Multi-finger pinch hits the same code with non-unit scales.

    // Multi-finger: free-form X+Y zoom.
    // X — anchor at focal point so the data under the fingers stays fixed.
    final spanX = _gestureRangeEnd! - _gestureRangeStart!;
    final scaleX = details.horizontalScale.clamp(0.05, 50.0);
    final newSpanX = spanX / scaleX;
    final fracX = _focalFraction(details.localFocalPoint.dx);
    final newStart = _gestureFocalDataX! - fracX * newSpanX;
    final full = _fullDataRange();
    final clampedStart = newStart.clamp(full.$1, full.$2 - 0.001);
    final clampedEnd = (newStart + newSpanX).clamp(full.$1 + 0.001, full.$2);
    // Pure local pan preview — no provider write until _onScaleEnd. Only
    // this chart rebuilds (RepaintBoundary further isolates the paint).
    // Other charts in the worksheet catch up in one repaint on release.
    setState(() => _localPanX = (clampedStart, clampedEnd));

    // Y — only when the slot is in manual mode. Auto-fit Y values aren't
    // accessible from outside fl_chart, so vertical pinch in auto mode
    // is a no-op (matches the dispatcher's policy).
    final vScale = details.verticalScale;
    if ((vScale - 1.0).abs() > 0.001) {
      final state = ref.read(workspaceProvider);
      final slot = state.activeWorksheet.charts[widget.slotIndex];
      if (slot.yScaleMode == YScaleMode.manual &&
          slot.yMin != null &&
          slot.yMax != null) {
        // Convert focal pixel-Y to data Y. Pixel Y grows downward; data Y
        // grows upward; we need the data Y under the fingers.
        final renderBox =
            _chartKey.currentContext?.findRenderObject() as RenderBox?;
        final height = renderBox?.size.height ?? 1.0;
        final fracFromTop =
            (details.localFocalPoint.dy / height).clamp(0.0, 1.0);
        final focalY = slot.yMax! - fracFromTop * (slot.yMax! - slot.yMin!);
        final (newYMin, newYMax) = computeManualYFocal(
          oldMin: slot.yMin!,
          oldMax: slot.yMax!,
          focalY: focalY,
          verticalScale: vScale,
        );
        ref.read(workspaceProvider.notifier).updateChartProperties(
              widget.slotIndex,
              slot.copyWith(
                yScaleMode: YScaleMode.manual,
                yMin: newYMin,
                yMax: newYMax,
              ),
            );
      }
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    // Flush the local pan preview into the worksheet-shared provider so
    // every other chart in the worksheet catches up in one repaint. Then
    // clear the local field — the next build returns to reading the
    // provider's range.
    if (_localPanX != null) {
      final (s, e) = _localPanX!;
      ref
          .read(workspaceProvider.notifier)
          .setXAxisRange(widget.worksheetId, s, e);
      _localPanX = null;
    }
    if (_pointerCount != 0) {
      setState(() => _pointerCount = 0);
    }
  }

  /// Modifier + mouse-wheel → zoom (Ctrl) or pan (Shift) of the shared X
  /// range — the mouse counterpart to the trackpad pinch/scrub in
  /// [_onScaleUpdate]. A plain wheel is left unclaimed so it keeps scrolling
  /// the worksheet list; a recognised modifier claims the event via the
  /// pointer-signal resolver so the list does not also scroll.
  ///
  /// The scheme comes from [wheelModeFor], the single source of truth shared
  /// with the Settings reference table. Alt is deliberately not a trigger —
  /// see [WheelMode] for why (Alt+Tab stuck-modifier bug). This is also the
  /// only wheel handler in the chart stack: [ChartContextMenu] no longer
  /// touches `onPointerSignal`, so a single notch produces a single action.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final keys = HardwareKeyboard.instance;
    final mode = wheelModeFor(
      ctrl: keys.isControlPressed,
      shift: keys.isShiftPressed,
    );
    if (mode == WheelMode.none) return; // plain wheel scrolls the sheet
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (e) => mode == WheelMode.zoom
          ? _zoomFromScroll(e as PointerScrollEvent)
          : _panFromScroll(e as PointerScrollEvent),
    );
  }

  /// Zooms the shared worksheet X range around the cursor by one wheel notch.
  /// Scroll up (dy < 0) zooms in, down zooms out; the data value under the
  /// pointer stays fixed. Fully zooming out clears the custom range so the
  /// auto/full view (and a hidden reset banner) returns.
  void _zoomFromScroll(PointerScrollEvent event) {
    final dy = event.scrollDelta.dy;
    if (dy == 0) return;
    final focalSecs = _localDxToSeconds(event.localPosition.dx);
    if (focalSecs == null) return;

    final xRange = ref.read(
      workspaceProvider.select(
        (s) => s.worksheetRanges[widget.worksheetId],
      ),
    );
    final full = _fullDataRange();
    final start = xRange?.startSecs ?? full.$1;
    final end = xRange?.endSecs ?? full.$2;
    final span = end - start;
    if (span <= 0) return;
    final fullSpan = full.$2 - full.$1;

    // exp() gives smooth, device-independent zoom per notch; scroll up
    // (dy < 0) → scaleX > 1 → narrower span → zoom in.
    final scaleX = math.exp(-dy / 300.0);
    final newSpan = (span / scaleX).clamp(0.02, fullSpan).toDouble();
    if (newSpan >= fullSpan - 1e-9) {
      ref.read(workspaceProvider.notifier).resetXAxisRange(widget.worksheetId);
      return;
    }

    final frac = (focalSecs - start) / span;
    final newStart =
        (focalSecs - frac * newSpan).clamp(full.$1, full.$2 - newSpan).toDouble();
    ref.read(workspaceProvider.notifier).setXAxisRange(
          widget.worksheetId,
          newStart,
          newStart + newSpan,
        );
  }

  /// Shift+wheel → pan the shared worksheet X range. Scroll down (dy > 0)
  /// moves the window toward later time; scroll up moves earlier. The window
  /// slides by a fraction of the current span per notch and stops at the data
  /// edge without shrinking (mirrors [dispatchChartAction]'s keyboard pan).
  /// No-op while the full range is shown — there is nothing to pan to.
  void _panFromScroll(PointerScrollEvent event) {
    final dy = event.scrollDelta.dy;
    if (dy == 0) return;

    final xRange = ref.read(
      workspaceProvider.select(
        (s) => s.worksheetRanges[widget.worksheetId],
      ),
    );
    if (xRange == null) return; // full view — nothing to pan
    final full = _fullDataRange();
    final start = xRange.startSecs;
    final end = xRange.endSecs;
    final span = end - start;
    if (span <= 0) return;

    // 15% of the visible span per wheel notch (~100 px of scrollDelta),
    // proportional so trackpad fling and detented wheels both feel natural.
    final shift = span * (dy / 666.0);
    var newStart = start + shift;
    var newEnd = end + shift;
    if (newStart < full.$1) {
      newEnd += full.$1 - newStart;
      newStart = full.$1;
    }
    if (newEnd > full.$2) {
      newStart -= newEnd - full.$2;
      newEnd = full.$2;
    }
    ref
        .read(workspaceProvider.notifier)
        .setXAxisRange(widget.worksheetId, newStart, newEnd);
  }

  void _onDoubleTap() {
    dispatchChartAction(
      ChartAction.resetView,
      ChartActionContext(
        worksheetId: widget.worksheetId,
        read: ref.read,
        fullDataRange: _fullDataRange(),
        // Reset Y to auto through the same seam the menu uses — the slot for
        // worksheet charts, or the preview's local writer.
        onApplyYScale:
            widget.onApplyYScale ?? slotYScaleWriter(ref.read, widget.slotIndex),
      ),
    );
    _clearHoverCursor();
  }

  // ── Cursor ──────────────────────────────────────────────────────────────

  /// Converts a pixel offset [localDx] to data-space seconds and writes to
  /// [cursorProvider] as cursor A.
  ///
  /// Accounts for the active zoom range so the cursor lands on the correct
  /// data point.
  void _moveCursor(double localDx) {
    final seconds = _localDxToSeconds(localDx);
    if (seconds == null) return;
    ref.read(cursorProvider(widget.worksheetId).notifier).setA(seconds);
  }

  /// Updates [hoverCursorProvider] from a hover event's pixel offset. Same
  /// pixel-to-seconds mapping as [_moveCursor]; only the destination
  /// provider differs.
  void _moveHoverCursor(double localDx) {
    final now = DateTime.now();
    if (now.difference(_lastHoverWrite) < const Duration(milliseconds: 33)) {
      return;
    }
    _lastHoverWrite = now;
    final seconds = _localDxToSeconds(localDx);
    if (seconds == null) return;
    ref.read(hoverCursorProvider(widget.worksheetId).notifier).state = seconds;
  }

  /// Clears [hoverCursorProvider] when the pointer leaves the chart so the
  /// pinned cursor takes over. Cheap no-op when already null.
  void _clearHoverCursor() {
    ref.read(hoverCursorProvider(widget.worksheetId).notifier).state = null;
  }

  /// Shared pixel-to-data-seconds conversion for cursor and hover writes.
  /// Returns null when the chart hasn't laid out yet or the visible span
  /// has collapsed.
  double? _localDxToSeconds(double localDx) {
    final xRange = ref.read(
      workspaceProvider.select(
        (s) => s.worksheetRanges[widget.worksheetId],
      ),
    );
    final full = _fullDataRange();
    final rangeStart = xRange?.startSecs ?? full.$1;
    final rangeEnd = xRange?.endSecs ?? full.$2;
    final span = rangeEnd - rangeStart;
    if (span <= 0) return null;

    final frac = _focalFraction(localDx);
    return rangeStart + frac * span;
  }

  /// Returns one [ShowingTooltipIndicators] per channel at the data-space
  /// X coordinate of cursor A. Empty when cursor A is unset, when the
  /// chart has no renderable bars, or while the user is mid-pinch
  /// (multi-pointer gesture).
  List<ShowingTooltipIndicators> _tooltipIndicators(
    CursorPair pair,
    List<LineChartBarData> bars,
  ) {
    final aSecs = pair.aSecs;
    if (aSecs == null || bars.isEmpty || _pointerCount > 1) {
      return const [];
    }
    // fl_chart needs one ShowingTooltipIndicators per "tooltip surface".
    // We render one tooltip per chart containing one spot per bar — that
    // means a single ShowingTooltipIndicators with one LineBarSpot per bar.
    final spots = <LineBarSpot>[];
    for (var i = 0; i < bars.length; i++) {
      final bar = bars[i];
      final spot = _nearestSpotAtX(bar.spots, aSecs);
      if (spot != null) {
        spots.add(LineBarSpot(bar, i, spot));
      }
    }
    if (spots.isEmpty) return const [];
    return [ShowingTooltipIndicators(spots)];
  }

  /// Linear search for the [FlSpot] nearest [targetX] in [spots]. Returns
  /// `null` when [spots] is empty or every entry is `FlSpot.nullSpot`
  /// (NaN samples — lap-aware math channels outside their lap window).
  FlSpot? _nearestSpotAtX(List<FlSpot> spots, double targetX) {
    // TODO(idl0): spots are X-monotonic (built from j / rate in
    // _buildChartData). Switch to binary search when channel count ×
    // sample count makes this linear scan visible in drag-frame budget.
    FlSpot? best;
    var bestDelta = double.infinity;
    for (final s in spots) {
      if (s.x.isNaN || s.y.isNaN) continue;
      final d = (s.x - targetX).abs();
      if (d < bestDelta) {
        bestDelta = d;
        best = s;
      }
    }
    return best;
  }

  // ── Context-menu callbacks ─────────────────────────────────────────────

  /// Opens the chart properties dialog. Invoked by the context menu's
  /// "Properties..." item (and F5 keybinding).
  void _openPropertiesDialog(BuildContext context) {
    final state = ref.read(workspaceProvider);
    final slot = state.activeWorksheet.charts[widget.slotIndex];
    final selectedIds = ref.read(effectiveSessionIdsProvider);
    showDialog<void>(
      context: context,
      builder: (_) => ChartPropertiesDialog(
        chartIndex: widget.slotIndex,
        slot: slot,
        selectedIds: selectedIds,
      ),
    );
  }

  /// Copies cursor A and B times to the system clipboard in a compact
  /// human-readable format. No-op when both cursors are unset.
  void _copyCursorValues() {
    final pair = ref.read(cursorProvider(widget.worksheetId));
    final buf = StringBuffer();
    if (pair.aSecs != null) {
      buf.write('A: t=${formatTimeReadout(pair.aSecs!)}');
    }
    if (pair.bSecs != null) {
      if (buf.isNotEmpty) buf.write(' | ');
      buf.write('B: t=${formatTimeReadout(pair.bSecs!)}');
    }
    if (buf.isEmpty) return;
    Clipboard.setData(ClipboardData(text: buf.toString()));
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Approximate left "dead zone" of the rendered chart in pixels —
  /// SideTitles `reservedSize` (44 px) on the leftTitles axis. Subtracted
  /// from `localDx` so cursor pin / hover lands on the visual position the
  /// user is pointing at rather than offset rightward by the axis-label
  /// width.
  static const double _timeSeriesChartLeftInset = 44.0;

  /// Returns the pixel fraction [0, 1] of [localDx] within the chart widget,
  /// adjusted for the leftTitles axis "dead zone".
  double _focalFraction(double localDx) {
    final box = _chartKey.currentContext?.findRenderObject() as RenderBox?;
    final width = box?.size.width ?? 1.0;
    final dataWidth = width - _timeSeriesChartLeftInset;
    if (dataWidth <= 0) return 0.0;
    final adjusted =
        (localDx - _timeSeriesChartLeftInset).clamp(0.0, dataWidth);
    return adjusted / dataWidth;
  }

  /// Full data range [start, end] in seconds across all channels.
  ///
  /// Event-driven channels span to their last recorded sample time, self-sourced
  /// from the handle via [channelSampleTimesProvider]. Read (not watched) so this
  /// can be called from gesture handlers; the build path subscribes via
  /// [_buildChartData], so the chart recomputes when the times arrive. Fixed-rate
  /// channels derive duration from `length / rate` — no samples needed.
  (double, double) _fullDataRange() {
    double maxX = 0;
    for (final ch in widget.channels) {
      if (ch.length == 0) continue;
      final rate = ch.sampleRateHz > 0 ? ch.sampleRateHz : 1.0;
      double dur = ch.length / rate;
      if (ch.isEventDriven) {
        final times = ref
            .read(
              channelSampleTimesProvider(
                (sessionId: ch.sessionId, channelId: ch.channelId),
              ),
            )
            .valueOrNull;
        if (times != null && times.isNotEmpty) dur = times.last;
      }
      if (dur > maxX) maxX = dur;
    }
    return (0.0, maxX > 0 ? maxX : 1.0);
  }

  /// Resolves the effective X axis mode, falling back to [XAxisMode.time] when
  /// the required channel data is absent.
  XAxisMode _resolveXAxisMode() {
    if (widget.xAxisMode == XAxisMode.wheelDistance &&
        !hasWheelData(widget.channels)) {
      return XAxisMode.time;
    }
    if (widget.xAxisMode == XAxisMode.gpsDistance &&
        !hasGpsData(widget.channels)) {
      return XAxisMode.time;
    }
    return widget.xAxisMode;
  }

  LineChartData _buildChartData(
    CursorPair cursorPair,
    XAxisMode effectiveMode,
    XAxisRange? xRange,
  ) {
    // TODO(idl0): compute wheelDistance/gpsDistance X values once distance
    // channels are wired up. For now effectiveMode is always time.
    final cache = ref.read(chartTileCacheProvider);
    final fullRange = _fullDataRange();
    final viewportStart = xRange?.startSecs ?? fullRange.$1;
    final viewportEnd = xRange?.endSecs ?? fullRange.$2;
    final chartWidthPx = _chartPixelWidth();
    // Bottom-axis tick interval, sized from the *actual visible span* (zoom range
    // or full data range) and the chart's pixel width, so label density stays
    // readable at every zoom level. Always explicit — fl_chart's auto-density
    // picker over-packs the wide full-session view and under-fills narrow zooms.
    final xInterval = _xAxisInterval(viewportStart, viewportEnd, chartWidthPx);
    // Y-axis display transform. Resolve the real-unit Y range first so the
    // symlog band (dataMaxAbs) is stable across pan/zoom; spots and bounds are
    // forwarded to display space and labels inverse-formatted back to real
    // units. Linear is the allocation-free identity fast-path.
    final union = _unionSessionYBounds();
    final realMinY = widget.yMin ?? union?.$1;
    final realMaxY = widget.yMax ?? union?.$2;
    final yt = YScaleTransform(
      widget.yScale,
      dataMaxAbs: math.max((realMinY ?? 0).abs(), (realMaxY ?? 0).abs()),
    );
    final bars = <LineChartBarData>[];
    for (var i = 0; i < widget.channels.length; i++) {
      final ch = widget.channels[i];
      if (ch.length == 0) continue;
      // Event-driven channels need their per-sample times to place buckets on
      // the X axis; self-source them from the handle (watched here so the chart
      // repaints when they land). Fixed-rate channels use index / rate — no
      // times needed.
      final times = ch.isEventDriven
          ? ref
              .watch(
                channelSampleTimesProvider(
                  (sessionId: ch.sessionId, channelId: ch.channelId),
                ),
              )
              .valueOrNull
          : null;
      // NaN samples become FlSpot.nullSpot so fl_chart renders a gap
      // instead of asserting in its axis-interval rounder
      // (`_roundIntervalAboveOne` requires input >= 1.0 — NaN fails
      // that). Lap-aware math channels like LapTime / Lap Delta T
      // emit NaN outside lap windows, so this matters for them.
      final spots = _spotsForChannel(
        ch: ch,
        times: times,
        xStart: viewportStart,
        xEnd: viewportEnd,
        chartPixelWidth: chartWidthPx,
        cache: cache,
        yt: yt,
      );
      bars.add(
        LineChartBarData(
          // Collapse an all-null series (tiles still loading, or an all-NaN
          // window) to an empty bar so fl_chart's axis auto-scaler skips it
          // instead of reading an uninitialized mostRightSpot and throwing.
          spots: TimeSeriesChart.renderableSpots(spots),
          color: TimeSeriesChart.resolveLineColor(
            channelId: ch.channelId,
            paletteIndex: i,
            channelColors: widget.channelColors,
          ),
          dotData: const FlDotData(show: false),
          isCurved: false,
        ),
      );
    }

    final lines = <VerticalLine>[];
    if (cursorPair.aSecs != null) {
      lines.add(
        VerticalLine(
          x: cursorPair.aSecs!,
          color: brandFg,
          strokeWidth: 1.5,
        ),
      );
    }
    if (cursorPair.bSecs != null) {
      lines.add(
        VerticalLine(
          x: cursorPair.bSecs!,
          color: brandHivis,
          strokeWidth: 1.5,
          dashArray: const [4, 3],
        ),
      );
    }

    final indicators = _tooltipIndicators(cursorPair, bars);

    return LineChartData(
      lineBarsData: bars,
      showingTooltipIndicators: indicators,
      minY: realMinY == null ? null : yt.forward(realMinY),
      maxY: realMaxY == null ? null : yt.forward(realMaxY),
      minX: xRange?.startSecs,
      maxX: xRange?.endSecs,
      extraLinesData: ExtraLinesData(
        verticalLines: lines,
        horizontalLines: widget.showZeroLine
            ? [
                HorizontalLine(
                  y: 0,
                  color: brandRule,
                  strokeWidth: brandHairlineWidth,
                  dashArray: const [4, 4],
                ),
              ]
            : const [],
      ),
      lineTouchData: LineTouchData(
        enabled: true,
        // We pin tooltip indicators ourselves via showingTooltipIndicators
        // below — don't let fl_chart's built-in touch handler clobber the
        // pinned set when the user taps to move the cursor.
        handleBuiltInTouches: false,
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => brandSurface,
          tooltipBorder: const BorderSide(
            color: brandRule,
            width: brandHairlineWidth,
          ),
          tooltipRoundedRadius: brandControlRadius,
          tooltipPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 6,
          ),
          tooltipMargin: 8,
          fitInsideHorizontally: true,
          fitInsideVertically: true,
          // This in-chart tooltip shows the decimated bucket value because
          // getTooltipItems must return synchronously (it cannot await Rust).
          // An exact interpolated readout would be a small additive handle
          // method; it is not currently wired.
          getTooltipItems: (spots) => [
            for (final s in spots)
              LineTooltipItem(
                formatChannelValue(yt.isIdentity ? s.y : yt.inverse(s.y)),
                plexMono(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: s.bar.color ?? brandFg,
                ),
              ),
          ],
        ),
      ),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
        rightTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 44,
            getTitlesWidget: (value, meta) => Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                // Axis ticks live in display space; inverse-format to real
                // units. Linear keeps fl_chart's default formatting exactly.
                yt.isIdentity
                    ? meta.formattedValue
                    : formatChannelValue(yt.inverse(value)),
                textAlign: TextAlign.right,
                style: plexMono(fontSize: 10, color: brandFgDim),
              ),
            ),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 28,
            // Explicit interval avoids fl_chart's auto-density picker
            // packing 6-char "MM:SS" labels too tightly on narrow x-spans
            // (e.g. a single-lap variance chart): the auto picker measures
            // numeric span only, not label width, so it ends up overlapping
            // labels at the same readability budget it would happily allow
            // for 1-2-character "5s" labels.
            interval: xInterval,
            getTitlesWidget: (value, meta) => Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                formatTimeAxisLabel(value, intervalSecs: xInterval),
                style: plexMono(fontSize: 10, color: brandFgDim),
              ),
            ),
          ),
        ),
      ),
      gridData: FlGridData(
        show: true,
        getDrawingHorizontalLine: (_) => const FlLine(
          color: brandRule,
          strokeWidth: brandHairlineWidth,
        ),
        getDrawingVerticalLine: (_) => const FlLine(
          color: brandRule,
          strokeWidth: brandHairlineWidth,
        ),
      ),
      borderData: FlBorderData(
        show: true,
        border: Border.all(color: brandRule, width: brandHairlineWidth),
      ),
    );
  }

  /// Picks a "nice" tick interval (seconds) for the bottom x-axis, sized so the
  /// `MM:SS` / `H:MM:SS` labels stay readable at every zoom level instead of
  /// piling up when zoomed out or thinning to a handful when zoomed in.
  ///
  /// [spanStart]/[spanEnd] are the visible window (zoom range or full data
  /// range); [widthPx] is the chart's pixel width. The label budget is the width
  /// divided by a per-label pixel slot (wider for the 7-char `H:MM:SS` form that
  /// hour-plus views use), so the count scales with the chart size rather than a
  /// fixed ~6. The chosen target is rounded up to the next "nice" value.
  double? _xAxisInterval(double spanStart, double spanEnd, double widthPx) {
    final span = (spanEnd - spanStart).abs();
    if (span <= 0) return null;
    // Per-label pixel slot: `H:MM:SS` (hour-plus views) needs more room than
    // `MM:SS` / `12.5s`. Plex Mono ~7 px/char at 10 pt, plus breathing space.
    final slotPx = spanEnd.abs() >= 3600 ? 74.0 : 58.0;
    final maxLabels =
        widthPx > 0 ? (widthPx / slotPx).floor().clamp(2, 40) : 8;
    final target = span / maxLabels;
    const niceValues = <double>[
      0.01,
      0.02,
      0.05,
      0.1,
      0.2,
      0.5,
      1,
      2,
      5,
      10,
      15,
      20,
      30,
      60,
      90,
      120,
      180,
      300,
      600,
      900,
      1800,
      3600,
    ];
    for (final v in niceValues) {
      if (target <= v) return v;
    }
    return target;
  }
}

/// Narrow banner shown when the requested X axis mode cannot be satisfied.
class _FallbackBanner extends StatelessWidget {
  const _FallbackBanner(this.message);

  /// Warning text displayed in the banner.
  final String message;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(
          color: brandSurface2,
          border: Border(
            bottom: BorderSide(color: brandRule, width: brandHairlineWidth),
          ),
        ),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 13, color: brandHivis),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    message,
                    style: plexMono(fontSize: 11, color: brandFgDim),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

/// Compact `A → B  Δ <t>` chip shown above a [TimeSeriesChart] when both
/// cursors A and B are pinned. Hidden in the common single-cursor case.
class _CursorPairChip extends ConsumerWidget {
  const _CursorPairChip({required this.worksheetId});

  /// Stable UUID of the worksheet whose [cursorProvider] state drives
  /// the chip's visibility and Δ value.
  final String worksheetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pair = ref.watch(cursorProvider(worksheetId));
    final aSecs = pair.aSecs;
    final bSecs = pair.bSecs;
    if (aSecs == null || bSecs == null) return const SizedBox.shrink();

    final delta = (bSecs - aSecs).abs();
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 12, bottom: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: const BoxDecoration(
            color: brandSurface,
            border: Border.fromBorderSide(
              BorderSide(color: brandRule, width: brandHairlineWidth),
            ),
          ),
          child: Text(
            'A → B  Δ ${formatTimeReadout(delta)}',
            style: plexMono(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: brandFg,
              letterSpacing: brandLabelTracking,
            ),
          ),
        ),
      ),
    );
  }
}

/// Computes new manual Y axis bounds for a pinch zoom anchored at the
/// gesture focal point in data space.
///
/// `focalY` is the data-space Y value under the user's fingers. The point
/// under the fingers stays fixed across the zoom; the rest of the range
/// scales away from it.
(double, double) computeManualYFocal({
  required double oldMin,
  required double oldMax,
  required double focalY,
  required double verticalScale,
}) {
  final scale = verticalScale.clamp(0.05, 50.0);
  final newSpan = (oldMax - oldMin) / scale;
  final fracBelow = (focalY - oldMin) / (oldMax - oldMin);
  final newMin = focalY - fracBelow * newSpan;
  final newMax = newMin + newSpan;
  return (newMin, newMax);
}

/// X coordinate in seconds for sample [index] of a channel.
///
/// Event-driven channels (non-null, non-empty [timesSecs]) read the explicit
/// per-sample time, clamped to the array bounds. Fixed-rate channels fall back
/// to `index / rate`, treating a non-positive [rate] as 1 Hz. This is what
/// stops an irregular channel (e.g. HR_RR) being stretched by its mean event
/// rate when plotted at the legacy 1 Hz fallback. See §21.2.
double sampleXSeconds({
  required List<double>? timesSecs,
  required double rate,
  required int index,
}) {
  if (timesSecs != null && timesSecs.isNotEmpty) {
    if (index <= 0) return timesSecs.first;
    if (index >= timesSecs.length) return timesSecs.last;
    return timesSecs[index];
  }
  final r = rate > 0 ? rate : 1.0;
  return index / r;
}

/// Lower-bound sample index whose time is ≥ [xSecs] (the first sample at or
/// after [xSecs]).
///
/// Event-driven channels binary-search the monotonic [timesSecs]; the result
/// is in `[0, timesSecs.length]`. Fixed-rate channels compute
/// `floor(xSecs × rate)`, treating a non-positive [rate] as 1 Hz. See §21.2.
int sampleIndexAtTime({
  required List<double>? timesSecs,
  required double rate,
  required double xSecs,
}) {
  if (timesSecs != null && timesSecs.isNotEmpty) {
    var lo = 0;
    var hi = timesSecs.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (timesSecs[mid] < xSecs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
  final r = rate > 0 ? rate : 1.0;
  return (xSecs * r).floor();
}

/// Top-left corner overlay mirroring the FFT chart's legend strip: one
/// colour-dotted chip per rendered channel. Positioned by the caller via the
/// parent Stack — this widget is just the chips themselves.
class _ChannelLegendOverlay extends StatelessWidget {
  const _ChannelLegendOverlay({required this.entries});

  /// Channel ID + matching line colour for each rendered series, in the same
  /// order the lines appear in the chart.
  final List<({String channelId, Color color})> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 12,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final entry in entries)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: entry.color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                entry.channelId,
                style: plexMono(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: brandFg,
                ),
              ),
            ],
          ),
      ],
    );
  }
}
