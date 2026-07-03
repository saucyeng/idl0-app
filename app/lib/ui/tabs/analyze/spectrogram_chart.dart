import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/fft_options.dart';
import '../../../data/session_model.dart';
import '../../../data/y_scale.dart';
import '../../../providers/channel_provider.dart'
    show sessionHandleProvider;
import '../../../providers/cursor_provider.dart';
import '../../../providers/lap_provider.dart';
import '../../../providers/selection_provider.dart';
import '../../../providers/session_workspace_provider.dart';
import '../../../providers/workspace_provider.dart';
import '../../../src/rust/fft.dart' show FftWindow, Detrend, Scaling;
import '../../../src/rust/session.dart' show spectrogramChannel;
import '../../../src/rust/spectrogram.dart' show SpectrogramResult;
import '../../brand/brand.dart';
import '../../widgets/chart_context_menu.dart';
import '../../widgets/time_format.dart';
import 'chart_workspace.dart' show ChartPropertiesDialog, confirmRemoveChart;

/// Height of the bottom time axis, in logical pixels. The left frequency axis
/// and right colour legend are inset by this at the bottom so all three span
/// the same vertical extent as the heatmap canvas.
const double _kTimeAxisHeight = 20;

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// Windowed spectrogram for one channel, computed in the engine from the
/// retained handle ([spectrogramChannel] — no samples cross FFI, only the
/// [SpectrogramResult] matrix does). `autoDispose`; keyed by (sessionId,
/// channelId, t0Secs, t1Secs) plus every DSP parameter so a zoom, lap
/// selection, or parameter change yields a fresh heatmap. See §26.
final spectrogramProvider = FutureProvider.autoDispose.family<
    SpectrogramResult,
    ({
      String sessionId,
      String channelId,
      double t0Secs,
      double t1Secs,
      FftWindow window,
      int nperseg,
      int noverlap,
      Detrend detrend,
      Scaling scaling,
    })>((ref, k) async {
  final handle = await ref.watch(sessionHandleProvider(k.sessionId).future);
  return spectrogramChannel(
    handle: handle,
    channelId: k.channelId,
    t0Secs: k.t0Secs,
    t1Secs: k.t1Secs,
    window: k.window,
    nperseg: BigInt.from(k.nperseg),
    noverlap: BigInt.from(k.noverlap),
    detrend: k.detrend,
    scaling: k.scaling,
  );
});

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------

/// Paints a [SpectrogramResult] as a time × frequency heatmap.
///
/// Colour encodes each cell's power value mapped through the [YScaleTransform]
/// built from [yScale] (default `log`, giving dB-like compression) and a brand
/// gradient: dark canvas → azure info → amber hot. Frequency on Y (bottom=0 Hz,
/// top=Nyquist); time on X. The DC bin (f=0 Hz) is skipped on a log frequency
/// axis because log(0) is undefined. §26.
class _SpectrogramPainter extends CustomPainter {
  /// Creates a [_SpectrogramPainter].
  const _SpectrogramPainter({
    required this.result,
    required this.yScale,
    required this.logFreq,
    required this.maxV,
  });

  /// The spectrogram result containing the flat power matrix (row-major,
  /// `power[t * nFreqs + f]`), frequency bin centres in Hz, and frame times
  /// in session seconds.
  final SpectrogramResult result;

  /// Y-axis display scale applied to each cell's power value before colour
  /// mapping. [YScale.log] (the default) gives dB-like compression so both
  /// quiet and loud frequency content are visible simultaneously.
  final YScale yScale;

  /// When true, frequency bins are spaced logarithmically on the Y axis so
  /// low-frequency suspension content occupies more pixels than on a linear
  /// axis. The DC bin is skipped automatically. Matches [FftXScale.log] on the
  /// sibling FFT chart's X axis.
  final bool logFreq;

  /// Global maximum power across [SpectrogramResult.power], computed ONCE per
  /// result by the widget (see `_maxVFor`) rather than re-scanned every paint.
  final double maxV;

