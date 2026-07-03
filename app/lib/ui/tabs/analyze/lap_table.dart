import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/session_model.dart';
import '../../../data/workspace.dart';
import '../../../providers/lap_provider.dart';
import '../../../providers/selection_provider.dart';
import '../../../providers/session_provider.dart';
import '../../../providers/session_workspace_provider.dart';
import '../../brand/brand.dart';
import '../../widgets/mode_aware_checkbox.dart';

/// Formats [ms] as `mm:ss.sss`.
String _formatLapTime(int ms) {
  final minutes = ms ~/ 60000;
  final seconds = (ms % 60000) / 1000.0;
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toStringAsFixed(3).padLeft(6, '0')}';
}

/// Formats a signed delta in milliseconds as `+mm:ss.sss` / `−mm:ss.sss`.
String _formatDelta(int deltaMs) {
  final sign = deltaMs >= 0 ? '+' : '−';
  return '$sign${_formatLapTime(deltaMs.abs())}';
}

/// Brand-styled compact checkbox for the per-lap **M** (main) / **O** (overlay)
/// designation columns: a [brandGood] tick on selection, a [brandRule] hairline
/// outline when off, dark [brandBg] check glyph. Single-select semantics live
/// in the caller's toggle handler — this is purely the control's appearance.
Widget _designationCheckbox({
  required bool value,
  required ValueChanged<bool?> onChanged,
}) {
  return Checkbox(
    value: value,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    checkColor: brandBg,
    side: const BorderSide(color: brandRule, width: 1.5),
    fillColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.selected)) return brandGood;
      return Colors.transparent;
    }),
    onChanged: onChanged,
  );
}

// Reference resolution lives in lap_provider.dart as
// `resolveGhostReferenceLapNumber` — shared with `ghost_chart.dart`.

/// A per-session lap × sector data table shown below the chart list.
///
/// Reads laps from [sessionLapsProvider] and the workspace from
/// [sessionWorkspaceProvider] for each selected session. When no selected
/// session has any laps, shows a prompt directing the user to place a
/// start/finish gate on the GPS map. Each session with laps gets its own
/// section rendered as an [ExpansionTile] (collapsible when more than one
/// session is selected so the table stays manageable).
///
/// Per-row: lap number, lap time, delta to best lap, per-sector time and
/// delta to best sector ("theoretical-best-lap" colouring). Long-press a
/// row to set it as the ghost-timing reference; tapping the ghost icon
/// opens [GhostDeltaPage] for a target/reference comparison.
///
/// **Ignored laps** (added when worksheet feature shipped): the per-row
/// `Icons.block` toggle adds the lap to `Workspace.ignoredLapNumbers`.
/// Ignored laps stay in the table (greyed and struck through) but are
/// excluded from best-lap selection, Δ-sector colouring, and ghost-timing
/// reference. The worksheet-level "Show ignored" toggle (above the table)
/// hides them entirely when off — local widget state, not persisted.
///
/// See §14.3 and §21.3.
class LapTable extends ConsumerStatefulWidget {
  /// Creates a [LapTable].
  const LapTable({super.key});

  @override
  ConsumerState<LapTable> createState() => _LapTableState();
}

class _LapTableState extends ConsumerState<LapTable> {
  /// When `false`, ignored laps are filtered from the rendered list.
  ///
  /// Local widget state — not persisted. Default ON so users always see
  /// what's there before deciding to hide.
  bool _showIgnored = true;

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(sessionProvider).sessions;
    final selectedIds = ref.watch(effectiveSessionIdsProvider);

    if (selectedIds.isEmpty) return const SizedBox.shrink();

    final lapValues = {
      for (final id in selectedIds) id: ref.watch(sessionLapsProvider(id)),
    };

    // Empty-state — every session has either reported zero laps or is
    // still loading. Once at least one session has data, only sessions with
    // laps render below.
    final allEmpty = lapValues.values.every(
      (v) => v.whenOrNull(data: (laps) => laps.isEmpty) ?? false,
    );
    final anyLoaded = lapValues.values.any((v) => v.hasValue);

