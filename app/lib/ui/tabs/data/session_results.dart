import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../data/track.dart';
import '../../../providers/data_results_provider.dart';
import '../../../providers/detail_selection_provider.dart';
import '../../../providers/runs_provider.dart';
import '../../../providers/selection_provider.dart';
import '../../../providers/session_workspace_provider.dart';
import '../../brand/brand.dart';
import '../../shell/adaptive_shell.dart';
import 'compare_with_picker.dart';

// ---------------------------------------------------------------------------
// Shared column geometry
// ---------------------------------------------------------------------------
//
// Every row (the pinned header, session rows, and lap sub-rows) lays its cells
// out on this one grid so values align vertically into scannable columns —
// the readability win over the old dot-joined run. Right-aligned numeric
// columns (laps / duration / best) keep tabular mono digits stacked.
//
// Leading gutter = checkbox + disclosure. The lap sub-row leaves the
// disclosure cell blank (a one-step indent) and puts its `Lap n` label in the
// TIME column, its time in the BEST column, and its actions in the trailing
// cell — so a session's best lap and each of its lap times share one column.

const double _cChk = 30; // selection checkbox gutter
const double _cChev = 26; // expand/collapse disclosure (blank on lap rows)
const double _cTime = 58; // session HH:mm / lap "Lap n"
const double _cLaps = 50; // lap count (wide only)
const double _cDur = 62; // total duration (wide only)
const double _cBest = 88; // session best lap / lap time
const double _cActions = 92; // per-lap action icons (blank on session rows)

/// Result-panel renderer for the Sessions view. Reads
/// [filteredSessionRowsProvider], groups rows by `(localDate, displayVenue)`,
/// and renders each group as an aligned, expandable table.
///
/// Layout: a pinned [TableHeader] (wide only) sits above a [ListView] of
/// collapsible `(date · venue)` blocks. Each session is a [DenseRow] whose
/// cells follow the shared column geometry above; expanding a session reveals
/// its laps as recessed sub-rows on the same grid.
///
/// Behaviour is unchanged from the pre-table tree: the checkbox toggles
/// `selectionProvider` (session- or lap-mode, XOR); the chevron expands; the
/// row body opens the session detail via [detailSelectionProvider]; the venue
/// in the group header opens the venue card; per-lap Compare-with and
/// Ignore/Restore are preserved.
class SessionResults extends ConsumerWidget {
  /// Creates a [SessionResults].
  const SessionResults({super.key});