  @override
  void paint(Canvas canvas, Size size) {
    final nT = result.nTimes;
    final nF = result.nFreqs;
    if (nT == 0 || nF == 0 || maxV <= 0) return;

    // Build the display-space transform once per paint pass.
    final yt = YScaleTransform(yScale, dataMaxAbs: maxV);
    final dispMax = yt.forward(maxV);
    if (dispMax <= 0) return;

    // Skip the DC bin on a log frequency axis — log₁₀(0) is undefined and
    // DC is almost never meaningful for suspension analysis.
    final fStart = logFreq ? 1 : 0;
    if (nF <= fStart) return;

    // Aggregate frequency bins to ~one rect per vertical PIXEL instead of one
    // per bin. 4097 bins drawn into ~400 px is pure overdraw and builds a
    // ~nT×nF (≈1 M) display list that is brutal to rasterize — the source of
    // the whole-app jank. Each band takes the MAX power over the bins it covers
    // so narrow spectral peaks survive the downsampling.
    final h = size.height;
    final rows = h.ceil().clamp(1, nF - fStart);
    final cellW = size.width / nT;
    final paint = Paint()..style = PaintingStyle.fill;

    // Bin index at the top edge of each band (band 0 = top = Nyquist). Mirrors
    // _freqToY so heatmap, gridlines, and axis ticks share one mapping.
    final boundary = List<int>.generate(
      rows + 1,
      (r) => _binAtTopFraction(r / rows, nF, fStart),
    );

    for (var r = 0; r < rows; r++) {
      final bTop = boundary[r]; // higher-frequency bin (top of band)
      final bBot = boundary[r + 1]; // lower-frequency bin (bottom of band)
      final lo = bBot < bTop ? bBot : bTop;
      final hi = bBot < bTop ? bTop : bBot;
      final y0 = (r / rows) * h;
      final y1 = ((r + 1) / rows) * h;
      for (var t = 0; t < nT; t++) {
        final base = t * nF;
        var v = 0.0;
        for (var b = lo; b <= hi; b++) {
          final p = result.power[base + b];
          if (p.isFinite && p > v) v = p;
        }
        final norm = (yt.forward(v) / dispMax).clamp(0.0, 1.0);
        paint.color = _ramp(norm);
        canvas.drawRect(
          Rect.fromLTRB(t * cellW, y0, (t + 1) * cellW, y1),
          paint,
        );
      }
    }
  }

  /// Frequency-bin index at screen top-fraction [topFrac] (0 = top = Nyquist,
  /// 1 = bottom). Inverse of [_freqToY] so the heatmap, gridlines, and axis
  /// labels all agree on where a frequency lands.
  int _binAtTopFraction(double topFrac, int nF, int fStart) {
    if (!logFreq) {
      return (nF * (1.0 - topFrac)).round().clamp(fStart, nF - 1);
    }
    final lo = math.log(fStart.toDouble());
    final hi = math.log(nF.toDouble());
    final f = math.exp(lo + (1.0 - topFrac) * (hi - lo));
    return f.round().clamp(fStart, nF - 1);
  }

  /// Brand gradient: dark canvas → saturated azure info → amber hot.
  ///
  /// The two-stop lerp gives a distinctly warm-to-cool-to-hot appearance,
  /// avoiding "AI grey". Saturated, not desaturated.
  Color _ramp(double t) => Color.lerp(
        Color.lerp(
          brandBg,
          brandInfo,
          (t * 2).clamp(0.0, 1.0),
        )!,
        brandHivis,
        ((t - 0.5) * 2).clamp(0.0, 1.0),
      )!;

  @override
  bool shouldRepaint(_SpectrogramPainter old) =>
      old.result != result ||
      old.yScale != yScale ||
      old.logFreq != logFreq ||
      old.maxV != maxV;
}

// ---------------------------------------------------------------------------
// Cursor + gridline overlay (cheap, repaints on cursor change only)
// ---------------------------------------------------------------------------

