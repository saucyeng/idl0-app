import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/workbook.dart';
import '../../../providers/workbook_provider.dart';
import '../../../providers/workspace_provider.dart';
import '../../brand/brand.dart';

/// Sort order for the Browse-all modal.
enum _BrowseSort {
  /// Most recently updated first.
  recent,

  /// Alphabetical, case-insensitive.
  name,

  /// Most recently created first.
  created,
}

/// Modal listing every workbook in the library, with search + sort.
///
/// Tap a row → switches to that workbook and closes the modal. Trailing
/// 3-dot menu offers per-row Rename / Duplicate / Export / Delete (only
/// Duplicate is wired in this task — see spec §8.3 and the per-task plan).
///
/// Show via `showDialog<void>(context: ctx, builder: (_) => const
/// BrowseWorkbooksModal())`.
class BrowseWorkbooksModal extends ConsumerStatefulWidget {
  /// Creates a [BrowseWorkbooksModal].
  const BrowseWorkbooksModal({super.key});

  @override
  ConsumerState<BrowseWorkbooksModal> createState() =>
      _BrowseWorkbooksModalState();
}

class _BrowseWorkbooksModalState extends ConsumerState<BrowseWorkbooksModal> {
  String _query = '';
  _BrowseSort _sort = _BrowseSort.recent;

  @override
  Widget build(BuildContext context) {
    final workbooks =
        ref.watch(workbookProvider).valueOrNull ?? const <Workbook>[];
    final filtered = _sortAndFilter(workbooks, _query, _sort);
    final size = MediaQuery.of(context).size;
    final width = size.width < 720 ? size.width * 0.95 : 640.0;
    final height = size.height * 0.7;

    return Dialog(
      child: SizedBox(
        width: width,
        height: height,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _Header(
                onClose: () => Navigator.of(context).pop(),
              ),
              const SizedBox(height: 12),
              _SearchAndSort(
                query: _query,
                sort: _sort,
                onQueryChanged: (q) => setState(() => _query = q),
                onSortChanged: (s) => setState(() => _sort = s),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          'No workbooks match.',
                          style: plexMono(fontSize: 14, color: brandFgDim),
                        ),
                      )
                    : ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) => _Row(
                          workbook: filtered[i],
                          onSwitch: () => _switchAndClose(filtered[i]),
                          onDuplicate: () => _duplicate(filtered[i]),
                          onStubbed: (action) => _stub(context, action),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _switchAndClose(Workbook wb) {
    final workbooks =
        ref.read(workbookProvider).valueOrNull ?? const <Workbook>[];
    final idx = workbooks.indexWhere((w) => w.workbookId == wb.workbookId);
    if (idx >= 0) {
      ref.read(workspaceProvider.notifier).setActiveWorkbook(idx);
    }
    Navigator.of(context).pop();
  }

  Future<void> _duplicate(Workbook wb) async {
    await ref.read(workbookProvider.notifier).duplicateWorkbook(wb);
  }

  void _stub(BuildContext context, String action) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$action — coming soon')),
    );
  }

  static List<Workbook> _sortAndFilter(
    List<Workbook> all,
    String query,
    _BrowseSort sort,
  ) {
    final lowered = query.trim().toLowerCase();
    final filtered = lowered.isEmpty
        ? [...all]
        : all.where((w) => w.name.toLowerCase().contains(lowered)).toList();
    switch (sort) {
      case _BrowseSort.recent:
        filtered.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
      case _BrowseSort.name:
        filtered.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
      case _BrowseSort.created:
        filtered.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    }
    return filtered;
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          'Browse Workbooks',
          style: plexMono(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: brandFg,
          ),
        ),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.close, size: 20),
          onPressed: onClose,
          tooltip: 'Close',
        ),
      ],
    );
  }
}

class _SearchAndSort extends StatelessWidget {
  const _SearchAndSort({
    required this.query,
    required this.sort,
    required this.onQueryChanged,
    required this.onSortChanged,
  });

  final String query;
  final _BrowseSort sort;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<_BrowseSort> onSortChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search…',
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18),
              border: OutlineInputBorder(),
            ),
            onChanged: onQueryChanged,
          ),
        ),
        const SizedBox(width: 12),
        DropdownButton<_BrowseSort>(
          value: sort,
          underline: const SizedBox.shrink(),
          items: [
            DropdownMenuItem(
              value: _BrowseSort.recent,
              child: Text(
                'Recent',
                style: plexMono(fontSize: 13, color: brandFg),
              ),
            ),
            DropdownMenuItem(
              value: _BrowseSort.name,
              child: Text(
                'Name',
                style: plexMono(fontSize: 13, color: brandFg),
              ),
            ),
            DropdownMenuItem(
              value: _BrowseSort.created,
              child: Text(
                'Created',
                style: plexMono(fontSize: 13, color: brandFg),
              ),
            ),
          ],
          onChanged: (v) {
            if (v != null) onSortChanged(v);
          },
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.workbook,
    required this.onSwitch,
    required this.onDuplicate,
    required this.onStubbed,
  });

  final Workbook workbook;
  final VoidCallback onSwitch;
  final Future<void> Function() onDuplicate;
  final void Function(String action) onStubbed;

  @override
  Widget build(BuildContext context) {
    final updated = DateTime.fromMillisecondsSinceEpoch(
      workbook.updatedAtMs,
      isUtc: true,
    );
    final subtitle =
        '${workbook.worksheets.length} worksheet${workbook.worksheets.length == 1 ? '' : 's'}'
        ' · last used ${_relativeTime(updated)}';

    return ListTile(
      title: Text(workbook.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        subtitle,
        style: plexMono(fontSize: 12, color: brandFgDim),
      ),
      onTap: onSwitch,
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 18),
        tooltip: 'Workbook actions',
        onSelected: (v) {
          switch (v) {
            case 'rename':
              onStubbed('Rename');
            case 'duplicate':
              onDuplicate();
            case 'export':
              onStubbed('Export');
            case 'delete':
              onStubbed('Delete');
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'rename', child: Text('Rename…')),
          const PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
          const PopupMenuItem(value: 'export', child: Text('Export…')),
          PopupMenuItem(
            value: 'delete',
            child: Text(
              'Delete',
              style: plexMono(fontSize: 13, color: brandAccent),
            ),
          ),
        ],
      ),
    );
  }

  /// Returns a short human-readable timestamp like "2m ago", "3h ago",
  /// "2d ago", or an absolute date for >30 days. Approximate is fine — this
  /// is a glanceable list, not a precision timeline.
  static String _relativeTime(DateTime utc) {
    final now = DateTime.now().toUtc();
    final diff = now.difference(utc);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 30) return '${diff.inDays}d ago';
    final y = utc.year.toString().padLeft(4, '0');
    final m = utc.month.toString().padLeft(2, '0');
    final d = utc.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
