import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/data_filters_provider.dart';
import '../../../providers/data_results_provider.dart';
import '../../../providers/detail_selection_provider.dart';
import '../../../providers/drive_sync_provider.dart';
import '../../../providers/runs_provider.dart';
import '../../../providers/selection_provider.dart';
import '../../../providers/session_provider.dart';
import '../../brand/brand.dart';
import '../../shell/adaptive_shell.dart';
import 'data_detail_pane.dart';
import 'filter_rail.dart';
import 'session_results.dart';
import 'track_results.dart';

/// Tab 2 — Data. See `docs/IDL0_SPEC.md §15.3`.
///
/// McMaster-style faceted search: a filter rail (or bottom-sheet on
/// narrow widths) drives [filteredSessionRowsProvider] and
/// [filteredTrackRowsProvider], rendered in either the Sessions tree or
/// Tracks table. Drive status is a compact icon in the results toolbar
/// (`_DriveStatusIcon`) with sign-in/out in the toolbar overflow menu.
///
/// Watching [sessionIndexLoaderProvider] here triggers the initial load
/// of all sessions from the SQLite index into [sessionProvider] on first
/// build.
class DataTab extends ConsumerWidget {
  /// Creates a [DataTab].
  const DataTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(sessionIndexLoaderProvider);
    final width = MediaQuery.sizeOf(context).width;
    final isWide = width >= 720;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Drive no longer gets its own row: its status is a compact icon in the
        // results toolbar and sign-in/out lives in the toolbar overflow menu, on
        // both layouts.
        Expanded(
          child: isWide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(width: 280, child: FilterRail()),
                    const VerticalDivider(width: 1),
                    const Expanded(child: _ResultsPanel()),
                    Consumer(
                      builder: (context, ref, _) {
                        final sel = ref.watch(detailSelectionProvider);
                        if (sel.kind == DetailKind.none) {
                          return const SizedBox.shrink();
                        }
                        return const Row(
                          children: [
                            VerticalDivider(width: 1),
                            SizedBox(width: 320, child: DataDetailPane()),
                          ],
                        );
                      },
                    ),
                  ],
                )
              : const _NarrowResultsAndSheet(),
        ),
        if (!isWide) const _MobileFilterBar(),
        const _AnalyzeLauncher(),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Narrow layout — results + detail bottom sheet
// ---------------------------------------------------------------------------

/// On narrow widths (< 720 px) renders [_ResultsPanel] and opens [DataDetailPane]
/// as a modal bottom sheet whenever [detailSelectionProvider] becomes non-none.
/// Clears the provider when the sheet is dismissed so re-tapping the same row
/// reopens it. See `docs/IDL0_SPEC.md §24`.
class _NarrowResultsAndSheet extends ConsumerStatefulWidget {
  const _NarrowResultsAndSheet();

  @override
  ConsumerState<_NarrowResultsAndSheet> createState() =>
      _NarrowResultsAndSheetState();
}

class _NarrowResultsAndSheetState
    extends ConsumerState<_NarrowResultsAndSheet> {
  @override
  Widget build(BuildContext context) {
    ref.listen(detailSelectionProvider, (prev, next) async {
      if (next.kind == DetailKind.none) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (sheetCtx) {
          // Size the sheet to most of the screen (not a fixed half) and lift it
          // above the soft keyboard: `viewInsets.bottom` pads the content up by
          // the keyboard height, and the body height shrinks by the same amount
          // so the focused field stays visible while editing. See §24.2.
          final media = MediaQuery.of(sheetCtx);
          final available = media.size.height * 0.92 - media.viewInsets.bottom;
          return Padding(
            padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
            child: SizedBox(
              height: available > 280 ? available : media.size.height * 0.5,
              child: const DataDetailPane(),
            ),
          );
        },
      );
      if (mounted) {
        ref.read(detailSelectionProvider.notifier).clear();
      }
    });
    return const _ResultsPanel();
  }
}

// ---------------------------------------------------------------------------
// Results panel — top toolbar + active chip row + body
// ---------------------------------------------------------------------------

