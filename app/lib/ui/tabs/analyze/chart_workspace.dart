import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/fft_options.dart';
import '../../../data/session_model.dart';
import '../../../data/worksheet_block.dart';
import '../../../data/y_scale.dart';
import '../../../providers/channel_provider.dart';
import '../../../providers/lap_provider.dart';
import '../../../providers/math_channel_provider.dart';
import '../../../providers/selection_provider.dart';
import '../../../providers/session_provider.dart' show sessionProvider;
import '../../../providers/session_workspace_provider.dart';
import 'fft_window_resolver.dart';
import '../../../providers/workbook_view_context_provider.dart';
import '../../../providers/workspace_provider.dart';
import '../../../src/rust/fft.dart' show FftWindow, Detrend, Averaging, Scaling;
import '../../../ui/shell/adaptive_shell.dart';
import '../../brand/brand.dart';
import '../../widgets/color_grid_picker.dart';
import '../../widgets/grouped_channel_list.dart';
import 'chart_type_catalog.dart';
import 'fft_chart.dart';
import 'gps_map_chart.dart';
import 'histogram_chart.dart';
import 'lap_progression_chart.dart';
import 'lap_table.dart';
import 'per_lap_table.dart';
import 'scatter_chart.dart' show ScatterChart;
import 'session_label.dart';
import 'spectrogram_chart.dart';
import 'table_widget.dart';
import 'time_series_chart.dart';

/// Base chart height in logical pixels. [ChartSlot.heightFactor] multiplies
/// this value.
const double _baseChartHeight = 300.0;

/// Auto-binds the primary session when exactly one session is loaded and
/// nothing is bound yet. Also clears stale bindings when sessions are
/// unloaded from the selection.
///
/// Extracted from [ChartWorkspace]'s `ref.listen` callback so the logic can
/// be unit-tested without a mounted widget.
///
/// [loadedIds] is the current value of [effectiveSessionIdsProvider].
void reconcileViewContext(WidgetRef ref, Set<String> loadedIds) {
  // Auto-bind: single session loaded and primary slot is empty.
  if (loadedIds.length == 1 &&
      ref.read(workbookViewContextProvider).primarySessionId == null) {
    ref.read(workbookViewContextProvider.notifier).setPrimary(loadedIds.first);
  }
  // Clear stale primary if the bound session was unloaded.
  final currentPrimary = ref.read(workbookViewContextProvider).primarySessionId;
  if (currentPrimary != null && !loadedIds.contains(currentPrimary)) {
    ref.read(workbookViewContextProvider.notifier).clearPrimary();
  }
  // Clear stale overlay if the bound session was unloaded.
  final currentOverlay = ref.read(workbookViewContextProvider).overlaySessionId;
  if (currentOverlay != null && !loadedIds.contains(currentOverlay)) {
    ref.read(workbookViewContextProvider.notifier).clearOverlay();
  }
}

