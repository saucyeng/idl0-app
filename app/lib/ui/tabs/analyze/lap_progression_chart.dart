import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/session_model.dart';
import '../../../data/y_scale.dart';
import '../../../providers/lap_provider.dart';
import '../../../providers/selection_provider.dart';
import '../../../providers/session_provider.dart';
import '../../../providers/session_workspace_provider.dart';
import '../../brand/brand.dart';
import '../../widgets/chart_context_menu.dart';
import '../../widgets/time_format.dart';
import 'session_label.dart';

/// Lap-time progression chart — one line per session in scope, with X = lap
/// index within that session (1..N) and Y = lap time in seconds.
///
/// **Scope** is the parent sessions of any entity in [selectionProvider]
/// regardless of mode — `effectiveSessionIdsProvider` resolves both
/// `SelectionMode.session` (the selected sessions verbatim) and
/// `SelectionMode.lap` (the parent sessions of any pinned lap key) to a
/// flat session-id set, so the same chart works for both modes without
/// branching.
///
/// **Ignored laps are filtered out** — laps marked ignored in the lap
/// table (added to `Workspace.ignoredLapNumbers`) are excluded from the
/// session's line and from the fastest-lap marker. Hiding an outlier
/// lap (out lap, red flag, etc.) on the lap table now also drops it
/// from the progression line, keeping the "did I get faster" view
/// honest. No Data-tab track filters apply.
///
/// Each session line gets a distinct colour from the shared
/// [brandChartPalette]. Sessions still loading are skipped silently — the
/// chart re-renders when the lap data resolves.
class LapProgressionChart extends ConsumerWidget {
  /// Creates a [LapProgressionChart].
  const LapProgressionChart({
    super.key,
    required this.slotIndex,
    this.yScale = YScale.linear,
  });

  /// Y-axis display scale applied to the lap-time spots and axis labels.
  final YScale yScale;