/// Faint frequency/time gridlines plus the shared A/B/hover cursor lines,
/// painted on a layer ABOVE the (RepaintBoundary-isolated) heatmap so cursor
/// motion never forces the heavy heatmap to re-rasterize.
///
/// Reads the worksheet's [cursorProvider] + [hoverCursorProvider] so the lines
/// match every other chart: A (solid [brandFg]), B (dashed [brandHivis]), and
/// — when A is unpinned — the hover position previews as A, exactly as the
/// time-series chart does.
class _SpectrogramCursorOverlay extends ConsumerWidget {
  const _SpectrogramCursorOverlay({
    required this.worksheetId,
    required this.t0Secs,
    required this.t1Secs,
  });

  /// Worksheet whose shared cursor pair this overlay renders.
  final String worksheetId;

  /// Session-relative seconds at the left/right edges of the heatmap — the
  /// window the spectrogram is showing (zoom span or lap). A cursor outside
  /// `[t0Secs, t1Secs]` is not drawn.
  final double t0Secs;

  /// See [t0Secs].
  final double t1Secs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pair = ref.watch(cursorProvider(worksheetId));
    final hover = ref.watch(hoverCursorProvider(worksheetId));
    return CustomPaint(
      painter: _SpectrogramOverlayPainter(
        t0Secs: t0Secs,
        t1Secs: t1Secs,
        aSecs: pair.aSecs,
        bSecs: pair.bSecs,
        hoverSecs: hover,
      ),
      child: const SizedBox.expand(),
    );
  }
}

/// Paints the gridlines and cursor lines for [_SpectrogramCursorOverlay].
class _SpectrogramOverlayPainter extends CustomPainter {
  const _SpectrogramOverlayPainter({
    required this.t0Secs,
    required this.t1Secs,
    required this.aSecs,
    required this.bSecs,
    required this.hoverSecs,
  });

  /// Window edges in session seconds — map cursor time → X.
  final double t0Secs;

  /// See [t0Secs].
  final double t1Secs;

  /// Pinned cursor A in session seconds, or null.
  final double? aSecs;

  /// Pinned cursor B in session seconds, or null.
  final double? bSecs;

  /// Transient hover position in session seconds, or null.
  final double? hoverSecs;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = brandRule
      ..strokeWidth = brandHairlineWidth;
    // Horizontal frequency gridlines at the interior freq-axis tick fractions
    // (i/6); evenly spaced on screen = log-spaced in Hz, which is what makes
    // the log scale legible. Edges (0, 1) are the axis borders, skipped.
    for (var i = 1; i <= 5; i++) {
      final y = (i / 6) * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    // Vertical time gridlines at the interior time-axis tick fractions (i/4).
    for (var i = 1; i <= 3; i++) {
      final x = (i / 4) * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }

    final span = t1Secs - t0Secs;
    if (span <= 0) return;
    // A (or hover-as-A when A is unpinned) solid; B dashed — matching the
    // time-series chart's cursor convention exactly.
    final effA = aSecs ?? hoverSecs;
    if (effA != null) _cursor(canvas, size, effA, span, brandFg, dashed: false);
    if (bSecs != null) _cursor(canvas, size, bSecs!, span, brandHivis, dashed: true);
  }

  /// Draws one vertical cursor line at [secs] if it falls within the window.
  void _cursor(
    Canvas canvas,
    Size size,
    double secs,
    double span,
    Color color, {
    required bool dashed,
  }) {
    if (secs < t0Secs || secs > t1Secs) return;
    final x = (secs - t0Secs) / span * size.width;
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    if (!dashed) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
      return;
    }
    const dash = 4.0, gap = 3.0;
    var y = 0.0;
    while (y < size.height) {
      canvas.drawLine(Offset(x, y), Offset(x, math.min(y + dash, size.height)), p);
      y += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_SpectrogramOverlayPainter old) =>
      old.t0Secs != t0Secs ||
      old.t1Secs != t1Secs ||
      old.aSecs != aSecs ||
      old.bSecs != bSecs ||
      old.hoverSecs != hoverSecs;
}

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------