/// Scrollable container holding all chart components for one worksheet.
///
/// Reads the active worksheet's [ChartSlot] list from [workspaceProvider] and
/// renders one chart widget per slot — [TimeSeriesChart], [FftChart], or
/// [GpsMapChart] — based on [ChartSlot.chartType]. Each chart self-sources its
/// bounded views from the retained session handle by channel id (the slot is
/// given only channel *metadata* from [sessionChannelMetaProvider]); a
/// [LinearProgressIndicator] is shown while any session's metadata is loading.
///
/// Math channels in each slot are evaluated via [mathChannelEvalProvider] and
/// combined with raw channel data. Evaluation errors are shown as overlays on
/// the affected chart without blocking raw channels from rendering.
///
/// Below the charts, [LapTable] is rendered automatically when any selected
/// session has laps.
///
/// The "Add Chart" button opens [_AddChartDialog] to let the user choose a
/// chart type before the slot is created.
///
/// Keyed with [ValueKey(worksheet.id)] in [AnalyzeTab] so that switching
/// worksheets disposes and rebuilds this widget, resetting scroll position.
///
/// See §15.5.
class ChartWorkspace extends ConsumerWidget {
  /// Creates a [ChartWorkspace].
  const ChartWorkspace({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspace = ref.watch(workspaceProvider);
    final worksheet = workspace.activeWorksheet;
    final xAxisMode = worksheet.xAxisMode;
    final selectedIds = ref.watch(effectiveSessionIdsProvider);

    // Auto-bind the primary session when exactly one session is loaded and
    // nothing is bound yet. Also cleans up stale bindings when sessions are
    // unloaded. Extracted to a top-level helper so it can be unit-tested
    // without widget plumbing.
    ref.listen<Set<String>>(effectiveSessionIdsProvider, (prev, next) {
      reconcileViewContext(ref, next);
    });

    if (selectedIds.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No sessions selected — pick runs or laps in the Data tab to load data.',
            textAlign: TextAlign.center,
            style: plexSans(fontSize: 13, color: brandFgDim),
          ),
        ),
      );
    }

    final viewContext = ref.watch(workbookViewContextProvider);

    // Resolve which sessions to render. Prefer the view-context binding; fall
    // back to the first loaded session when nothing is bound yet (e.g. the
    // auto-bind listener hasn't fired on the very first frame, or 2+ sessions
    // are loaded and the user hasn't picked one yet). The fallback keeps the
    // pre-Phase-2 behaviour intact for the multi-session case until Task 11's
    // binding chips ship.
    final primary = viewContext.primarySessionId ??
        (selectedIds.isNotEmpty ? selectedIds.first : null);
    final overlay = viewContext.overlaySessionId;

    // The rendered id set passed downstream — primary + overlay (deduped).
    final renderedIds = {
      if (primary != null) primary,
      if (overlay != null) overlay,
    };

    // Charts self-source their bounded views from the retained handle; the only
    // shared "still parsing" signal left is whether each rendered session's
    // channel metadata has resolved (§15.3).
    final isAnyLoading = renderedIds
        .any((id) => ref.watch(sessionChannelMetaProvider(id)).isLoading);

    // Active zoom range for this worksheet — null = full view.
    final xRange = workspace.worksheetRanges[worksheet.id];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isAnyLoading)
          const LinearProgressIndicator(
            minHeight: 2,
            color: brandInfo,
            backgroundColor: brandSurface2,
          ),
        // Zoom reset banner — visible whenever a custom range is active.
        if (xRange != null) _ZoomResetBanner(worksheetId: worksheet.id),
        Expanded(
          child: Column(
            children: [
              Expanded(
                child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: worksheet.charts.length,
                  onReorder: (oldIndex, newIndex) => ref
                      .read(workspaceProvider.notifier)
                      .moveChart(oldIndex, newIndex),
                  proxyDecorator: (child, index, animation) => AnimatedBuilder(
                    animation: animation,
                    builder: (_, __) {
                      final t = Curves.easeInOut.transform(animation.value);
                      return Material(
                        elevation: 8 * t,
                        color: Colors.transparent,
                        shadowColor: Colors.black54,
                        child: Transform.scale(
                          scale: 1 - 0.02 * t,
                          child: child,
                        ),
                      );
                    },
                  ),
                  // Table blocks render after the charts (charts-before-tables
                  // invariant), stacked in the scroll flow and not reorderable
                  // in v1. The bound primary session drives their evaluation.
                  footer: worksheet.tableBlocks.isEmpty
                      ? null
                      : Column(
                          key: const ValueKey('worksheet-tables'),
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final b in worksheet.tableBlocks)
                              TableWidget(
                                key: ValueKey(b.id),
                                blockId: b.id,
                                table: (b.content as TableContent).table,
                                sessionId: primary ?? '',
                              ),
                          ],
                        ),
                  itemBuilder: (context, i) {
                    final slot = worksheet.charts[i];
                    return KeyedSubtree(
                      key: ValueKey(slot.slotId),
                      child: _isSlotVisible(slot, renderedIds)
                          ? _ChartSlotView(
                              slotIndex: i,
                              slot: slot,
                              worksheetId: worksheet.id,
                              worksheetKind: worksheet.kind,
                              xAxisMode: xAxisMode,
                              selectedIds: renderedIds,
                            )
                          : const SizedBox.shrink(),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: QuietButton(
                        label: 'Add chart',
                        icon: Icons.add,
                        onPressed: () => _showAddChartDialog(context, ref),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: QuietButton(
                        label: 'Add table',
                        icon: Icons.table_rows_outlined,
                        onPressed: () => _addTable(ref, primary),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Returns `true` when [slot] should render given the active session set.
  /// Every remaining chart type renders unconditionally — the ghost-only
  /// gating was removed when `ChartType.ghostDelta` was deleted.
  bool _isSlotVisible(ChartSlot slot, Set<String> selectedIds) => true;

  /// Builds a per-lap summary table for the bound [sessionId] and appends it as
  /// a table block. Default metric columns are the first two real (non-GPS,
  /// non-synthesized, fixed-rate) channels; the user can retemplate columns and
  /// edit cells afterward. No-op when no session is bound.
  void _addTable(WidgetRef ref, String? sessionId) {
    if (sessionId == null) return;
    final lapCount =
        ref.read(sessionLapsProvider(sessionId)).valueOrNull?.length ?? 0;
    final metas =
        ref.read(sessionChannelMetaProvider(sessionId)).valueOrNull ?? [];
    final metricChannels = <String>[
      for (final m in metas)
        if (!m.synthesized && !m.isEventDriven) m.channelId,
    ].take(2).toList();
    final table = buildPerLapTable(
      sessionId: sessionId,
      lapCount: lapCount,
      metricChannels: metricChannels,
    );
    ref.read(workspaceProvider.notifier).addBlock(WorksheetBlock.table(table));
  }

  Future<void> _showAddChartDialog(BuildContext context, WidgetRef ref) async {
    // Desktop (wide) merges type-pick and properties into one panel: create a
    // default chart up front and open the editor, whose left rail is the type
    // picker. Cancelling/dismissing discards the freshly-created chart.
    if (MediaQuery.sizeOf(context).width > 700) {
      ref.read(workspaceProvider.notifier).addChart();
      if (!context.mounted) return;
      final workspace = ref.read(workspaceProvider);
      final newIndex = workspace.activeWorksheet.charts.length - 1;
      final newSlot = workspace.activeWorksheet.charts[newIndex];
      final selectedIds = ref.read(effectiveSessionIdsProvider);
      final committed = await showDialog<bool>(
        context: context,
        builder: (_) => ChartPropertiesDialog(
          chartIndex: newIndex,
          slot: newSlot,
          selectedIds: selectedIds,
          isNew: true,
        ),
      );
      // Discard the placeholder chart unless the user pressed Add.
      if (committed != true) {
        ref.read(workspaceProvider.notifier).removeChart(newIndex);
      }
      return;
    }

    // Mobile: keep the two-step pick-then-configure flow.
    final type = await showDialog<ChartType>(
      context: context,
      builder: (_) => const _AddChartDialog(),
    );
    if (type == null) return;
    ref.read(workspaceProvider.notifier).addChart(type);

    // Channel-bearing chart types open the properties dialog immediately so
    // the user can assign channels without a second click. Types that do not
    // take user-assigned channels (gpsMap auto-resolves; lapProgression has
    // none) render straight away.
    if (type != ChartType.timeSeries &&
        type != ChartType.fft &&
        type != ChartType.spectrogram) {
      return;
    }
    if (!context.mounted) return;

    final workspace = ref.read(workspaceProvider);
    final newIndex = workspace.activeWorksheet.charts.length - 1;
    final newSlot = workspace.activeWorksheet.charts[newIndex];
    final selectedIds = ref.read(effectiveSessionIdsProvider);

    await showDialog<void>(
      context: context,
      builder: (_) => ChartPropertiesDialog(
        chartIndex: newIndex,
        slot: newSlot,
        selectedIds: selectedIds,
      ),
    );
  }
}

/// Thin banner shown when the worksheet has an active zoom range.
class _ZoomResetBanner extends ConsumerWidget {
  const _ZoomResetBanner({required this.worksheetId});

  final String worksheetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: brandSurface2,
        border: Border(
          bottom: BorderSide(color: brandRule, width: brandHairlineWidth),
        ),
      ),
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          child: Row(
            children: [
              const Icon(Icons.zoom_in, size: 14, color: brandInfo),
              const SizedBox(width: 6),
              Text(
                'ZOOM ACTIVE',
                style: plexMono(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: brandFgDim,
                  letterSpacing: brandLabelTracking,
                ),
              ),
              const Spacer(),
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  foregroundColor: brandInfo,
                ),
                onPressed: () => ref
                    .read(workspaceProvider.notifier)
                    .resetXAxisRange(worksheetId),
                child: Text(
                  'RESET ZOOM',
                  style: plexMono(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: brandLabelTracking,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _ChartSlotView
// ---------------------------------------------------------------------------

/// Renders a single chart slot with header, chart body, and drag-resize
/// handle. Per-chart cursor readout (when applicable) lives inside the
/// chart widget itself — e.g. [TimeSeriesChart]'s fl_chart tooltip pinned
/// to cursor A.
///
/// Uses [ConsumerStatefulWidget] to track the in-progress drag height without
/// committing to the provider on every frame.
class _ChartSlotView extends ConsumerStatefulWidget {
  const _ChartSlotView({
    required this.slotIndex,
    required this.slot,
    required this.worksheetId,
    required this.worksheetKind,
    required this.xAxisMode,
    required this.selectedIds,
  });

  final int slotIndex;
  final ChartSlot slot;
  final String worksheetId;

  /// Drives the pinned-slot rendering (header label + delete-button hide)
  /// for [WorksheetKind.sessionSheet] worksheets.
  final WorksheetKind worksheetKind;
  final XAxisMode xAxisMode;
  final Set<String> selectedIds;

  @override
  ConsumerState<_ChartSlotView> createState() => _ChartSlotViewState();
}

class _ChartSlotViewState extends ConsumerState<_ChartSlotView> {
  /// Overrides the persisted height during an active drag. Null when idle.
  double? _dragHeight;

  void _onDragStart(DragStartDetails _) {
    setState(() {
      _dragHeight = _baseChartHeight * widget.slot.heightFactor;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragHeight = (_dragHeight! + details.delta.dy).clamp(
        _baseChartHeight * 0.5,
        _baseChartHeight * 3.0,
      );
    });
  }

  void _onDragEnd(DragEndDetails _) {
    final newFactor = (_dragHeight! / _baseChartHeight).clamp(0.5, 3.0);
    ref.read(workspaceProvider.notifier).updateChartProperties(
          widget.slotIndex,
          widget.slot.copyWith(heightFactor: newFactor),
        );
    setState(() => _dragHeight = null);
  }

  @override
  Widget build(BuildContext context) {
    final rawChannels = _rawChannelsForSlot(widget.slot, widget.selectedIds);

    // The GPS map is a spatial overlay of *all* selected sessions, not the
    // Main/Overlay lap-comparison pair the other charts follow. Source it from
    // the full effective selection rather than the bound primary/overlay set.
    // Non-GPS charts keep the bound set unchanged.
    final gpsSessionIds = widget.slot.chartType == ChartType.gpsMap
        ? ref.watch(effectiveSessionIdsProvider)
        : widget.selectedIds;

    // Evaluate math channels and collect results/errors.
    final mathState = ref.watch(mathChannelProvider);
    final mathChannels = <SessionChannelData>[];
    final mathErrors = <String>[];
    var anyMathLoading = false;

    for (final mathId in widget.slot.mathChannelIds) {
      final idx = mathState.channels.indexWhere((mc) => mc.id == mathId);
      if (idx < 0) continue; // math channel was deleted
      final mathChannel = mathState.channels[idx];
      for (final sessionId in widget.selectedIds) {
        final eval = ref.watch(
          mathChannelEvalProvider((channelId: mathId, sessionId: sessionId)),
        );
        eval.when(
          // The evaluator wrote the result into the handle's math store under
          // `mathChannel.name` (see mathChannelEvalProvider), so the chart
          // self-sources its tiles / bounds / spectrum by that id — this entry
          // carries only metadata. `length` is the eval sample count; math
          // channels are fixed-rate (no per-sample times).
          data: (result) {
            mathChannels.add(
              SessionChannelData(
                sessionId: sessionId,
                channelId: mathChannel.name,
                sampleRateHz: result.sampleRateHz,
                length: result.length,
                isEventDriven: false,
              ),
            );
          },
          loading: () => anyMathLoading = true,
          error: (e, _) => mathErrors.add('${mathChannel.name}: $e'),
        );
      }
    }

    final allChannels = [...rawChannels, ...mathChannels];

    // Lap-pair scope: when ChartScope.auto, the rendered session has
    // both M and O designated, and the slot is a time-series chart, swap
    // the channel list for sliced main+overlay traces on a lap-relative
    // x-axis. Anything else falls back to the session-wide trace set.
    final lapPairChannels = _resolveLapPairChannels(allChannels);
    final renderedChannels = lapPairChannels ?? allChannels;

    Widget chart;
    switch (widget.slot.chartType) {
      case ChartType.fft:
        // Resolve which time windows the FFT chart should compute, from the
        // worksheet's current zoom + lap selection. One SpectrumRequest is
        // issued per (channel × window): session-mode = one per channel over
        // the zoom span (or whole session when unzoomed); lap-mode = one per
        // (channel × selected lap). See fft_window_resolver.dart.
        final fftSelection = ref.watch(selectionProvider);
        final fftLapMode = fftSelection.mode == SelectionMode.lap;
        final fftXRange =
            ref.watch(workspaceProvider).worksheetRanges[widget.worksheetId];
        final fftZoom = fftXRange == null
            ? null
            : (startSecs: fftXRange.startSecs, endSecs: fftXRange.endSecs);

        // Build lapsBySession from sessionLapsProvider for each rendered session.
        final fftLapsBySession = <String,
            List<({int lapNumber, double startSecs, double endSecs})>>{};
        for (final sessionId in widget.selectedIds) {
          final laps =
              ref.watch(sessionLapsProvider(sessionId)).valueOrNull ?? [];
          fftLapsBySession[sessionId] = [
            for (final l in laps)
              (
                lapNumber: l.lapNumber,
                startSecs: l.startTimeSecs,
                endSecs: l.endTimeSecs,
              ),
          ];
        }

        // selectedLaps from effectiveLapKeysProvider.
        final fftSelectedLaps = {
          for (final k in ref.watch(effectiveLapKeysProvider))
            (sessionId: k.sessionId, lapNumber: k.lapNumber),
        };

        // Build channel pairs from rendered channels (metadata only).
        final fftChannels = [
          for (final c in allChannels)
            if (c.sampleRateHz > 0 && c.length > 0)
              (sessionId: c.sessionId, channelId: c.channelId),
        ];

        // sessionDurationSecs: look up durationMs from the session catalog.
        final fftSessions = ref.watch(sessionProvider).sessions;
        double fftSessionDuration(String sessionId) {
          final meta =
              fftSessions.where((s) => s.sessionId == sessionId).firstOrNull;
          return (meta?.durationMs ?? 0) / 1000.0;
        }

        final fftResolved = resolveFftWindows(
          channels: fftChannels,
          lapMode: fftLapMode,
          lapsBySession: fftLapsBySession,
          selectedLaps: fftSelectedLaps,
          zoom: fftZoom,
          sessionDurationSecs: fftSessionDuration,
        );

        // Build renderableMetaById so FftChart can look up sampleRateHz by
        // channelId for each request (last writer wins when multiple sessions
        // share the same channel name — rate is the same in practice).
        final fftMetaById = <String, SessionChannelData>{
          for (final c in allChannels)
            if (c.sampleRateHz > 0 && c.length > 0) c.channelId: c,
        };

        chart = FftChart(
          requests: fftResolved.requests,
          truncated: fftResolved.truncated,
          renderableMetaById: fftMetaById,
          worksheetId: widget.worksheetId,
          slotIndex: widget.slotIndex,
          yMin: widget.slot.yScaleMode == YScaleMode.manual
              ? widget.slot.yMin
              : null,
          yMax: widget.slot.yScaleMode == YScaleMode.manual
              ? widget.slot.yMax
              : null,
          channelColors: widget.slot.channelColors,
        );
      case ChartType.histogram:
        chart = HistogramChart(
          channels: renderedChannels,
          worksheetId: widget.worksheetId,
          slotIndex: widget.slotIndex,
          channelColors: widget.slot.channelColors,
        );
      case ChartType.gpsMap:
        chart = GpsMapChart(
          selectedIds: gpsSessionIds,
          channelColors: widget.slot.channelColors,
          worksheetId: widget.worksheetId,
          colorChannelId: widget.slot.gpsColorChannelId,
          colorMin: widget.slot.gpsColorMin,
          colorMax: widget.slot.gpsColorMax,
        );
      case ChartType.timeSeries:
        chart = TimeSeriesChart(
          channels: renderedChannels,
          xAxisMode: widget.xAxisMode,
          worksheetId: widget.worksheetId,
          slotIndex: widget.slotIndex,
          yMin: widget.slot.yScaleMode == YScaleMode.manual
              ? widget.slot.yMin
              : null,
          yMax: widget.slot.yScaleMode == YScaleMode.manual
              ? widget.slot.yMax
              : null,
          channelColors: widget.slot.channelColors,
          showZeroLine: widget.slot.showZeroLine,
          yScale: widget.slot.yScale,
        );
      case ChartType.lapTable:
        chart = const LapTable();
      case ChartType.lapProgression:
        chart = LapProgressionChart(
          slotIndex: widget.slotIndex,
          yScale: widget.slot.yScale,
        );
      case ChartType.spectrogram:
        chart = SpectrogramChart(
          channels: renderedChannels,
          worksheetId: widget.worksheetId,
          slotIndex: widget.slotIndex,
          channelColors: widget.slot.channelColors,
        );
      case ChartType.varianceTrace:
        // TODO(idl0): replace with VarianceTraceChart (N-lap variance design
        // §8 — Task 5.3, widget + hot-reload). Placeholder keeps the build
        // green now that the chart type and slot fields exist.
        chart = const Center(
          child: Text('Lap Variance — chart widget pending (Task 5.3)'),
        );
      case ChartType.scatter:
        chart = ScatterChart(
          sessionId:
              widget.selectedIds.isNotEmpty ? widget.selectedIds.first : '',
          scope: widget.slot.scope,
          xChannel: widget.slot.scatterXChannelId,
          yChannel: widget.slot.scatterYChannelId,
          mode: widget.slot.scatterMode,
          colorChannel: widget.slot.scatterColorChannelId,
          colorMin: widget.slot.scatterColorMin,
          colorMax: widget.slot.scatterColorMax,
          equalAspect: widget.slot.scatterEqualAspect,
          referenceCircles: widget.slot.scatterReferenceCircles,
          binCount: widget.slot.scatterBinCount,
        );
    }

    final isGps = widget.slot.chartType == ChartType.gpsMap;
    final isLapTable = widget.slot.chartType == ChartType.lapTable;
    final isLapProgression = widget.slot.chartType == ChartType.lapProgression;
    // Pinned slot = lapTable / lapProgression slot at the top of a Session
    // Sheet. Cannot be removed; renders a "PINNED" badge instead of the
    // editable title overlay.
    final isPinned = widget.worksheetKind == WorksheetKind.sessionSheet &&
        widget.slotIndex < kSessionSheetPinnedSlotCount;
    final hasPropertiesDialog = !isPinned && !isLapTable && !isLapProgression;

    // RepaintBoundary isolates the chart's render layer so panning one
    // chart in the worksheet doesn't repaint the others. Significant pan
    // FPS win for worksheets with 3+ charts stacked.
    final Widget chartArea = RepaintBoundary(
      child: Stack(
        children: [
          chart,
          if (mathErrors.isNotEmpty)
            Positioned(
              top: 4,
              left: 4,
              right: 4,
              child: _MathErrorOverlay(errors: mathErrors),
            ),
          if (!isPinned &&
              !isLapTable &&
              (widget.slot.title?.isNotEmpty ?? false))
            Positioned(
              top: 2,
              left: 0,
              right: 0,
              child: Center(
                child: _ChartTitleOverlay(
                  slot: widget.slot,
                  slotIndex: widget.slotIndex,
                ),
              ),
            ),
          if (isPinned)
            const Positioned(
              top: 2,
              left: 8,
              child: _PinnedBadge(),
            ),
          if (hasPropertiesDialog ||
              _canReorder(widget.worksheetKind, widget.slotIndex))
            Positioned(
              top: 0,
              right: 0,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_canReorder(widget.worksheetKind, widget.slotIndex))
                    _DragHandleOverlay(slotIndex: widget.slotIndex),
                  if (hasPropertiesDialog)
                    _PropertiesCogOverlay(
                      slot: widget.slot,
                      slotIndex: widget.slotIndex,
                      selectedIds: gpsSessionIds,
                    ),
                ],
              ),
            ),
        ],
      ),
    );

    final chartHeight =
        _dragHeight ?? _baseChartHeight * widget.slot.heightFactor;

    return Column(
      children: [
        if (anyMathLoading)
          const LinearProgressIndicator(
            minHeight: 2,
            color: brandInfo,
            backgroundColor: brandSurface2,
          ),
        // Lap table sizes to its content — its inner DataTable can grow tall
        // for many-lap sessions and clamping it to chartHeight just overflows.
        // All other chart types are scaled, so they need the explicit height.
        if (isLapTable)
          chartArea
        else
          SizedBox(height: chartHeight, child: chartArea),
        // Drag-resize handle — 6 px strip flush with the axis row below the
        // chart. Lap table / lap progression have intrinsic sizing semantics
        // so the handle isn't useful there either.
        if (!isGps && !isLapTable && !isLapProgression)
          GestureDetector(
            onVerticalDragStart: _onDragStart,
            onVerticalDragUpdate: _onDragUpdate,
            onVerticalDragEnd: _onDragEnd,
            child: const MouseRegion(
              cursor: SystemMouseCursors.resizeUpDown,
              child: SizedBox(
                height: 6,
                child: Center(
                  child: ColoredBox(
                    color: brandRule,
                    child: SizedBox(width: 32, height: 2),
                  ),
                ),
              ),
            ),
          ),
        // "Add Channel" shortcut — only for chart types that take channels
        // and only when none are assigned yet.
        if (!isGps &&
            !isLapTable &&
            !isLapProgression &&
            widget.slot.channelIds.isEmpty &&
            widget.slot.mathChannelIds.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: QuietButton(
              label: 'Add channel',
              icon: Icons.show_chart,
              onPressed: () => _showChannelPicker(context, ref),
            ),
          ),
      ],
    );
  }

  /// Collects [SessionChannelData] *metadata* for the raw channels assigned to
  /// [slot] across all [selectedIds], from [sessionChannelMetaProvider] (no
  /// samples — each chart self-sources its bounded view by id from the handle).
  /// Sessions still loading or in error are skipped.
  List<SessionChannelData> _rawChannelsForSlot(
    ChartSlot slot,
    Set<String> selectedIds,
  ) {
    if (slot.channelIds.isEmpty) return const [];
    final result = <SessionChannelData>[];
    for (final sessionId in selectedIds) {
      final metas =
          ref.watch(sessionChannelMetaProvider(sessionId)).valueOrNull;
      if (metas == null) continue;
      for (final m in metas) {
        if (slot.channelIds.contains(m.channelId)) {
          result.add(
            SessionChannelData(
              sessionId: sessionId,
              channelId: m.channelId,
              sampleRateHz: m.sampleRateHz,
              length: m.length,
              isEventDriven: m.isEventDriven,
            ),
          );
        }
      }
    }
    return result;
  }

  void _showChannelPicker(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (_) => _ChannelPickerDialog(
        chartIndex: widget.slotIndex,
        initialChannelIds: List<String>.from(widget.slot.channelIds),
        initialMathChannelIds: List<String>.from(widget.slot.mathChannelIds),
      ),
    );
  }

  /// Produces a lap-windowed channel list when this slot should render in
  /// lap-focused mode; returns `null` to fall through to the session-wide
  /// trace set built upstream.
  ///
  /// "Main lap" comes from one of two sources, in priority order:
  /// the Analyze tab's lap-table M checkbox (`setMainLap`), or — if no
  /// explicit M is set — the Data tab's lap-mode selection when exactly
  /// one lap from this session is selected.
  ///
  /// Three modes, in order of preference:
  ///
  /// 1. **Main+overlay** — both effective main lap and `overlayLapKey`
  ///    set: emits two traces per input channel, sliced to the main lap
  ///    (from this session) and the overlay lap (from the overlay session)
  ///    with `" (main)"` / `" (overlay)"` suffixes so the legend
  ///    disambiguates.
  /// 2. **Main only** — main lap resolved but no overlay: every input
  ///    channel is sliced to the main lap window with no suffix. The chart
  ///    shows only the selected lap, not the whole session.
  /// 3. **No lap resolved** — neither source nor overlay available:
  ///    returns `null`, caller falls through to session-wide rendering.
  ///
  /// Eligibility (all must hold for any of the three modes):
  ///   - `slot.scope == ChartScope.auto` (`session` is the explicit opt-out)
  ///   - `slot.chartType == ChartType.timeSeries`
  ///   - Exactly one selected session — multi-session selections leave
  ///     lap designation ambiguous, so the chart stays session-wide
  ///
  /// Sample indices in each slice start at 0, so the x-axis is naturally
  /// lap-relative (i / rate seconds).
  List<SessionChannelData>? _resolveLapPairChannels(
    List<SessionChannelData> allChannels,
  ) {
    if (widget.slot.scope == ChartScope.session) return null;
    if (widget.slot.chartType != ChartType.timeSeries) return null;
    if (widget.selectedIds.length != 1) return null;

    final sessionId = widget.selectedIds.first;
    final wsAsync = ref.watch(sessionWorkspaceProvider(sessionId));
    final ws = wsAsync.valueOrNull;
    if (ws == null) return null;
    final overlayKey = ws.overlayLapKey;
    // Effective main lap: prefer the Analyze tab's explicit `setMainLap`
    // designation (M checkbox in the lap table). If none is set, fall
    // back to the Data tab's selection — when the user has selected
    // exactly one lap for this session in lap-mode, that lap drives the
    // chart window. Without either, fall through to session-wide.
    int? mainLapNum = ws.mainLapNumber;
    if (mainLapNum == null) {
      final selection = ref.watch(selectionProvider);
      if (selection.mode == SelectionMode.lap) {
        final lapsForThisSession =
            selection.lapKeys.where((k) => k.sessionId == sessionId).toList();
        if (lapsForThisSession.length == 1) {
          mainLapNum = lapsForThisSession.first.lapNumber;
        }
      }
    }
    if (mainLapNum == null) return null;

    final mainLaps = ref.watch(sessionLapsProvider(sessionId)).valueOrNull;
    if (mainLaps == null) return null;
    final mainLap =
        mainLaps.where((l) => l.lapNumber == mainLapNum).firstOrNull;
    if (mainLap == null) return null;

    final mainSessionStart =
        ref.watch(sessionStartMsProvider(sessionId)).valueOrNull ??
            mainLap.startTimestampMs.toDouble();
    final mainStartSec = (mainLap.startTimestampMs - mainSessionStart) / 1000.0;
    final mainEndSec = (mainLap.endTimestampMs - mainSessionStart) / 1000.0;

    // A math channel's recompute generation keys its lap slice, so editing the
    // expression re-cuts the lap-relative trace (the session-wide path already
    // invalidates by name). Base channels are absent from the map → generation 0
    // (they never change).
    final gens = ref.watch(mathChannelProvider).generations;

    // Mode 2: main only — slice every channel to the main lap.
    if (overlayKey == null) {
      final out = <SessionChannelData>[];
      for (final entry in allChannels) {
        final sliced = _lapSlice(
          entry,
          mainStartSec,
          mainEndSec,
          overlay: false,
          lap: mainLapNum,
          sourceGeneration: gens[entry.channelId] ?? 0,
        );
        if (sliced != null) out.add(sliced);
      }
      // Still slicing → fall through to the session-wide trace set rather than
      // flashing an empty chart; the lap view appears once the first slice lands.
      return out.isEmpty ? null : out;
    }

    // Mode 1: main+overlay — both traces with suffixes.
    final overlayLaps =
        ref.watch(sessionLapsProvider(overlayKey.sessionId)).valueOrNull;
    if (overlayLaps == null) return null;
    final overlayLap = overlayLaps
        .where((l) => l.lapNumber == overlayKey.lapNumber)
        .firstOrNull;
    if (overlayLap == null) return null;

    final overlaySessionStart =
        ref.watch(sessionStartMsProvider(overlayKey.sessionId)).valueOrNull ??
            overlayLap.startTimestampMs.toDouble();
    final overlayStartSec =
        (overlayLap.startTimestampMs - overlaySessionStart) / 1000.0;
    final overlayEndSec =
        (overlayLap.endTimestampMs - overlaySessionStart) / 1000.0;

    // The overlay trace comes from the overlay session's own channels; map each
    // raw channel id to its rate there. (Math channels live only in the rendered
    // session's handle, so they have no overlay counterpart — same as before.)
    final overlayMetas =
        ref.watch(sessionChannelMetaProvider(overlayKey.sessionId)).valueOrNull;
    final overlayRates = <String, double>{};
    if (overlayMetas != null) {
      for (final m in overlayMetas) {
        overlayRates[m.channelId] = m.sampleRateHz;
      }
    }

    final out = <SessionChannelData>[];
    for (final entry in allChannels) {
      final mainSliced = _lapSlice(
        entry,
        mainStartSec,
        mainEndSec,
        overlay: false,
        lap: mainLapNum,
        sourceGeneration: gens[entry.channelId] ?? 0,
      );
      if (mainSliced != null) out.add(mainSliced);
      final overlayRate = overlayRates[entry.channelId];
      if (overlayRate != null) {
        final overlaySliced = _lapSlice(
          SessionChannelData(
            sessionId: overlayKey.sessionId,
            channelId: entry.channelId,
            sampleRateHz: overlayRate,
            length: 0,
            isEventDriven: false,
          ),
          overlayStartSec,
          overlayEndSec,
          // Overlay traces are base channels of the overlay session (math
          // channels have no overlay counterpart), so generation 0.
          overlay: true,
          lap: overlayKey.lapNumber,
          sourceGeneration: 0,
        );
        if (overlaySliced != null) out.add(overlaySliced);
      }
    }
    return out.isEmpty ? null : out;
  }

  /// Materializes a lap-windowed, rebased slice of [source] into its session's
  /// handle store (via [lapSlicedChannelProvider]) under the engine's lap-slice
  /// token and returns the metadata the chart decimates by. `null` while the
  /// slice is still in flight or the window covers no sample (event-driven
  /// channels have no nominal rate to slice by and yield nothing). The slice
  /// starts at sample 0, so the chart renders it on a lap-relative x-axis.
  /// [overlay]/[lap] pick the typed slice identity; [sourceGeneration] re-cuts
  /// the slice when an upstream math channel is edited (0 for base channels).
  SessionChannelData? _lapSlice(
    SessionChannelData source,
    double startSec,
    double endSec, {
    required bool overlay,
    required int lap,
    required int sourceGeneration,
  }) {
    if (source.sampleRateHz <= 0) return null;
    final r = ref
        .watch(
          lapSlicedChannelProvider(
            (
              sessionId: source.sessionId,
              channelId: source.channelId,
              sampleRateHz: source.sampleRateHz,
              startSec: startSec,
              endSec: endSec,
              overlay: overlay,
              lap: lap,
              sourceGeneration: sourceGeneration,
            ),
          ),
        )
        .valueOrNull;
    if (r == null) return null;
    return SessionChannelData(
      sessionId: source.sessionId,
      channelId: r.channelId,
      sampleRateHz: source.sampleRateHz,
      length: r.length,
      isEventDriven: false,
    );
  }
}

// ---------------------------------------------------------------------------
// In-canvas overlays — title (editable), properties cog, pinned badge
// ---------------------------------------------------------------------------

/// Confirmation dialog shared by the properties dialog and the context
/// menu's "Remove chart" action.
Future<bool> confirmRemoveChart(
  BuildContext context,
  WidgetRef ref,
  int slotIndex,
) async {
  // Capture the notifier before the await: callers (e.g. the properties
  // dialog's Remove button) may dispose their own widget while the confirm
  // dialog is open, leaving `ref` dead. The notifier lives in the
  // ProviderContainer and outlives the widget, so it stays safe to call.
  final notifier = ref.read(workspaceProvider.notifier);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        'Remove chart?',
        style: plexMono(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: brandFg,
        ),
      ),
      content: Text(
        'Remove this chart from the worksheet? '
        'Channel assignments and Y-axis settings are lost.',
        style: plexSans(fontSize: 13, color: brandFgDim),
      ),
      actions: [
        QuietButton(
          label: 'Cancel',
          onPressed: () => Navigator.of(dialogContext).pop(false),
        ),
        QuietButton(
          label: 'Remove',
          emphasis: ButtonEmphasis.alert,
          filled: true,
          onPressed: () => Navigator.of(dialogContext).pop(true),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    notifier.removeChart(slotIndex);
    return true;
  }
  return false;
}

/// Click-to-edit title overlay rendered at the top-left of the chart canvas.
///
/// Default state: low-opacity label. Tapping switches to an inline
/// [TextField]; Enter or focus loss persists the title to the slot via
/// [WorkspaceNotifier.updateChartProperties]. Empty text clears [title]
/// back to null so the default channel-name string returns.
class _ChartTitleOverlay extends ConsumerStatefulWidget {
  const _ChartTitleOverlay({required this.slot, required this.slotIndex});

  final ChartSlot slot;
  final int slotIndex;

  @override
  ConsumerState<_ChartTitleOverlay> createState() => _ChartTitleOverlayState();
}

class _ChartTitleOverlayState extends ConsumerState<_ChartTitleOverlay> {
  bool _editing = false;
  late final TextEditingController _ctrl;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.slot.title ?? '');
    _focusNode = FocusNode();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (!_focusNode.hasFocus && _editing) {
      _commit();
    }
  }

  void _commit() {
    final trimmed = _ctrl.text.trim();
    final newTitle = trimmed.isEmpty ? null : trimmed;
    if (newTitle != widget.slot.title) {
      ref.read(workspaceProvider.notifier).updateChartProperties(
            widget.slotIndex,
            widget.slot.copyWith(title: newTitle),
          );
    }
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final display = widget.slot.title ?? '';
    if (_editing) {
      return SizedBox(
        height: 24,
        child: TextField(
          controller: _ctrl,
          focusNode: _focusNode,
          autofocus: true,
          style: plexMono(fontSize: 11, color: brandFg),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: brandSurface2,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(brandControlRadiusSoft),
              borderSide: const BorderSide(
                color: brandRule,
                width: brandHairlineWidth,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(brandControlRadiusSoft),
              borderSide: const BorderSide(
                color: brandFgDim,
                width: brandHairlineWidth,
              ),
            ),
          ),
          onSubmitted: (_) => _commit(),
        ),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.text,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _ctrl.text = widget.slot.title ?? '';
          setState(() => _editing = true);
          _focusNode.requestFocus();
        },
        child: Opacity(
          opacity: 0.7,
          child: Text(
            display,
            style: plexMono(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: brandFg,
              letterSpacing: brandLabelTracking,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

/// Top-right cog that opens the chart properties dialog. Sits at low opacity
/// by default; gains full opacity on pointer hover. Tap target is full size
/// either way.
class _PropertiesCogOverlay extends ConsumerStatefulWidget {
  const _PropertiesCogOverlay({
    required this.slot,
    required this.slotIndex,
    required this.selectedIds,
  });

  final ChartSlot slot;
  final int slotIndex;
  final Set<String> selectedIds;

  @override
  ConsumerState<_PropertiesCogOverlay> createState() =>
      _PropertiesCogOverlayState();
}

class _PropertiesCogOverlayState extends ConsumerState<_PropertiesCogOverlay> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Opacity(
        opacity: _hover ? 1.0 : 0.45,
        child: IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          iconSize: 16,
          color: brandFg,
          icon: const Icon(Icons.tune),
          tooltip: 'Chart properties',
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => ChartPropertiesDialog(
              chartIndex: widget.slotIndex,
              slot: widget.slot,
              selectedIds: widget.selectedIds,
            ),
          ),
        ),
      ),
    );
  }
}

/// True when slot [slotIndex] on a worksheet of [kind] can be reordered.
/// Session Sheet pinned slots (`< [kSessionSheetPinnedSlotCount]`) are fixed.
bool _canReorder(WorksheetKind kind, int slotIndex) {
  if (kind != WorksheetKind.sessionSheet) return true;
  return slotIndex >= kSessionSheetPinnedSlotCount;
}

/// Drag handle paired with the cog at the top-right of each chart. Same
/// hover-fade affordance as the cog. Long-press / mouse-down starts a
/// reorder via [ReorderableDragStartListener]. Hidden entirely for pinned
/// Session Sheet slots.
class _DragHandleOverlay extends StatefulWidget {
  const _DragHandleOverlay({required this.slotIndex});

  final int slotIndex;

  @override
  State<_DragHandleOverlay> createState() => _DragHandleOverlayState();
}

class _DragHandleOverlayState extends State<_DragHandleOverlay> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.grab,
      child: Opacity(
        opacity: _hover ? 1.0 : 0.45,
        child: ReorderableDragStartListener(
          index: widget.slotIndex,
          child: const Padding(
            padding: EdgeInsets.all(6),
            child: Icon(Icons.drag_indicator, size: 16, color: brandFgDim),
          ),
        ),
      ),
    );
  }
}