    if (anyLoaded && allEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'No laps detected — place a Start/Finish gate on the GPS map.',
          style: plexSans(fontSize: 13, color: brandFgDim),
        ),
      );
    }

    final sections = <Widget>[];
    final orderedIds = selectedIds.toList();
    final multiSession = selectedIds.length > 1;

    for (final id in orderedIds) {
      final meta = sessions.where((s) => s.sessionId == id).firstOrNull;
      final lapsValue = lapValues[id];
      if (lapsValue == null) continue;
      lapsValue.whenData((laps) {
        if (laps.isEmpty) return;
        sections.add(
          _SessionLapSection(
            sessionId: id,
            sessionLabel:
                meta != null ? _formatLabel(meta) : id.substring(0, 8),
            laps: laps,
            collapsible: multiSession,
            showIgnored: _showIgnored,
          ),
        );
      });
    }

    if (sections.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 4),
          child: Row(
            children: [
              Text(
                'LAPS',
                style: plexMono(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: brandFgDim,
                  letterSpacing: brandKickerTracking,
                ),
              ),
              const Spacer(),
              _ShowIgnoredToggle(
                value: _showIgnored,
                onChanged: (v) => setState(() => _showIgnored = v),
              ),
            ],
          ),
        ),
        ...sections,
      ],
    );
  }

  static String _formatLabel(SessionMetadata meta) {
    final dt = DateTime.fromMillisecondsSinceEpoch(
      meta.createdTimestampMs,
      isUtc: true,
    );
    final dateStr =
        '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    final timeStr =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return '$dateStr $timeStr UTC';
  }
}

/// Worksheet-level toggle: when off, ignored laps are filtered out of the
/// rendered list entirely.
class _ShowIgnoredToggle extends StatelessWidget {
  const _ShowIgnoredToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              value ? Icons.visibility : Icons.visibility_off,
              size: 16,
              color: value ? brandFgDim : brandFgFaint,
            ),
            const SizedBox(width: 5),
            Text(
              'SHOW IGNORED',
              style: plexMono(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: value ? brandFgDim : brandFgFaint,
                letterSpacing: brandLabelTracking,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One section showing laps for a single session. Collapsible when
/// [collapsible] is `true` (multi-session view).
class _SessionLapSection extends ConsumerWidget {
  const _SessionLapSection({
    required this.sessionId,
    required this.sessionLabel,
    required this.laps,
    required this.collapsible,
    required this.showIgnored,
  });

  final String sessionId;
  final String sessionLabel;
  final List<Lap> laps;
  final bool collapsible;
  final bool showIgnored;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wsValue = ref.watch(sessionWorkspaceProvider(sessionId));
    final referenceLapNumber = wsValue.whenOrNull(
      data: (ws) => ws.referenceLapNumber,
    );
    final ignored = wsValue.whenOrNull(
          data: (ws) => ws.ignoredLapNumbers,
        ) ??
        const <int>{};
    final mainLapNumber = wsValue.whenOrNull(
      data: (ws) => ws.mainLapNumber,
    );
    final overlayLapKey = wsValue.whenOrNull(
      data: (ws) => ws.overlayLapKey,
    );
    final starredLapNumber = wsValue.whenOrNull(
      data: (ws) => ws.starredLapNumber,
    );

    final visibleLaps = showIgnored
        ? laps
        : laps.where((l) => !ignored.contains(l.lapNumber)).toList();

    if (visibleLaps.isEmpty) return const SizedBox.shrink();

    final body = _LapDataTable(
      sessionId: sessionId,
      laps: visibleLaps,
      // Pass full lap list separately so the data table can compute "best of
      // non-ignored" using all laps, not just the visible ones — the result
      // must not change when the user flips the visibility toggle.
      allLaps: laps,
      ignored: ignored,
      pinnedReferenceLapNumber: referenceLapNumber,
      mainLapNumber: mainLapNumber,
      overlayLapKey: overlayLapKey,
      starredLapNumber: starredLapNumber,
    );

    final selection = ref.watch(selectionProvider);
    final isSessionChecked = selection.mode == SelectionMode.session &&
        selection.sessionIds.contains(sessionId);
    final sessionMuted = selection.mode == SelectionMode.lap;
    final sessionCheckbox = ModeAwareCheckbox(
      checked: isSessionChecked,
      muted: sessionMuted,
      tooltip: sessionMuted
          ? 'Tap to switch to session selection'
          : 'Toggle session selection',
      onToggle: () =>
          ref.read(selectionProvider.notifier).toggleSession(sessionId),
    );

    final overlayPickerButton = _OverlayFromOtherSessionButton(
      activeSessionId: sessionId,
    );

    if (!collapsible) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  sessionCheckbox,
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      sessionLabel,
                      overflow: TextOverflow.ellipsis,
                      style: plexMono(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: brandFg,
                        letterSpacing: brandLabelTracking,
                      ),
                    ),
                  ),
                  overlayPickerButton,
                ],
              ),
            ),
            body,
          ],
        ),
      );
    }

    return ExpansionTile(
      title: Row(
        children: [
          sessionCheckbox,
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              sessionLabel,
              overflow: TextOverflow.ellipsis,
              style: plexMono(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: brandFg,
                letterSpacing: brandLabelTracking,
              ),
            ),
          ),
          overlayPickerButton,
        ],
      ),
      initiallyExpanded: true,
      // Strip the default Material expand/collapse borders so the section
      // reads as a hairline-ruled brand block, not a boxed Material tile.
      shape: const Border(),
      collapsedShape: const Border(),
      iconColor: brandFgDim,
      collapsedIconColor: brandFgDim,
      backgroundColor: brandSurface2,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      children: [body],
    );
  }
}