/// A time × frequency heatmap spectrogram chart. See §26.
///
/// Renders ONE channel per slot (the first channel in [channels] with a fixed
/// sample rate and non-zero length). In session-mode the time window is the
/// worksheet zoom span, or the full session when unzoomed. In lap-mode the
/// window is the PRIMARY lap: the workspace [mainLapNumber] when set and
/// present, else the lowest-numbered selected lap from [effectiveLapKeysProvider].
///
/// Window, segment length, overlap, detrend, scaling, and frequency-axis scale
/// are read from [ChartSlot.spectral]; the colour scale comes from
/// [ChartSlot.yScale] (default [YScale.log] for dB-like compression).
///
/// Same empty/loading states as [FftChart]: "FFT requires a fixed-rate channel"
/// when no fixed-rate channel is present; a [CircularProgressIndicator] while
/// the engine is computing. Wrapped in [ChartContextMenu] (no worksheet-time X
/// axis — the spectrogram X axis is relative time within the selected window).
class SpectrogramChart extends ConsumerStatefulWidget {
  /// Creates a [SpectrogramChart].
  const SpectrogramChart({
    super.key,
    required this.channels,
    required this.worksheetId,
    required this.slotIndex,
    this.channelColors = const {},
  });

  /// All channel metadata assigned to this slot. The first fixed-rate channel
  /// ([SessionChannelData.sampleRateHz] > 0, [SessionChannelData.length] > 0)
  /// is used; additional channels are ignored by the spectrogram (one channel
  /// per slot). Metadata only — samples are read from the engine.
  final List<SessionChannelData> channels;

  /// Stable UUID of the containing worksheet — keys [cursorProvider] for the
  /// "Copy Cursor Values" menu item and [WorkspaceState.worksheetRanges] for
  /// the session-mode zoom span.
  final String worksheetId;

  /// Index of this chart's slot in the active worksheet — used by
  /// [ChartContextMenu] to dispatch slot-local actions (vertical zoom,
  /// properties).
  final int slotIndex;

  /// Per-channel colour overrides keyed by [SessionChannelData.channelId] as
  /// ARGB int values. Unused by the heatmap itself (colour is power-mapped),
  /// but preserved for the deferred properties dialog wiring.
  final Map<String, int> channelColors;

  @override
  ConsumerState<SpectrogramChart> createState() => _SpectrogramChartState();
}

class _SpectrogramChartState extends ConsumerState<SpectrogramChart> {
  // Window edges + content width captured during the data build so the
  // ChartContextMenu's pixelToTimeSecs (built in build(), before the child
  // lays out) can map a tap to session seconds. A one-frame lag is harmless
  // for tap-to-pin and persists across the loading→data rebuild.
  double? _winT0;
  double? _winT1;
  double? _contentWidth;

  // Colour-max cache — computed ONCE per SpectrogramResult instead of scanned
  // on every paint. Riverpod returns the same result instance until the key
  // changes, so identity keys the cache.
  SpectrogramResult? _maxVResult;
  double _maxV = 0.0;

  /// Global max power for [sp], memoised by result identity.
  double _maxVFor(SpectrogramResult sp) {
    if (identical(sp, _maxVResult)) return _maxV;
    var m = 0.0;
    for (final v in sp.power) {
      if (v.isFinite && v > m) m = v;
    }
    _maxVResult = sp;
    _maxV = m;
    return m;
  }

  /// Maps a primary-tap's local X — in the chart-content coordinate space,
  /// which begins at the [_FreqAxis] — to session seconds within the displayed
  /// window, so a tap pins cursor A at the right time. The heatmap canvas is
  /// inset by the freq axis (left) and colour legend (right); see [_FreqAxis]
  /// (44) and [_ColourLegend] (20).
  double _localDxToSeconds(double localDx) {
    final t0 = _winT0;
    final t1 = _winT1;
    final w = _contentWidth;
    if (t0 == null || t1 == null || w == null || t1 <= t0) return t0 ?? 0.0;
    const leftInset = 44.0;
    const rightInset = 20.0;
    final plotW = w - leftInset - rightInset;
    if (plotW <= 0) return t0;
    final frac = ((localDx - leftInset) / plotW).clamp(0.0, 1.0);
    return t0 + frac * (t1 - t0);
  }

