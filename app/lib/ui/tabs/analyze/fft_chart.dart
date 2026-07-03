import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/fft_options.dart';
import '../../../data/session_model.dart';
import '../../../data/y_scale.dart';
import '../../../providers/channel_provider.dart' show sessionHandleProvider;
import '../../../providers/cursor_provider.dart';
import '../../../providers/selection_provider.dart';
import '../../../providers/workspace_provider.dart';
import '../../../src/rust/fft.dart'
    show WelchResult, FftWindow, Detrend, Averaging, Scaling;
import '../../../src/rust/session.dart' show welchChannelWindowed;
import 'fft_window_resolver.dart' show SpectrumRequest, kMaxFftSpectra;
import '../../brand/brand.dart';
import '../../widgets/chart_context_menu.dart';
import '../../widgets/time_format.dart';
import '../../widgets/value_format.dart' show formatChannelValue;
import 'chart_workspace.dart' show ChartPropertiesDialog, confirmRemoveChart;

/// Welch spectrum for one windowed segment of a channel, computed in the engine
/// from the retained handle ([welchChannelWindowed] — no samples cross FFI, only
/// the [WelchResult] does). `autoDispose`; keyed by (sessionId, channelId,
/// t0Secs, t1Secs) plus every Welch parameter so a zoom, lap-selection, or
/// parameter change yields a fresh spectrum. See §26.
final fftSpectrumProvider = FutureProvider.autoDispose.family<
    WelchResult,
    ({
      String sessionId,
      String channelId,
      double t0Secs,
      double t1Secs,
      FftWindow window,
      int nperseg,
      int noverlap,
      Detrend detrend,
      Averaging averaging,
      Scaling scaling,
    })>((ref, k) async {
  final handle = await ref.watch(sessionHandleProvider(k.sessionId).future);
  return welchChannelWindowed(
    handle: handle,
    channelId: k.channelId,
    t0Secs: k.t0Secs,
    t1Secs: k.t1Secs,
    window: k.window,
    nperseg: BigInt.from(k.nperseg),
    noverlap: BigInt.from(k.noverlap),
    detrend: k.detrend,
    averaging: k.averaging,
    scaling: k.scaling,
  );
});

/// A one-sided FFT magnitude spectrum chart. See §14.1.
///
/// Renders one spectral line per resolved [SpectrumRequest] (windowed Welch,
/// computed in the engine via [welchChannelWindowed] — no samples cross FFI).
/// In session-mode the window tracks the worksheet zoom; in lap-mode each
/// selected lap produces a separate labelled line. Window, segment length,
/// overlap, detrend, averaging, scaling, and both axis scales (linear / log)
/// are configured in the chart properties dialog and persisted on the slot.
///
/// **Log X:** X values are transformed to `log₁₀(freq_Hz)`. The DC bin is
/// skipped. Axis labels show actual Hz values (0.1, 1, 10, 100 …) at one-
/// decade intervals. This reveals low-frequency suspension content that would
/// be compressed into a thin sliver on a linear axis.
///
/// **Log Y:** magnitude values are transformed to `log₁₀(max(mag, floor))`,
/// where the floor is a small fraction of the global maximum to avoid
/// `log₁₀(0)`. Axis labels show actual linear values.
///
/// When [truncated] is true (more than [kMaxFftSpectra] requests), a note is
/// shown above the chart asking the user to narrow the selection.
///
/// **Colors** come from [channelColors] (ARGB int override per channel ID) or
/// fall back to a built-in palette. The title bar renders a colored dot + label
/// per line as a legend.
///
/// Optional [yMin]/[yMax] clip the Y axis; null means auto-scale.
///
/// No cursor is rendered — FFT charts are read-only frequency-domain views.
///
/// **Context menu:** Right-click / long-press opens [ChartContextMenu].
/// Properties... opens [ChartPropertiesDialog]; Copy Cursor Values copies the
/// worksheet cursor pair to the clipboard.
class FftChart extends ConsumerStatefulWidget {
  /// Creates an [FftChart].
  const FftChart({
    super.key,
    required this.requests,
    required this.truncated,
    required this.renderableMetaById,
    required this.worksheetId,
    required this.slotIndex,
    this.yMin,
    this.yMax,
    this.channelColors = const {},
  });

