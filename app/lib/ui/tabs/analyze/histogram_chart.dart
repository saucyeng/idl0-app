import 'dart:math' as math;
import 'dart:typed_data' show Float64List;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/session_model.dart';
import '../../../data/y_scale.dart';
import '../../../providers/channel_provider.dart' show sessionHandleProvider;
import '../../../providers/selection_provider.dart';
import '../../../providers/workspace_provider.dart';
import '../../../src/rust/histogram.dart' show HistogramResult;
import '../../../src/rust/session.dart'
    show ChannelBounds, channelHistogram, channelMinMax;
import '../../brand/brand.dart';
import '../../widgets/chart_context_menu.dart';
import '../../widgets/value_format.dart' show formatChannelValue;
import 'chart_workspace.dart' show ChartPropertiesDialog, confirmRemoveChart;

/// Finite min/max of one channel's samples (engine-folded, no materialization).
/// The histogram unions these across every series to derive the shared binning
/// range so overlaid distributions align on one value axis. `autoDispose`,
/// keyed by (sessionId, channelId).
final _channelBoundsProvider = FutureProvider.autoDispose
    .family<ChannelBounds?, ({String sessionId, String channelId})>(
        (ref, k) async {
  final handle = await ref.watch(sessionHandleProvider(k.sessionId).future);
  return channelMinMax(handle: handle, channelId: k.channelId);
});

/// Equal-width value histogram for one channel over an **explicit** shared
/// range, computed in the engine ([channelHistogram] — samples never cross
/// FFI). `autoDispose`; keyed by (sessionId, channelId, binCount, range) so
/// every overlaid series bins onto identical edges. See §26.10.
final histogramProvider = FutureProvider.autoDispose.family<
    HistogramResult,
    ({
      String sessionId,
      String channelId,
      int binCount,
      double rangeMin,
      double rangeMax,
    })>((ref, k) async {
  final handle = await ref.watch(sessionHandleProvider(k.sessionId).future);
  return channelHistogram(
    handle: handle,
    channelId: k.channelId,
    binCount: k.binCount,
    // The chart precomputes the (symmetric-aware) shared range and passes it
    // explicitly, so the engine's own symmetric/auto path is bypassed here.
    symmetric: false,
    rangeMin: k.rangeMin,
    rangeMax: k.rangeMax,
  );
});

/// One plotted distribution: a (session, channel) series over the shared range.
class _Series {
  const _Series({
    required this.label,
    required this.color,
    required this.result,
  });
  final String label;
  final Color color;
  final HistogramResult result;
}

/// A value-distribution histogram chart. See §26.10.
///
/// Overlays the distribution of every assigned (session × channel) series as
/// equal-width bars, computed via the Rust `channel_histogram` bridge (samples
/// never cross FFI). All series share one value axis: the chart unions each
/// channel's min/max (`channel_min_max`) into a common range — widened to
/// `[−m, m]` when [ChartSlot.histogramSymmetric] — and bins every series onto
/// the same edges, so front/rear (and main/overlay sessions) lie on top of each
/// other. Y is the percentage of each series' samples per bin; an optional log
/// Y exposes the sparse high-velocity tails.
///
/// **Window.** Computed over the whole rendered session, like the FFT chart —
/// neither windows by zoom nor lap in v1.
///
/// **Context menu:** Right-click / long-press opens [ChartContextMenu]; zoom and
/// pan items are hidden because the X axis is channel value, not worksheet time.
class HistogramChart extends ConsumerStatefulWidget {
  /// Creates a [HistogramChart].
  const HistogramChart({
    super.key,
    required this.channels,
    required this.worksheetId,
    required this.slotIndex,
    this.channelColors = const {},
  });

  /// Assigned data series; each entry with samples becomes an overlaid bar set.
  final List<SessionChannelData> channels;

  /// Stable UUID of the containing worksheet — keys context-menu state.
  final String worksheetId;

  /// Index of this chart's slot in the active worksheet.
  final int slotIndex;