  @override
  Widget build(BuildContext context) {
    return ChartContextMenu(
      worksheetId: widget.worksheetId,
      slotIndex: widget.slotIndex,
      // The spectrogram X axis IS time (session seconds within the displayed
      // window), so the shared worksheet cursor applies: a tap pins cursor A
      // and the A/B/hover lines render on the overlay, matching the
      // time-series chart. Zoom acts on the worksheet window the chart follows.
      fullDataRange: (_winT0 ?? 0.0, _winT1 ?? 1.0),
      pixelToTimeSecs: _localDxToSeconds,
      onOpenProperties: () => _openPropertiesDialog(context),
      onRemoveChart: () => confirmRemoveChart(context, ref, widget.slotIndex),
      onCopyCursorValues: _copyCursorValues,
      child: _buildContent(context),
    );
  }

  /// Returns the chart body (without the [ChartContextMenu] wrapper).
  Widget _buildContent(BuildContext context) {
    if (widget.channels.isEmpty) {
      return Center(
        child: Text(
          'No channel assigned — tap "Add channel" to select one.',
          style: plexMono(fontSize: 12, color: brandFgFaint),
        ),
      );
    }

    // First fixed-rate, non-empty channel is the spectrogram channel.
    final ch = widget.channels.firstWhereOrNull(
      (c) => c.sampleRateHz > 0 && c.length > 0,
    );

    if (ch == null) {
      return Center(
        child: Text(
          'FFT requires a fixed-rate channel.',
          style: plexMono(fontSize: 12, color: brandFgFaint),
        ),
      );
    }

    // Bounds-guard: this widget can briefly outlive its slot on worksheet switch.
    final slot = ref.watch(
      workspaceProvider.select(
        (s) => widget.slotIndex < s.activeWorksheet.charts.length
            ? s.activeWorksheet.charts[widget.slotIndex]
            : null,
      ),
    );
    if (slot == null) return const SizedBox.shrink();

    // Resolve the time window.
    final window = _resolveWindow(ch);
    if (window == null) {
      return Center(
        child: Text(
          'No lap selected.',
          style: plexMono(fontSize: 12, color: brandFgFaint),
        ),
      );
    }
    final (t0, t1) = window;

    // Segment length sets the frequency resolution — derived from the windowed
    // sample count, mirroring FftChart. But the time-column count is a display
    // concern, not a Welch-averaging one: instead of the FFT chart's fixed 50%
    // overlap (which would yield only ~15–26 columns), auto-size the hop to fill
    // the heatmap's time axis with ~kSpectrogramTargetColumns frames.
    final winLen = ((t1 - t0) * ch.sampleRateHz).round();
    final seg =
        slot.spectral.segmentLength ?? ChartSlot.autoFftSegmentLength(winLen);
    final overlap = ChartSlot.autoSpectrogramOverlap(winLen, seg);

    final logFreq = slot.spectral.freqScale == FftXScale.log;

    final result = ref.watch(
      spectrogramProvider((
        sessionId: ch.sessionId,
        channelId: ch.channelId,
        t0Secs: t0,
        t1Secs: t1,
        window: slot.spectral.window,
        nperseg: seg,
        noverlap: overlap,
        detrend: slot.spectral.detrend,
        scaling: slot.spectral.scaling,
      ),),
    );

    return result.when(
      loading: () => const Center(
        child: CircularProgressIndicator(color: brandInfo),
      ),
      error: (e, _) => Center(
        child: Text(
          'Error: $e',
          style: plexMono(fontSize: 11, color: brandAccent),
        ),
      ),
      data: (sp) => _buildHeatmap(sp, ch, t0, t1, slot, logFreq),
    );
  }