class _ResultsPanel extends ConsumerWidget {
  const _ResultsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(dataFiltersProvider);
    final width = MediaQuery.sizeOf(context).width;
    final isNarrow = width < 720;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Toolbar(isNarrow: isNarrow),
        if (filters.hasAnyActiveFilter) const _ActiveChipRow(),
        Expanded(
          child: filters.view == DataView.tracks
              ? const TrackResults()
              : const SessionResults(),
        ),
      ],
    );
  }
}

/// The Data results toolbar: search + view toggle + sort + actions.
///
/// **Wide** lays every control out in one [Wrap] with full text labels, plus a
/// compact Drive-status icon and an overflow `⋮` (Drive sign-in/out only — the
/// rescans are visible buttons here). **Narrow** compacts to two short rows —
/// search (+ Drive status icon + the overflow `⋮`) on top, then the view
/// toggle, sort, and an icon-only Import below — moving the infrequent Rescan
/// and Drive actions into the overflow menu so the toolbar no longer stacks
/// five button rows on a phone.
class _Toolbar extends ConsumerWidget {
  const _Toolbar({required this.isNarrow});

  final bool isNarrow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (isNarrow) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: _SearchField()),
                SizedBox(width: 4),
                _DriveStatusIcon(),
                _ToolbarOverflowMenu(),
              ],
            ),
            SizedBox(height: 8),
            Row(
              children: [
                _ViewToggle(),
                SizedBox(width: 8),
                _SortControl(),
                Spacer(),
                _ImportButton(compact: true),
              ],
            ),
          ],
        ),
      );
    }

    return const Padding(
      padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(width: 240, child: _SearchField()),
          _ViewToggle(),
          _SortControl(),
          _ImportButton(),
          _RescanVisitsButton(),
          _RescanFromDiskButton(),
          _DriveStatusIcon(),
          // Rescans are already visible buttons on wide, so the overflow
          // carries only Drive sign-in/out here.
          _ToolbarOverflowMenu(includeRescans: false),
        ],
      ),
    );
  }
}

/// The faceted-search text field. Width is set by the caller (a [SizedBox] on
/// wide, [Expanded] on narrow); this widget supplies only the field itself.
class _SearchField extends ConsumerWidget {
  const _SearchField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(dataFiltersProvider);
    final notifier = ref.read(dataFiltersProvider.notifier);
    final searchAvailable = filters.searchText.isNotEmpty;
    return TextField(
      decoration: InputDecoration(
        hintText: 'Search…',
        isDense: true,
        prefixIcon: const Icon(Icons.search, size: 18),
        suffixIcon: searchAvailable
            ? IconButton(
                icon: const Icon(Icons.close, size: 16),
                onPressed: () => notifier.setSearchText(''),
              )
            : null,
        border: const OutlineInputBorder(),
      ),
      controller: TextEditingController(text: filters.searchText)
        ..selection = TextSelection.collapsed(
          offset: filters.searchText.length,
        ),
      onChanged: notifier.setSearchText,
    );
  }
}

