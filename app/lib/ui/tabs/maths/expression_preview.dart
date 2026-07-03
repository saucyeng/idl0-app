import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/math_channel.dart';
import '../../../data/session_model.dart';
import '../../../data/worksheet.dart';
import '../../../providers/math_channel_provider.dart';
import '../../../providers/selection_provider.dart';
import '../../../providers/workspace_provider.dart';
import '../../brand/brand.dart';
import '../analyze/time_series_chart.dart';

/// Synthetic worksheet id under which the preview's shared X range and cursor
/// state live, isolated from every real worksheet. A stable constant so the
/// single key never accumulates — see [TimeSeriesChart.worksheetId].
const String _kMathPreviewWorksheetId = '__math_preview__';

/// Ephemeral manual Y override (yMin, yMax) for the interactive preview, or
/// null in auto Y mode. Local to the Maths tab — never persisted, disposed
/// when the preview leaves the tree. Watched at the top of [ExpressionPreview]
/// so it survives the loading flashes between re-evaluations while the user
/// tweaks a filter, keeping the zoom pinned.
final _mathPreviewYRangeProvider =
    StateProvider.autoDispose<(double, double)?>((ref) => null);

/// Live, fully interactive preview of a math channel expression result.
///
/// Renders the active math channel through the same [TimeSeriesChart] the
/// Analyze tab uses, so zoom, pan, cursors, the right-click menu and
/// full-fidelity re-decimation are identical — Ctrl+wheel to zoom into a
/// trace and watch a filter's effect update in real time as its parameters
/// change. The chart is hosted outside a worksheet via a synthetic
/// [worksheetId] and a local Y override ([_mathPreviewYRangeProvider]), so it
/// never touches the workbook's slots.
///
/// States:
/// - No active channel or no session selected → placeholder prompt.
/// - Loading → centered [CircularProgressIndicator].
/// - Error → red error message.
/// - Data → an embedded [TimeSeriesChart].
///
/// See §15.4.
class ExpressionPreview extends ConsumerWidget {
  /// Creates an [ExpressionPreview].
  const ExpressionPreview({super.key});

  /// Fixed height of the preview chart. Tall enough to read a trace and zoom
  /// into it; the surrounding editor scrolls, so it cannot flex.
  static const double _previewHeight = 260;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeChannelId = ref.watch(
      mathChannelProvider.select((s) => s.activeChannelId),
    );
    final selectedSessionIds = ref.watch(effectiveSessionIdsProvider);

    if (activeChannelId == null || selectedSessionIds.isEmpty) {
      return _Placeholder(
        message: selectedSessionIds.isEmpty
            ? 'Select a session to preview'
            : 'Select a channel to preview',
      );
    }

    final channels = ref.watch(mathChannelProvider).channels;
    final matches = channels.where((c) => c.id == activeChannelId);
    final MathChannel? activeChannel = matches.isEmpty ? null : matches.first;
    if (activeChannel == null) {
      return const _Placeholder(message: 'Select a channel to preview');
    }

    final sessionId = selectedSessionIds.first;
    final evalAsync = ref.watch(
      mathChannelEvalProvider(
        (channelId: activeChannelId, sessionId: sessionId),
      ),
    );

    // Watched here (not inside the data branch) so the manual-Y zoom survives
    // the loading flash on each re-evaluation while a filter is being tuned.
    final manualY = ref.watch(_mathPreviewYRangeProvider);

    return SizedBox(
      height: _previewHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: brandRule, width: brandHairlineWidth),
          borderRadius: BorderRadius.zero,
        ),
        child: evalAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          error: (e, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                e.toString(),
                style: plexMono(color: brandAccent, fontSize: 11),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          data: (result) {
            if (result.length == 0) {
              return Center(
                child: Text('No data', style: plexMono(color: brandFgDim)),
              );
            }
            // The evaluator wrote the result into the handle's math store under
            // the channel name; the chart self-sources its tiles by that id,
            // identical to how the Analyze tab renders a math channel.
            final channelData = SessionChannelData(
              sessionId: sessionId,
              channelId: activeChannel.name,
              sampleRateHz: result.sampleRateHz,
              length: result.length,
              isEventDriven: false,
            );
            return TimeSeriesChart(
              channels: [channelData],
              xAxisMode: XAxisMode.time,
              worksheetId: _kMathPreviewWorksheetId,
              slotIndex: 0,
              channelColors: {activeChannel.name: activeChannel.colorValue},
              manualYRange: manualY,
              onApplyYScale: ({
                required YScaleMode mode,
                double? yMin,
                double? yMax,
              }) {
                final notifier = ref.read(_mathPreviewYRangeProvider.notifier);
                if (mode == YScaleMode.auto) {
                  notifier.state = null;
                } else if (yMin != null && yMax != null) {
                  notifier.state = (yMin, yMax);
                }
              },
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Placeholder
// ---------------------------------------------------------------------------

class _Placeholder extends StatelessWidget {
  final String message;

  const _Placeholder({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 120,
      decoration: BoxDecoration(
        border: Border.all(color: brandRule, width: brandHairlineWidth),
        borderRadius: BorderRadius.zero,
        color: brandSurface2,
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.show_chart, size: 32, color: brandFgFaint),
            const SizedBox(height: 4),
            Text(
              message,
              style: plexMono(color: brandFgDim),
            ),
          ],
        ),
      ),
    );
  }
}
