import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' hide Context;

import '../../../data/database_paths.dart';
import '../../../data/session_index.dart';
import '../../../data/session_model.dart';
import '../../../data/track.dart';
import '../../../data/workspace.dart';
import '../../../providers/detail_selection_provider.dart';
import '../../../providers/runs_provider.dart';
import '../../../providers/session_provider.dart';
import '../../../providers/track_provider.dart';
import 'track_editor_modal.dart';

/// Resolves the venue to show and edit for a session: the explicit
/// [SessionMetadata.venueName] when set, otherwise the first non-empty
/// `venueName` among the workspace's visited Tracks (resolved against
/// [tracks]), otherwise the empty string.
///
/// Mirrors `SessionRow.displayVenueName` and the `SessionDetailCard` header so
/// the editable Venue field is *pre-filled* with the same venue the card and
/// the Sessions tree already display — saving then writes that venue into the
/// session's own metadata instead of leaving it blank. See §24.10.
String resolveSessionVenue(
  SessionMetadata meta,
  Workspace? ws,
  List<Track> tracks,
) {
  if (meta.venueName.isNotEmpty) return meta.venueName;
  if (ws == null) return '';
  final byId = {for (final t in tracks) t.trackId: t};
  for (final v in ws.trackVisits) {
    final venue = byId[v.trackId]?.venueName;
    if (venue != null && venue.isNotEmpty) return venue;
  }
  return '';
}

/// AlertDialog wrapper for [MetadataForm] — preserves the modal entry point
/// used by callers that want a dialog instead of a side panel. See §24.
///
/// Present via [showDialog]. The Cancel button dismisses without saving; the
/// Save button delegates to [MetadataFormState.save] via a [GlobalKey].
class MetadataEditor extends ConsumerStatefulWidget {
  /// Creates a [MetadataEditor].
  const MetadataEditor({
    super.key,
    required this.meta,
    required this.workspace,
    required this.saver,
  });

  /// Session metadata providing initial field values.
  final SessionMetadata meta;

  /// Workspace loaded from the companion `.idl0w` file. Drives the
  /// tracks-visited row via [Workspace.trackVisits].
  final Workspace workspace;

  /// Persists the workspace on save.
  final WorkspaceSaver saver;

  @override
  ConsumerState<MetadataEditor> createState() => _MetadataEditorState();
}

class _MetadataEditorState extends ConsumerState<MetadataEditor> {
  final _formKey = GlobalKey<MetadataFormState>();

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Edit Session'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: MetadataForm(
              key: _formKey,
              meta: widget.meta,
              workspace: widget.workspace,
              saver: widget.saver,
              onSaved: () {
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              }
            },
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => _formKey.currentState?.save(),
            child: const Text('Save'),
          ),
        ],
      );
}

/// Editable form body for [SessionMetadata]. Used by [MetadataEditor]
/// (modal dialog) and `SessionDetailCard` (side panel). Save persists
/// the workspace via [saver], upserts the updated metadata into
/// `SessionIndex`, and refreshes `sessionProvider`. See §24.
///
/// Callers that host this widget outside a dialog can trigger a save by
/// holding a [GlobalKey<MetadataFormState>] and calling [save].
class MetadataForm extends ConsumerStatefulWidget {
  /// Creates a [MetadataForm].
  const MetadataForm({
    super.key,
    required this.meta,
    required this.workspace,
    required this.saver,
    this.onSaved,
  });

  /// Session metadata providing initial field values.
  final SessionMetadata meta;

  /// Workspace loaded from the companion `.idl0w` file. Drives the
  /// tracks-visited row via [Workspace.trackVisits].
  final Workspace workspace;

  /// Persists the workspace on save.
  final WorkspaceSaver saver;

  /// Optional callback fired after a successful save.
  final VoidCallback? onSaved;

  @override
  ConsumerState<MetadataForm> createState() => MetadataFormState();
}

/// Public state class for [MetadataForm] — exposes [save] so a parent widget
/// can trigger persistence via a [GlobalKey<MetadataFormState>].
class MetadataFormState extends ConsumerState<MetadataForm> {
  late final TextEditingController _rider;
  late final TextEditingController _bike;
  late final TextEditingController _bikeComment;
  late final TextEditingController _venueName;
  late final TextEditingController _eventName;
  late final TextEditingController _eventSession;
  late final TextEditingController _shortComment;
  late final TextEditingController _longComment;
  late final TextEditingController _tag;