/// Sessions ⇄ Tracks view toggle. `showSelectedIcon: false` drops the M3
/// selected-state check (which widened the active segment and pushed "Sessions"
/// onto a second line), and `maxLines: 1` keeps each label on one row.
class _ViewToggle extends ConsumerWidget {
  const _ViewToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(dataFiltersProvider.select((f) => f.view));
    final notifier = ref.read(dataFiltersProvider.notifier);
    return SegmentedButton<DataView>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(
          value: DataView.sessions,
          icon: Icon(Icons.list_alt),
          label: Text('Sessions', maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        ButtonSegment(
          value: DataView.tracks,
          icon: Icon(Icons.terrain),
          label: Text('Tracks', maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
      selected: {view},
      onSelectionChanged: (s) => notifier.setView(s.first),
    );
  }
}

/// Import button. [compact] renders an icon-only [IconButton] (narrow toolbar);
/// otherwise an [OutlinedButton.icon] with a text label (wide toolbar).
class _ImportButton extends ConsumerWidget {
  const _ImportButton({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> run() async {
      final messenger = ScaffoldMessenger.of(context);
      final res = await ref.read(runsProvider.notifier).importFiles();
      if (res.imported == 0 && res.failed.isEmpty) return;
      final msg = res.failed.isEmpty
          ? 'Imported ${res.imported} file${res.imported == 1 ? '' : 's'}'
          : 'Imported ${res.imported}, failed: ${res.failed.join(', ')}';
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    }

    if (compact) {
      return IconButton(
        tooltip: 'Import .idl0 / .gpx files',
        icon: const Icon(Icons.upload_file, size: 20),
        onPressed: run,
      );
    }
    return OutlinedButton.icon(
      icon: const Icon(Icons.upload_file, size: 18),
      label: const Text('Import'),
      onPressed: run,
    );
  }
}

/// Compact Drive sign-in status as a single icon (narrow toolbar). Green
/// `cloud_done` (green) when signed in, dim `cloud_off` otherwise, with a
/// spinner while a sign-in is in flight.
///
/// When **signed out** the icon is the live sign-in affordance — tapping it
/// runs the real interactive Drive sign-in (`DriveSyncNotifier.signIn`). When
/// **signed in** it is a status-only indicator (sign-out lives in
/// [_ToolbarOverflowMenu]).
class _DriveStatusIcon extends ConsumerWidget {
  const _DriveStatusIcon();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drive = ref.watch(driveSyncProvider);

    if (drive.isSigningIn) {
      return const Tooltip(
        message: 'Signing in to Drive…',
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
        ),
      );
    }

    if (drive.isSignedIn) {
      // Status only — sign-out lives in the overflow menu.
      return Tooltip(
        message: 'Drive — ${drive.accountEmail ?? 'signed in'}',
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Icon(Icons.cloud_done_outlined, size: 20, color: brandGood),
        ),
      );
    }

    // Signed out — tap to start the real interactive sign-in flow.
    return IconButton(
      tooltip: 'Drive — not signed in (tap to sign in)',
      icon: const Icon(Icons.cloud_off_outlined, size: 20, color: brandFgDim),
      onPressed: () => ref.read(driveSyncProvider.notifier).signIn(),
    );
  }
}

/// Actions the toolbar tucks into the `⋮` overflow menu: Drive sign-in/out,
/// the two (infrequent) rescans, and the one-time timestamp/filename repair.
enum _OverflowAction { drive, rescanVisits, rescanDisk, repairNames }

/// The narrow-toolbar `⋮` menu hosting Drive sign-in/out and the rescans.
/// Progress is surfaced via [SnackBar] (a popup menu has no room for the inline
/// spinners the wide-layout [_RescanVisitsButton] / [_RescanFromDiskButton]
/// show).
class _ToolbarOverflowMenu extends ConsumerWidget {
  const _ToolbarOverflowMenu({this.includeRescans = true});