  /// Per-channel colour overrides keyed by channel ID, as ARGB int values.
  final Map<String, int> channelColors;

  @override
  ConsumerState<HistogramChart> createState() => _HistogramChartState();
}

class _HistogramChartState extends ConsumerState<HistogramChart> {
  @override
  Widget build(BuildContext context) {
    return ChartContextMenu(
      worksheetId: widget.worksheetId,
      slotIndex: widget.slotIndex,
      // Histogram X axis is channel value, not the worksheet time axis — hide
      // zoom + pan so users don't see commands that mutate worksheet state
      // without affecting this chart.
      fullDataRange: const (0.0, 1.0),
      pixelToTimeSecs: (_) => 0.0,
      xAxisIsWorksheetTime: false,
      onOpenProperties: () => _openPropertiesDialog(context),
      onRemoveChart: () => confirmRemoveChart(context, ref, widget.slotIndex),
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    // A histogram only needs samples (any rate).
    final renderable = [
      for (final c in widget.channels)
        if (c.length > 0) c,
    ];
    if (renderable.isEmpty) {
      return _message(
        widget.channels.isEmpty
            ? 'No channel assigned — open properties to select one.'
            : 'No data — select sessions in the Data tab.',
      );
    }

    // Watch the slot so the chart re-renders when bin-count / symmetric / log
    // change. Bounds-guard the index: on a worksheet switch this widget can
    // briefly outlive its slot (the newly-active sheet may have fewer charts),
    // and an unguarded `charts[slotIndex]` would throw a RangeError from the
    // stale selector before the widget is disposed.
    final slot = ref.watch(
      workspaceProvider.select(
        (s) => widget.slotIndex < s.activeWorksheet.charts.length
            ? s.activeWorksheet.charts[widget.slotIndex]
            : null,
      ),
    );
    if (slot == null) return const SizedBox.shrink();

    // 1) Union each series' min/max into the shared binning range. Wait for
    //    *all* bounds before binning so the range (and thus the edges) doesn't
    //    shift as later series resolve.
    var lo = double.infinity;
    var hi = double.negativeInfinity;
    var boundsLoading = false;
    for (final c in renderable) {
      final b = ref.watch(
        _channelBoundsProvider(
          (sessionId: c.sessionId, channelId: c.channelId),
        ),
      );
      if (b.isLoading) {
        boundsLoading = true;
      } else {
        final v = b.valueOrNull;
        if (v != null) {
          if (v.min < lo) lo = v.min;
          if (v.max > hi) hi = v.max;
        }
      }
    }
    if (boundsLoading) {
      return const Center(child: CircularProgressIndicator(color: brandInfo));
    }
    if (!lo.isFinite || !(hi > lo)) {
      return _message('Not enough variation to bin.');
    }
    if (slot.histogramSymmetric) {
      final m = math.max(lo.abs(), hi.abs());
      lo = -m;
      hi = m;
    }

    // 2) Histogram every series over the shared range (identical edges).
    final series = <_Series>[];
    var histLoading = false;
    for (var i = 0; i < renderable.length; i++) {
      final c = renderable[i];
      final r = ref
          .watch(
            histogramProvider(
              (
                sessionId: c.sessionId,
                channelId: c.channelId,
                binCount: slot.histogramBinCount,
                rangeMin: lo,
                rangeMax: hi,
              ),
            ),
          )
          .valueOrNull;
      if (r == null) {
        histLoading = true;
        continue;
      }
      if (r.total == 0 || r.counts.isEmpty) continue;
      series.add(
        _Series(
          label: c.channelId,
          color: _colorFor(c.channelId, i),
          result: r,
        ),
      );
    }
    if (series.isEmpty) {
      return histLoading
          ? const Center(child: CircularProgressIndicator(color: brandInfo))
          : _message('Not enough variation to bin.');
    }

    return Column(
      children: [
        _TitleBar(
          series: series,
          symmetric: slot.histogramSymmetric,
          yScale: slot.yScale,
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
            child: _buildChart(
              series,
              lo,
              hi,
              slot.yScale,
              slot.histogramSmooth,
            ),
          ),
        ),
      ],
    );
  }