/// Small "📌 PINNED" badge for slots the user cannot remove (Session
/// Sheet's pinned lap table and lap progression).
class _PinnedBadge extends StatelessWidget {
  const _PinnedBadge();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.push_pin, size: 12, color: brandFgDim),
        const SizedBox(width: 3),
        Text(
          'PINNED',
          style: plexMono(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: brandFgDim,
            letterSpacing: brandLabelTracking,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _MathErrorOverlay
// ---------------------------------------------------------------------------

/// Small overlay that lists math channel evaluation errors on the chart.
class _MathErrorOverlay extends StatelessWidget {
  const _MathErrorOverlay({required this.errors});

  final List<String> errors;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: brandBg.withValues(alpha: 0.9),
        border: Border.all(color: brandAccent, width: brandHairlineWidth),
        borderRadius: BorderRadius.circular(brandControlRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in errors)
              Text(
                e,
                style: plexMono(fontSize: 11, color: brandAccent),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _AddChartDialog
// ---------------------------------------------------------------------------

/// Dialog that lets the user choose a chart type before creating a new slot.
///
/// Returns the selected [ChartType] via [Navigator.pop] on confirm, or `null`
/// if the user cancels.
class _AddChartDialog extends StatefulWidget {
  const _AddChartDialog();

  @override
  State<_AddChartDialog> createState() => _AddChartDialogState();
}

class _AddChartDialogState extends State<_AddChartDialog> {
  ChartType _selected = ChartType.timeSeries;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        'Add Chart',
        style: plexMono(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: brandFg,
        ),
      ),
      content: RadioGroup<ChartType>(
        groupValue: _selected,
        onChanged: (v) => setState(() => _selected = v!),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final type in kAddableChartTypes)
              RadioListTile<ChartType>(
                // Type glyph on the leading edge; radio control trails so the
                // icon reads as the row's identity (matches the desktop rail).
                controlAffinity: ListTileControlAffinity.trailing,
                secondary: Icon(
                  chartTypeInfo(type).icon,
                  size: 22,
                  color: chartTypeInfo(type).accent,
                ),
                title: Text(
                  chartTypeInfo(type).label,
                  style: plexMono(fontSize: 13, color: brandFg),
                ),
                subtitle: Text(
                  chartTypeInfo(type).blurb,
                  style: plexSans(fontSize: 12, color: brandFgDim),
                ),
                value: type,
                fillColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? brandGood
                      : brandFgDim,
                ),
              ),
          ],
        ),
      ),
      actions: [
        QuietButton(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        QuietButton(
          label: 'Add',
          filled: true,
          onPressed: () => Navigator.of(context).pop(_selected),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _ChannelPickerDialog
// ---------------------------------------------------------------------------

/// Dialog that lists available channels (raw and math) as [CheckboxListTile]s
/// and applies additions/removals to `charts[chartIndex]` on confirm.
///
/// Raw channels are listed under "Channels"; math channels under
/// "Math Channels" (section omitted when no math channels exist). See §15.5.
class _ChannelPickerDialog extends ConsumerStatefulWidget {
  const _ChannelPickerDialog({
    required this.chartIndex,
    required this.initialChannelIds,
    required this.initialMathChannelIds,
  });

  /// Index of the [ChartSlot] to update in the active worksheet.
  final int chartIndex;

  /// Raw channel IDs already assigned to this slot; pre-ticked in the dialog.
  final List<String> initialChannelIds;

  /// Math channel IDs already assigned to this slot; pre-ticked in the dialog.
  final List<String> initialMathChannelIds;

  @override
  ConsumerState<_ChannelPickerDialog> createState() =>
      _ChannelPickerDialogState();
}

class _ChannelPickerDialogState extends ConsumerState<_ChannelPickerDialog> {
  late Set<String> _selectedRaw;
  late Set<String> _selectedMath;

  @override
  void initState() {
    super.initState();
    _selectedRaw = Set<String>.from(widget.initialChannelIds);
    _selectedMath = Set<String>.from(widget.initialMathChannelIds);
  }

  @override
  Widget build(BuildContext context) {
    final availableNames = ref.watch(availableChannelNamesProvider);
    final mathState = ref.watch(mathChannelProvider);
    final hasMathChannels = mathState.channels.isNotEmpty;

    final hasAnyChannels = availableNames.isNotEmpty || hasMathChannels;

    return AlertDialog(
      title: Text(
        'Add Channel',
        style: plexMono(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: brandFg,
        ),
      ),
      content: !hasAnyChannels
          ? Text(
              'No channels available',
              style: plexSans(fontSize: 13, color: brandFgDim),
            )
          : SizedBox(
              width: double.maxFinite,
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (availableNames.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        'CHANNELS',
                        style: plexMono(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: brandFgDim,
                          letterSpacing: brandKickerTracking,
                        ),
                      ),
                    ),
                    GroupedChannelList(
                      names: availableNames,
                      rowBuilder: (name) => CheckboxListTile(
                        title: Text(
                          name,
                          style: plexMono(fontSize: 13, color: brandFg),
                        ),
                        checkColor: brandBg,
                        side: const BorderSide(color: brandRule, width: 1.5),
                        fillColor: WidgetStateProperty.resolveWith(
                          (states) => states.contains(WidgetState.selected)
                              ? brandGood
                              : Colors.transparent,
                        ),
                        value: _selectedRaw.contains(name),
                        onChanged: (v) => setState(
                          () => v == true
                              ? _selectedRaw.add(name)
                              : _selectedRaw.remove(name),
                        ),
                      ),
                    ),
                  ],
                  if (hasMathChannels) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        'MATH CHANNELS',
                        style: plexMono(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: brandFgDim,
                          letterSpacing: brandKickerTracking,
                        ),
                      ),
                    ),
                    for (final mc in mathState.channels)
                      CheckboxListTile(
                        title: Text(
                          mc.name,
                          style: plexMono(fontSize: 13, color: brandFg),
                        ),
                        checkColor: brandBg,
                        side: const BorderSide(color: brandRule, width: 1.5),
                        fillColor: WidgetStateProperty.resolveWith(
                          (states) => states.contains(WidgetState.selected)
                              ? brandGood
                              : Colors.transparent,
                        ),
                        value: _selectedMath.contains(mc.id),
                        onChanged: (v) => setState(
                          () => v == true
                              ? _selectedMath.add(mc.id)
                              : _selectedMath.remove(mc.id),
                        ),
                      ),
                  ],
                ],
              ),
            ),
      actions: [
        QuietButton(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        QuietButton(
          label: 'OK',
          filled: true,
          onPressed: _confirm,
        ),
      ],
    );
  }

  void _confirm() {
    final notifier = ref.read(workspaceProvider.notifier);

    // Apply raw channel diff.
    final prevRaw = Set<String>.from(
      ref
          .read(workspaceProvider)
          .activeWorksheet
          .charts[widget.chartIndex]
          .channelIds,
    );
    for (final name in _selectedRaw.difference(prevRaw)) {
      notifier.addChannelToChart(widget.chartIndex, name);
    }
    for (final name in prevRaw.difference(_selectedRaw)) {
      notifier.removeChannelFromChart(widget.chartIndex, name);
    }

    // Apply math channel diff.
    final prevMath = Set<String>.from(
      ref
          .read(workspaceProvider)
          .activeWorksheet
          .charts[widget.chartIndex]
          .mathChannelIds,
    );
    for (final id in _selectedMath.difference(prevMath)) {
      notifier.addMathChannelToChart(widget.chartIndex, id);
    }
    for (final id in prevMath.difference(_selectedMath)) {
      notifier.removeMathChannelFromChart(widget.chartIndex, id);
    }

    Navigator.of(context).pop();
  }
}