  /// Resolves `(t0Secs, t1Secs)` for the channel.
  ///
  /// Session-mode: worksheet zoom span, or the whole session when unzoomed.
  /// Lap-mode: primary lap = workspace [mainLapNumber] when set and present,
  /// else the lowest-numbered selected lap for this session. Returns null
  /// when in lap-mode but no lap is determinable.
  (double, double)? _resolveWindow(SessionChannelData ch) {
    final selection = ref.watch(selectionProvider);
    final worksheetRange = ref
        .watch(workspaceProvider)
        .worksheetRanges[widget.worksheetId];

    if (selection.mode == SelectionMode.session) {
      // Session-mode: use zoom span or full session.
      if (worksheetRange != null) {
        return (worksheetRange.startSecs, worksheetRange.endSecs);
      }
      // Full session — derive from channel length + rate.
      final durationSecs =
          ch.sampleRateHz > 0 ? ch.length / ch.sampleRateHz : 0.0;
      return (0.0, durationSecs);
    }

    // Lap-mode: resolve the primary lap.
    final wsValue = ref.watch(sessionWorkspaceProvider(ch.sessionId));
    final ws = wsValue.valueOrNull;

    // Try workspace mainLapNumber first.
    int? lapNum = ws?.mainLapNumber;

    if (lapNum == null) {
      // Fall back to lowest selected lap for this session.
      final lapKeys = ref
          .watch(effectiveLapKeysProvider)
          .where((k) => k.sessionId == ch.sessionId)
          .toList()
        ..sort((a, b) => a.lapNumber.compareTo(b.lapNumber));
      lapNum = lapKeys.firstOrNull?.lapNumber;
    }

    if (lapNum == null) return null;

    final laps = ref.watch(sessionLapsProvider(ch.sessionId)).valueOrNull;
    if (laps == null) return null;
    final lap = laps.where((l) => l.lapNumber == lapNum).firstOrNull;
    if (lap == null) return null;

    // Use engine-computed session-relative seconds (epoch_ms_to_time_secs,
    // GPS-grid interpolated) so the window aligns with FFT and time-series
    // charts — not the raw GPS epoch subtraction.
    final t0 = lap.startTimeSecs;
    final t1 = lap.endTimeSecs;
    return (t0, t1);
  }