  Widget _message(String text) => Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: plexMono(fontSize: 12, color: brandFgFaint),
        ),
      );

  /// Rendering colour for [channelId] at palette index [i] — honours
  /// [HistogramChart.channelColors] overrides, else the brand palette.
  Color _colorFor(String channelId, int i) {
    final override = widget.channelColors[channelId];
    if (override != null) return Color(override);
    return brandChartPalette[i % brandChartPalette.length];
  }

  void _openPropertiesDialog(BuildContext context) {
    final state = ref.read(workspaceProvider);
    final charts = state.activeWorksheet.charts;
    if (widget.slotIndex >= charts.length) return;
    final slot = charts[widget.slotIndex];
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

  /// Builds the overlaid histogram. Each series is a staircase outline (one
  /// step per bin) with a translucent fill, all sharing the value (X) and
  /// percentage (Y) axes. When [logCount] the Y axis is base-10 log, so the
  /// bars rise from the log floor to `log₁₀(pct)`, exposing the sparse tails.
  Widget _buildChart(
    List<_Series> series,
    double lo,
    double hi,
    YScale yScale,
    bool smooth,
  ) {
    final edges = series.first.result.binEdges; // shared across all series

    // Percentages per series + the shared Y extent across every series.
    final pcts = <List<double>>[];
    var maxPct = 0.0;
    var minNonZero = double.infinity;
    for (final s in series) {
      final total = s.result.total;
      final p = [
        for (final c in s.result.counts) total > 0 ? c / total * 100.0 : 0.0,
      ];
      for (final v in p) {
        if (v > maxPct) maxPct = v;
        if (v > 0 && v < minNonZero) minNonZero = v;
      }
      pcts.add(p);
    }
    if (maxPct <= 0) return _message('Not enough variation to bin.');

    // `log` keeps the existing floor + decade mapping; linear / sqrt / square
    // go through the shared transform (counts are >= 0). The symlog band is
    // sized from the max plotted percentage.
    final isLog = yScale == YScale.log;
    final yt = YScaleTransform(yScale, dataMaxAbs: maxPct);
    final logFloorPct = minNonZero.isFinite ? minNonZero : maxPct / 10;
    final logFloor = _log10(logFloorPct);
    final logMax = _log10(maxPct);
    final double minY = isLog ? logFloor : yt.forward(0.0);
    final double maxY = isLog
        ? (logMax <= logFloor ? logFloor + 1 : logMax)
        : yt.forward(maxPct * 1.08);

    double ty(double p) {
      if (isLog) return p > 0 ? _log10(p).clamp(logFloor, maxY) : logFloor;
      return yt.forward(p);
    }

    final bars = <LineChartBarData>[
      for (var si = 0; si < series.length; si++)
        LineChartBarData(
          // Smooth = a fitted polyline through the bin centres; otherwise a
          // stepped staircase that traces the bars' tops.
          spots: smooth
              ? _polyline(edges, pcts[si], ty)
              : _staircase(edges, pcts[si], ty),
          isCurved: smooth,
          curveSmoothness: 0.2,
          preventCurveOverShooting: true,
          color: series[si].color,
          barWidth: 1.6,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(
            show: true,
            color: series[si].color.withValues(alpha: 0.16),
          ),
        ),
    ];

    final xInterval = (hi - lo) / 6.0;

    return LineChart(
      LineChartData(
        minX: lo,
        maxX: hi,
        minY: minY,
        maxY: maxY,
        lineBarsData: bars,
        lineTouchData: const LineTouchData(enabled: false),
        clipData: const FlClipData.all(),
        gridData: FlGridData(
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) =>
              const FlLine(color: brandRule, strokeWidth: 0.5),
        ),
        borderData: FlBorderData(
          show: true,
          border: const Border(
            left: BorderSide(color: brandRule),
            bottom: BorderSide(color: brandRule),
          ),
        ),
        titlesData: FlTitlesData(
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              interval: isLog ? 1.0 : null,
              getTitlesWidget: (value, meta) =>
                  _leftLabel(value, isLog, yt, minY, maxY),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 26,
              interval: xInterval > 0 ? xInterval : null,
              getTitlesWidget: (value, meta) => Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  formatChannelValue(value),
                  style: plexMono(fontSize: 10, color: brandFgDim),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Two points per bin (`edge_j` and `edge_{j+1}` at the same height) trace a
  /// flat-topped staircase; consecutive bins connect with a vertical step.
  List<FlSpot> _staircase(
    Float64List edges,
    List<double> pct,
    double Function(double) ty,
  ) {
    final spots = <FlSpot>[];
    for (var j = 0; j < pct.length; j++) {
      final y = ty(pct[j]);
      spots.add(FlSpot(edges[j], y));
      spots.add(FlSpot(edges[j + 1], y));
    }
    return spots;
  }

  /// One point per bin at its centre — the fitted-polyline form. Anchored at
  /// the outer edges (baseline) so the curve and its fill close cleanly at the
  /// range ends instead of floating.
  List<FlSpot> _polyline(
    Float64List edges,
    List<double> pct,
    double Function(double) ty,
  ) {
    final n = pct.length;
    final base = ty(0);
    final spots = <FlSpot>[FlSpot(edges[0], base)];
    for (var j = 0; j < n; j++) {
      spots.add(FlSpot((edges[j] + edges[j + 1]) / 2.0, ty(pct[j])));
    }
    spots.add(FlSpot(edges[n], base));
    return spots;
  }

  /// Left-axis percentage label. On a log axis the tick value is `log₁₀(pct)`,
  /// exponentiated back to a percentage; only decade ticks are labelled.
  Widget _leftLabel(
    double value,
    bool isLog,
    YScaleTransform yt,
    double minY,
    double maxY,
  ) {
    String text;
    if (isLog) {
      if ((value - value.roundToDouble()).abs() > 1e-6) {
        return const SizedBox.shrink();
      }
      text = '${formatChannelValue(math.pow(10, value).toDouble())}%';
    } else {
      if (value <= minY || value >= maxY) return const SizedBox.shrink();
      // Ticks are in display space; inverse-format to the real percentage
      // (identity for linear).
      text = '${formatChannelValue(yt.inverse(value))}%';
    }
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Text(
        text,
        style: plexMono(fontSize: 10, color: brandFgDim),
        textAlign: TextAlign.right,
      ),
    );
  }
}

double _log10(double v) => math.log(v) / math.ln10;

/// Title row above the histogram: a colour-dot legend (one entry per overlaid
/// series) plus active-option tags (symmetric, and the non-linear count-axis
/// scale — log / sqrt / sq).
class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.series,
    required this.symmetric,
    required this.yScale,
  });

  final List<_Series> series;
  final bool symmetric;

  /// The active count-axis scale; tagged in the title when non-linear.
  final YScale yScale;

  @override
  Widget build(BuildContext context) {
    final scaleTag = switch (yScale) {
      YScale.linear => null,
      YScale.log => 'log',
      YScale.sqrtSigned => 'sqrt',
      YScale.squareSigned => 'sq',
    };
    final tags = [
      if (symmetric) 'symmetric',
      if (scaleTag != null) scaleTag,
    ];
    return Padding(
      // Reserve the top-right corner for the per-chart drag + properties
      // overlay buttons so the legend / tags don't sit under them.
      padding: const EdgeInsets.fromLTRB(8, 6, 60, 2),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 12,
              runSpacing: 2,
              children: [
                for (final s in series)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: s.color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        s.label,
                        style: plexMono(fontSize: 12, color: brandFg),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          if (tags.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(
              '· ${tags.join(' · ')}',
              style: plexMono(fontSize: 11, color: brandFgDim),
            ),
          ],
        ],
      ),
    );
  }
}