  /// Whether the rescan actions are listed here. False on wide, where the
  /// rescans are already shown as their own buttons.
  final bool includeRescans;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signedIn = ref.watch(driveSyncProvider.select((s) => s.isSignedIn));
    return PopupMenuButton<_OverflowAction>(
      tooltip: 'More actions',
      icon: const Icon(Icons.more_vert),
      position: PopupMenuPosition.under,
      onSelected: (a) => _handle(context, ref, a),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: _OverflowAction.drive,
          child: Text(signedIn ? 'Sign out of Drive' : 'Sign in to Drive'),
        ),
        if (includeRescans) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: _OverflowAction.rescanVisits,
            child: Text('Rescan visits'),
          ),
          const PopupMenuItem(
            value: _OverflowAction.rescanDisk,
            child: Text('Rescan disk'),
          ),
        ],
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _OverflowAction.repairNames,
          child: Text('Repair timestamps & names'),
        ),
      ],
    );
  }

  Future<void> _handle(
    BuildContext context,
    WidgetRef ref,
    _OverflowAction action,
  ) async {
    // Capture context-bound handles up front — the awaits below outlive this
    // widget's element, so reaching back through `context`/`ref` afterwards
    // would be unsafe.
    final messenger = ScaffoldMessenger.of(context);
    final runs = ref.read(runsProvider.notifier);
    switch (action) {
      case _OverflowAction.drive:
        // Real interactive sign-in / sign-out (mirrors the Settings Drive row).
        final drive = ref.read(driveSyncProvider.notifier);
        if (ref.read(driveSyncProvider).isSignedIn) {
          await drive.signOut();
        } else {
          await drive.signIn();
        }
      case _OverflowAction.rescanVisits:
        messenger.showSnackBar(
          const SnackBar(content: Text('Rescanning visits…')),
        );
        final result = await runs.rescanAllTrackVisits();
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              result.failed == 0
                  ? 'Rescanned ${result.rescanned} sessions'
                  : 'Rescanned ${result.rescanned}, ${result.failed} failed'
                      '${result.firstError != null ? ' — ${result.firstError}' : ''}',
            ),
            duration: result.failed == 0
                ? const Duration(seconds: 4)
                : const Duration(seconds: 12),
          ),
        );
      case _OverflowAction.rescanDisk:
        messenger.showSnackBar(
          const SnackBar(content: Text('Rescanning disk…')),
        );
        final result = await runs.rescanSessionsFromDisk();
        final parts = <String>[
          if (result.added > 0) 'added ${result.added}',
          if (result.alreadyKnown > 0) '${result.alreadyKnown} already indexed',
          if (result.failed > 0) '${result.failed} failed',
        ];
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              parts.isEmpty
                  ? 'No session files found on disk.'
                  : 'Disk rescan — ${parts.join(', ')}.',
            ),
          ),
        );
      case _OverflowAction.repairNames:
        // Renames files on disk — confirm first (no await before showDialog, so
        // `context` is still valid here).
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Repair timestamps & names?'),
            content: const Text(
              'Re-derives each session\'s recording time (correcting older logs '
              'that show the device boot time) and renames its files to that '
              'time. Safe to run more than once.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Repair'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        messenger.showSnackBar(
          const SnackBar(content: Text('Repairing sessions…')),
        );
        final r = await runs.repairSessionFilenames();
        final segs = <String>[
          if (r.renamed > 0) '${r.renamed} renamed',
          if (r.retimed > 0) '${r.retimed} retimed',
          if (r.failed > 0) '${r.failed} failed',
        ];
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              segs.isEmpty
                  ? 'All ${r.unchanged} sessions already current.'
                  : 'Repair — ${segs.join(', ')}'
                      '${r.unchanged > 0 ? ' (${r.unchanged} already current)' : ''}.',
            ),
            duration: r.failed == 0
                ? const Duration(seconds: 4)
                : const Duration(seconds: 10),
          ),
        );
    }
  }
}

/// Compact sort control: a field chooser + an independent direction toggle.
///
/// Renders as one bordered pill — `[ ⇅ Field ▾ | ↓ ]`. The left zone opens a
/// popup of the fields valid for the active view (a [brandGood] check marks
/// the current one); the right zone flips ascending/descending in one tap.
/// Selecting a field resets the direction to that field's natural default
/// ([DataSortFieldX.defaultAscending]); the arrow then overrides it.
class _SortControl extends ConsumerWidget {
  const _SortControl();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(dataFiltersProvider);
    final notifier = ref.read(dataFiltersProvider.notifier);
    final fields = sortFieldsForView(filters.view);
    final radius = BorderRadius.circular(brandControlRadiusSoft);