  Widget _buildHeatmap(
    SpectrogramResult sp,
    SessionChannelData ch,
    double t0Secs,
    double t1Secs,
    ChartSlot slot,
    bool logFreq,
  ) {
    final nT = sp.nTimes;
    final nF = sp.nFreqs;

    // Nyquist frequency in Hz — top of the Y axis.
    final nyquist = ch.sampleRateHz / 2.0;

    // Time span displayed on the X axis in seconds.
    final spanSecs = (t1Secs - t0Secs).abs();

    // Colour-max once per result; window captured for the cursor mapping.
    final maxV = _maxVFor(sp);
    _winT0 = t0Secs;
    _winT1 = t1Secs;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Capture content width for the context-menu tap→seconds mapping.
        _contentWidth = constraints.maxWidth;
        return Column(
          children: [
            _TitleBar(channelId: ch.channelId),
            Expanded(
              child: Row(
                children: [
                  // Frequency axis on the left — inset at the bottom by the
                  // time-axis height so its ticks span exactly the heatmap
                  // canvas and line up with the overlay's frequency gridlines.
                  Padding(
                    padding: const EdgeInsets.only(bottom: _kTimeAxisHeight),
                    child: _FreqAxis(
                      nyquistHz: nyquist,
                      logFreq: logFreq,
                      nBins: nF,
                    ),
                  ),
                  // Heatmap canvas + cursor/gridline overlay.
                  Expanded(
                    child: Column(
                      children: [
                        Expanded(
                          child: nT == 0 || nF == 0
                              ? Center(
                                  child: Text(
                                    'No data — window too short.',
                                    style: plexMono(
                                      fontSize: 11,
                                      color: brandFgFaint,
                                    ),
                                  ),
                                )
                              : Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    // Heavy heatmap: rasterized once and
                                    // isolated so unrelated repaints (incl. the
                                    // cursor overlay above) can't re-raster it.
                                    RepaintBoundary(
                                      child: CustomPaint(
                                        painter: _SpectrogramPainter(
                                          result: sp,
                                          yScale: slot.yScale,
                                          logFreq: logFreq,
                                          maxV: maxV,
                                        ),
                                        child: const SizedBox.expand(),
                                      ),
                                    ),
                                    // Cheap gridlines + shared A/B/hover cursor.
                                    // Pointer-transparent so taps/drags fall
                                    // through to the ChartContextMenu gesture
                                    // detector that pins the cursor.
                                    IgnorePointer(
                                      child: _SpectrogramCursorOverlay(
                                        worksheetId: widget.worksheetId,
                                        t0Secs: t0Secs,
                                        t1Secs: t1Secs,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                        // Time axis labels below the canvas.
                        _TimeAxis(t0Secs: t0Secs, spanSecs: spanSecs),
                      ],
                    ),
                  ),
                  // Colour scale legend on the right — same bottom inset as
                  // the frequency axis so it aligns with the heatmap canvas.
                  Padding(
                    padding: const EdgeInsets.only(bottom: _kTimeAxisHeight),
                    child: _ColourLegend(yScale: slot.yScale),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  // ── Context menu helpers ───────────────────────────────────────────────────

  /// Opens [ChartPropertiesDialog] for this slot.
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

  /// Copies cursor A and B times to the system clipboard.
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
}

// ---------------------------------------------------------------------------
// _TitleBar
// ---------------------------------------------------------------------------

/// Single-channel title bar for the spectrogram. Shows the channel ID.
class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.channelId});

  /// Registry name of the channel being displayed.
  final String channelId;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              color: brandInfo,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            channelId,
            style: plexMono(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: brandFg,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _FreqAxis
// ---------------------------------------------------------------------------

/// Left-side frequency axis with up to 5 tick labels (1 Hz … Nyquist on log;
/// 0 Hz … Nyquist on linear).
///
/// Width is 44 logical pixels — matches the reserved size used by the FFT
/// chart's left axis. Labels are in Hz with compact formatting (k suffix
/// for values ≥ 1 000 Hz).
///
/// On a log frequency axis the tick Y positions mirror [_SpectrogramPainter._freqToY]
/// exactly — bin index [f] maps to `h * (1 − (log(f) − log(1)) / (log(nBins) − log(1)))`.
/// The DC bin (f = 0) is skipped on log because log(0) is undefined and the
/// painter skips it too, so label and painted position are always consistent.
/// On a linear axis the ticks are placed at uniform fractions of height and
/// labelled with the corresponding fraction of [nyquistHz].
class _FreqAxis extends StatelessWidget {
  const _FreqAxis({
    required this.nyquistHz,
    required this.logFreq,
    required this.nBins,
  });

  /// Nyquist frequency in Hz — top of the Y axis.
  final double nyquistHz;

  /// Whether the frequency axis uses logarithmic spacing (matches the painter).
  final bool logFreq;

  /// Number of frequency bins in the [SpectrogramResult] — determines the log
  /// mapping range `[1, nBins]`.
  final int nBins;

  @override
  Widget build(BuildContext context) {
    const w = 44.0;
    return SizedBox(
      width: w,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final h = constraints.maxHeight;
          // Build tick (topFraction, labelHz) pairs consistent with the painter.
          final ticks = _buildTicks(h);
          return Stack(
            children: [
              for (final (topFrac, hz) in ticks)
                Positioned(
                  right: 2,
                  top: topFrac * h - 6,
                  child: Text(
                    _fmt(hz),
                    style: plexMono(fontSize: 9, color: brandFgDim),
                    textAlign: TextAlign.right,
                  ),
                ),
              // Axis name rotated 90 degrees.
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: RotatedBox(
                  quarterTurns: 3,
                  child: Center(
                    child: Text(
                      'Freq (Hz)',
                      style: plexMono(fontSize: 10, color: brandFgDim),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Returns up to 5 `(topFraction, frequencyHz)` pairs for the tick labels.
  ///
  /// [topFraction] is in `[0, 1]` where 0 = top of the axis (Nyquist) and
  /// 1 = bottom (0 Hz / lowest rendered bin). The formula mirrors
  /// [_SpectrogramPainter._freqToY] so painted rows and labels share the same
  /// Y mapping.
  List<(double, double)> _buildTicks(double h) {
    // Seven evenly-spaced screen positions → denser detail than the old five;
    // the interior five sit at i/6, lining up exactly with the overlay's
    // horizontal frequency gridlines so labels and lines coincide.
    final fracs = [for (var i = 0; i <= 6; i++) i / 6];
    if (logFreq) {
      // Log axis: DC (f=0) is skipped; fStart=1, range is [1, nBins].
      // Mirror the painter's log mapping: topFrac = 1 − (log f / log nBins).
      if (nBins < 2) return [];
      final lo = math.log(1.0);
      final hi = math.log(nBins.toDouble());
      final span = hi - lo;
      if (span <= 0) return [];
      return fracs.map((pos) {
        // Invert: p = pos → f = exp(lo + pos*span); label is bin-centre Hz.
        final f = math.exp(lo + pos * span);
        final hz = (f / nBins) * nyquistHz;
        return (1.0 - pos, hz); // topFrac = 1 − pos (pos=0 bottom, 1 top)
      }).toList();
    }
    // Linear axis: uniform fractions of height and of Nyquist.
    return fracs.map((frac) => (1.0 - frac, frac * nyquistHz)).toList();
  }

  String _fmt(double hz) {
    if (hz >= 1000) return '${(hz / 1000).toStringAsFixed(0)}k';
    if (hz >= 1) return hz.toStringAsFixed(0);
    return hz.toStringAsFixed(1);
  }
}

// ---------------------------------------------------------------------------
// _TimeAxis
// ---------------------------------------------------------------------------

/// Bottom time axis showing five evenly-spaced absolute time labels across the
/// window (session-relative seconds). The interior three sit at i/4, lining up
/// with the overlay's vertical time gridlines. Replaces the old start / span /
/// end layout whose centre label was the duration, not a midpoint time.
class _TimeAxis extends StatelessWidget {
  const _TimeAxis({required this.t0Secs, required this.spanSecs});

  /// Session-relative start of the window in seconds.
  final double t0Secs;

  /// Duration of the displayed window in seconds.
  final double spanSecs;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _kTimeAxisHeight,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (var i = 0; i <= 4; i++)
            Text(
              formatTimeReadout(t0Secs + (i / 4) * spanSecs),
              style: plexMono(fontSize: 9, color: brandFgDim),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _ColourLegend
// ---------------------------------------------------------------------------

/// Right-side colour scale legend showing the brand gradient vertically with
/// "min" / "max" labels. Width is 20 logical pixels.
///
/// The gradient mirrors [_SpectrogramPainter._ramp]: dark canvas at the
/// bottom (low power) → azure info → amber hot at the top (high power).
class _ColourLegend extends StatelessWidget {
  const _ColourLegend({required this.yScale});

  /// The active [YScale] — shown as a compact label below the legend.
  final YScale yScale;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      child: Column(
        children: [
          Text(
            'max',
            style: plexMono(fontSize: 8, color: brandFgDim),
          ),
          Expanded(
            child: Container(
              width: 10,
              margin: const EdgeInsets.symmetric(horizontal: 5),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [brandBg, brandInfo, brandHivis],
                  stops: [0.0, 0.5, 1.0],
                ),
              ),
            ),
          ),
          Text(
            'min',
            style: plexMono(fontSize: 8, color: brandFgDim),
          ),
          const SizedBox(height: 2),
          Text(
            _scaleLabel(yScale),
            style: plexMono(fontSize: 8, color: brandFgFaint),
          ),
        ],
      ),
    );
  }

  String _scaleLabel(YScale scale) => switch (scale) {
        YScale.linear => 'lin',
        YScale.log => 'log',
        YScale.sqrtSigned => '√',
        YScale.squareSigned => 'x²',
      };
}

// ---------------------------------------------------------------------------
// Extension helper
// ---------------------------------------------------------------------------

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
  T? firstWhereOrNull(bool Function(T) test) {
    for (final element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}
