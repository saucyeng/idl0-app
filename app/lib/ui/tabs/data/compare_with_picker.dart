import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../data/cached_session_laps.dart';
import '../../../data/session_model.dart';
import '../../../data/track.dart';
import '../../../data/workspace.dart';
import '../../../providers/session_provider.dart';
import '../../../providers/session_workspace_provider.dart';
import '../../../providers/track_provider.dart';

/// One row in the Compare-with… picker. Carries everything the caller
/// needs to launch a cross-session ghost chart from a tap.
class ComparePickerEntry {
  /// Session UUID of the comparison lap.
  final String sessionId;

  /// 1-based lap number within [sessionId].
  final int lapNumber;

  /// Lap time in milliseconds — used for sort + display.
  final int lapTimeMs;

  /// Local-time start of the lap. Drives the date column.
  final DateTime localStart;

  /// Source session's free-text [SessionMetadata.tag], or `''`.
  final String sessionTag;

  /// Creates a [ComparePickerEntry].
  const ComparePickerEntry({
    required this.sessionId,
    required this.lapNumber,
    required this.lapTimeMs,
    required this.localStart,
    required this.sessionTag,
  });
}

/// Compare-with… picker. See `docs/IDL0_SPEC.md §12.3` and §15.3.
///
/// Walks `sessionProvider` + per-session `Workspace.trackVisits` + per-visit
/// `visitLapsProvider` to gather every lap on [track] across the loaded
/// sessions, drops the source lap and any ignored laps, and sorts by lap
/// time ascending. Returns the chosen [ComparePickerEntry] via
/// [Navigator.pop], or `null` if the user cancels.
///
/// The picker is data-only — it doesn't dispatch to the Analyze tab. The
/// caller (the Sessions tree's lap-row Compare button) is responsible for
/// switching tabs and adding the ghost ChartSlot.
class CompareWithPicker extends ConsumerWidget {
  /// Creates a [CompareWithPicker].
  const CompareWithPicker({
    super.key,
    required this.track,
    required this.sourceSessionId,
    required this.sourceLapNumber,
    required this.sourceLapTimeMs,
  });

  /// Track scope — only laps on this Track are shown.
  final Track track;

  /// Session UUID of the lap the user is comparing FROM. Excluded from
  /// the picker list (same lap can't compare with itself).
  final String sourceSessionId;

  /// 1-based lap number of the source lap. Combined with [sourceSessionId]
  /// to identify the row to exclude.
  final int sourceLapNumber;

  /// Lap time of the source lap in milliseconds — used to compute the Δ
  /// column.
  final int sourceLapTimeMs;

  static final _dateFormat = DateFormat('d MMM');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (
      trackId: track.trackId,
      sourceSessionId: sourceSessionId,
      sourceLapNumber: sourceLapNumber,
    );
    final entriesAsync = ref.watch(compareEntriesProvider(args));

    return AlertDialog(
      title: Text('Compare with… (${track.name})'),
      content: SizedBox(
        width: 480,
        height: 420,
        child: entriesAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Could not load laps: $e')),
          data: (entries) {
            if (entries.isEmpty) {
              return const Center(
                child: Text(
                  'No other non-ignored laps on this track yet.',
                  textAlign: TextAlign.center,
                ),
              );
            }
            return _buildList(context, entries);
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildList(BuildContext context, List<ComparePickerEntry> entries) {
    final theme = Theme.of(context);
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        final delta = e.lapTimeMs - sourceLapTimeMs;
        final deltaStr = _formatDelta(delta);
        final deltaColor = delta < 0
            ? Colors.green
            : delta > 0
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant;

        return ListTile(
          leading: SizedBox(
            width: 44,
            child: Text('#${e.lapNumber}', style: theme.textTheme.bodySmall),
          ),
          title: Row(
            children: [
              Text(
                _formatLapTime(e.lapTimeMs),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(width: 8),
              Text(
                deltaStr,
                style: theme.textTheme.bodySmall?.copyWith(color: deltaColor),
              ),
            ],
          ),
          subtitle: Row(
            children: [
              Text(_dateFormat.format(e.localStart)),
              if (e.sessionTag.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.zero,
                  ),
                  child: Text(
                    e.sessionTag,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ],
          ),
          onTap: () => Navigator.of(context).pop(e),
        );
      },
    );
  }

  static String _formatLapTime(int ms) {
    final total = Duration(milliseconds: ms);
    final m = total.inMinutes;
    final s = total.inSeconds.remainder(60).toString().padLeft(2, '0');
    final tenths = ((ms % 1000) ~/ 100).toString();
    return '$m:$s.$tenths';
  }

  /// Formats a millisecond delta as `±M.SSS` for the Δ column. Uses 3
  /// decimal places so close laps show their fractional difference.
  static String _formatDelta(int ms) {
    final sign = ms < 0 ? '-' : '+';
    final abs = ms.abs();
    final whole = abs ~/ 1000;
    final frac = (abs % 1000).toString().padLeft(3, '0');
    return '$sign$whole.${frac}s';
  }
}

/// Args record for [compareEntriesProvider]. Keyed on the
/// `(trackId, sourceSessionId, sourceLapNumber)` triple so reopening the
/// dialog for a different lap returns a fresh provider instance.
typedef CompareEntriesArgs = ({
  String trackId,
  String sourceSessionId,
  int sourceLapNumber,
});

/// Async provider that walks every loaded session and emits the laps on
/// [CompareEntriesArgs.trackId] excluding the source lap and ignored laps.
/// Sorted by lap time ascending so the fastest comparison is on top.
final compareEntriesProvider =
    FutureProvider.family<List<ComparePickerEntry>, CompareEntriesArgs>(
        (ref, args) async {
  final sessions = ref.watch(sessionProvider).sessions;
  final tracksById = {
    for (final t in await ref.watch(trackProvider.future)) t.trackId: t,
  };
  final out = <ComparePickerEntry>[];

  for (final meta in sessions) {
    Workspace ws;
    try {
      ws = await ref.watch(
        sessionWorkspaceProvider(meta.sessionId).future,
      );
    } catch (_) {
      continue;
    }

    // Cached laps (§17.4), renumbered session-wide so `lapNumber` matches the
    // ignored set and the source lap (both session-wide). No session parse.
    for (final entry in cachedSessionLaps(ws, tracksById)) {
      if (entry.track?.trackId != args.trackId) continue;
      if (entry.isIgnored) continue;
      final lap = entry.lap;
      if (meta.sessionId == args.sourceSessionId &&
          lap.lapNumber == args.sourceLapNumber) {
        continue;
      }
      out.add(
        ComparePickerEntry(
          sessionId: meta.sessionId,
          lapNumber: lap.lapNumber,
          lapTimeMs: lap.lapTimeMs,
          localStart: DateTime.fromMillisecondsSinceEpoch(lap.startTimestampMs)
              .toLocal(),
          sessionTag: meta.tag,
        ),
      );
    }
  }

  out.sort((a, b) => a.lapTimeMs.compareTo(b.lapTimeMs));
  return out;
});