  /// Index of this chart's slot in the active worksheet — passed to
  /// [ChartContextMenu] for slot-local dispatch. Properties and cursor-copy
  /// are both null for lap progression (no channel config, no time-axis
  /// cursor).
  final int slotIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Lap progression has no time-axis cursor and no channel/Y-axis config,
    // so both onOpenProperties and onCopyCursorValues are null — the context
    // menu hides those items but still provides zoom/pan/reset commands.
    return ChartContextMenu(
      worksheetId: '',
      slotIndex: slotIndex,
      fullDataRange: const (0.0, 1.0),
      pixelToTimeSecs: (_) => 0.0,
      // Lap progression's X axis is lap number (1, 2, 3…), independent of
      // the worksheet's time-axis range. Hide zoom + pan items so users
      // don't see commands that update worksheet state without changing
      // this chart visually.
      xAxisIsWorksheetTime: false,
      onOpenProperties: null,
      onCopyCursorValues: null,
      child: _buildContent(context, ref),
    );
  }

  /// Returns the chart body without the [ChartContextMenu] wrapper so
  /// [build] can wrap all rendering paths in a single call.
  Widget _buildContent(BuildContext context, WidgetRef ref) {
    final selectedIds = ref.watch(effectiveSessionIdsProvider);
    if (selectedIds.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Select sessions or laps to see lap progression.',
            style: plexMono(fontSize: 12, color: brandFgDim),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // Build one line per session. Skip sessions whose laps are still
    // loading or empty — the chart will rebuild when they arrive.
    final sessions = ref.watch(sessionProvider).sessions;
    final orderedIds = selectedIds.toList();
    final lines = <_SessionLine>[];
    var maxLaps = 0;
    var maxTimeSec = 0.0;

    for (var i = 0; i < orderedIds.length; i++) {
      final sessionId = orderedIds[i];
      final lapsAsync = ref.watch(sessionLapsProvider(sessionId));
      final laps = lapsAsync.whenOrNull(data: (l) => l) ?? const <Lap>[];
      if (laps.isEmpty) continue;

      // Drop laps marked ignored on the lap table — out laps, red-flag
      // laps, etc. should not skew the progression line.
      final wsAsync = ref.watch(sessionWorkspaceProvider(sessionId));
      final ignored = wsAsync.whenOrNull(
            data: (ws) => ws.ignoredLapNumbers,
          ) ??
          const <int>{};

      // Spots: x = 1-based lap index within the session, y = seconds.
      // Ignored laps are skipped so the line shows only valid attempts;
      // the displayed lap index still reflects the lap's true position
      // within the session (lap 4 stays lap 4 even if lap 3 is hidden).
      final spots = <FlSpot>[];
      var bestSec = double.infinity;
      var bestX = 1.0;
      for (var k = 0; k < laps.length; k++) {
        final lap = laps[k];
        if (ignored.contains(lap.lapNumber)) continue;
        final secs = lap.lapTimeMs / 1000.0;
        spots.add(FlSpot(lap.lapNumber.toDouble(), secs));
        if (secs < bestSec) {
          bestSec = secs;
          bestX = lap.lapNumber.toDouble();
        }
        if (secs > maxTimeSec) maxTimeSec = secs;
      }
      if (spots.isEmpty) continue;
      final lastLapNumber = laps.last.lapNumber;
      if (lastLapNumber > maxLaps) maxLaps = lastLapNumber;

      lines.add(
        _SessionLine(
          sessionId: sessionId,
          label: sessionDisplayLabel(sessions, sessionId),
          color: brandChartPalette[i % brandChartPalette.length],
          spots: spots,
          bestSpot: FlSpot(bestX, bestSec),
        ),
      );
    }

    if (lines.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'No laps detected in any session in scope.',
            style: plexMono(fontSize: 12, color: brandFgDim),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // Y-axis display transform. Lap times are >= 0; the band is sized from the
    // slowest lap so it's stable. minY stays 0 (forward(0) == 0 for all modes).
    final yt = YScaleTransform(yScale, dataMaxAbs: maxTimeSec);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Legend(lines: lines),
          const SizedBox(height: 8),
          Expanded(
            child: LineChart(
              LineChartData(
                minX: 0.5,
                maxX: maxLaps + 0.5,
                minY: 0,
                lineBarsData: [
                  for (final line in lines)
                    LineChartBarData(
                      spots: yt.isIdentity
                          ? line.spots
                          : [
                              for (final s in line.spots)
                                FlSpot(s.x, yt.forward(s.y)),
                            ],
                      color: line.color,
                      barWidth: 2,
                      isCurved: false,
                      dotData: FlDotData(
                        show: true,
                        getDotPainter: (spot, _, __, ___) {
                          // Highlight the fastest lap of this session with a
                          // larger filled circle. Ties (multiple laps at the
                          // same min) all get marked — the fl_chart default
                          // dot painter ignores tie-breaking. Spots are in
                          // display space, so compare against the forwarded
                          // best time.
                          final bestY = yt.isIdentity
                              ? line.bestSpot.y
                              : yt.forward(line.bestSpot.y);
                          final isBest =
                              spot.x == line.bestSpot.x && spot.y == bestY;
                          return FlDotCirclePainter(
                            radius: isBest ? 5 : 2.5,
                            color: line.color,
                            strokeWidth: isBest ? 2 : 0,
                            strokeColor: brandSurface,
                          );
                        },
                      ),
                    ),
                ],
                titlesData: FlTitlesData(
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  leftTitles: AxisTitles(
                    axisNameWidget: Text(
                      'Lap time',
                      style: plexMono(fontSize: 11, color: brandFgDim),
                    ),
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 44,
                      getTitlesWidget: (value, meta) => Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text(
                          formatTimeAxisLabel(
                            yt.isIdentity ? value : yt.inverse(value),
                          ),
                          style: plexMono(fontSize: 10, color: brandFgDim),
                        ),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    axisNameWidget: Text(
                      'Lap #',
                      style: plexMono(fontSize: 11, color: brandFgDim),
                    ),
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 24,
                      interval: 1,
                      getTitlesWidget: (value, meta) => SideTitleWidget(
                        axisSide: meta.axisSide,
                        child: Text(
                          value.toInt().toString(),
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
                  border:
                      Border.all(color: brandRule, width: brandHairlineWidth),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Per-session line data prepared once in build, consumed by the renderer
/// + the legend.
class _SessionLine {
  const _SessionLine({
    required this.sessionId,
    required this.label,
    required this.color,
    required this.spots,
    required this.bestSpot,
  });

  final String sessionId;
  final String label;
  final Color color;
  final List<FlSpot> spots;
  final FlSpot bestSpot;
}

/// Compact swatch + session-label legend above the chart.
class _Legend extends StatelessWidget {
  const _Legend({required this.lines});

  final List<_SessionLine> lines;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        for (final line in lines)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: line.color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                line.label,
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