// ---------------------------------------------------------------------------
// ChartPropertiesDialog
// ---------------------------------------------------------------------------

/// Modal dialog for configuring per-chart display properties.
///
/// **Channels section** — reorderable list (raw then math). Per-channel colour
/// swatch opens [_ColorPickerDialog]. Remove button on each row. Math channel
/// rows also have an edit button that navigates to the Maths tab.
/// A "+ Add Channel" button at the top opens [_ChannelPickerDialog] on top
/// of this dialog without closing it; channel list is read live from the
/// provider so newly added channels appear immediately.
///
/// **Y Axis section** — Auto / Manual toggle and optional Min/Max fields.
/// Hidden for [ChartType.gpsMap].
///
/// **Apply** writes all changes via [WorkspaceNotifier.updateChartProperties].
/// The Size slider is removed — drag the resize handle on the chart instead.
class ChartPropertiesDialog extends ConsumerStatefulWidget {
  /// Creates a [ChartPropertiesDialog].
  const ChartPropertiesDialog({
    super.key,
    required this.chartIndex,
    required this.slot,
    required this.selectedIds,
    this.isNew = false,
  });

  /// Index of the [ChartSlot] to configure in the active worksheet.
  final int chartIndex;

  /// Snapshot of the slot at dialog-open time; live updates come from the
  /// provider watch inside [_ChartPropertiesDialogState].
  final ChartSlot slot;