/// Compact text button that opens the cross-session overlay picker for the
/// session whose lap section it lives on.
///
/// The picker is a two-stage dialog:
///  1. Choose a session — eligible candidates are sessions whose `.idl0w`
///     workspace contains a [TrackVisit] to one of the active session's
///     tracks. Filtering is lazy with a 5-second per-session timeout so a
///     missing or unreadable workspace can't hang the picker.
///  2. Choose a lap from that session — `setOverlayLap` is called with
///     `(sessionId: chosen.sessionId, lapNumber: chosen.lapNumber)`.
///
/// See lap-delta-rewrite §7.2.
class _OverlayFromOtherSessionButton extends ConsumerWidget {
  const _OverlayFromOtherSessionButton({required this.activeSessionId});

  /// Session this picker is targeting — the overlay it produces is written
  /// to *this* session's workspace via `setOverlayLap`.
  final String activeSessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextButton.icon(
      icon: const Icon(Icons.layers, size: 16),
      label: Text(
        'OVERLAY FROM…',
        style: plexMono(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          letterSpacing: brandLabelTracking,
        ),
      ),
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 28),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        foregroundColor: brandFgDim,
        visualDensity: VisualDensity.compact,
        shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.all(Radius.circular(brandControlRadiusSoft)),
        ),
      ),
      onPressed: () => _openPicker(context, ref),
    );
  }

  Future<void> _openPicker(BuildContext context, WidgetRef ref) async {
    final sessions = ref.read(sessionProvider).sessions;
    final activeWsValue = ref.read(sessionWorkspaceProvider(activeSessionId));
    final activeWs = activeWsValue.whenOrNull(data: (ws) => ws);
    final activeTrackIds =
        activeWs?.trackVisits.map((v) => v.trackId).toSet() ?? const <String>{};

    final candidates =
        sessions.where((s) => s.sessionId != activeSessionId).toList();

    // Filter to sessions whose workspace visits at least one of the active
    // session's tracks. Lazy + bounded-timeout per session so an unreadable
    // workspace can't hang the picker (this is the failure mode that hung
    // the earlier Re-derive picker — see lap-delta-rewrite §7.2).
    final eligible = <SessionMetadata>[];
    if (activeTrackIds.isEmpty) {
      // No tracks bound to the active session — show all candidates and let
      // the user pick. setOverlayLap doesn't require a shared track.
      eligible.addAll(candidates);
    } else {
      for (final meta in candidates) {
        try {
          final ws = await Workspace.load(meta.workspacePath)
              .timeout(const Duration(seconds: 5));
          final ids = ws.trackVisits.map((v) => v.trackId).toSet();
          if (ids.intersection(activeTrackIds).isNotEmpty) {
            eligible.add(meta);
          }
        } catch (_) {
          // Skip sessions whose workspace can't be loaded (missing file,
          // malformed JSON, or timeout). Falling back to "include anyway"
          // would clutter the list with sessions that almost certainly
          // can't share a track.
        }
      }
    }

    if (!context.mounted) return;

    if (eligible.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No other sessions visit this track.'),
        ),
      );
      return;
    }

    final pickedSession = await showDialog<SessionMetadata>(
      context: context,
      builder: (dialogContext) => _SessionPickerDialog(sessions: eligible),
    );
    if (pickedSession == null) return;
    if (!context.mounted) return;

    final lapsValue = ref.read(sessionLapsProvider(pickedSession.sessionId));
    final lapsList = lapsValue.whenOrNull(data: (laps) => laps);
    if (!context.mounted) return;

    if (lapsList == null || lapsList.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            lapsList == null
                ? 'Selected session is still loading laps — try again.'
                : 'Selected session has no laps.',
          ),
        ),
      );
      return;
    }

    final pickedLap = await showDialog<Lap>(
      context: context,
      builder: (dialogContext) => _LapPickerDialog(
        sessionLabel: _formatSessionLabel(pickedSession),
        laps: lapsList,
      ),
    );
    if (pickedLap == null) return;

    await ref
        .read(sessionWorkspaceProvider(activeSessionId).notifier)
        .setOverlayLap(
      (
        sessionId: pickedSession.sessionId,
        lapNumber: pickedLap.lapNumber,
      ),
    );
  }
}

