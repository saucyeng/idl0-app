import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/worksheet.dart' show ChartScope, ChartType, ScatterMode;
import '../../../providers/channel_provider.dart' show sessionHandleProvider;
import '../../../providers/lap_provider.dart' show sessionLapsProvider;
import '../../../providers/selection_provider.dart';
import '../../../providers/session_provider.dart' show sessionProvider;
import '../../../providers/session_workspace_provider.dart'
    show sessionWorkspaceProvider;
import '../../../src/rust/scatter.dart'
    show ScatterDensity, ScatterPoints, scatterDensity, scatterPoints;
import '../../brand/brand.dart';
import 'chart_type_catalog.dart' show chartTypeInfo;
import 'turbo_colormap.dart' show turboColor;

/// The recording-time `(t0, t1)` window (seconds) a scatter renders for one
/// session, plus the channel pair. Keyed family input for the points provider.
typedef ScatterKey = ({
  String sessionId,
  String xChannel,
  String yChannel,
  String? colorChannel,
  double t0Secs,
  double t1Secs,
});

/// Max spots fed to the painter — uniform-stride decimation in the engine keeps
/// the cloud render-friendly while preserving the envelope.
const int _kMaxScatterPoints = 6000;

/// Decimated `(x, y)` cloud for one session/window, computed in `idl-rs`
/// ([scatterPoints]). Single FRB call; the reduced result (and its extent)
/// crosses the boundary, never the raw samples. autoDispose; keyed by the window
/// + channel triple so a lap change or channel edit yields a fresh cloud.
final scatterPointsProvider = FutureProvider.autoDispose
    .family<ScatterPoints, ScatterKey>((ref, k) async {
  final handle = await ref.watch(sessionHandleProvider(k.sessionId).future);
  return scatterPoints(
    handle: handle,
    xChannel: k.xChannel,
    yChannel: k.yChannel,
    colorChannel: k.colorChannel,
    t0Secs: k.t0Secs,
    t1Secs: k.t1Secs,
    maxPoints: _kMaxScatterPoints,
  );
});

/// Density-mode family input: the window/channel pair plus grid resolution and
/// the equal-aspect flag (the engine owns the bound computation).
typedef ScatterDensityKey = ({
  String sessionId,
  String xChannel,
  String yChannel,
  double t0Secs,
  double t1Secs,
  int bins,
  bool equalAspect,
});

/// 2D density grid for one session/window, computed in `idl-rs`
/// ([scatterDensity]). The engine returns the bounds it binned into — the
/// painter reads them off the result, never computing axis bounds itself.
final scatterDensityProvider = FutureProvider.autoDispose
    .family<ScatterDensity, ScatterDensityKey>((ref, k) async {
  final handle = await ref.watch(sessionHandleProvider(k.sessionId).future);
  return scatterDensity(
    handle: handle,
    xChannel: k.xChannel,
    yChannel: k.yChannel,
    t0Secs: k.t0Secs,
    t1Secs: k.t1Secs,
    bins: k.bins,
    equalAspect: k.equalAspect,
  );
});

/// XY scatter / G-G chart. Renders one in-scope session (the first selected) in
/// v1; pairing/decimation/binning live in `idl-rs`, and this widget only paints
/// the reduced result through a single [_ScatterPainter].
class ScatterChart extends ConsumerWidget {
  /// Creates a scatter / G-G chart for one session's `(xChannel, yChannel)`
  /// pair. All fields come straight off the rendered [ChartSlot].
  const ScatterChart({
    super.key,
    required this.sessionId,
    required this.scope,
    required this.xChannel,
    required this.yChannel,
    required this.mode,
    required this.colorChannel,
    required this.colorMin,
    required this.colorMax,
    required this.equalAspect,
    required this.referenceCircles,
    required this.binCount,
  });

  /// Session whose cloud is plotted (the first selected session in v1).
  final String sessionId;

  /// Lap-pair / session window resolution (see [_ScatterPainter] caller).
  final ChartScope scope;

  /// X-axis channel id, or null until the user picks one.
  final String? xChannel;

  /// Y-axis channel id, or null until the user picks one.
  final String? yChannel;

  /// Points cloud or density heatmap.
  final ScatterMode mode;

  /// Points-mode colour-by channel id, or null for a solid colour.
  final String? colorChannel;

  /// Manual lower bound of the colour scale; null ⇒ auto.
  final double? colorMin;

  /// Manual upper bound of the colour scale; null ⇒ auto.
  final double? colorMax;

  /// 1:1 data-units-per-pixel square plot (the G-G friction circle).
  final bool equalAspect;

  /// Concentric reference g-circles + quadrant cross.
  final bool referenceCircles;

  /// Density-mode grid resolution (square `bins × bins`).
  final int binCount;

