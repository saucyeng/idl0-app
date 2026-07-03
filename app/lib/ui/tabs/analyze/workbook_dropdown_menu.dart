import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/workbook.dart';
import '../../../providers/workbook_provider.dart';
import '../../brand/brand.dart';

/// Actions emitted by the workbook dropdown menu.
///
/// [switchTo] is special — the menu emits a workbookId (the target ID) via
/// the second `onAction` parameter; other actions emit only the enum value.
enum WorkbookMenuAction {
  /// User picked a workbook from the recents list.
  switchTo,

  /// Open the full library picker. Implemented in Task 14.
  browseAll,

  /// Create a brand-new empty workbook.
  newWorkbook,

  /// Inline-rename the active workbook (existing flow on WorkbookBar).
  rename,

  /// Duplicate the active workbook (fresh UUID + " (Copy)" suffix).
  duplicate,

  /// Export the active workbook to disk. Implemented in Task 15.
  exportFile,

  /// Import a workbook from disk. Implemented in Task 15.
  importFile,

  /// Re-import the last-used `.idl0wb` (or pick one) and make it active — a
  /// one-tap reload for editing a workbook file externally (e.g. via the
  /// idl0-workbook-authoring skill) and seeing the result.
  reloadFromFile,

  /// Open per-workbook sync settings. Implemented in Task 16.
  syncSettings,

  /// Delete the active workbook (with confirm). Implemented in Task 15.
  delete,
}

/// Mono text style for a workbook dropdown menu item. Defaults to [brandFg];
/// pass [brandAccent] for the destructive Delete entry.
TextStyle _menuText([Color color = brandFg]) =>
    plexMono(fontSize: 13, color: color);

/// Dropdown attached to the workbook label in [WorkbookBar].
///
/// Spec §8.2 layout: active workbook with check, up to 5 recents, divider,
/// Browse all…, divider, actions, divider, Sync settings + Delete.
class WorkbookDropdownMenu extends ConsumerWidget {
  /// Creates a [WorkbookDropdownMenu].
  const WorkbookDropdownMenu({
    super.key,
    required this.activeWorkbookName,
    required this.activeWorkbookId,
    required this.onAction,
  });

  /// Display name of the active workbook — shown in the button label.
  final String activeWorkbookName;

  /// `workbookId` of the active workbook — used to filter recents and to
  /// label the "Rename …" entry.
  ///
  /// When the controller does not yet know the active workbook's UUID (e.g.
  /// when reading legacy [WorkbookData] via the bridge), pass an empty string
  /// — the menu will fall back to first-by-name matching.
  final String activeWorkbookId;

  /// Invoked when the user picks an entry. `workbookId` is non-null only for
  /// [WorkbookMenuAction.switchTo].
  final void Function(WorkbookMenuAction action, {String? workbookId}) onAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workbooks =
        ref.watch(workbookProvider).valueOrNull ?? const <Workbook>[];
    // Recents: workbooks other than the active, ordered by updatedAtMs desc,
    // capped at 5. Uses both id and name to filter so the active row is
    // excluded even when id matching falls back to name matching.
    final recents = ([...workbooks]
          ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs)))
        .where(
          (w) =>
              w.workbookId != activeWorkbookId && w.name != activeWorkbookName,
        )
        .take(5)
        .toList();

    return PopupMenuButton<Object>(
      tooltip: 'Workbook actions',
      onSelected: (value) {
        if (value is String) {
          onAction(WorkbookMenuAction.switchTo, workbookId: value);
        } else if (value is WorkbookMenuAction) {
          onAction(value);
        }
      },
      itemBuilder: (_) => [
        // Active workbook row with check — disabled so tapping is a no-op.
        PopupMenuItem<Object>(
          value: activeWorkbookId.isNotEmpty
              ? activeWorkbookId
              : WorkbookMenuAction.switchTo,
          enabled: false,
          child: Row(
            children: [
              const Icon(Icons.check, size: 16, color: brandGood),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  activeWorkbookName,
                  overflow: TextOverflow.ellipsis,
                  style: plexMono(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        // Up to 5 recent workbooks (other than active), newest first.
        for (final wb in recents)
          PopupMenuItem<Object>(
            value: wb.workbookId,
            child: Padding(
              padding: const EdgeInsets.only(left: 24),
              child: Text(
                wb.name,
                overflow: TextOverflow.ellipsis,
                style: _menuText(),
              ),
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          value: WorkbookMenuAction.browseAll,
          child: Text('Browse all…', style: _menuText()),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          value: WorkbookMenuAction.newWorkbook,
          child: Text('New workbook', style: _menuText()),
        ),
        PopupMenuItem<Object>(
          value: WorkbookMenuAction.rename,
          child: Text(
            'Rename "$activeWorkbookName"…',
            overflow: TextOverflow.ellipsis,
            style: _menuText(),
          ),
        ),
        PopupMenuItem<Object>(
          value: WorkbookMenuAction.duplicate,
          child: Text('Duplicate', style: _menuText()),
        ),
        PopupMenuItem<Object>(
          value: WorkbookMenuAction.exportFile,
          child: Text('Export…', style: _menuText()),
        ),
        PopupMenuItem<Object>(
          value: WorkbookMenuAction.importFile,
          child: Text('Import…', style: _menuText()),
        ),
        PopupMenuItem<Object>(
          value: WorkbookMenuAction.reloadFromFile,
          child: Text('Reload from file', style: _menuText()),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          value: WorkbookMenuAction.syncSettings,
          child: Text('Sync settings…', style: _menuText()),
        ),
        PopupMenuItem<Object>(
          value: WorkbookMenuAction.delete,
          child: Text('Delete', style: _menuText(brandAccent)),
        ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            activeWorkbookName,
            style: plexMono(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: brandFg,
            ),
          ),
          const Icon(Icons.arrow_drop_down, size: 18, color: brandFgDim),
        ],
      ),
    );
  }
}