  /// Resolved windowed spectra to draw — one line each (Task 5 output).
  final List<SpectrumRequest> requests;

  /// True when more spectra were requested than [kMaxFftSpectra] allows.
  final bool truncated;

  /// Channel metadata keyed by channelId — provides [SessionChannelData.sampleRateHz]
  /// and [SessionChannelData.length] for each renderable channel.
  final Map<String, SessionChannelData> renderableMetaById;

  /// Stable UUID of the containing worksheet — keys [cursorProvider] for
  /// the "Copy Cursor Values" menu item.
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

  @override
  ConsumerState<FftChart> createState() => _FftChartState();
}

class _FftChartState extends ConsumerState<FftChart> {
  @override
  Widget build(BuildContext context) {
    return ChartContextMenu(
      worksheetId: widget.worksheetId,
      slotIndex: widget.slotIndex,
      // FFT X axis is frequency (Hz), not the worksheet time axis. Hide
      // zoom + pan items so users don't see commands that update
      // worksheet state without affecting this chart. A frequency-aware
      // zoom is a v2 follow-up.
      fullDataRange: const (0.0, 1.0),
      pixelToTimeSecs: (_) => 0.0,
      xAxisIsWorksheetTime: false,
      onOpenProperties: () => _openPropertiesDialog(context),
      onRemoveChart: () => confirmRemoveChart(context, ref, widget.slotIndex),
      onCopyCursorValues: _copyCursorValues,
      child: _buildContent(context),
    );
  }