/// Stage 1: list eligible sessions. Each row pops the dialog with the
/// chosen [SessionMetadata].
class _SessionPickerDialog extends StatelessWidget {
  const _SessionPickerDialog({required this.sessions});

  final List<SessionMetadata> sessions;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        'Pick overlay session',
        style: plexMono(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: brandFg,
        ),
      ),
      content: SizedBox(
        width: 360,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: sessions.length,
          itemBuilder: (_, i) {
            final meta = sessions[i];
            return ListTile(
              dense: true,
              title: Text(
                _formatSessionLabel(meta),
                style: plexMono(fontSize: 13, color: brandFg),
              ),
              onTap: () => Navigator.of(context).pop(meta),
            );
          },
        ),
      ),
      actions: [
        QuietButton(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

/// Stage 2: list laps in the picked session. Row pops with the chosen [Lap].
class _LapPickerDialog extends StatelessWidget {
  const _LapPickerDialog({required this.sessionLabel, required this.laps});

  final String sessionLabel;
  final List<Lap> laps;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        'Pick overlay lap — $sessionLabel',
        style: plexMono(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: brandFg,
        ),
      ),
      content: SizedBox(
        width: 360,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: laps.length,
          itemBuilder: (_, i) {
            final lap = laps[i];
            final seconds = (lap.lapTimeMs / 1000.0).toStringAsFixed(3);
            return ListTile(
              dense: true,
              title: Text(
                'Lap ${lap.lapNumber} — ${seconds}s',
                style: plexMono(fontSize: 13, color: brandFg),
              ),
              onTap: () => Navigator.of(context).pop(lap),
            );
          },
        ),
      ),
      actions: [
        QuietButton(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

/// Formats `"{rider || '(no rider)'} — {date}"` for the session picker row.
///
/// Date is rendered as `YYYY-MM-DD HH:MM UTC` to match other session labels
/// in the Analyze tab.
String _formatSessionLabel(SessionMetadata meta) {
  final rider = meta.rider.isEmpty ? '(no rider)' : meta.rider;
  final dt = DateTime.fromMillisecondsSinceEpoch(
    meta.createdTimestampMs,
    isUtc: true,
  );
  final dateStr =
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  final timeStr =
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  return '$rider — $dateStr $timeStr UTC';
}

/// The data table itself, isolated so it can rebuild on workspace changes
/// (e.g. setting reference lap, ignoring a lap) without rebuilding the
/// surrounding tile.
class _LapDataTable extends ConsumerWidget {
  const _LapDataTable({
    required this.sessionId,
    required this.laps,
    required this.allLaps,
    required this.ignored,
    required this.pinnedReferenceLapNumber,
    required this.mainLapNumber,
    required this.overlayLapKey,
    required this.starredLapNumber,
  });

  final String sessionId;

  /// Laps to render — already filtered by the [_SessionLapSection] for the
  /// "Show ignored" toggle.
  final List<Lap> laps;

  /// All laps for this session (incl. ignored). Used for sector-count and
  /// best-lap computations so values stay stable as the user toggles
  /// visibility.
  final List<Lap> allLaps;

  /// Ignored lap numbers from the workspace.
  final Set<int> ignored;

  /// User's pinned reference; null when no reference is pinned.
  final int? pinnedReferenceLapNumber;

  /// User-designated "main" lap of this session for variance math
  /// functions. Null when nothing is designated. See lap-delta-rewrite §7.
  final int? mainLapNumber;

  /// User-designated overlay lap (variance reference). May point at a
  /// different session — this widget renders the filled "O" indicator only
  /// when `overlayLapKey.sessionId == sessionId`.
  final ({String sessionId, int lapNumber})? overlayLapKey;

  /// User-designated "starred" (favourite) lap of this session. Null means
  /// auto-derive — the fastest non-ignored lap is shown as starred. See
  /// lap-delta-rewrite §7.3.
  final int? starredLapNumber;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eligibleLaps =
        allLaps.where((l) => !ignored.contains(l.lapNumber)).toList();
    final hasEligible = eligibleLaps.isNotEmpty;

    final bestLapMs = hasEligible
        ? eligibleLaps.map((l) => l.lapTimeMs).reduce((a, b) => a < b ? a : b)
        : null;

    final sectorCount =
        allLaps.map((l) => l.sectors.length).fold(0, (a, b) => a > b ? a : b);

    // Per-sector best — only across eligible (non-ignored) laps. Use a
    // sentinel so callers can detect "no eligible time" per slot.
    const noBest = -1;
    final bestSectorMs = List<int>.filled(sectorCount, noBest);
    for (final lap in eligibleLaps) {
      for (var s = 0; s < lap.sectors.length; s++) {
        final t = lap.sectors[s].sectorTimeMs;
        if (bestSectorMs[s] == noBest || t < bestSectorMs[s]) {
          bestSectorMs[s] = t;
        }
      }
    }

    final activeReferenceLapNumber = resolveGhostReferenceLapNumber(
      laps: allLaps,
      ignored: ignored,
      pinned: pinnedReferenceLapNumber,
    );

    // Effective starred lap: explicit pick when set + still valid, else the
    // fastest non-ignored lap (same fallback as the ghost reference, but
    // independent of pin). See lap-delta-rewrite §7.3.
    int? effectiveStarredLapNumber;
    if (starredLapNumber != null &&
        !ignored.contains(starredLapNumber) &&
        allLaps.any((l) => l.lapNumber == starredLapNumber)) {
      effectiveStarredLapNumber = starredLapNumber;
    } else if (hasEligible) {
      effectiveStarredLapNumber = eligibleLaps
          .reduce((a, b) => a.lapTimeMs <= b.lapTimeMs ? a : b)
          .lapNumber;
    }
    final isStarExplicit = starredLapNumber != null &&
        effectiveStarredLapNumber == starredLapNumber;

    // Re-theme the Material DataTable to the field-manual aesthetic: mono
    // tracked kicker headers, mono tabular data text, and hairline brandRule
    // dividers in place of the default faint-white Material rules. Per-cell
    // colours (deltas, best-row tint, star, etc.) override dataTextStyle where
    // they need a semantic colour.
    return Theme(
      data: Theme.of(context).copyWith(
        dividerColor: brandRule,
        dataTableTheme: DataTableThemeData(
          headingTextStyle: plexMono(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: brandFgDim,
            letterSpacing: brandLabelTracking,
          ),
          dataTextStyle: plexMono(fontSize: 12, color: brandFg),
          dividerThickness: brandHairlineWidth,
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columnSpacing: 12,
          headingRowHeight: 32,
          dataRowMinHeight: 32,
          dataRowMaxHeight: 40,
          columns: _columns(sectorCount),
          rows: [
            for (final lap in laps)
              _row(
                context,
                ref,
                lap,
                bestLapMs,
                bestSectorMs,
                activeReferenceLapNumber,
                eligibleLaps.length,
                effectiveStarredLapNumber,
                isStarExplicit,
              ),
          ],
        ),
      ),
    );
  }

  List<DataColumn> _columns(int sectorCount) {
    return [
      const DataColumn(label: SizedBox(width: 24)), // ignore toggle column
      const DataColumn(label: Text('M')), // main-lap designation (checkbox)
      const DataColumn(label: Text('O')), // overlay-lap designation (checkbox)
      const DataColumn(label: Text('Lap')),
      const DataColumn(label: Text('Time'), numeric: true),
      const DataColumn(label: Text('Δ Best'), numeric: true),
      for (var s = 1; s <= sectorCount; s++) ...[
        DataColumn(label: Text('S$s'), numeric: true),
        DataColumn(label: Text('Δ S$s'), numeric: true),
      ],
    ];
  }

  DataRow _row(
    BuildContext context,
    WidgetRef ref,
    Lap lap,
    int? bestLapMs,
    List<int> bestSectorMs,
    int? activeReferenceLapNumber,
    int eligibleCount,
    int? effectiveStarredLapNumber,
    bool isStarExplicit,
  ) {
    final isIgnored = ignored.contains(lap.lapNumber);
    final isBest =
        !isIgnored && bestLapMs != null && lap.lapTimeMs == bestLapMs;
    final isStarred = !isIgnored && effectiveStarredLapNumber == lap.lapNumber;
    // Flag is shown only for a *pinned* reference — when the user has not
    // pinned anything, the active reference equals the fastest lap (which
    // already gets the Star), so Flag would be redundant.
    final isPinnedReference = pinnedReferenceLapNumber != null &&
        lap.lapNumber == pinnedReferenceLapNumber &&
        !isIgnored;
    final ignoredTextStyle = isIgnored
        ? const TextStyle(
            decoration: TextDecoration.lineThrough,
            color: brandFgFaint,
          )
        : null;
    Widget ignoredCellStyle(Widget child) => DefaultTextStyle.merge(
          style: ignoredTextStyle ?? const TextStyle(),
          child: child,
        );

    final lapCellChildren = <Widget>[
      if (isPinnedReference)
        const Padding(
          padding: EdgeInsets.only(right: 4),
          child: Icon(
            Icons.flag,
            size: 14,
            color: brandInfo,
          ),
        ),
      // Interactive star: filled (gold) when this lap is the effective
      // starred lap (either explicit pick or auto-derived fastest). Tapping
      // toggles between explicit and auto-derive. Star is dimmer when the
      // designation is auto-derived to hint that it's a default. See
      // lap-delta-rewrite §7.3.
      _StarToggle(
        isStarred: isStarred,
        isExplicit: isStarred && isStarExplicit,
        lapNumber: lap.lapNumber,
        onToggle: () =>
            _toggleStar(ref, lap.lapNumber, isStarred && isStarExplicit),
      ),
      Text('${lap.lapNumber}'),
    ];

    final cells = <DataCell>[
      DataCell(
        IconButton(
          icon: Icon(
            isIgnored ? Icons.visibility_off : Icons.block,
            size: 16,
            color: isIgnored ? brandAccent : brandFgDim,
          ),
          tooltip: isIgnored ? 'Unignore lap' : 'Ignore lap',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          onPressed: () => _toggleIgnore(ref, lap.lapNumber, isIgnored),
        ),
      ),
      DataCell(_mainCell(context, ref, lap)),
      DataCell(_overlayCell(context, ref, lap)),
      DataCell(
        ignoredCellStyle(
          Row(mainAxisSize: MainAxisSize.min, children: lapCellChildren),
        ),
      ),
      DataCell(ignoredCellStyle(Text(_formatLapTime(lap.lapTimeMs)))),
      DataCell(_lapDeltaCell(context, lap, bestLapMs, isBest, isIgnored)),
      for (var s = 0; s < bestSectorMs.length; s++) ...[
        DataCell(
          ignoredCellStyle(
            Text(
              s < lap.sectors.length
                  ? _formatLapTime(lap.sectors[s].sectorTimeMs)
                  : '—',
            ),
          ),
        ),
        DataCell(
          _sectorDeltaCell(
            context,
            lap,
            s,
            bestSectorMs[s],
            isIgnored,
          ),
        ),
      ],
    ];

    return DataRow(
      color: isIgnored
          ? WidgetStateProperty.all(brandSurface2)
          : isBest
              ? WidgetStateProperty.all(
                  brandGood.withValues(alpha: 0.14),
                )
              : null,
      cells: cells,
      onLongPress: () => _showRowMenu(context, ref, lap, isPinnedReference),
    );
  }

  Widget _lapDeltaCell(
    BuildContext context,
    Lap lap,
    int? bestLapMs,
    bool isBest,
    bool isIgnored,
  ) {
    if (isIgnored || bestLapMs == null) {
      return Text(
        '—',
        style: TextStyle(
          color: brandFgFaint,
          decoration: isIgnored ? TextDecoration.lineThrough : null,
        ),
      );
    }
    if (isBest) {
      return const Text(
        '—',
        style: TextStyle(color: brandGood),
      );
    }
    final delta = lap.lapTimeMs - bestLapMs;
    return Text(
      _formatDelta(delta),
      style: TextStyle(color: delta < 0 ? brandGood : brandAccent),
    );
  }

  Widget _sectorDeltaCell(
    BuildContext context,
    Lap lap,
    int sectorIndex,
    int bestSectorMs,
    bool isIgnored,
  ) {
    if (sectorIndex >= lap.sectors.length) return const Text('—');
    if (isIgnored || bestSectorMs < 0) {
      return Text(
        '—',
        style: TextStyle(
          color: brandFgFaint,
          decoration: isIgnored ? TextDecoration.lineThrough : null,
        ),
      );
    }
    final t = lap.sectors[sectorIndex].sectorTimeMs;
    if (t == bestSectorMs) {
      return const Text(
        '—',
        style: TextStyle(color: brandGood),
      );
    }
    final delta = t - bestSectorMs;
    return Text(
      _formatDelta(delta),
      style: TextStyle(color: delta > 0 ? brandAccent : brandGood),
    );
  }

  /// "Main" checkbox. Checked when this lap is `workspace.mainLapNumber`.
  /// Single-select per session: tapping another row's checkbox moves the
  /// designation; tapping the active main clears it. Checkbox styling
  /// matches the Overlay column for visual consistency — the underlying
  /// semantics stay radio-style (only one M can be active at a time).
  Widget _mainCell(BuildContext context, WidgetRef ref, Lap lap) {
    final isMain = mainLapNumber == lap.lapNumber;
    return Tooltip(
      message: isMain ? 'Clear main lap' : 'Set lap ${lap.lapNumber} as main',
      child: _designationCheckbox(
        value: isMain,
        onChanged: (_) => _toggleMain(ref, lap.lapNumber, isMain),
      ),
    );
  }

  /// "Overlay" checkbox. Checked when `overlayLapKey` points at this
  /// session and this lap. Single-select per session (same semantics as
  /// the M column).
  Widget _overlayCell(BuildContext context, WidgetRef ref, Lap lap) {
    final overlay = overlayLapKey;
    final isOverlay = overlay != null &&
        overlay.sessionId == sessionId &&
        overlay.lapNumber == lap.lapNumber;
    return Tooltip(
      message: isOverlay
          ? 'Clear overlay lap'
          : 'Set lap ${lap.lapNumber} as overlay',
      child: _designationCheckbox(
        value: isOverlay,
        onChanged: (_) => _toggleOverlay(ref, lap.lapNumber, isOverlay),
      ),
    );
  }

  Future<void> _toggleMain(
    WidgetRef ref,
    int lapNumber,
    bool currentlyMain,
  ) async {
    final notifier = ref.read(
      sessionWorkspaceProvider(sessionId).notifier,
    );
    await notifier.setMainLap(currentlyMain ? null : lapNumber);
  }

  Future<void> _toggleOverlay(
    WidgetRef ref,
    int lapNumber,
    bool currentlyOverlay,
  ) async {
    final notifier = ref.read(
      sessionWorkspaceProvider(sessionId).notifier,
    );
    await notifier.setOverlayLap(
      currentlyOverlay ? null : (sessionId: sessionId, lapNumber: lapNumber),
    );
  }

  /// Toggle handler for the per-row star icon.
  ///
  /// When [currentlyExplicit] is true the star is on this lap because the
  /// user picked it (not because it's the auto-derived fastest) — tap clears
  /// the explicit pick and restores the auto-derive default. Otherwise the
  /// star is either off OR auto-derived onto this lap; tap promotes it to an
  /// explicit pick on this lap.
  Future<void> _toggleStar(
    WidgetRef ref,
    int lapNumber,
    bool currentlyExplicit,
  ) async {
    final notifier = ref.read(
      sessionWorkspaceProvider(sessionId).notifier,
    );
    await notifier.setStarredLap(currentlyExplicit ? null : lapNumber);
  }

  Future<void> _toggleIgnore(
    WidgetRef ref,
    int lapNumber,
    bool currentlyIgnored,
  ) async {
    final notifier = ref.read(
      sessionWorkspaceProvider(sessionId).notifier,
    );
    if (currentlyIgnored) {
      await notifier.unignoreLap(lapNumber);
    } else {
      await notifier.ignoreLap(lapNumber);
    }
  }

  void _showRowMenu(
    BuildContext context,
    WidgetRef ref,
    Lap lap,
    bool isReference,
  ) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return ColoredBox(
          color: brandSurface,
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(
                    isReference ? Icons.flag_outlined : Icons.flag,
                    color: brandInfo,
                  ),
                  title: Text(
                    isReference
                        ? 'Clear reference lap'
                        : 'Set lap ${lap.lapNumber} as reference',
                    style: plexMono(fontSize: 13, color: brandFg),
                  ),
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    final notifier = ref.read(
                      sessionWorkspaceProvider(sessionId).notifier,
                    );
                    await notifier.setReferenceLapNumber(
                      isReference ? null : lap.lapNumber,
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Compact tappable star used as the lap-row "starred lap" indicator.
///
/// Three visual states:
/// 1. Filled gold + full opacity → explicit user pick on this lap.
/// 2. Filled gold + dim (60% alpha) → auto-derived (this lap is the
///    fastest non-ignored, no user pick set).
/// 3. Outlined neutral → not the starred lap.
///
/// Tooltip differs between explicit and auto-derived so the user knows
/// whether tapping will clear (state 1) or promote (states 2 and 3).
/// See lap-delta-rewrite §7.3.
class _StarToggle extends StatelessWidget {
  const _StarToggle({
    required this.isStarred,
    required this.isExplicit,
    required this.lapNumber,
    required this.onToggle,
  });

  /// Whether the row this widget renders on is the effective starred lap
  /// (explicit OR auto-derived).
  final bool isStarred;

  /// True when the star landed here because the user picked it explicitly.
  /// False when it landed via the auto-derive fastest-non-ignored fallback.
  /// Only meaningful when [isStarred] is true.
  final bool isExplicit;

  final int lapNumber;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    // brandHivis is the field-manual "dash light" amber — full strength for an
    // explicit pick, dimmed when the star is the auto-derived fastest lap.
    final Color color;
    if (isStarred) {
      color = isExplicit ? brandHivis : brandHivis.withValues(alpha: 0.6);
    } else {
      color = brandFgDim;
    }
    final String tooltip;
    if (isStarred && isExplicit) {
      tooltip = 'Clear starred lap (auto-derive fastest)';
    } else if (isStarred) {
      tooltip = 'Auto-derived (fastest) — tap to set lap $lapNumber explicitly';
    } else {
      tooltip = 'Set lap $lapNumber as starred';
    }
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: IconButton(
        icon: Icon(
          isStarred ? Icons.star : Icons.star_border,
          size: 16,
          color: color,
        ),
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
        visualDensity: VisualDensity.compact,
        onPressed: onToggle,
      ),
    );
  }
}