    return Container(
      decoration: BoxDecoration(
        color: brandControlFill,
        border: Border.all(color: brandRule, width: brandHairlineWidth),
        borderRadius: radius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopupMenuButton<DataSortField>(
            tooltip: 'Sort by',
            position: PopupMenuPosition.under,
            color: brandSurface,
            onSelected: notifier.setSortField,
            itemBuilder: (context) => [
              for (final f in fields)
                PopupMenuItem<DataSortField>(
                  value: f,
                  height: 40,
                  child: Row(
                    children: [
                      Icon(
                        Icons.check,
                        size: 14,
                        color: f == filters.sortField
                            ? brandGood
                            : Colors.transparent,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        f.label,
                        style: plexMono(
                          fontSize: 12.5,
                          color: f == filters.sortField ? brandFg : brandFgDim,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.sort, size: 15, color: brandFgDim),
                  const SizedBox(width: 7),
                  Text(
                    filters.sortField.label,
                    style: plexMono(fontSize: 12, color: brandFg),
                  ),
                  const Icon(
                    Icons.arrow_drop_down,
                    size: 18,
                    color: brandFgDim,
                  ),
                ],
              ),
            ),
          ),
          Container(width: brandHairlineWidth, height: 22, color: brandRule),
          InkWell(
            borderRadius: radius,
            onTap: notifier.toggleSortDirection,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
              child: Tooltip(
                message: filters.sortAscending
                    ? 'Ascending — tap for descending'
                    : 'Descending — tap for ascending',
                child: Icon(
                  filters.sortAscending
                      ? Icons.arrow_upward
                      : Icons.arrow_downward,
                  size: 15,
                  color: brandFg,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the [FilterRail] in a modal bottom sheet — the narrow-layout
/// entry point to the rail.
void _showFiltersSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const SizedBox(
      height: 560,
      child: FilterRail(),
    ),
  );
}

class _ActiveChipRow extends ConsumerWidget {
  const _ActiveChipRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(dataFiltersProvider);
    final notifier = ref.read(dataFiltersProvider.notifier);
    final chips = <Widget>[];
    Widget chip(String label, VoidCallback onDelete) => InputChip(
          label: Text(label),
          onDeleted: onDelete,
          deleteIcon: const Icon(Icons.close, size: 14),
          visualDensity: VisualDensity.compact,
        );
    if (filters.dateRange != null) {
      chips.add(
        chip(
          'Date: ${_dateLabel(filters.dateRange!)}',
          () => notifier.setDateRange(null),
        ),
      );
    }
    for (final id in filters.trackIds) {
      chips.add(chip('Track', () => notifier.toggleTrack(id)));
    }
    for (final v in filters.bikes) {
      chips.add(
        chip('Bike: ${v.isEmpty ? '(none)' : v}', () => notifier.toggleBike(v)),
      );
    }
    for (final v in filters.riders) {
      chips.add(
        chip(
          'Rider: ${v.isEmpty ? '(none)' : v}',
          () => notifier.toggleRider(v),
        ),
      );
    }
    for (final v in filters.tags) {
      chips.add(
        chip('Tag: ${v.isEmpty ? '(none)' : v}', () => notifier.toggleTag(v)),
      );
    }
    for (final v in filters.venues) {
      chips.add(
        chip(
          'Venue: ${v.isEmpty ? '(none)' : v}',
          () => notifier.toggleVenue(v),
        ),
      );
    }
    if (filters.lapTimeMs != null) {
      chips.add(
        chip(
          'Lap ${_formatMs(filters.lapTimeMs!.start.toInt())}–'
          '${_formatMs(filters.lapTimeMs!.end.toInt())}',
          () => notifier.setLapTimeRange(null),
        ),
      );
    }
    for (final s in filters.sources) {
      chips.add(chip('.${s.name}', () => notifier.toggleSource(s)));
    }
    if (filters.requireGates) {
      chips.add(chip('Has gates', () => notifier.setRequireGates(false)));
    }
    if (filters.requireGps) {
      chips.add(chip('Has GPS', () => notifier.setRequireGps(false)));
    }
    if (filters.searchText.isNotEmpty) {
      chips.add(
        chip(
          '"${filters.searchText}"',
          () => notifier.setSearchText(''),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Wrap(spacing: 6, runSpacing: 4, children: chips),
          ),
          TextButton.icon(
            icon: const Icon(Icons.clear_all, size: 16),
            label: const Text('Clear all'),
            onPressed: () => notifier.clearAll(),
          ),
        ],
      ),
    );
  }

  static String _formatMs(int ms) {
    final m = ms ~/ 60000;
    final s = (ms ~/ 1000) % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  static String _dateLabel(DateTimeRange r) {
    String fmt(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    if (r.start == r.end) return fmt(r.start);
    return '${fmt(r.start)} → ${fmt(r.end)}';
  }
}

// ---------------------------------------------------------------------------
// Rescan visits button
// ---------------------------------------------------------------------------

/// Toolbar button that re-evaluates track-visit membership for every session.
///
/// Shows a [CircularProgressIndicator] while the async operation is in flight
/// and presents a [SnackBar] with the outcome count on completion.
class _RescanVisitsButton extends ConsumerStatefulWidget {
  const _RescanVisitsButton();

  @override
  ConsumerState<_RescanVisitsButton> createState() =>
      _RescanVisitsButtonState();
}

class _RescanVisitsButtonState extends ConsumerState<_RescanVisitsButton> {
  bool _running = false;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      icon: _running
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh, size: 18),
      label: const Text('Rescan visits'),
      onPressed: _running ? null : _run,
    );
  }

  Future<void> _run() async {
    setState(() => _running = true);
    try {
      final result =
          await ref.read(runsProvider.notifier).rescanAllTrackVisits();
      if (!mounted) return;
      final msg = result.failed == 0
          ? 'Rescanned ${result.rescanned} sessions'
          : 'Rescanned ${result.rescanned}, ${result.failed} failed'
              '${result.firstError != null ? ' — ${result.firstError}' : ''}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: result.failed == 0
              ? const Duration(seconds: 4)
              : const Duration(seconds: 12),
        ),
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }
}

/// Recovery toolbar button: walks the on-disk sessions directory and
/// re-indexes any session files that aren't in `sessions.db`. Used after
/// the index has been wiped (e.g. by a `flutter clean` against the old
/// build-tree database location) while the `.idl0` / `.gpx` recordings
/// themselves survived in the user's documents folder.
class _RescanFromDiskButton extends ConsumerStatefulWidget {
  const _RescanFromDiskButton();

  @override
  ConsumerState<_RescanFromDiskButton> createState() =>
      _RescanFromDiskButtonState();
}

class _RescanFromDiskButtonState extends ConsumerState<_RescanFromDiskButton> {
  bool _running = false;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      icon: _running
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.cloud_download_outlined, size: 18),
      label: const Text('Rescan disk'),
      onPressed: _running ? null : _run,
    );
  }