  /// Returns the chart body without the [ChartContextMenu] wrapper so
  /// [build] can wrap all rendering paths in a single call.
  Widget _buildContent(BuildContext context) {
    if (widget.requests.isEmpty) {
      return Center(
        child: Text(
          'No channel assigned — tap "Add channel" to select one.',
          style: plexMono(fontSize: 12, color: brandFgFaint),
        ),
      );
    }

    // Requests with no matching metadata (event-driven or absent channel) are
    // silently skipped so a mixed selection still renders any renderable request.
    final renderable = [
      for (final r in widget.requests)
        if (widget.renderableMetaById.containsKey(r.channelId)) r,
    ];

    if (renderable.isEmpty) {
      // No fixed-rate channel metadata found; show the most specific message.
      final anyMeta = widget.renderableMetaById.values.any((c) => c.sampleRateHz > 0);
      return Center(
        child: Text(
          anyMeta
              ? 'No data — select sessions in the Data tab.'
              : 'FFT requires a fixed-rate channel.',
          style: plexMono(fontSize: 12, color: brandFgFaint),
        ),
      );
    }

    // Window function and X scale live on the slot — configure via the
    // chart properties dialog. Watching the slot here means the chart
    // re-renders the moment the dialog applies a change. Bounds-guard the
    // index: when the active worksheet is switched, this widget can briefly
    // outlive its slot (the newly-active sheet may have fewer charts), and an
    // unguarded `charts[slotIndex]` would throw a RangeError from the stale
    // selector before the widget is disposed.
    final slot = ref.watch(
      workspaceProvider.select(
        (s) => widget.slotIndex < s.activeWorksheet.charts.length
            ? s.activeWorksheet.charts[widget.slotIndex]
            : null,
      ),
    );
    if (slot == null) return const SizedBox.shrink();

    final legend = [
      for (var i = 0; i < renderable.length; i++)
        (
          label: renderable[i].label,
          color: _colorFor(renderable[i].channelId, i),
        ),
    ];

    return Column(
      children: [
        _TitleBar(entries: legend),
        if (widget.truncated)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Text(
              'Showing first $kMaxFftSpectra spectra — narrow the selection.',
              style: plexMono(fontSize: 11, color: brandFgDim),
            ),
          ),
        Expanded(child: _buildChart(renderable, slot)),
      ],
    );
  }

  /// Returns the rendering colour for [channelId] at palette index [i] —
  /// honours [FftChart.channelColors] overrides and falls back to the palette.
  Color _colorFor(String channelId, int i) {
    final override = widget.channelColors[channelId];
    if (override != null) return Color(override);
    return brandChartPalette[i % brandChartPalette.length];
  }

  // ── Context menu helpers ───────────────────────────────────────────────────

  /// Opens [ChartPropertiesDialog] for this slot. Invoked by the context
  /// menu's "Properties..." item (and F5 keybinding).
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

  /// Copies cursor A and B times (session-relative seconds) to the system
  /// clipboard. No-op when both cursors are unset.
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

  Widget _buildChart(List<SpectrumRequest> renderable, ChartSlot slot) {
    final logX = slot.spectral.freqScale == FftXScale.log;
    final logY = slot.yScale == YScale.log;

    // First pass: gather every request's spectrum so a shared log-Y floor can
    // be derived from the global maximum before building spots. Each spectrum is
    // computed in the engine from the retained handle ([fftSpectrumProvider] →
    // welchChannelWindowed — no samples cross FFI) over the request's time window
    // so zoom / lap selection drives the frequency content shown. Segment length
    // derives from the windowed sample count so short windows auto-reduce nperseg.
    final spectra =
        <({List<double> freqs, List<double> values, String id, int i})>[];
    var globalMax = 0.0;
    var anyLoading = false;
    for (var i = 0; i < renderable.length; i++) {
      final r = renderable[i];
      final ch = widget.renderableMetaById[r.channelId]!;
      final winLen = ((r.t1Secs - r.t0Secs) * ch.sampleRateHz).round();
      final seg =
          slot.spectral.segmentLength ?? ChartSlot.autoFftSegmentLength(winLen);
      final overlap =
          winLen == 0 ? 0 : ((slot.spectral.overlapPercent / 100.0) * seg).round();
      final result = ref
          .watch(
            fftSpectrumProvider(
              (
                sessionId: r.sessionId,
                channelId: r.channelId,
                t0Secs: r.t0Secs,
                t1Secs: r.t1Secs,
                window: slot.spectral.window,
                nperseg: seg,
                noverlap: overlap,
                detrend: slot.spectral.detrend,
                averaging: slot.fftAveraging,
                scaling: slot.spectral.scaling,
              ),
            ),
          )
          .valueOrNull;
      if (result == null) {
        anyLoading = true;
        continue;
      }
      for (final v in result.values) {
        if (v > globalMax) globalMax = v;
      }
      spectra.add(
        (
          freqs: result.freqsHz,
          values: result.values,
          id: r.channelId,
          i: i,
        ),
      );
    }

    // Nothing computed yet — every channel's spectrum is still in flight.
    if (spectra.isEmpty && anyLoading) {
      return const Center(child: CircularProgressIndicator(color: brandInfo));
    }

    // Log-Y floor: a small fraction of the global max keeps the line continuous
    // and avoids log10(0) = -infinity. Guard the all-zero case.
    final yFloor = globalMax > 0 ? globalMax / 1e6 : 1e-12;
    // Non-log scales (linear / sqrt / square) go through the shared transform;
    // `log` keeps FFT's floor + decade rendering below. Magnitude is >= 0, so
    // the signed transforms reduce to plain sqrt / square.
    final yt = YScaleTransform(slot.yScale, dataMaxAbs: globalMax);

    final bars = <LineChartBarData>[];
    // Track the plotted data range (in axis space) so a log axis can place its
    // decade-minor grid lines across exactly the visible span.
    var minXv = double.infinity;
    var maxXv = double.negativeInfinity;
    var minYv = double.infinity;
    var maxYv = double.negativeInfinity;
    for (final s in spectra) {
      final spots = <FlSpot>[];
      for (var k = 0; k < s.values.length; k++) {
        final f = s.freqs[k];
        if (logX && f <= 0) continue; // skip DC; log10(0) undefined
        final x = logX ? math.log(f) / math.ln10 : f;
        final mag = s.values[k];
        final y = logY
            ? math.log(math.max(mag, yFloor)) / math.ln10
            : yt.forward(mag);
        if (x < minXv) minXv = x;
        if (x > maxXv) maxXv = x;
        if (y < minYv) minYv = y;
        if (y > maxYv) maxYv = y;
        spots.add(FlSpot(x, y));
      }
      bars.add(
        LineChartBarData(
          spots: spots,
          color: _colorFor(s.id, s.i),
          dotData: const FlDotData(show: false),
          isCurved: false,
          barWidth: 1,
        ),
      );
    }

    // Minor (intra-decade) grid lines for whichever axis is in log mode — the
    // 2…9 ticks between each power of ten that give a log axis its
    // characteristic "log paper" bunching. The major decade lines come from the
    // FlGridData interval below (1.0 in log space = one per decade); these dim
    // minors are layered on top via extraLines.
    final minorColor = brandRule.withValues(alpha: 0.4);
    final minorVertical = <VerticalLine>[
      if (logX && maxXv > minXv)
        for (final p in _logMinorPositions(minXv, maxXv))
          VerticalLine(
            x: p,
            color: minorColor,
            strokeWidth: brandHairlineWidth,
          ),
    ];
    final minorHorizontal = <HorizontalLine>[
      if (logY && maxYv > minYv)
        for (final p in _logMinorPositions(minYv, maxYv))
          HorizontalLine(
            y: p,
            color: minorColor,
            strokeWidth: brandHairlineWidth,
          ),
    ];

    final AxisTitles bottomTitles;
    if (logX) {
      bottomTitles = AxisTitles(
        axisNameWidget: _axisName('Frequency (Hz)'),
        sideTitles: SideTitles(
          showTitles: true,
          // One label per decade: …0.1, 1, 10, 100, 1000…
          interval: 1.0,
          getTitlesWidget: _logFreqLabel,
        ),
      );
    } else {
      bottomTitles = AxisTitles(
        axisNameWidget: _axisName('Frequency (Hz)'),
        sideTitles: SideTitles(
          showTitles: true,
          getTitlesWidget: _axisValue,
        ),
      );
    }

    final yAxisName =
        slot.spectral.scaling == Scaling.density ? 'PSD (units²/Hz)' : 'Magnitude';
    final AxisTitles leftTitles;
    if (logY) {
      leftTitles = AxisTitles(
        axisNameWidget: _axisName(yAxisName),
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 44,
          interval: 1.0,
          getTitlesWidget: _logMagLabel,
        ),
      );
    } else {
      leftTitles = AxisTitles(
        axisNameWidget: _axisName(yAxisName),
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 44,
          // Linear keeps fl_chart's default label; sqrt/square are display
          // space, so inverse-format to the real magnitude.
          getTitlesWidget: yt.isIdentity
              ? _axisValue
              : (value, meta) => _magLabel(yt.inverse(value), meta),
        ),
      );
    }

    final chartData = LineChartData(
      lineBarsData: bars,
      minY: widget.yMin,
      maxY: widget.yMax,
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => brandSurface,
          tooltipBorder:
              const BorderSide(color: brandRule, width: brandHairlineWidth),
          tooltipRoundedRadius: brandControlRadius,
          tooltipPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          tooltipMargin: 8,
          fitInsideHorizontally: true,
          fitInsideVertically: true,
          getTooltipItems: (touchedSpots) {
            // Plotted coordinates live in transform space — invert them back to
            // real units for the readout: x → Hz (pow10 when the frequency axis
            // is log), y → magnitude (pow10 when the magnitude axis is log, else
            // the sqrt/square inverse). Frequency is shared by every series at a
            // touch x, so it heads the first item only; each item's magnitude is
            // coloured by its series.
            final items = <LineTooltipItem>[];
            for (var i = 0; i < touchedSpots.length; i++) {
              final s = touchedSpots[i];
              final mag = logY
                  ? math.pow(10.0, s.y).toDouble()
                  : (yt.isIdentity ? s.y : yt.inverse(s.y));
              final magStyle = plexMono(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: s.bar.color ?? brandFg,
              );
              if (i == 0) {
                final f = logX ? math.pow(10.0, s.x).toDouble() : s.x;
                final header = LineTooltipItem(
                  '${formatChannelValue(f)} Hz\n',
                  plexMono(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: brandFg,
                  ),
                  children: [
                    TextSpan(text: formatChannelValue(mag), style: magStyle),
                  ],
                );
                items.add(header);
              } else {
                items.add(LineTooltipItem(formatChannelValue(mag), magStyle));
              }
            }
            return items;
          },
        ),
      ),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        leftTitles: leftTitles,
        bottomTitles: bottomTitles,
      ),
      gridData: FlGridData(
        show: true,
        // A log axis snaps its major grid to one line per decade so the lines
        // land on the same 0.1 / 1 / 10 / 100 ticks as the labels; a linear
        // axis keeps fl_chart's auto interval.
        verticalInterval: logX ? 1.0 : null,
        horizontalInterval: logY ? 1.0 : null,
        getDrawingHorizontalLine: (_) => const FlLine(
          color: brandRule,
          strokeWidth: brandHairlineWidth,
        ),
        getDrawingVerticalLine: (_) => const FlLine(
          color: brandRule,
          strokeWidth: brandHairlineWidth,
        ),
      ),
      extraLinesData: ExtraLinesData(
        verticalLines: minorVertical,
        horizontalLines: minorHorizontal,
      ),
      borderData: FlBorderData(
        show: true,
        border: Border.all(color: brandRule, width: brandHairlineWidth),
      ),
    );

    return LineChart(chartData);
  }

  /// Decade-minor axis positions — the 2…9 ticks inside each power of ten —
  /// for a log axis spanning [minLog, maxLog] in log10 space. The decade lines
  /// themselves (k = 1) are drawn by the grid interval, so they are skipped
  /// here; the result feeds the dim minor grid layered via extraLines.
  List<double> _logMinorPositions(double minLog, double maxLog) {
    final out = <double>[];
    final first = minLog.floor();
    final last = maxLog.ceil();
    for (var d = first; d <= last; d++) {
      for (var k = 2; k <= 9; k++) {
        final p = d + math.log(k.toDouble()) / math.ln10;
        if (p >= minLog && p <= maxLog) out.add(p);
      }
    }
    return out;
  }

  /// Mono brand axis-name label (e.g. "Frequency (Hz)", "Magnitude").
  Widget _axisName(String text) =>
      Text(text, style: plexMono(fontSize: 11, color: brandFgDim));

  /// Mono brand value label for the linear (non-log) side titles — uses
  /// fl_chart's auto-formatted value so density/formatting is unchanged.
  Widget _axisValue(double value, TitleMeta meta) => SideTitleWidget(
        axisSide: meta.axisSide,
        child: Text(
          meta.formattedValue,
          style: plexMono(fontSize: 10, color: brandFgDim),
        ),
      );

  /// Formats a log-scale Y axis label. [value] is `log₁₀(magnitude)`; converts
  /// back to linear and formats compactly.
  Widget _logMagLabel(double value, TitleMeta meta) =>
      _magLabel(math.pow(10.0, value).toDouble(), meta);

  /// Compact magnitude axis label (k/M suffixes for large values, exponential
  /// below 1). Shared by the log-Y decade labels and the inverse-formatted
  /// sqrt/square labels.
  Widget _magLabel(double mag, TitleMeta meta) {
    final String label;
    if (mag >= 1e6) {
      label = '${(mag / 1e6).toStringAsFixed(0)}M';
    } else if (mag >= 1000) {
      label = '${(mag / 1000).toStringAsFixed(0)}k';
    } else if (mag >= 1) {
      label = mag.toStringAsFixed(0);
    } else {
      label = mag.toStringAsExponential(0);
    }
    return SideTitleWidget(
      axisSide: meta.axisSide,
      child: Text(label, style: plexMono(fontSize: 10, color: brandFgDim)),
    );
  }

  /// Formats a log-scale X axis label.
  ///
  /// [value] is `log₁₀(freq_Hz)`. Converts back to Hz and formats compactly:
  /// sub-1 Hz as one decimal place, 1–999 Hz as integer, ≥ 1000 Hz as `Nk`.
  Widget _logFreqLabel(double value, TitleMeta meta) {
    final freq = math.pow(10.0, value).toDouble();
    final String label;
    if (freq >= 1000) {
      label = '${(freq / 1000).toStringAsFixed(0)}k';
    } else if (freq >= 1) {
      label = freq.toStringAsFixed(0);
    } else {
      label = freq.toStringAsFixed(1);
    }
    return SideTitleWidget(
      axisSide: meta.axisSide,
      child: Text(label, style: plexMono(fontSize: 10, color: brandFgDim)),
    );
  }
}

// ---------------------------------------------------------------------------
// _TitleBar
// ---------------------------------------------------------------------------

/// One colour-dotted chip per rendered line, acting as the FFT chart's legend.
/// In session-mode the label is the channel ID; in lap-mode it is
/// `"<channel> · Lap N"`. Window function and X scale selectors live in the
/// chart properties dialog (§21.1).
class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.entries});

  /// Display label + render colour for each FFT line currently drawn.
  final List<({String label, Color color})> entries;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Wrap(
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
                  entry.label,
                  style: plexMono(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: brandFg,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