  static final _dayFormat = DateFormat('EEEE · yyyy-MM-dd');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rowsAsync = ref.watch(filteredSessionRowsProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Wide enough for the laps/duration columns + a usable SESSION column.
        final wide = constraints.maxWidth >= 620;
        return rowsAsync.when(
          loading: () => const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: brandFgDim,
              ),
            ),
          ),
          error: (e, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Could not load sessions: $e',
                textAlign: TextAlign.center,
                style: plexMono(fontSize: 13, color: brandAccent),
              ),
            ),
          ),
          data: (rows) {
            if (rows.isEmpty) return const _EmptyState();

            // Group by (localDate, displayVenue) — the venue falls back to a
            // matched Track's venue when the session has no explicit
            // venueName, mirroring the venue-facet match semantics (see
            // SessionRow.displayVenueName).
            final byDateVenue = <_DayVenueKey, List<SessionRow>>{};
            for (final r in rows) {
              final key = _DayVenueKey(r.localDate, r.displayVenueName);
              byDateVenue.putIfAbsent(key, () => []).add(r);
            }
            // Group order follows the active sort. `byDateVenue` is a
            // LinkedHashMap filled by iterating the already-sorted `rows`, so
            // its keys are in sorted-first-appearance order — the day holding
            // the top-ranked session leads. (Previously this re-sorted keys by
            // date-descending, which overrode every non-date sort and made the
            // Date direction toggle a no-op.)
            final keys = byDateVenue.keys.toList();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide) const _SessionTableHeader(),
                Expanded(
                  child: ListView.builder(
                    itemCount: keys.length,
                    itemBuilder: (context, i) {
                      final key = keys[i];
                      return _DayVenueBlock(
                        date: key.date,
                        venue: key.venue,
                        rows: byDateVenue[key]!,
                        format: SessionResults._dayFormat,
                        wide: wide,
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Pinned column header
// ---------------------------------------------------------------------------

/// The aligned column header shown above the Sessions table (wide layout).
/// Its cell widths match the [DenseRow] session rows so the labels sit over
/// their columns.
class _SessionTableHeader extends StatelessWidget {
  const _SessionTableHeader();

  @override
  Widget build(BuildContext context) {
    return TableHeader(
      children: [
        const SizedBox(width: _cChk),
        const SizedBox(width: _cChev),
        SizedBox(width: _cTime, child: TableHeader.headerCell('Time')),
        Expanded(child: TableHeader.headerCell('Session')),
        SizedBox(
          width: _cLaps,
          child: TableHeader.headerCell('Laps', right: true),
        ),
        SizedBox(
          width: _cDur,
          child: TableHeader.headerCell('Dur', right: true),
        ),
        SizedBox(
          width: _cBest,
          child: TableHeader.headerCell('Best', right: true),
        ),
        const SizedBox(width: _cActions),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Brand selection checkbox + small cell helpers
// ---------------------------------------------------------------------------

/// Compact brand-styled selection checkbox shared by session and lap rows.
///
/// [activeMode] is whether this checkbox's selection mode (session or lap) is
/// the one currently held by `selectionProvider`. When `false` the box reads
/// as recessed ([brandControlFill] fill, [brandRule] outline) so the inactive
/// axis of the XOR selection is visually muted; tapping it still works (it
/// flips the active mode, preserving the legacy toggle behaviour). When
/// `true` and selected it fills with [brandGood].
Widget _selectCheckbox({
  required bool value,
  required bool activeMode,
  required ValueChanged<bool?> onChanged,
}) {
  return Checkbox(
    value: value,
    tristate: false,
    onChanged: onChanged,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    checkColor: brandBg,
    side: BorderSide(
      color: activeMode ? brandFgDim : brandRule,
      width: 1.5,
    ),
    fillColor: WidgetStateProperty.resolveWith((states) {
      if (!activeMode) return brandControlFill;
      if (states.contains(WidgetState.selected)) return brandGood;
      return Colors.transparent;
    }),
  );
}

/// A fixed-width, right-aligned numeric cell (mono, tabular). Used for the
/// laps / duration / best columns so digits stack vertically.
Widget _numCell(
  double width,
  String text, {
  Color color = brandFgDim,
  FontWeight weight = FontWeight.w400,
  TextDecoration decoration = TextDecoration.none,
}) {
  return SizedBox(
    width: width,
    child: Text(
      text,
      textAlign: TextAlign.right,
      overflow: TextOverflow.ellipsis,
      style: plexMono(fontSize: 12.5, color: color, fontWeight: weight)
          .copyWith(decoration: decoration),
    ),
  );
}

// ---------------------------------------------------------------------------
// (date, venue) composite key
// ---------------------------------------------------------------------------

class _DayVenueKey {
  final DateTime date;
  final String venue;

  const _DayVenueKey(this.date, this.venue);

  @override
  int get hashCode => Object.hash(date, venue);

  @override
  bool operator ==(Object other) =>
      other is _DayVenueKey && other.date == date && other.venue == venue;
}

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

class _EmptyState extends ConsumerWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filtersActive = ref.watch(filteredSessionRowsProvider);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.search_off, size: 36, color: brandFgFaint),
          const SizedBox(height: 10),
          Text(
            filtersActive.value?.isEmpty ?? true
                ? 'No sessions yet. Import your first .idl0 or .gpx file.'
                : 'No matches. Try clearing filters.',
            textAlign: TextAlign.center,
            style: plexSans(fontSize: 13, color: brandFgDim),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Date · Venue heading block (collapsible)
// ---------------------------------------------------------------------------

/// One collapsible block for a `(date, venue)` combination.
///
/// The header bar has two independent tappable zones:
/// - The venue text (rendered bright with an underline) calls
///   `detailSelectionProvider.notifier.showVenue` so the right-pane detail
///   card opens.
/// - The rest of the bar toggles expand/collapse.
class _DayVenueBlock extends ConsumerStatefulWidget {
  const _DayVenueBlock({
    required this.date,
    required this.venue,
    required this.rows,
    required this.format,
    required this.wide,
  });

  final DateTime date;
  final String venue;
  final List<SessionRow> rows;
  final DateFormat format;
  final bool wide;

  @override
  ConsumerState<_DayVenueBlock> createState() => _DayVenueBlockState();
}

class _DayVenueBlockState extends ConsumerState<_DayVenueBlock> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final venueLabel = widget.venue.isEmpty ? '(no venue)' : widget.venue;
    final count = widget.rows.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: const BoxDecoration(
              color: brandSurface2,
              border: Border(
                bottom:
                    BorderSide(color: brandRule, width: brandHairlineWidth),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 16,
                  color: brandFgDim,
                ),
                const SizedBox(width: 6),
                Text(
                  widget.format.format(widget.date).toUpperCase(),
                  style: plexMono(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: brandFg,
                    letterSpacing: brandLabelTracking,
                  ),
                ),
                Text(
                  '  ·  ',
                  style: plexMono(fontSize: 12, color: brandFgFaint),
                ),
                Flexible(
                  child: GestureDetector(
                    onTap: () => ref
                        .read(detailSelectionProvider.notifier)
                        .showVenue(widget.venue),
                    child: Text(
                      venueLabel.toUpperCase(),
                      overflow: TextOverflow.ellipsis,
                      style: plexMono(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: brandFg,
                        letterSpacing: brandLabelTracking,
                      ).copyWith(decoration: TextDecoration.underline),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '· $count',
                  style: plexMono(fontSize: 11, color: brandFgDim),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          for (final row in widget.rows)
            _SessionRowTile(
              key: ValueKey(row.meta.sessionId),
              row: row,
              wide: widget.wide,
            ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Session row tile + lap rows
// ---------------------------------------------------------------------------

class _SessionRowTile extends ConsumerStatefulWidget {
  const _SessionRowTile({super.key, required this.row, required this.wide});

  final SessionRow row;
  final bool wide;

  @override
  ConsumerState<_SessionRowTile> createState() => _SessionRowTileState();
}

class _SessionRowTileState extends ConsumerState<_SessionRowTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final wide = widget.wide;
    final selection = ref.watch(selectionProvider);
    final inSessionMode = selection.mode == SelectionMode.session;
    final sessionSelected = selection.sessionIds.contains(row.meta.sessionId);
    // Per-row rescan spinner. Watched via .select so only the row currently
    // being scanned rebuilds — the results list itself does not refresh.
    final scanning = ref.watch(
      rescanProgressProvider.select((p) => p.isScanning(row.meta.sessionId)),
    );

    final time = DateFormat('HH:mm').format(
      DateTime.fromMillisecondsSinceEpoch(row.meta.createdTimestampMs),
    );
    final dur = row.meta.durationMs != null
        ? _formatDuration(row.meta.durationMs!)
        : '—';

    // SESSION column: bike · [tag] · tracks. On narrow layouts the laps and
    // duration (their own columns when wide) fold in here as a dim tail so no
    // data is lost.
    final descParts = <String>[
      if (row.meta.bike.isNotEmpty) row.meta.bike,
      if (row.meta.tag.isNotEmpty) '[${row.meta.tag}]',
      _trackInline(row),
      if (!wide) '${row.laps.length} laps',
      if (!wide && row.meta.durationMs != null) dur,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DenseRow(
          selected: inSessionMode && sessionSelected,
          onTap: () => ref
              .read(detailSelectionProvider.notifier)
              .showSession(row.meta.sessionId),
          children: [
            SizedBox(
              width: _cChk,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _selectCheckbox(
                  value: inSessionMode && sessionSelected,
                  activeMode: inSessionMode,
                  onChanged: (_) => ref
                      .read(selectionProvider.notifier)
                      .toggleSession(row.meta.sessionId),
                ),
              ),
            ),
            // Chevron: independent expand/collapse tap target.
            SizedBox(
              width: _cChev,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _expanded = !_expanded),
                child: Icon(
                  _expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 18,
                  color: brandFgDim,
                ),
              ),
            ),
            SizedBox(
              width: _cTime,
              child: Text(
                time,
                style: plexMono(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: brandFg,
                ),
              ),
            ),
            Expanded(
              child: Text(
                descParts.join('  ·  '),
                overflow: TextOverflow.ellipsis,
                style: plexMono(fontSize: 12.5, color: brandFgDim),
              ),
            ),
            if (wide) _numCell(_cLaps, '${row.laps.length}'),
            if (wide) _numCell(_cDur, dur),
            _numCell(
              _cBest,
              row.bestLapMs != null ? _formatLap(row.bestLapMs!) : '—',
              color: row.bestLapMs != null ? brandGood : brandFgFaint,
              weight: FontWeight.w600,
            ),
            SizedBox(
              width: _cActions,
              child: scanning
                  ? const Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: EdgeInsets.only(right: 6),
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: brandInfo,
                          ),
                        ),
                      ),
                    )
                  : null,
            ),
          ],
        ),
        if (_expanded)
          for (final lap in row.laps)
            _LapRow(row: row, lap: lap, wide: wide),
        const Divider(
          height: 1,
          thickness: brandHairlineWidth,
          color: brandRule,
        ),
      ],
    );
  }

  /// Builds a compact track name list: `name1, name2 +K more` (Q3 Option B).
  ///
  /// Distinct track names are gathered in lap order, duplicates suppressed.
  /// At most two names are shown inline; additional names are collapsed to
  /// `+K more`.  Returns `(no tracks)` when no laps have a matched Track.
  String _trackInline(SessionRow row) {
    final names = <String>[];
    final seen = <String>{};
    for (final l in row.laps) {
      final n = l.track?.name;
      if (n == null || n.isEmpty || seen.contains(n)) continue;
      seen.add(n);
      names.add(n);
    }
    if (names.isEmpty) return '(no tracks)';
    if (names.length <= 2) return names.join(', ');
    return '${names.take(2).join(', ')} +${names.length - 2} more';
  }

  static String _formatDuration(int ms) {
    final total = Duration(milliseconds: ms);
    final m = total.inMinutes;
    final s = total.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  static String _formatLap(int ms) {
    final m = ms ~/ 60000;
    final s = (ms ~/ 1000) % 60;
    final tenths = (ms % 1000) ~/ 100;
    return '$m:${s.toString().padLeft(2, '0')}.$tenths';
  }
}

class _LapRow extends ConsumerWidget {
  const _LapRow({required this.row, required this.lap, required this.wide});

  final SessionRow row;
  final SessionRowLap lap;
  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(selectionProvider);
    final inLapMode = selection.mode == SelectionMode.lap;
    final lapKey =
        LapKey(sessionId: row.meta.sessionId, lapNumber: lap.lap.lapNumber);
    final lapSelected = selection.lapKeys.contains(lapKey);

    final lapColor = lap.isIgnored ? brandFgFaint : brandFg;
    final lapDeco =
        lap.isIgnored ? TextDecoration.lineThrough : TextDecoration.none;
    final lapStyle = plexMono(fontSize: 12.5, color: lapColor)
        .copyWith(decoration: lapDeco);

    return Container(
      // Recessed sub-row; left/right padding matches DenseRow's 16 px content
      // inset (3 px reserved border + 13 px pad) so cells align with sessions.
      color: brandSurface2,
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
      child: Row(
        children: [
          SizedBox(
            width: _cChk,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _selectCheckbox(
                value: inLapMode && lapSelected,
                activeMode: inLapMode,
                onChanged: (_) =>
                    ref.read(selectionProvider.notifier).toggleLap(lapKey),
              ),
            ),
          ),
          // Disclosure column left blank — the one-step indent for laps.
          const SizedBox(width: _cChev),
          SizedBox(
            width: _cTime,
            child: Text('Lap ${lap.lap.lapNumber}', style: lapStyle),
          ),
          Expanded(
            child: Text(
              lap.track?.name ?? '',
              overflow: TextOverflow.ellipsis,
              style: lapStyle.copyWith(color: brandFgDim),
            ),
          ),
          if (wide) const SizedBox(width: _cLaps),
          if (wide) const SizedBox(width: _cDur),
          _numCell(
            _cBest,
            _formatLap(lap.lap.lapTimeMs),
            color: lapColor,
            weight: FontWeight.w500,
            decoration: lapDeco,
          ),
          SizedBox(
            width: _cActions,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (lap.isSessionBest)
                  const Padding(
                    padding: EdgeInsets.only(right: 2),
                    child: Icon(Icons.star, size: 14, color: brandGood),
                  ),
                IconButton(
                  tooltip: 'Compare with…',
                  icon: const Icon(Icons.compare_arrows, size: 16),
                  color: brandFgDim,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 30, minHeight: 30),
                  onPressed: lap.track == null
                      ? null
                      : () => _onCompare(context, ref, lap.track!),
                ),
                IconButton(
                  tooltip: lap.isIgnored ? 'Restore lap' : 'Ignore lap',
                  icon: Icon(
                    lap.isIgnored
                        ? Icons.visibility_off_outlined
                        : Icons.block,
                    size: 16,
                  ),
                  color: brandFgDim,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 30, minHeight: 30),
                  onPressed: () => _toggleIgnore(ref),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleIgnore(WidgetRef ref) async {
    final notifier =
        ref.read(sessionWorkspaceProvider(row.meta.sessionId).notifier);
    if (lap.isIgnored) {
      await notifier.unignoreLap(lap.lap.lapNumber);
    } else {
      await notifier.ignoreLap(lap.lap.lapNumber);
    }
  }

  Future<void> _onCompare(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) async {
    final picked = await showDialog<ComparePickerEntry>(
      context: context,
      builder: (_) => CompareWithPicker(
        track: track,
        sourceSessionId: row.meta.sessionId,
        sourceLapNumber: lap.lap.lapNumber,
        sourceLapTimeMs: lap.lap.lapTimeMs,
      ),
    );
    if (picked == null || !context.mounted) return;

    // Select the source session, then set main = source lap and overlay =
    // the picked lap. The Analyze tab's variance + auto-scope rendering
    // picks up the M/O pair automatically. Replaces the legacy ghost-chart
    // wiring path.
    ref.read(selectionProvider.notifier).selectMany(
      sessions: {row.meta.sessionId, picked.sessionId},
    );

    final sourceWorkspaceNotifier = ref.read(
      sessionWorkspaceProvider(row.meta.sessionId).notifier,
    );
    await sourceWorkspaceNotifier.setMainLap(lap.lap.lapNumber);
    await sourceWorkspaceNotifier.setOverlayLap(
      (sessionId: picked.sessionId, lapNumber: picked.lapNumber),
    );

    ref.read(shellIndexProvider.notifier).state = 3;

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Comparing Lap ${lap.lap.lapNumber} vs Lap ${picked.lapNumber}',
        ),
      ),
    );
  }

  static String _formatLap(int ms) {
    final m = ms ~/ 60000;
    final s = (ms ~/ 1000) % 60;
    final tenths = (ms % 1000) ~/ 100;
    return '$m:${s.toString().padLeft(2, '0')}.$tenths';
  }
}