  /// Whether a save is currently in-flight. Guards against double-taps.
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final m = widget.meta;
    final tracks = ref.read(trackProvider).value ?? const <Track>[];
    _rider = TextEditingController(text: m.rider);
    _bike = TextEditingController(text: m.bike);
    _bikeComment = TextEditingController(text: m.bikeComment);
    // Pre-fill Venue with the resolved track venue when the session carries no
    // explicit venueName, so the metadata field reflects (and on Save persists)
    // the venue the card header already shows. See §24.10.
    _venueName = TextEditingController(
      text: resolveSessionVenue(m, widget.workspace, tracks),
    );
    _eventName = TextEditingController(text: m.eventName);
    _eventSession = TextEditingController(text: m.eventSession);
    _shortComment = TextEditingController(text: m.shortComment);
    _longComment = TextEditingController(text: m.longComment);
    _tag = TextEditingController(text: m.tag);
  }

  @override
  void dispose() {
    _rider.dispose();
    _bike.dispose();
    _bikeComment.dispose();
    _venueName.dispose();
    _eventName.dispose();
    _eventSession.dispose();
    _shortComment.dispose();
    _longComment.dispose();
    _tag.dispose();
    super.dispose();
  }

  /// Public save entry point — call from a parent's save button.
  ///
  /// Persists the workspace via [WorkspaceSaver], upserts updated metadata
  /// fields into the SQLite session index, then refreshes [sessionProvider]
  /// in-memory. Fires [MetadataForm.onSaved] on success.
  Future<void> save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.saver.save(widget.workspace);
      final updated = widget.meta.copyWith(
        rider: _rider.text,
        bike: _bike.text,
        bikeComment: _bikeComment.text,
        venueName: _venueName.text,
        eventName: _eventName.text,
        eventSession: _eventSession.text,
        tag: _tag.text,
        shortComment: _shortComment.text,
        longComment: _longComment.text,
      );
      final dbPath = join(await getStableDatabasesPath(), 'sessions.db');
      final index = await SessionIndex.open(dbPath);
      await index.upsert(updated);
      await index.close();
      ref.read(sessionProvider.notifier).updateSession(updated);
      if (mounted) widget.onSaved?.call();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tracks = ref.watch(trackProvider).value ?? const <Track>[];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _TracksVisitedRow(
          sessionId: widget.meta.sessionId,
          visits: widget.workspace.trackVisits,
          cachedLibraryHash: widget.workspace.trackVisitsLibraryHash,
          tracks: tracks,
        ),
        const Divider(height: 24),
        _field('Rider', _rider),
        _field('Bike', _bike),
        _field('Bike comment', _bikeComment),
        _venueAutocomplete(tracks),
        _field('Event', _eventName),
        _field('Session', _eventSession),
        _field('Tag', _tag),
        _field('Short comment', _shortComment),
        _field('Long comment', _longComment, maxLines: 4),
      ],
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    int maxLines = 1,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: controller,
          maxLines: maxLines,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      );

  Widget _venueAutocomplete(List<Track> tracks) {
    final options = <String>{
      for (final t in tracks)
        if (t.venueName.isNotEmpty) t.venueName,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Autocomplete<String>(
        initialValue: TextEditingValue(text: _venueName.text),
        optionsBuilder: (value) {
          if (value.text.isEmpty) return options;
          final lc = value.text.toLowerCase();
          return options.where((o) => o.toLowerCase().contains(lc));
        },
        onSelected: (s) => _venueName.text = s,
        fieldViewBuilder: (BuildContext ctx, txtCtrl, focus, onSubmitted) {
          // Bind the inner Autocomplete controller to our long-lived one
          // so the parent can read the latest text on save.
          txtCtrl.text = _venueName.text;
          txtCtrl.addListener(() => _venueName.text = txtCtrl.text);
          return TextField(
            controller: txtCtrl,
            focusNode: focus,
            decoration: const InputDecoration(
              labelText: 'Venue',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => onSubmitted(),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _TracksVisitedRow — read-only summary of Tracks ridden in this session.
// ---------------------------------------------------------------------------

/// Read-only summary of which Tracks the session visited and how many times.
///
/// Driven by [Workspace.trackVisits] (populated by Phase 3 visit detection).
/// Multiple visits to the same Track are coalesced — `A-Line (3 visits)`.
/// Visits whose `trackId` no longer resolves to a current Track are skipped
/// per the §12.3 skip-on-resolve rule. The row collapses to a "No tracks
/// visited yet" placeholder when [visits] is empty.
class _TracksVisitedRow extends ConsumerStatefulWidget {
  const _TracksVisitedRow({
    required this.sessionId,
    required this.visits,
    required this.cachedLibraryHash,
    required this.tracks,
  });

  final String sessionId;
  final List<TrackVisit> visits;

  /// `Workspace.trackVisitsLibraryHash` at the time visits were last
  /// computed. Compared with the live track-library hash to flag a
  /// stale cache. `null` when detection has never run for this session.
  final String? cachedLibraryHash;

  final List<Track> tracks;

  @override
  ConsumerState<_TracksVisitedRow> createState() => _TracksVisitedRowState();
}

class _TracksVisitedRowState extends ConsumerState<_TracksVisitedRow> {
  bool _rescanning = false;

  Future<void> _rescan() async {
    setState(() => _rescanning = true);
    try {
      final result = await ref
          .read(runsProvider.notifier)
          .rescanTrackVisits(widget.sessionId);
      if (!mounted) return;
      final msg = result == null
          ? 'Rescan failed (no GPS or workspace error)'
          : 'Rescan: ${result.visits} visit${result.visits == 1 ? '' : 's'} detected';
      // Use super.context to disambiguate from path.Context
      ScaffoldMessenger.of(super.context)
          .showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) setState(() => _rescanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final liveHash = trackLibraryHash(widget.tracks);
    final isStale = widget.cachedLibraryHash != null &&
        widget.cachedLibraryHash != liveHash;

    final tracksById = {for (final t in widget.tracks) t.trackId: t};

    // Coalesce visits: preserve first-seen order, count per trackId.
    final order = <String>[];
    final counts = <String, int>{};
    for (final v in widget.visits) {
      if (!counts.containsKey(v.trackId)) order.add(v.trackId);
      counts[v.trackId] = (counts[v.trackId] ?? 0) + 1;
    }

    // Resolved entries only (§12.3 skip-on-resolve).
    final resolved = [
      for (final id in order)
        if (tracksById.containsKey(id)) (id: id, track: tracksById[id]!),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.flag_circle_outlined),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('Tracks visited', style: theme.textTheme.labelSmall),
                    if (isStale) ...[
                      const SizedBox(width: 8),
                      Tooltip(
                        message: 'Track library has changed since last scan',
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.tertiaryContainer,
                            borderRadius: BorderRadius.zero,
                          ),
                          child: Text(
                            'rescan available',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onTertiaryContainer,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (widget.visits.isEmpty) ...[
                  // Empty-state: message + CTA to create a track.
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 4),
                    child: Text(
                      'No tracks visited yet.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.add_location_alt_outlined),
                    label: const Text('Create Track from this session'),
                    onPressed: () => TrackEditorModal.createFromSessionAndShow(
                      context,
                      ref,
                      widget.sessionId,
                    ),
                  ),
                ] else if (resolved.isEmpty) ...[
                  Text(
                    'Tracks no longer in library',
                    style: theme.textTheme.bodyMedium,
                  ),
                ] else ...[
                  // One tappable row per resolved track.
                  for (final entry in resolved)
                    InkWell(
                      onTap: () => ref
                          .read(detailSelectionProvider.notifier)
                          .showTrack(entry.id),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '${entry.track.name} '
                          '(${counts[entry.id]} '
                          '${counts[entry.id] == 1 ? 'visit' : 'visits'})',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.primary,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: 'Rescan tracks',
            icon: _rescanning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh, size: 20),
            onPressed: _rescanning ? null : _rescan,
          ),
        ],
      ),
    );
  }
}
