import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../data/exceptions.dart';
import '../../../data/lap_timing.dart';
import '../../../data/track.dart';
import '../../../data/track_artifact_io.dart';
import '../../../providers/data_results_provider.dart';
import '../../../providers/session_provider.dart';
import '../../../providers/track_provider.dart';
import '../../brand/brand.dart';
import 'track_editor_modal.dart';
import 'track_import_conflict_dialog.dart';

/// Result-panel renderer for the Tracks view. Reads
/// [filteredTrackRowsProvider] and shows per-Track stats grouped into
/// collapsible venue sections (mirroring the Sessions Date·Venue tree). The
/// header carries an "Import .gpx tracks…" entry that supports multi-selection
/// — each chosen file becomes a fresh Track via
/// [TrackNotifier.importTrackFromGpx].
class TrackResults extends ConsumerStatefulWidget {
  /// Creates a [TrackResults].
  const TrackResults({super.key});

  @override
  ConsumerState<TrackResults> createState() => _TrackResultsState();
}

class _TrackResultsState extends ConsumerState<TrackResults> {
  String? _selectedTrackId;
  bool _importing = false;

  @override
  Widget build(BuildContext context) {
    final rowsAsync = ref.watch(filteredTrackRowsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              QuietButton(
                label: 'Create from session',
                icon: Icons.directions_bike,
                onPressed: _onCreateFromSession,
              ),
              QuietButton(
                label: 'Import track',
                icon: Icons.file_open_outlined,
                onPressed: _onImportArtifact,
              ),
              QuietButton(
                label: _importing ? 'Importing…' : 'Import .gpx tracks',
                icon: Icons.terrain,
                filled: true,
                onPressed: _importing ? null : _onImport,
              ),
            ],
          ),
        ),
        const Divider(
          height: 1,
          thickness: brandHairlineWidth,
          color: brandRule,
        ),
        Expanded(
          child: rowsAsync.when(
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
                  'Could not load tracks: $e',
                  textAlign: TextAlign.center,
                  style: plexMono(fontSize: 13, color: brandAccent),
                ),
              ),
            ),
            data: (rows) {
              if (rows.isEmpty) return const _EmptyTracks();
              return Row(
                children: [
                  Expanded(
                    child: _TrackTable(
                      rows: rows,
                      selectedTrackId: _selectedTrackId,
                      onSelect: (id) => setState(() => _selectedTrackId = id),
                    ),
                  ),
                  if (_selectedTrackId != null)
                    SizedBox(
                      width: 320,
                      child: TrackDetailPanel(
                        row: rows.firstWhere(
                          (r) => r.track.trackId == _selectedTrackId,
                          orElse: () => rows.first,
                        ),
                        onClose: () => setState(() => _selectedTrackId = null),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// Shows an [AlertDialog] listing all known sessions. On selection, calls
  /// [TrackEditorModal.createFromSessionAndShow] directly — no tab switching,
  /// no pending-selection provider.
  Future<void> _onCreateFromSession() async {
    final sessions = ref.read(sessionProvider).sessions;
    if (sessions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No sessions available.')),
      );
      return;
    }

    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pick a session'),
        content: SizedBox(
          width: 320,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: sessions.length,
            itemBuilder: (_, i) {
              final s = sessions[i];
              final date = DateFormat('yyyy-MM-dd').format(
                DateTime.fromMillisecondsSinceEpoch(s.createdTimestampMs)
                    .toLocal(),
              );
              final label = [
                if (s.venueName.isNotEmpty) s.venueName,
                if (s.rider.isNotEmpty) s.rider,
                date,
              ].join(' · ');
              return ListTile(
                title: Text(label),
                onTap: () => Navigator.of(ctx).pop(s.sessionId),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (picked == null || !mounted) return;
    await TrackEditorModal.createFromSessionAndShow(context, ref, picked);
  }

  Future<void> _onImport() async {
    setState(() => _importing = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final notifier = ref.read(trackProvider.notifier);
      var imported = 0;
      final failed = <String>[];
      for (final file in result.files) {
        if (file.bytes == null) {
          failed.add(file.name);
          continue;
        }
        if (!file.name.toLowerCase().endsWith('.gpx')) {
          failed.add(file.name);
          continue;
        }
        try {
          await notifier.importTrackFromGpx(
            bytes: file.bytes!,
            name: _stripGpxExt(file.name),
            venueName: '',
          );
          imported++;
        } catch (_) {
          failed.add(file.name);
        }
      }
      if (!mounted) return;
      final msg = failed.isEmpty
          ? 'Imported $imported track${imported == 1 ? '' : 's'}'
          : 'Imported $imported, failed: ${failed.join(', ')}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  static String _stripGpxExt(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.gpx')) {
      return filename.substring(0, filename.length - 4);
    }
    return filename;
  }

  /// Imports a single `.idl0t` portable Track. On a `trackId` collision the
  /// user chooses update-in-place vs a fresh copy; otherwise the imported id is
  /// kept (preserving identity across share / re-import).
  Future<void> _onImportArtifact() async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Import track',
      type: FileType.custom,
      allowedExtensions: const ['idl0t'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.single.bytes;
    if (bytes == null) return;

    final Track imported;
    try {
      imported = decodeTrackArtifact(utf8.decode(bytes));
    } on TrackArtifactException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Import failed: ${e.message}')),
      );
      return;
    }

    final notifier = ref.read(trackProvider.notifier);
    final existing = notifier.existingById(imported.trackId);
    if (existing == null) {
      await notifier.addImportedTrack(imported);
      messenger.showSnackBar(
        SnackBar(content: Text('Imported "${imported.name}".')),
      );
      return;
    }
    if (!mounted) return;
    final res = await TrackImportConflictDialog.show(context, existing.name);
    switch (res) {
      case TrackImportResolution.updateInPlace:
        await notifier.updateTrack(
          imported.copyWith(updatedAtMs: DateTime.now().millisecondsSinceEpoch),
        );
        messenger.showSnackBar(
          SnackBar(content: Text('Updated "${imported.name}".')),
        );
      case TrackImportResolution.newCopy:
        await notifier.addImportedTrack(imported, asNewCopy: true);
        messenger.showSnackBar(
          SnackBar(content: Text('Imported "${imported.name}" as a copy.')),
        );
      case null:
        break; // cancelled
    }
  }
}

class _EmptyTracks extends StatelessWidget {
  const _EmptyTracks();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.terrain, size: 36, color: brandFgFaint),
          const SizedBox(height: 10),
          Text(
            'No tracks yet. Create one from a session, or import a .gpx.',
            textAlign: TextAlign.center,
            style: plexSans(fontSize: 13, color: brandFgDim),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Track table
// ---------------------------------------------------------------------------

// Shared column widths for the Tracks table (header + rows align).
const double _wtSessions = 76;
const double _wtLaps = 56;
const double _wtBest = 84;
const double _wtLast = 104;

class _TrackTable extends StatelessWidget {
  const _TrackTable({
    required this.rows,
    required this.selectedTrackId,
    required this.onSelect,
  });

  final List<TrackRow> rows;
  final String? selectedTrackId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    // Group by venue, mirroring the Sessions Date·Venue tree. Order follows the
    // provider's active sort: `byVenue` is a LinkedHashMap filled by iterating
    // the already-sorted `rows`, so the venue holding the top-ranked track
    // leads and within a venue the rows keep their sorted order. Tracks with no
    // venue collect under a single trailing-or-leading "(no venue)" section.
    final byVenue = <String, List<TrackRow>>{};
    for (final row in rows) {
      byVenue.putIfAbsent(row.track.venueName, () => []).add(row);
    }
    final venues = byVenue.keys.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TableHeader(
          children: [
            Expanded(child: TableHeader.headerCell('Name')),
            SizedBox(
              width: _wtSessions,
              child: TableHeader.headerCell('Sessions', right: true),
            ),
            SizedBox(
              width: _wtLaps,
              child: TableHeader.headerCell('Laps', right: true),
            ),
            SizedBox(
              width: _wtBest,
              child: TableHeader.headerCell('Best', right: true),
            ),
            SizedBox(
              width: _wtLast,
              child: TableHeader.headerCell('Last ridden', right: true),
            ),
          ],
        ),
        Expanded(
          child: ListView.builder(
            itemCount: venues.length,
            itemBuilder: (context, i) {
              final venue = venues[i];
              return _VenueBlock(
                venue: venue,
                rows: byVenue[venue]!,
                selectedTrackId: selectedTrackId,
                onSelect: onSelect,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// One collapsible venue section in the Tracks table. The header bar mirrors
/// the Sessions tree's `(date · venue)` block: a [brandSurface2] strip with a
/// chevron, the uppercase mono venue name, and a `· count`. Expanded by
/// default; its track rows lay their cells on the shared column grid so they
/// align under the pinned header.
class _VenueBlock extends StatefulWidget {
  const _VenueBlock({
    required this.venue,
    required this.rows,
    required this.selectedTrackId,
    required this.onSelect,
  });

  final String venue;
  final List<TrackRow> rows;
  final String? selectedTrackId;
  final ValueChanged<String> onSelect;

  @override
  State<_VenueBlock> createState() => _VenueBlockState();
}

class _VenueBlockState extends State<_VenueBlock> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final label = widget.venue.isEmpty ? '(no venue)' : widget.venue;
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
                bottom: BorderSide(color: brandRule, width: brandHairlineWidth),
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
                Flexible(
                  child: Text(
                    label.toUpperCase(),
                    overflow: TextOverflow.ellipsis,
                    style: plexMono(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: brandFg,
                      letterSpacing: brandLabelTracking,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '· ${widget.rows.length}',
                  style: plexMono(fontSize: 11, color: brandFgDim),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          for (final row in widget.rows)
            _trackRow(
              row,
              selected: row.track.trackId == widget.selectedTrackId,
              onTap: () => widget.onSelect(row.track.trackId),
            ),
      ],
    );
  }
}

final _trackDateFormat = DateFormat('yyyy-MM-dd');

/// One Track row laid on the shared Tracks column grid (name + sessions / laps
/// / best / last-ridden). Shared by every [_VenueBlock].
Widget _trackRow(
  TrackRow row, {
  required bool selected,
  required VoidCallback onTap,
}) {
  return DenseRow(
    key: ValueKey(row.track.trackId),
    selected: selected,
    onTap: onTap,
    children: [
      Expanded(
        child: Text(
          row.track.name.isEmpty ? '(unnamed)' : row.track.name,
          overflow: TextOverflow.ellipsis,
          style: plexMono(fontSize: 12.5, color: brandFg),
        ),
      ),
      _trackNumCell(_wtSessions, '${row.sessionCount}'),
      _trackNumCell(_wtLaps, '${row.lapCount}'),
      _trackNumCell(
        _wtBest,
        row.bestLapMs == null ? '—' : _formatTrackLap(row.bestLapMs!),
        color: row.bestLapMs == null ? brandFgFaint : brandGood,
        weight: FontWeight.w600,
      ),
      _trackNumCell(
        _wtLast,
        row.lastRiddenMs == null
            ? '—'
            : _trackDateFormat.format(
                DateTime.fromMillisecondsSinceEpoch(row.lastRiddenMs!)
                    .toLocal(),
              ),
      ),
    ],
  );
}

/// A fixed-width, right-aligned mono numeric cell for the Tracks table.
Widget _trackNumCell(
  double width,
  String text, {
  Color color = brandFgDim,
  FontWeight weight = FontWeight.w400,
}) {
  return SizedBox(
    width: width,
    child: Text(
      text,
      textAlign: TextAlign.right,
      overflow: TextOverflow.ellipsis,
      style: plexMono(fontSize: 12.5, color: color, fontWeight: weight),
    ),
  );
}

String _formatTrackLap(int ms) {
  final m = ms ~/ 60000;
  final s = (ms ~/ 1000) % 60;
  final tenths = (ms % 1000) ~/ 100;
  return '$m:${s.toString().padLeft(2, '0')}.$tenths';
}

/// Brand-styled [InputDecoration] for the Track detail panel fields.
InputDecoration _brandInput(String label) {
  OutlineInputBorder border(Color c) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(brandControlRadiusSoft),
        borderSide: BorderSide(color: c, width: brandHairlineWidth),
      );
  return InputDecoration(
    labelText: label,
    labelStyle: plexMono(fontSize: 12, color: brandFgDim),
    isDense: true,
    filled: true,
    fillColor: brandControlFill,
    border: border(brandRule),
    enabledBorder: border(brandRule),
    focusedBorder: border(brandFgDim),
  );
}

// ---------------------------------------------------------------------------
// Side detail panel
// ---------------------------------------------------------------------------

/// Side-panel detail card for a Track. Used by [TrackResults] today
/// and by `DataDetailPane` (Task B4) when the right pane is showing
/// a Track. See `docs/IDL0_SPEC.md §24`.
class TrackDetailPanel extends ConsumerStatefulWidget {
  /// Creates a [TrackDetailPanel].
  const TrackDetailPanel({super.key, required this.row, required this.onClose});

  /// The track row whose details are displayed and edited.
  final TrackRow row;

  /// Called when the user closes the panel.
  final VoidCallback onClose;

  @override
  ConsumerState<TrackDetailPanel> createState() => TrackDetailPanelState();
}

/// State for [TrackDetailPanel].
class TrackDetailPanelState extends ConsumerState<TrackDetailPanel> {
  late TextEditingController _nameCtrl;
  late TextEditingController _venueCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.row.track.name);
    _venueCtrl = TextEditingController(text: widget.row.track.venueName);
  }

  @override
  void didUpdateWidget(TrackDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.row.track.trackId != widget.row.track.trackId) {
      _nameCtrl.text = widget.row.track.name;
      _venueCtrl.text = widget.row.track.venueName;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _venueCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.row.track;
    return Material(
      color: brandSurface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'TRACK DETAIL',
                    style: plexMono(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: brandFgDim,
                      letterSpacing: brandLabelTracking,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  color: brandFgDim,
                  onPressed: widget.onClose,
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Scroll the editable fields + stats so they never overflow a
            // bounded host (the mobile detail bottom sheet shrinks as the
            // keyboard rises); the action buttons below stay pinned. See §24.2.
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _nameCtrl,
                      style: plexMono(fontSize: 13, color: brandFg),
                      cursorColor: brandFg,
                      decoration: _brandInput('Name'),
                      onSubmitted: (_) => _commit(),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Autocomplete<String>(
                        initialValue: TextEditingValue(text: _venueCtrl.text),
                        optionsBuilder: (value) {
                          final tracks =
                              ref.read(trackProvider).value ?? const [];
                          final opts = <String>{
                            for (final t in tracks)
                              if (t.venueName.isNotEmpty) t.venueName,
                          };
                          if (value.text.isEmpty) return opts;
                          final lc = value.text.toLowerCase();
                          return opts
                              .where((o) => o.toLowerCase().contains(lc));
                        },
                        onSelected: (s) => _venueCtrl.text = s,
                        fieldViewBuilder: (ctx, txtCtrl, focus, onSubmitted) {
                          txtCtrl.text = _venueCtrl.text;
                          txtCtrl.addListener(
                            () => _venueCtrl.text = txtCtrl.text,
                          );
                          return TextField(
                            controller: txtCtrl,
                            focusNode: focus,
                            style: plexMono(fontSize: 13, color: brandFg),
                            cursorColor: brandFg,
                            decoration: _brandInput('Venue'),
                            onSubmitted: (_) => onSubmitted(),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    _stat(
                      'Timing',
                      '${_lapTimingLabel(track.lapTiming)} · '
                          '${track.sectorGates.length} sector gate'
                          '${track.sectorGates.length == 1 ? '' : 's'}',
                    ),
                    _stat('Sessions', '${widget.row.sessionCount}'),
                    _stat('Laps', '${widget.row.lapCount}'),
                    if (widget.row.bestLapMs != null)
                      _stat('Best lap', _formatLap(widget.row.bestLapMs!)),
                    if (widget.row.lastRiddenMs != null)
                      _stat(
                        'Last ridden',
                        DateTime.fromMillisecondsSinceEpoch(
                          widget.row.lastRiddenMs!,
                        ).toLocal().toString(),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            QuietButton(
              label: 'Edit gates on map',
              icon: Icons.map_outlined,
              onPressed: () => TrackEditorModal.show(context, widget.row.track),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                QuietButton(
                  label: 'Save',
                  filled: true,
                  onPressed: _commit,
                ),
                const Spacer(),
                QuietButton(
                  label: 'Delete',
                  emphasis: ButtonEmphasis.alert,
                  icon: Icons.delete_outline,
                  onPressed: _confirmDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// One `label  value` stats line, mono.
  Widget _stat(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 88,
              child: Text(
                label,
                style: plexMono(fontSize: 11.5, color: brandFgDim),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: plexMono(fontSize: 11.5, color: brandFg),
              ),
            ),
          ],
        ),
      );

  /// Persists the current name and venue values when either has changed.
  Future<void> _commit() async {
    final name = _nameCtrl.text.trim();
    final venue = _venueCtrl.text.trim();
    final track = widget.row.track;
    final nameChanged = name.isNotEmpty && name != track.name;
    final venueChanged = venue != track.venueName;
    if (!nameChanged && !venueChanged) return;
    final updated = track.copyWith(
      name: nameChanged ? name : track.name,
      venueName: venue,
    );
    await ref.read(trackProvider.notifier).updateTrack(updated);
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete track?'),
        content: Text(
          'Existing session visits will keep their cached lap data but '
          'will no longer resolve to "${widget.row.track.name}".',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref
        .read(trackProvider.notifier)
        .deleteTrack(widget.row.track.trackId);
    widget.onClose();
  }

  /// Human-readable label for the [LapTiming] variant on the detail panel.
  ///
  /// Returns `'none'` when no timing is set, `'Circuit'` for [Circuit], or
  /// `'Point-to-Point'` for [PointToPoint].
  static String _lapTimingLabel(LapTiming? timing) {
    if (timing == null) return 'none';
    if (timing is Circuit) return 'Circuit';
    return 'Point-to-Point';
  }

  static String _formatLap(int ms) {
    final m = ms ~/ 60000;
    final s = (ms ~/ 1000) % 60;
    final tenths = (ms % 1000) ~/ 100;
    return '$m:${s.toString().padLeft(2, '0')}.$tenths';
  }
}