  /// Session IDs currently selected — used by the GPS map colour rows.
  final Set<String> selectedIds;

  /// True when the dialog is editing a chart that was just created by the
  /// desktop Add-Chart flow. Drives the create-style action row (Cancel /
  /// Add instead of Remove / Cancel / Apply) and the discard-on-cancel
  /// contract: the dialog pops `true` only when the user commits via Add.
  final bool isNew;

  @override
  ConsumerState<ChartPropertiesDialog> createState() =>
      _ChartPropertiesDialogState();
}

class _ChartPropertiesDialogState extends ConsumerState<ChartPropertiesDialog> {
  late YScaleMode _yScaleMode;
  late ChartScope _scope;
  late TextEditingController _yMinCtrl;
  late TextEditingController _yMaxCtrl;
  late TextEditingController _titleCtrl;
  late Map<String, int> _channelColors;
  late FftWindow _fftWindow;
  late FftXScale _fftXScale;
  int? _fftSegment;
  late TextEditingController _fftOverlapCtrl;
  late Detrend _fftDetrend;
  late Averaging _fftAveraging;
  late Scaling _fftScaling;
  late YScale _yScale;
  late bool _showZeroLine;
  late TextEditingController _histogramBinCtrl;
  late bool _histogramSymmetric;
  late bool _histogramSmooth;
  String? _gpsColorChannelId;
  late TextEditingController _gpsColorMinCtrl;
  late TextEditingController _gpsColorMaxCtrl;
  String? _scatterXChannelId;
  String? _scatterYChannelId;
  late ScatterMode _scatterMode;
  String? _scatterColorChannelId;
  late TextEditingController _scatterColorMinCtrl;
  late TextEditingController _scatterColorMaxCtrl;
  late bool _scatterEqualAspect;
  late bool _scatterReferenceCircles;
  late TextEditingController _scatterBinCtrl;

  @override
  void initState() {
    super.initState();
    _yScaleMode = widget.slot.yScaleMode;
    _scope = widget.slot.scope;
    _yMinCtrl = TextEditingController(
      text: widget.slot.yMin?.toString() ?? '',
    );
    _yMaxCtrl = TextEditingController(
      text: widget.slot.yMax?.toString() ?? '',
    );
    _titleCtrl = TextEditingController(text: widget.slot.title ?? '');
    _channelColors = Map<String, int>.from(widget.slot.channelColors);
    _fftWindow = widget.slot.spectral.window;
    _fftXScale = widget.slot.spectral.freqScale;
    // Segment length as a discrete choice; null = Auto (the render path resolves
    // it per zoom window via ChartSlot.autoFftSegmentLength).
    _fftSegment = widget.slot.spectral.segmentLength;
    _fftOverlapCtrl = TextEditingController(
      text: widget.slot.spectral.overlapPercent.toStringAsFixed(0),
    );
    _fftDetrend = widget.slot.spectral.detrend;
    _fftAveraging = widget.slot.fftAveraging;
    _fftScaling = widget.slot.spectral.scaling;
    _yScale = widget.slot.yScale;
    _showZeroLine = widget.slot.showZeroLine;
    _histogramBinCtrl = TextEditingController(
      text: widget.slot.histogramBinCount.toString(),
    );
    _histogramSymmetric = widget.slot.histogramSymmetric;
    _histogramSmooth = widget.slot.histogramSmooth;
    _gpsColorChannelId = widget.slot.gpsColorChannelId;
    _gpsColorMinCtrl =
        TextEditingController(text: widget.slot.gpsColorMin?.toString() ?? '');
    _gpsColorMaxCtrl =
        TextEditingController(text: widget.slot.gpsColorMax?.toString() ?? '');
    _scatterXChannelId = widget.slot.scatterXChannelId;
    _scatterYChannelId = widget.slot.scatterYChannelId;
    _scatterMode = widget.slot.scatterMode;
    _scatterColorChannelId = widget.slot.scatterColorChannelId;
    _scatterColorMinCtrl = TextEditingController(
      text: widget.slot.scatterColorMin?.toString() ?? '',
    );
    _scatterColorMaxCtrl = TextEditingController(
      text: widget.slot.scatterColorMax?.toString() ?? '',
    );
    _scatterEqualAspect = widget.slot.scatterEqualAspect;
    _scatterReferenceCircles = widget.slot.scatterReferenceCircles;
    _scatterBinCtrl = TextEditingController(
      text: widget.slot.scatterBinCount.toString(),
    );
  }

  @override
  void dispose() {
    _yMinCtrl.dispose();
    _yMaxCtrl.dispose();
    _titleCtrl.dispose();
    _fftOverlapCtrl.dispose();
    _histogramBinCtrl.dispose();
    _gpsColorMinCtrl.dispose();
    _gpsColorMaxCtrl.dispose();
    _scatterColorMinCtrl.dispose();
    _scatterColorMaxCtrl.dispose();
    _scatterBinCtrl.dispose();
    super.dispose();
  }

  /// Live slot from the provider — reflects changes made by nested dialogs.
  ChartSlot get _liveSlot =>
      ref.read(workspaceProvider).activeWorksheet.charts[widget.chartIndex];