  /// Resolves the recording-time `(t0, t1)` window for this session: the
  /// designated main lap when `scope == auto` and one resolves, else the whole
  /// session. Mirrors the time-series main-lap resolution (chart_workspace
  /// `_resolveLapPairChannels`) but yields just the window.
  ({double t0, double t1}) _window(WidgetRef ref) {
    final sessions = ref.watch(sessionProvider).sessions;
    final meta = sessions.where((s) => s.sessionId == sessionId).firstOrNull;
    final durationSecs = (meta?.durationMs ?? 0) / 1000.0;
    final full = (t0: 0.0, t1: durationSecs);
    if (scope == ChartScope.session) return full;

    final ws = ref.watch(sessionWorkspaceProvider(sessionId)).valueOrNull;
    int? mainLapNum = ws?.mainLapNumber;
    if (mainLapNum == null) {
      final selection = ref.watch(selectionProvider);
      if (selection.mode == SelectionMode.lap) {
        final laps =
            selection.lapKeys.where((k) => k.sessionId == sessionId).toList();
        if (laps.length == 1) mainLapNum = laps.first.lapNumber;
      }
    }
    if (mainLapNum == null) return full;
    final laps = ref.watch(sessionLapsProvider(sessionId)).valueOrNull;
    final lap = laps?.where((l) => l.lapNumber == mainLapNum).firstOrNull;
    if (lap == null) return full;
    return (t0: lap.startTimeSecs, t1: lap.endTimeSecs);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (xChannel == null || yChannel == null) {
      return Center(
        child: Text(
          'Pick an X and Y channel in chart properties.',
          style: plexSans(fontSize: 13, color: brandFgDim),
        ),
      );
    }
    if (sessionId.isEmpty) {
      return Center(
        child: Text(
          'Select a session to plot.',
          style: plexSans(fontSize: 13, color: brandFgDim),
        ),
      );
    }
    final w = _window(ref);

    if (mode == ScatterMode.density) {
      final key = (
        sessionId: sessionId,
        xChannel: xChannel!,
        yChannel: yChannel!,
        t0Secs: w.t0,
        t1Secs: w.t1,
        bins: binCount,
        equalAspect: equalAspect,
      );
      final async = ref.watch(scatterDensityProvider(key));
      return async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Text('$e', style: plexSans(fontSize: 12, color: brandFgDim)),
        ),
        data: (d) => CustomPaint(
          painter: _ScatterPainter.density(
            density: d,
            xLabel: xChannel!,
            yLabel: yChannel!,
            referenceCircles: referenceCircles,
            equalAspect: equalAspect,
          ),
          child: const SizedBox.expand(),
        ),
      );
    }

    final key = (
      sessionId: sessionId,
      xChannel: xChannel!,
      yChannel: yChannel!,
      colorChannel: colorChannel,
      t0Secs: w.t0,
      t1Secs: w.t1,
    );
    final async = ref.watch(scatterPointsProvider(key));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text('$e', style: plexSans(fontSize: 12, color: brandFgDim)),
      ),
      data: (p) => CustomPaint(
        painter: _ScatterPainter.points(
          points: p,
          xLabel: xChannel!,
          yLabel: yChannel!,
          colorMin: colorMin,
          colorMax: colorMax,
          referenceCircles: referenceCircles,
          equalAspect: equalAspect,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Left + bottom axis gutter, in logical pixels.
const double _kAxisGutter = 34;

/// Paints a scatter as points (cloud, optional Turbo colour) or density
/// (heatmap), sharing one data→pixel transform with the reference g-circles so
/// every layer agrees on where the origin and the rings sit.
class _ScatterPainter extends CustomPainter {
  _ScatterPainter.points({
    required ScatterPoints points,
    required this.xLabel,
    required this.yLabel,
    required this.colorMin,
    required this.colorMax,
    required this.referenceCircles,
    required this.equalAspect,
  })  : _points = points,
        _density = null,
        xMin = points.xMin,
        xMax = points.xMax,
        yMin = points.yMin,
        yMax = points.yMax;

  _ScatterPainter.density({
    required ScatterDensity density,
    required this.xLabel,
    required this.yLabel,
    required this.referenceCircles,
    required this.equalAspect,
  })  : _points = null,
        _density = density,
        colorMin = null,
        colorMax = null,
        xMin = density.xMin,
        xMax = density.xMax,
        yMin = density.yMin,
        yMax = density.yMax;

  final ScatterPoints? _points;
  final ScatterDensity? _density;
  final String xLabel;
  final String yLabel;
  final double? colorMin;
  final double? colorMax;
  final bool referenceCircles;
  final bool equalAspect;
  final double xMin;
  final double xMax;
  final double yMin;
  final double yMax;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(
      _kAxisGutter,
      8,
      size.width - 8,
      size.height - _kAxisGutter,
    );
    if (plot.width <= 0 || plot.height <= 0) return;

    // Equal-aspect: a square plot box centred in the available area, so one data
    // unit is the same pixel count on both axes (the friction circle stays
    // round). Otherwise stretch to fill.
    var box = plot;
    if (equalAspect) {
      final side = math.min(plot.width, plot.height);
      box = Rect.fromCenter(center: plot.center, width: side, height: side);
    }

    final dx = (xMax - xMin).abs() < 1e-12 ? 1.0 : (xMax - xMin);
    final dy = (yMax - yMin).abs() < 1e-12 ? 1.0 : (yMax - yMin);
    Offset toPixel(double x, double y) => Offset(
          box.left + (x - xMin) / dx * box.width,
          box.bottom - (y - yMin) / dy * box.height, // y up
        );

    final framePaint = Paint()
      ..style = PaintingStyle.stroke
      ..color = brandFgFaint
      ..strokeWidth = 1;
    canvas.drawRect(box, framePaint);

    if (referenceCircles) _paintReference(canvas, box, toPixel);
    if (_density != null) {
      _paintDensity(canvas, box, _density);
    } else if (_points != null) {
      _paintPoints(canvas, _points, toPixel);
    }
    _paintAxisLabels(canvas, size, box);
  }

  void _paintReference(
    Canvas canvas,
    Rect box,
    Offset Function(double, double) toPixel,
  ) {
    final axisPaint = Paint()
      ..color = brandFgFaint
      ..strokeWidth = 1;
    // Quadrant cross at the data origin (only when an axis straddles 0).
    if (xMin < 0 && xMax > 0) {
      final x0 = toPixel(0, yMin).dx;
      canvas.drawLine(Offset(x0, box.top), Offset(x0, box.bottom), axisPaint);
    }
    if (yMin < 0 && yMax > 0) {
      final y0 = toPixel(xMin, 0).dy;
      canvas.drawLine(Offset(box.left, y0), Offset(box.right, y0), axisPaint);
    }
    // Concentric g-rings at 0.5-unit spacing out to the axis half-extent.
    final maxR = math.max(xMax.abs(), yMax.abs());
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..color = brandFgFaint
      ..strokeWidth = 1;
    final center = toPixel(0, 0);
    final dxRange = (xMax - xMin).abs() < 1e-12 ? 1.0 : (xMax - xMin);
    final pxPerUnit = box.width / dxRange;
    for (var g = 0.5; g <= maxR + 1e-9; g += 0.5) {
      canvas.drawCircle(center, g * pxPerUnit, ringPaint);
    }
  }

  void _paintPoints(
    Canvas canvas,
    ScatterPoints p,
    Offset Function(double, double) toPixel,
  ) {
    final colors = p.colors;
    final hasColor = colors != null && colors.isNotEmpty;
    var lo = colorMin ?? double.infinity;
    var hi = colorMax ?? double.negativeInfinity;
    if (hasColor && (colorMin == null || colorMax == null)) {
      for (final c in colors) {
        if (c.isFinite) {
          lo = math.min(lo, c);
          hi = math.max(hi, c);
        }
      }
    }
    final span = (hi - lo).abs() < 1e-12 ? 1.0 : (hi - lo);
    final solid = Paint()
      ..color = chartTypeInfo(ChartType.scatter).accent.withValues(alpha: 0.55);
    for (var i = 0; i < p.xs.length; i++) {
      final o = toPixel(p.xs[i], p.ys[i]);
      if (hasColor) {
        final t = ((colors[i] - lo) / span).clamp(0.0, 1.0);
        canvas.drawCircle(o, 1.6, Paint()..color = turboColor(t));
      } else {
        canvas.drawCircle(o, 1.6, solid);
      }
    }
  }

  void _paintDensity(Canvas canvas, Rect box, ScatterDensity d) {
    final bins = d.bins;
    if (bins == 0) return;
    var maxCount = 0;
    for (final c in d.counts) {
      if (c > maxCount) maxCount = c;
    }
    if (maxCount == 0) return;
    final cellW = box.width / bins;
    final cellH = box.height / bins;
    for (var r = 0; r < bins; r++) {
      for (var c = 0; c < bins; c++) {
        final n = d.counts[r * bins + c];
        if (n == 0) continue;
        final t = n / maxCount;
        final rect = Rect.fromLTWH(
          box.left + c * cellW,
          box.bottom - (r + 1) * cellH, // row 0 = y_min at the bottom
          cellW + 0.5,
          cellH + 0.5,
        );
        canvas.drawRect(rect, Paint()..color = turboColor(t));
      }
    }
  }

  void _paintAxisLabels(Canvas canvas, Size size, Rect box) {
    void label(String text, Offset at, {bool rotate = false}) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: plexMono(fontSize: 10, color: brandFgDim),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      canvas.save();
      canvas.translate(at.dx, at.dy);
      if (rotate) canvas.rotate(-math.pi / 2);
      tp.paint(canvas, Offset.zero);
      canvas.restore();
    }

    label(xLabel, Offset(box.center.dx - 20, size.height - 14));
    label(yLabel, Offset(2, box.center.dy + 20), rotate: true);
  }

  @override
  bool shouldRepaint(_ScatterPainter old) =>
      !identical(old._points, _points) ||
      !identical(old._density, _density) ||
      old.equalAspect != equalAspect ||
      old.referenceCircles != referenceCircles ||
      old.colorMin != colorMin ||
      old.colorMax != colorMax;
}
