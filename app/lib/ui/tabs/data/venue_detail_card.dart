import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/data_results_provider.dart';
import '../../../providers/detail_selection_provider.dart';
import '../../../providers/track_provider.dart';

/// Side-panel detail card for a venue (derived). See `docs/IDL0_SPEC.md §24`.
///
/// Venue is a string field on Track / SessionMetadata, not a first-class
/// entity — see `docs/design_rationale.md`. Editing the name batch-renames
/// every Track that shares it via [TrackNotifier.renameVenue]. The kebab
/// "Delete venue…" action clears the venueName on every matching Track.
class VenueDetailCard extends ConsumerStatefulWidget {
  /// Creates a [VenueDetailCard].
  const VenueDetailCard({super.key, required this.venueName});

  /// Venue display name. Empty string is allowed and represents "(no venue)".
  final String venueName;

  @override
  ConsumerState<VenueDetailCard> createState() => _VenueDetailCardState();
}

class _VenueDetailCardState extends ConsumerState<VenueDetailCard> {
  late TextEditingController _nameCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.venueName);
  }

  @override
  void didUpdateWidget(VenueDetailCard old) {
    super.didUpdateWidget(old);
    if (old.venueName != widget.venueName) {
      _nameCtrl.text = widget.venueName;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tracks = (ref.watch(trackProvider).value ?? const [])
        .where((t) => t.venueName == widget.venueName)
        .toList();
    final trackRows =
        ref.watch(filteredTrackRowsProvider).value ?? const [];
    final stats = trackRows
        .where((r) => r.track.venueName == widget.venueName)
        .toList();
    final sessionCount = stats.fold<int>(0, (a, r) => a + r.sessionCount);
    final lapCount = stats.fold<int>(0, (a, r) => a + r.lapCount);

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.venueName.isEmpty
                          ? '(no venue)'
                          : widget.venueName,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 18),
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete venue…'),
                      ),
                    ],
                    onSelected: (v) {
                      if (v == 'delete') _confirmDelete(tracks.length);
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () =>
                        ref.read(detailSelectionProvider.notifier).clear(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => _confirmRename(tracks.length),
                    child: const Text('Save'),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Renames ${tracks.length} '
                  'track${tracks.length == 1 ? '' : 's'}',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: Colors.grey),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'TRACKS (${tracks.length})',
                style: theme.textTheme.labelSmall,
              ),
              const SizedBox(height: 4),
              for (final t in tracks)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(t.name.isEmpty ? '(unnamed)' : t.name),
                  trailing: const Icon(Icons.chevron_right, size: 16),
                  onTap: () => ref
                      .read(detailSelectionProvider.notifier)
                      .showTrack(t.trackId),
                ),
              const SizedBox(height: 16),
              Text('STATS', style: theme.textTheme.labelSmall),
              const SizedBox(height: 4),
              Text(
                '$sessionCount session${sessionCount == 1 ? '' : 's'} · '
                '$lapCount lap${lapCount == 1 ? '' : 's'}',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmRename(int trackCount) async {
    final newName = _nameCtrl.text.trim();
    if (newName.isEmpty || newName == widget.venueName) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename venue?'),
        content: Text(
          'This will rename $trackCount '
          'track${trackCount == 1 ? '' : 's'}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref
        .read(trackProvider.notifier)
        .renameVenue(widget.venueName, newName);
    if (!mounted) return;
    ref.read(detailSelectionProvider.notifier).showVenue(newName);
  }

  Future<void> _confirmDelete(int trackCount) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete venue?'),
        content: Text(
          "Remove '${widget.venueName}' from $trackCount "
          'track${trackCount == 1 ? '' : 's'}? '
          'Tracks will become unassigned.',
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
    if (ok != true) return;
    await ref.read(trackProvider.notifier).deleteVenue(widget.venueName);
    if (!mounted) return;
    ref.read(detailSelectionProvider.notifier).clear();
  }
}