  Future<void> _run() async {
    setState(() => _running = true);
    try {
      final result =
          await ref.read(runsProvider.notifier).rescanSessionsFromDisk();
      if (!mounted) return;
      final parts = <String>[
        if (result.added > 0) 'added ${result.added}',
        if (result.alreadyKnown > 0) '${result.alreadyKnown} already indexed',
        if (result.failed > 0) '${result.failed} failed',
      ];
      final msg = parts.isEmpty
          ? 'No session files found on disk.'
          : 'Disk rescan — ${parts.join(', ')}.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }
}

// ---------------------------------------------------------------------------
// Mobile filter bar — persistent bottom-edge entry to the FilterRail
// ---------------------------------------------------------------------------

/// Slim bar pinned to the bottom of the Data tab on narrow layouts.
///
/// Tapping anywhere slides the [FilterRail] up as a modal bottom sheet —
/// the discoverable mobile entry point. Replaces the easy-to-miss
/// `Filters` button that previously hid in the toolbar wrap.
///
/// Border colour follows the active filter count: green when filters are
/// applied, dim hairline when empty. Always renders the active-count in
/// parentheses for quick scanning.
class _MobileFilterBar extends ConsumerWidget {
  const _MobileFilterBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(
      dataFiltersProvider.select((f) => f.activeCount),
    );
    final hasActive = count > 0;
    final borderColor = hasActive ? brandGood : brandRule;
    return Material(
      color: brandSurface,
      child: InkWell(
        onTap: () => _showFiltersSheet(context),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: borderColor,
                width: brandHairlineWidth,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                Icons.tune,
                size: 16,
                color: hasActive ? brandGood : brandFgDim,
              ),
              const SizedBox(width: 10),
              Text(
                hasActive ? 'FILTERS  ($count)' : 'FILTERS',
                style: plexMono(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: hasActive ? brandFg : brandFgDim,
                  letterSpacing: brandLabelTracking,
                ),
              ),
              const Spacer(),
              const Icon(
                Icons.keyboard_arrow_up,
                size: 18,
                color: brandFgDim,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Floating "ANALYZE N selected" launcher
// ---------------------------------------------------------------------------

class _AnalyzeLauncher extends ConsumerWidget {
  const _AnalyzeLauncher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(selectionProvider);
    final effectiveSessions = ref.watch(effectiveSessionIdsProvider);
    if (selection.isEmpty) return const SizedBox.shrink();

    final n = selection.mode == SelectionMode.lap
        ? selection.lapKeys.length
        : effectiveSessions.length;
    final unit = selection.mode == SelectionMode.lap ? 'lap' : 'session';

    return Material(
      elevation: 4,
      color: Theme.of(context).colorScheme.primaryContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '$n $unit${n == 1 ? '' : 's'} selected',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.analytics),
                label: const Text('ANALYZE »'),
                onPressed: () =>
                    ref.read(shellIndexProvider.notifier).state = 3,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