  @override
  Widget build(BuildContext context) {
    // Watch so the channel list updates when _ChannelPickerDialog modifies it.
    // Nullable on purpose: the desktop Add-Chart flow removes the placeholder
    // slot on Cancel while this dialog is still mounted through its dismiss
    // animation, so the watched index can briefly point past the end of the
    // (now shorter) list. Render nothing in that window rather than crash.
    final liveSlot = ref.watch(
      workspaceProvider.select(
        (s) => widget.chartIndex < s.activeWorksheet.charts.length
            ? s.activeWorksheet.charts[widget.chartIndex]
            : null,
      ),
    );
    if (liveSlot == null) return const SizedBox.shrink();
    final mathState = ref.watch(mathChannelProvider);
    final mathNameMap = {
      for (final mc in mathState.channels) mc.id: mc.name,
    };

    // Desktop merges the type picker into this panel as a left rail; the rail
    // is shown only for user-switchable types (pinned lap slots never open
    // this dialog). Property sections key off the *live* type so switching
    // the rail re-renders them in place.
    final screenW = MediaQuery.sizeOf(context).width;
    final showRail =
        screenW > 700 && kAddableChartTypes.contains(liveSlot.chartType);
    final contentWidth = (screenW - 80).clamp(360.0, 720.0);

    final propertiesBody = SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _titleCtrl,
            style: plexMono(fontSize: 14, color: brandFg),
            cursorColor: brandFg,
            decoration: InputDecoration(
              labelText: 'Title (optional)',
              hintText: 'Defaults to assigned channel names',
              hintStyle: plexSans(fontSize: 13, color: brandFgFaint),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          // Scatter selects its axes via the dedicated X/Y pickers below, so it
          // skips the generic add-channels list.
          if (liveSlot.chartType != ChartType.scatter) ...[
            _buildChannelsSection(context, liveSlot, mathNameMap),
            const Divider(height: 24, color: brandRule),
          ],
          if (liveSlot.chartType == ChartType.gpsMap) ...[
            _buildGpsColorSection(context),
            const Divider(height: 24, color: brandRule),
          ],
          if (liveSlot.chartType == ChartType.scatter) ...[
            _buildScatterSection(context),
            const Divider(height: 24, color: brandRule),
          ],
          // The Y-axis controls are the shared value-axis range; the histogram,
          // GPS map, and scatter own their axes, so the generic section is
          // hidden there.
          if (liveSlot.chartType != ChartType.gpsMap &&
              liveSlot.chartType != ChartType.histogram &&
              liveSlot.chartType != ChartType.scatter) ...[
            _buildYAxisSection(context),
            const Divider(height: 24, color: brandRule),
          ],
          if (liveSlot.chartType == ChartType.timeSeries) ...[
            _buildScopeSection(context, liveSlot),
            const Divider(height: 24, color: brandRule),
          ],
          if (liveSlot.chartType == ChartType.fft) ...[
            _buildFftSection(context),
            const Divider(height: 24, color: brandRule),
          ],
          if (liveSlot.chartType == ChartType.histogram) ...[
            _buildHistogramSection(context, liveSlot),
            const Divider(height: 24, color: brandRule),
          ],
          _buildInfoNote(context),
        ],
      ),
    );

    return AlertDialog(
      title: Text(
        widget.isNew ? 'Add Chart' : 'Chart Properties',
        style: plexMono(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: brandFg,
        ),
      ),
      content: showRail
          ? SizedBox(
              width: contentWidth,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildTypeRail(liveSlot.chartType),
                  const SizedBox(width: 12),
                  Expanded(child: propertiesBody),
                ],
              ),
            )
          : SizedBox(width: double.maxFinite, child: propertiesBody),
      actions: widget.isNew
          ? [
              // Create flow: Cancel/dismiss discards the placeholder chart
              // (the caller removes it when this dialog returns anything but
              // `true`); Add commits via [_apply].
              QuietButton(
                label: 'Cancel',
                onPressed: () => Navigator.of(context).pop(false),
              ),
              QuietButton(
                label: 'Add',
                filled: true,
                onPressed: _apply,
              ),
            ]
          : [
              QuietButton(
                label: 'Remove chart',
                emphasis: ButtonEmphasis.alert,
                icon: Icons.delete_outline,
                onPressed: () async {
                  // Confirm while this dialog (and its ref) is still alive, then
                  // close it only if the chart was actually removed.
                  final removed =
                      await confirmRemoveChart(context, ref, widget.chartIndex);
                  if (removed && context.mounted) {
                    Navigator.of(context).pop(false);
                  }
                },
              ),
              const Spacer(),
              QuietButton(
                label: 'Cancel',
                onPressed: () => Navigator.of(context).pop(false),
              ),
              QuietButton(
                label: 'Apply',
                filled: true,
                onPressed: _apply,
              ),
            ],
    );
  }

  /// Vertical rail of chart-type buttons shown on the left of the desktop
  /// panel. Selecting a type converts the slot in place via [_switchType].
  Widget _buildTypeRail(ChartType current) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final type in kAddableChartTypes)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _ChartTypeRailButton(
              info: chartTypeInfo(type),
              selected: type == current,
              onTap: () => _switchType(type),
            ),
          ),
      ],
    );
  }

  /// Converts the slot to [type] in place, preserving assigned channels.
  /// No-op when the slot is already that type. Writes immediately so the
  /// property sections re-render for the new type.
  void _switchType(ChartType type) {
    if (type == _liveSlot.chartType) return;
    ref.read(workspaceProvider.notifier).updateChartProperties(
          widget.chartIndex,
          _liveSlot.copyWith(chartType: type),
        );
  }

  Widget _buildChannelsSection(
    BuildContext context,
    ChartSlot liveSlot,
    Map<String, String> mathNameMap,
  ) {
    final isGps = liveSlot.chartType == ChartType.gpsMap;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'CHANNELS',
              style: plexMono(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: brandFgDim,
                letterSpacing: brandKickerTracking,
              ),
            ),
            const Spacer(),
            if (!isGps)
              QuietButton(
                label: 'Add Channel',
                icon: Icons.add,
                onPressed: () => _openChannelPicker(context, liveSlot),
              ),
          ],
        ),
        const SizedBox(height: 4),
        if (isGps)
          // GPS map: non-reorderable per-session colour rows, labelled by date.
          Builder(
            builder: (context) {
              final sessions = ref.watch(sessionProvider).sessions;
              return Column(
                children: [
                  for (final sessionId in widget.selectedIds)
                    _ChannelColorRow(
                      key: ValueKey(sessionId),
                      label: sessionDisplayLabel(sessions, sessionId),
                      colorValue: _channelColors[sessionId],
                      onColorChanged: (v) =>
                          setState(() => _channelColors[sessionId] = v),
                      onRemove: null,
                      onEdit: null,
                    ),
                ],
              );
            },
          )
        else
          _buildReorderableChannelList(context, liveSlot, mathNameMap),
      ],
    );
  }

  Widget _buildReorderableChannelList(
    BuildContext context,
    ChartSlot liveSlot,
    Map<String, String> mathNameMap,
  ) {
    // Build a combined ordered list: raw channels first, then math channels.
    // Each item is tagged so we can split them back on reorder.
    final rawIds = liveSlot.channelIds;
    final mathIds = liveSlot.mathChannelIds;

    if (rawIds.isEmpty && mathIds.isEmpty) {
      return Text(
        'No channels assigned',
        style: plexMono(fontSize: 13, color: brandFgDim),
      );
    }

    // Items: (key, label, isMath, id)
    final items = [
      for (final id in rawIds) (key: id, label: id, isMath: false, id: id),
      for (final id in mathIds)
        (
          key: 'math_$id',
          label: mathNameMap[id] ?? id,
          isMath: true,
          id: id,
        ),
    ];

    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      // Off so the per-row buttons (colour / edit / remove) stay tappable on
      // desktop; each row carries its own drag handle (see [_ChannelColorRow]).
      buildDefaultDragHandles: false,
      onReorder: (oldIndex, newIndex) {
        if (newIndex > oldIndex) newIndex--;
        final updated = List.of(items);
        final item = updated.removeAt(oldIndex);
        updated.insert(newIndex, item);
        final newRaw =
            updated.where((e) => !e.isMath).map((e) => e.id).toList();
        final newMath =
            updated.where((e) => e.isMath).map((e) => e.id).toList();
        ref.read(workspaceProvider.notifier).updateChartProperties(
              widget.chartIndex,
              _liveSlot.copyWith(
                channelIds: newRaw,
                mathChannelIds: newMath,
                channelColors: _channelColors,
              ),
            );
      },
      children: [
        for (final (i, item) in items.indexed)
          _ChannelColorRow(
            key: ValueKey(item.key),
            reorderIndex: i,
            label: item.label,
            colorValue: _channelColors[item.id],
            onColorChanged: (v) => setState(() => _channelColors[item.id] = v),
            onRemove: () {
              // Update the slot only — the dialog watches the live slot and
              // rebuilds the list with the row gone. (Popping here would close
              // the whole properties dialog on every channel removal.)
              if (item.isMath) {
                ref
                    .read(workspaceProvider.notifier)
                    .removeMathChannelFromChart(widget.chartIndex, item.id);
              } else {
                ref
                    .read(workspaceProvider.notifier)
                    .removeChannelFromChart(widget.chartIndex, item.id);
              }
            },
            onEdit: item.isMath ? () => _editMathChannel(item.id) : null,
          ),
      ],
    );
  }

  void _openChannelPicker(BuildContext context, ChartSlot liveSlot) {
    showDialog<void>(
      context: context,
      builder: (_) => _ChannelPickerDialog(
        chartIndex: widget.chartIndex,
        initialChannelIds: List<String>.from(liveSlot.channelIds),
        initialMathChannelIds: List<String>.from(liveSlot.mathChannelIds),
      ),
    );
  }

  /// Sets [mathChannelId] as the active channel in the Maths tab and
  /// navigates to it.
  void _editMathChannel(String mathChannelId) {
    ref.read(mathChannelProvider.notifier).setActiveChannel(mathChannelId);
    ref.read(shellIndexProvider.notifier).state = 2; // Maths tab
    Navigator.of(context).pop();
  }

  /// Chart types with a continuous Y axis the shared [YScale] applies to.
  /// GPS map (no Y) and the lap table (a grid) are excluded.
  bool get _hasContinuousYAxis => switch (widget.slot.chartType) {
        ChartType.timeSeries ||
        ChartType.fft ||
        ChartType.spectrogram ||
        ChartType.histogram ||
        ChartType.lapProgression =>
          true,
        _ => false,
      };

  /// The shared Lin / Log / Sqrt / Sq scale control, bound to [_yScale]. Drives
  /// `ChartSlot.yScale` (the shared [YScale]); see SPEC §26.12. [label] names the
  /// axis it controls — "Scale" in the generic Y section, "Count axis scale"
  /// under the histogram section where the Y axis is a per-bin percentage.
  Widget _buildScaleControl(String label) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: plexMono(fontSize: 13, color: brandFg)),
        const SizedBox(height: 4),
        SegmentedButton<YScale>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: YScale.linear,
              label: Text('Lin', style: plexMono(color: brandFg)),
            ),
            ButtonSegment(
              value: YScale.log,
              label: Text('Log', style: plexMono(color: brandFg)),
            ),
            ButtonSegment(
              value: YScale.sqrtSigned,
              label: Text('Sqrt', style: plexMono(color: brandFg)),
            ),
            ButtonSegment(
              value: YScale.squareSigned,
              label: Text('Sq', style: plexMono(color: brandFg)),
            ),
          ],
          selected: {_yScale},
          onSelectionChanged: (s) => setState(() => _yScale = s.first),
        ),
      ],
    );
  }

  Widget _buildYAxisSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Y AXIS',
          style: plexMono(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: brandFgDim,
            letterSpacing: brandKickerTracking,
          ),
        ),
        const SizedBox(height: 8),
        SegmentedButton<YScaleMode>(
          segments: [
            ButtonSegment(
              value: YScaleMode.auto,
              label: Text('Auto', style: plexMono(color: brandFg)),
            ),
            ButtonSegment(
              value: YScaleMode.manual,
              label: Text('Manual', style: plexMono(color: brandFg)),
            ),
          ],
          selected: {_yScaleMode},
          onSelectionChanged: (s) => setState(() => _yScaleMode = s.first),
        ),
        if (_hasContinuousYAxis) ...[
          const SizedBox(height: 8),
          _buildScaleControl('Scale'),
        ],
        const SizedBox(height: 4),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          title: Text(
            'Show Y=0 reference line',
            style: plexMono(fontSize: 13, color: brandFg),
          ),
          checkColor: brandBg,
          side: const BorderSide(color: brandRule, width: 1.5),
          fillColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? brandGood
                : Colors.transparent,
          ),
          value: _showZeroLine,
          onChanged: (v) => setState(() => _showZeroLine = v ?? false),
        ),
        if (_yScaleMode == YScaleMode.manual) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _yMinCtrl,
                  style: plexMono(fontSize: 14, color: brandFg),
                  cursorColor: brandFg,
                  decoration: const InputDecoration(
                    labelText: 'Min',
                    isDense: true,
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _yMaxCtrl,
                  style: plexMono(fontSize: 14, color: brandFg),
                  cursorColor: brandFg,
                  decoration: const InputDecoration(
                    labelText: 'Max',
                    isDense: true,
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildInfoNote(BuildContext context) {
    return Text(
      'Drag the resize handle below the chart to adjust height.',
      style: plexSans(fontSize: 13, color: brandFgDim),
    );
  }

  /// GPS-only: pick one channel to colour the trace by (Turbo heatmap), with an
  /// optional manual scale range. `None` ⇒ solid per-session colours.
  Widget _buildGpsColorSection(BuildContext context) {
    final channels = ref.watch(availableChannelNamesProvider);
    final headStyle = plexMono(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: brandFgDim,
      letterSpacing: brandKickerTracking,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('COLOUR BY', style: headStyle),
        const SizedBox(height: 8),
        DropdownButton<String?>(
          isExpanded: true,
          value: _gpsColorChannelId,
          dropdownColor: brandSurface,
          style: plexMono(fontSize: 13, color: brandFg),
          hint: Text(
            'None (solid colours)',
            style: plexMono(fontSize: 13, color: brandFgDim),
          ),
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: Text(
                'None (solid colours)',
                style: plexMono(fontSize: 13, color: brandFgDim),
              ),
            ),
            for (final name in channels)
              DropdownMenuItem<String?>(
                value: name,
                child: Text(
                  name,
                  style: plexMono(fontSize: 13, color: brandFg),
                ),
              ),
          ],
          onChanged: (v) => setState(() => _gpsColorChannelId = v),
        ),
        if (_gpsColorChannelId != null) ...[
          const SizedBox(height: 8),
          Text(
            'Scale range — blank = auto (shared across traces)',
            style: plexSans(fontSize: 13, color: brandFgDim),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _gpsColorMinCtrl,
                  style: plexMono(fontSize: 14, color: brandFg),
                  cursorColor: brandFg,
                  decoration: InputDecoration(
                    labelText: 'Min',
                    hintText: 'auto',
                    hintStyle: plexSans(fontSize: 13, color: brandFgFaint),
                    isDense: true,
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _gpsColorMaxCtrl,
                  style: plexMono(fontSize: 14, color: brandFg),
                  cursorColor: brandFg,
                  decoration: InputDecoration(
                    labelText: 'Max',
                    hintText: 'auto',
                    hintStyle: plexSans(fontSize: 13, color: brandFgFaint),
                    isDense: true,
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Properties for a [ChartType.scatter] slot: X/Y channel pickers, the
  /// points/density mode toggle, an optional colour-by channel + scale, the
  /// density bin count, and the equal-aspect / reference-circle toggles.
  Widget _buildScatterSection(BuildContext context) {
    // Same source the GPS colour-by uses; spans the base ∪ math channel names.
    final channels = ref.watch(availableChannelNamesProvider);
    final headStyle = plexMono(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: brandFgDim,
      letterSpacing: brandKickerTracking,
    );

    DropdownButton<String?> channelDropdown(
      String? value,
      String hint,
      ValueChanged<String?> onChanged, {
      bool allowNone = false,
    }) {
      return DropdownButton<String?>(
        isExpanded: true,
        value: value,
        dropdownColor: brandSurface,
        style: plexMono(fontSize: 13, color: brandFg),
        hint: Text(hint, style: plexMono(fontSize: 13, color: brandFgDim)),
        items: [
          if (allowNone)
            DropdownMenuItem<String?>(
              value: null,
              child: Text(
                'None (solid colour)',
                style: plexMono(fontSize: 13, color: brandFgDim),
              ),
            ),
          for (final name in channels)
            DropdownMenuItem<String?>(
              value: name,
              child: Text(name, style: plexMono(fontSize: 13, color: brandFg)),
            ),
        ],
        onChanged: onChanged,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('X CHANNEL', style: headStyle),
        const SizedBox(height: 4),
        channelDropdown(
          _scatterXChannelId,
          'Pick X (lateral g)',
          (v) => setState(() => _scatterXChannelId = v),
        ),
        const SizedBox(height: 12),
        Text('Y CHANNEL', style: headStyle),
        const SizedBox(height: 4),
        channelDropdown(
          _scatterYChannelId,
          'Pick Y (longitudinal g)',
          (v) => setState(() => _scatterYChannelId = v),
        ),
        const SizedBox(height: 16),
        Text('MODE', style: headStyle),
        const SizedBox(height: 4),
        SegmentedButton<ScatterMode>(
          segments: const [
            ButtonSegment(value: ScatterMode.points, label: Text('Points')),
            ButtonSegment(value: ScatterMode.density, label: Text('Density')),
          ],
          selected: {_scatterMode},
          onSelectionChanged: (s) => setState(() => _scatterMode = s.first),
        ),
        const SizedBox(height: 16),
        if (_scatterMode == ScatterMode.points) ...[
          Text('COLOUR BY', style: headStyle),
          const SizedBox(height: 4),
          channelDropdown(
            _scatterColorChannelId,
            'None (solid colour)',
            (v) => setState(() => _scatterColorChannelId = v),
            allowNone: true,
          ),
          if (_scatterColorChannelId != null) ...[
            const SizedBox(height: 8),
            Text(
              'Scale range — blank = auto',
              style: plexSans(fontSize: 13, color: brandFgDim),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _scatterColorMinCtrl,
                    style: plexMono(fontSize: 14, color: brandFg),
                    cursorColor: brandFg,
                    decoration: InputDecoration(
                      labelText: 'Min',
                      hintText: 'auto',
                      hintStyle: plexSans(fontSize: 13, color: brandFgFaint),
                      isDense: true,
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                      decimal: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _scatterColorMaxCtrl,
                    style: plexMono(fontSize: 14, color: brandFg),
                    cursorColor: brandFg,
                    decoration: InputDecoration(
                      labelText: 'Max',
                      hintText: 'auto',
                      hintStyle: plexSans(fontSize: 13, color: brandFgFaint),
                      isDense: true,
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                      decimal: true,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
        if (_scatterMode == ScatterMode.density) ...[
          Text('BINS', style: headStyle),
          const SizedBox(height: 4),
          SizedBox(
            width: 120,
            child: TextField(
              controller: _scatterBinCtrl,
              style: plexMono(fontSize: 14, color: brandFg),
              cursorColor: brandFg,
              decoration: InputDecoration(
                hintText: '64',
                hintStyle: plexSans(fontSize: 13, color: brandFgFaint),
                isDense: true,
              ),
              keyboardType: TextInputType.number,
            ),
          ),
        ],
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            'Equal aspect (round circle)',
            style: plexSans(fontSize: 13, color: brandFg),
          ),
          value: _scatterEqualAspect,
          onChanged: (v) => setState(() => _scatterEqualAspect = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            'Reference g-circles',
            style: plexSans(fontSize: 13, color: brandFg),
          ),
          value: _scatterReferenceCircles,
          onChanged: (v) => setState(() => _scatterReferenceCircles = v),
        ),
      ],
    );
  }

  Widget _buildFftSection(BuildContext context) {
    final labelStyle = plexMono(fontSize: 13, color: brandFg);
    final headStyle = plexMono(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: brandFgDim,
      letterSpacing: brandKickerTracking,
    );
    // Discrete Welch segment lengths (samples). null = Auto (zoom-adaptive at
    // render). Power-of-2 values are the fastest for the realfft transform; a
    // stored non-standard value (legacy) is kept selectable so opening the dialog
    // never silently changes it.
    const segOptions = <int>[1024, 2048, 4096, 8192];
    final segItems = <int?>[null, ...segOptions];
    if (_fftSegment != null && !segOptions.contains(_fftSegment)) {
      segItems.add(_fftSegment);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('FFT', style: headStyle),
        const SizedBox(height: 8),
        Text('Window function', style: labelStyle),
        const SizedBox(height: 4),
        SegmentedButton<FftWindow>(
          segments: [
            ButtonSegment(
              value: FftWindow.hann,
              label: Text('Hann', style: plexMono(color: brandFg)),
            ),
            ButtonSegment(
              value: FftWindow.hamming,
              label: Text('Hamming', style: plexMono(color: brandFg)),
            ),
            ButtonSegment(
              value: FftWindow.rectangular,
              label: Text('Rect', style: plexMono(color: brandFg)),
            ),
          ],
          selected: {_fftWindow},
          onSelectionChanged: (s) => setState(() => _fftWindow = s.first),
        ),
        const Divider(height: 24, color: brandRule),

        // ── Spectral estimation (Welch) ──────────────────────────────────
        Text('SPECTRAL ESTIMATION', style: headStyle),
        const SizedBox(height: 4),
        Text(
          'Welch averaging: shorter segments = smoother spectrum, less '
          'frequency detail. Auto adapts to the zoom window.',
          style: plexSans(fontSize: 13, color: brandFgDim),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Segment length',
                  isDense: true,
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int?>(
                    value: _fftSegment,
                    isExpanded: true,
                    isDense: true,
                    dropdownColor: brandSurface,
                    style: plexMono(fontSize: 14, color: brandFg),
                    items: [
                      for (final opt in segItems)
                        DropdownMenuItem<int?>(
                          value: opt,
                          child: Text(opt == null ? 'Auto' : opt.toString()),
                        ),
                    ],
                    onChanged: (v) => setState(() => _fftSegment = v),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _fftOverlapCtrl,
                style: plexMono(fontSize: 14, color: brandFg),
                cursorColor: brandFg,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Overlap %',
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text('Detrend', style: labelStyle),
        const SizedBox(height: 4),
        SegmentedButton<Detrend>(
          segments: [
            ButtonSegment(
              value: Detrend.none,
              label: Text('None', style: plexMono(color: brandFg)),
            ),
            ButtonSegment(
              value: Detrend.mean,
              label: Text('Mean', style: plexMono(color: brandFg)),
            ),
            ButtonSegment(
              value: Detrend.linear,
              label: Text('Linear', style: plexMono(color: brandFg)),
            ),
          ],
          selected: {_fftDetrend},
          onSelectionChanged: (s) => setState(() => _fftDetrend = s.first),
        ),
        const SizedBox(height: 12),
        Text('Averaging', style: labelStyle),
        const SizedBox(height: 4),
        SegmentedButton<Averaging>(
          segments: [
            ButtonSegment(
              value: Averaging.mean,
              label: Text('Mean', style: plexMono(color: brandFg)),
            ),
            ButtonSegment(
              value: Averaging.median,
              label: Text('Median', style: plexMono(color: brandFg)),
            ),
          ],
          selected: {_fftAveraging},
          onSelectionChanged: (s) => setState(() => _fftAveraging = s.first),
        ),
        const SizedBox(height: 12),
        Text('Scaling', style: labelStyle),
        const SizedBox(height: 4),
        SegmentedButton<Scaling>(
          segments: [
            ButtonSegment(
              value: Scaling.magnitude,
              label: Text('Magnitude', style: plexMono(color: brandFg)),
            ),
            ButtonSegment(
              value: Scaling.density,
              label: Text('Density', style: plexMono(color: brandFg)),
            ),
          ],
          selected: {_fftScaling},
          onSelectionChanged: (s) => setState(() => _fftScaling = s.first),
        ),
        const Divider(height: 24, color: brandRule),

        // ── Axes ─────────────────────────────────────────────────────────
        Text('AXES', style: headStyle),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Frequency (X)', style: labelStyle),
                  const SizedBox(height: 4),
                  SegmentedButton<FftXScale>(
                    segments: [
                      ButtonSegment(
                        value: FftXScale.linear,
                        label: Text('Lin', style: plexMono(color: brandFg)),
                      ),
                      ButtonSegment(
                        value: FftXScale.log,
                        label: Text('Log', style: plexMono(color: brandFg)),
                      ),
                    ],
                    selected: {_fftXScale},
                    onSelectionChanged: (s) =>
                        setState(() => _fftXScale = s.first),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildScopeSection(BuildContext context, ChartSlot liveSlot) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'X AXIS SCOPE',
          style: plexMono(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: brandFgDim,
            letterSpacing: brandKickerTracking,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Auto: full session when no main/overlay laps are set; switches '
          'to a lap-pair view (main + overlay, lap-relative x-axis) when '
          'both are designated. Session: always full session.',
          style: plexSans(fontSize: 13, color: brandFgDim),
        ),
        const SizedBox(height: 8),
        SegmentedButton<ChartScope>(
          segments: [
            ButtonSegment(
              value: ChartScope.auto,
              label: Text('Auto', style: plexMono(color: brandFg)),
            ),
            ButtonSegment(
              value: ChartScope.session,
              label: Text('Session', style: plexMono(color: brandFg)),
            ),
          ],
          selected: {_scope},
          onSelectionChanged: (s) => setState(() => _scope = s.first),
        ),
      ],
    );
  }

  /// Histogram options: bin count, symmetric (zero-centred) range, smooth-curve
  /// rendering, and the shared Lin/Log/Sqrt/Sq count-axis scale. The channel(s)
  /// come from the shared channels section above.
  Widget _buildHistogramSection(BuildContext context, ChartSlot liveSlot) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'HISTOGRAM',
          style: plexMono(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: brandFgDim,
            letterSpacing: brandKickerTracking,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                'Bins',
                style: plexMono(fontSize: 13, color: brandFg),
              ),
            ),
            SizedBox(
              width: 90,
              child: TextField(
                controller: _histogramBinCtrl,
                style: plexMono(fontSize: 14, color: brandFg),
                cursorColor: brandFg,
                decoration: const InputDecoration(isDense: true),
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          title: Text(
            'Symmetric range (centre on 0)',
            style: plexMono(fontSize: 13, color: brandFg),
          ),
          subtitle: Text(
            'Bin over [−m, m] so compression and rebound mirror — for signed '
            'velocity channels.',
            style: plexSans(fontSize: 12, color: brandFgDim),
          ),
          checkColor: brandBg,
          side: const BorderSide(color: brandRule, width: 1.5),
          fillColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? brandGood
                : Colors.transparent,
          ),
          value: _histogramSymmetric,
          onChanged: (v) => setState(() => _histogramSymmetric = v ?? false),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          title: Text(
            'Smooth curve (polyline)',
            style: plexMono(fontSize: 13, color: brandFg),
          ),
          subtitle: Text(
            'Draw a fitted polyline through the bin centres instead of '
            'stepped bars.',
            style: plexSans(fontSize: 12, color: brandFgDim),
          ),
          checkColor: brandBg,
          side: const BorderSide(color: brandRule, width: 1.5),
          fillColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? brandGood
                : Colors.transparent,
          ),
          value: _histogramSmooth,
          onChanged: (v) => setState(() => _histogramSmooth = v ?? false),
        ),
        const SizedBox(height: 8),
        // Y here is the per-bin percentage (count / total); this is the shared
        // YScale (SPEC §26.10 / §26.12) — log exposes the sparse high-velocity
        // tails. The control lives in this section because the histogram owns
        // its value axis, so the generic Y-axis section is hidden for it.
        _buildScaleControl('Count axis scale'),
      ],
    );
  }

  /// Parses the bin-count field, clamping to `[2, 200]`; defaults to 40 on
  /// empty or unparseable input.
  int _parseHistogramBins() {
    final n = int.tryParse(_histogramBinCtrl.text.trim()) ?? 40;
    return n.clamp(2, 200);
  }

  void _apply() {
    // Read live slot so channel lists reflect any picker changes.
    final live = _liveSlot;
    double? yMin;
    double? yMax;
    if (_yScaleMode == YScaleMode.manual) {
      yMin = double.tryParse(_yMinCtrl.text);
      yMax = double.tryParse(_yMaxCtrl.text);
    }
    final titleText = _titleCtrl.text.trim();
    final int? fftSegment = _fftSegment;
    final overlap =
        (double.tryParse(_fftOverlapCtrl.text.trim()) ?? 50.0).clamp(0.0, 99.0);
    final gpsMin = double.tryParse(_gpsColorMinCtrl.text.trim());
    final gpsMax = double.tryParse(_gpsColorMaxCtrl.text.trim());
    final scatterColorMin = double.tryParse(_scatterColorMinCtrl.text.trim());
    final scatterColorMax = double.tryParse(_scatterColorMaxCtrl.text.trim());
    final scatterBins =
        (int.tryParse(_scatterBinCtrl.text.trim()) ?? 64).clamp(8, 256);
    final updated = live.copyWith(
      yScaleMode: _yScaleMode,
      yMin: yMin,
      yMax: yMax,
      channelColors: _channelColors,
      scope: _scope,
      spectral: live.spectral.copyWith(
        window: _fftWindow,
        freqScale: _fftXScale,
        segmentLength: fftSegment,
        clearSegmentLength: fftSegment == null,
        overlapPercent: overlap,
        detrend: _fftDetrend,
        scaling: _fftScaling,
      ),
      fftAveraging: _fftAveraging,
      yScale: _yScale,
      showZeroLine: _showZeroLine,
      histogramBinCount: _parseHistogramBins(),
      histogramSymmetric: _histogramSymmetric,
      histogramSmooth: _histogramSmooth,
      gpsColorChannelId: _gpsColorChannelId,
      gpsColorMin: gpsMin,
      gpsColorMax: gpsMax,
      scatterXChannelId: _scatterXChannelId,
      scatterYChannelId: _scatterYChannelId,
      scatterMode: _scatterMode,
      scatterColorChannelId: _scatterColorChannelId,
      scatterColorMin: scatterColorMin,
      scatterColorMax: scatterColorMax,
      scatterEqualAspect: _scatterEqualAspect,
      scatterReferenceCircles: _scatterReferenceCircles,
      scatterBinCount: scatterBins,
      title: titleText.isEmpty ? null : titleText,
    );
    ref
        .read(workspaceProvider.notifier)
        .updateChartProperties(widget.chartIndex, updated);
    // Pop `true` so the desktop Add-Chart caller knows the chart was kept.
    Navigator.of(context).pop(true);
  }
}

// ---------------------------------------------------------------------------
// _ChartTypeRailButton
// ---------------------------------------------------------------------------

/// One button in the desktop chart-type rail: the type glyph above its label,
/// boxed, lit in [brandHivis] when selected. Hover/tap converts the chart.
class _ChartTypeRailButton extends StatelessWidget {
  const _ChartTypeRailButton({
    required this.info,
    required this.selected,
    required this.onTap,
  });

  /// Catalog metadata for the chart type this button represents.
  final ChartTypeInfo info;

  /// Whether this is the slot's current type (drives the lit styling).
  final bool selected;

  /// Invoked when the button is tapped — converts the slot to [info]'s type.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The glyph always carries the type's signature colour so the rail reads
    // as colour-coded even at rest; selection adds a tinted fill + matching
    // border and lights the label.
    final accent = info.accent;
    return Tooltip(
      message: info.blurb,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: selected ? accent.withValues(alpha: 0.16) : Colors.transparent,
        borderRadius: BorderRadius.circular(brandControlRadiusSoft),
        child: InkWell(
          borderRadius: BorderRadius.circular(brandControlRadiusSoft),
          onTap: onTap,
          child: Container(
            width: 88,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(brandControlRadiusSoft),
              border: Border.all(
                color: selected ? accent : brandRule,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(info.icon, size: 26, color: accent),
                const SizedBox(height: 6),
                Text(
                  info.label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  softWrap: true,
                  style: plexMono(
                    fontSize: 11,
                    height: 1.15,
                    color: selected ? accent : brandFgDim,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _ChannelColorRow
// ---------------------------------------------------------------------------

/// One row in the channels section of [_ChartPropertiesDialog].
///
/// Shows a tappable colour swatch, the channel label, optional edit button
/// (math channels only), and an optional remove button.
class _ChannelColorRow extends StatelessWidget {
  const _ChannelColorRow({
    super.key,
    required this.label,
    required this.colorValue,
    required this.onColorChanged,
    required this.onRemove,
    required this.onEdit,
    this.reorderIndex,
  });

  final String label;

  /// Current ARGB int colour, or null to show the automatic swatch.
  final int? colorValue;

  final ValueChanged<int> onColorChanged;

  /// Null means the remove button is hidden (e.g. GPS session rows).
  final VoidCallback? onRemove;

  /// Non-null for math channel rows — tapping navigates to the Maths tab.
  final VoidCallback? onEdit;

  /// Position of this row in its [ReorderableListView]. When non-null a drag
  /// handle is shown and *only* the handle starts a reorder — the list runs
  /// with `buildDefaultDragHandles: false` so the row's buttons stay tappable
  /// (the default per-row drag recognizer eats button taps on desktop). Null
  /// for non-reorderable contexts (e.g. the GPS per-session rows).
  final int? reorderIndex;

  @override
  Widget build(BuildContext context) {
    final swatchColor = colorValue != null ? Color(colorValue!) : brandFgDim;
    return Row(
      children: [
        if (reorderIndex != null) ...[
          ReorderableDragStartListener(
            index: reorderIndex!,
            child: const MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Icon(Icons.drag_indicator, size: 18, color: brandFgFaint),
            ),
          ),
          const SizedBox(width: 6),
        ],
        GestureDetector(
          onTap: () async {
            final picked = await showColorGridPicker(
              context,
              current: colorValue == null ? null : Color(colorValue!),
            );
            if (picked != null) onColorChanged(picked.toARGB32());
          },
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: swatchColor,
              shape: BoxShape.circle,
              border: Border.all(color: brandRule),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: plexMono(fontSize: 13, color: brandFg),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (onEdit != null)
          IconButton(
            icon: const Icon(Icons.edit, size: 16, color: brandFgDim),
            tooltip: 'Edit in Maths tab',
            onPressed: onEdit,
          ),
        if (onRemove != null)
          IconButton(
            icon: const Icon(Icons.close, size: 16, color: brandFgDim),
            tooltip: 'Remove',
            onPressed: onRemove,
          ),
      ],
    );
  }
}
