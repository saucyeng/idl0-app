import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../data/workbook.dart';
import '../../../providers/workbook_provider.dart';
import '../../../providers/workspace_provider.dart';
import '../../brand/brand.dart';
import 'browse_workbooks_modal.dart';
import 'workbook_dropdown_menu.dart';
import 'workbook_sync_settings_dialog.dart';

/// SharedPreferences key remembering the last `.idl0wb` path imported or
/// reloaded via the workbook bar, so "Reload from file" is a one-tap
/// re-import (edit the file externally → reload → see it).
const String _kReloadPathKey = 'workbook_reload_last_path';

/// Workbook/worksheet selector bar displayed at the top of the Analyze tab.
///
/// Layout (left to right, full width, fixed 48 dp height):
/// - [DropdownButton] for workbook selection (double-tap name to rename)
/// - Vertical divider
/// - Scrollable [TabBar] for worksheet selection within the active workbook
///   (double-tap a tab label to rename)
/// - "+" [IconButton] to append a new auto-named worksheet
///
/// The [TabController] is rebuilt whenever the worksheet count changes so that
/// adding a sheet via "+" is reflected immediately without a hot-restart.
///
/// See §15.5.
class WorkbookBar extends ConsumerStatefulWidget {
  /// Creates a [WorkbookBar].
  const WorkbookBar({super.key});

  @override
  ConsumerState<WorkbookBar> createState() => _WorkbookBarState();
}

// TickerProviderStateMixin is required (not Single) because the TabController
// is disposed and recreated whenever the worksheet count changes. Single only
// allows createTicker to be called once per State lifetime — even after the
// first ticker is disposed its internal _ticker field stays non-null, so any
// subsequent createTicker call throws. TickerProviderStateMixin has no such
// restriction and is the correct choice whenever a ticker may be recreated.
class _WorkbookBarState extends ConsumerState<WorkbookBar>
    with TickerProviderStateMixin {
  late TabController _tabController;

  /// Non-null when the workbook name field is in inline-edit mode.
  TextEditingController? _workbookEditCtrl;

  /// Non-null when a worksheet tab label is in inline-edit mode.
  /// Stores the worksheet index being renamed.
  int? _renamingWorksheetIndex;
  TextEditingController? _worksheetEditCtrl;

  @override
  void initState() {
    super.initState();
    final state = ref.read(workspaceProvider);
    final worksheets = state.activeWorkbook.worksheets;
    final length = worksheets.isEmpty ? 1 : worksheets.length;
    _tabController = TabController(
      length: length,
      vsync: this,
      initialIndex: worksheets.isEmpty
          ? 0
          : state.activeWorksheetIndex.clamp(0, worksheets.length - 1),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _workbookEditCtrl?.dispose();
    _worksheetEditCtrl?.dispose();
    super.dispose();
  }

  void _startWorkbookRename(String currentName) {
    setState(() {
      _workbookEditCtrl = TextEditingController(text: currentName)
        ..selection =
            TextSelection(baseOffset: 0, extentOffset: currentName.length);
    });
  }

  void _commitWorkbookRename(int workbookIndex) {
    final name = _workbookEditCtrl?.text.trim() ?? '';
    if (name.isNotEmpty) {
      ref.read(workspaceProvider.notifier).renameWorkbook(workbookIndex, name);
    }
    setState(() {
      _workbookEditCtrl?.dispose();
      _workbookEditCtrl = null;
    });
  }

  /// Looks up the UUID for the active workbook by matching its display name
  /// against [workbookProvider]'s list.
  ///
  /// Returns null when [workbookProvider] hasn't loaded yet.
  /// Falls back to the first workbook when no name match is found — this is
  /// fragile when two workbooks share a name and will be fixed in Task 17
  /// when [WorkbookData] carries UUIDs directly.
  String? _activeWorkbookId(WorkspaceState state) {
    final wbs = ref.watch(workbookProvider).valueOrNull;
    if (wbs == null || wbs.isEmpty) return null;
    final activeName = state.workbooks[state.activeWorkbookIndex].name;
    return wbs
        .firstWhere(
          (w) => w.name == activeName,
          orElse: () => wbs.first,
        )
        .workbookId;
  }

  /// Resolves the persisted [Workbook] entity backing the active workbook by
  /// matching its display name against [wbs], or null when [wbs] is empty.
  ///
  /// [wbs] is empty when [workbookProvider] is still loading, has errored, or
  /// holds no persisted workbooks yet (a fresh user looking at the synthetic
  /// default "Workbook 1"). Callers that need a UUID-bearing entity (export,
  /// duplicate, sync settings, delete) must early-return on null rather than
  /// indexing into the empty list — see §15.5. Mirrors the guard in
  /// [_activeWorkbookId].
  Workbook? _resolveActiveWorkbook(
    List<Workbook> wbs,
    WorkspaceState state,
  ) {
    if (wbs.isEmpty) return null;
    final activeName = state.workbooks[state.activeWorkbookIndex].name;
    return wbs.firstWhere(
      (w) => w.name == activeName,
      orElse: () => wbs.first,
    );
  }

  /// Shows a transient SnackBar explaining that [verb] requires a workbook
  /// that has been persisted to [workbookProvider], which is not yet the case.
  void _showNoPersistedWorkbook(String verb) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('No saved workbook to $verb yet.')),
    );
  }

  /// Handles a [WorkbookMenuAction] emitted by [WorkbookDropdownMenu].
  Future<void> _onMenuAction(
    WorkbookMenuAction action, {
    String? workbookId,
  }) async {
    final notifierWS = ref.read(workspaceProvider.notifier);
    final notifierWB = ref.read(workbookProvider.notifier);
    final state = ref.read(workspaceProvider);

    switch (action) {
      case WorkbookMenuAction.switchTo:
        if (workbookId == null) return;
        final wbs =
            ref.read(workbookProvider).valueOrNull ?? const <Workbook>[];
        final idx = wbs.indexWhere((w) => w.workbookId == workbookId);
        if (idx < 0) return;
        notifierWS.setActiveWorkbook(idx);
      case WorkbookMenuAction.newWorkbook:
        final name = await _promptForName(context, 'New workbook', 'Untitled');
        if (name == null || name.isEmpty) return;
        await notifierWB.createWorkbook(name: name);
      case WorkbookMenuAction.rename:
        _startWorkbookRename(state.workbooks[state.activeWorkbookIndex].name);
      case WorkbookMenuAction.duplicate:
        final wbs =
            ref.read(workbookProvider).valueOrNull ?? const <Workbook>[];
        final source = _resolveActiveWorkbook(wbs, state);
        if (source == null) {
          _showNoPersistedWorkbook('duplicate');
          return;
        }
        await notifierWB.duplicateWorkbook(source);
      case WorkbookMenuAction.browseAll:
        if (!context.mounted) return;
        await showDialog<void>(
          context: context,
          builder: (_) => const BrowseWorkbooksModal(),
        );
      case WorkbookMenuAction.exportFile:
        final wbs =
            ref.read(workbookProvider).valueOrNull ?? const <Workbook>[];
        final source = _resolveActiveWorkbook(wbs, state);
        if (source == null) {
          _showNoPersistedWorkbook('export');
          return;
        }
        final outPath = await FilePicker.platform.saveFile(
          dialogTitle: 'Export workbook',
          fileName: '${source.name}.idl0wb',
          type: FileType.custom,
          allowedExtensions: const ['idl0wb'],
        );
        if (outPath == null) return;
        // saveFile on some platforms returns the path with the extension
        // already appended, on others it doesn't — defend with a check.
        final pathWithExt = outPath.toLowerCase().endsWith('.idl0wb')
            ? outPath
            : '$outPath.idl0wb';
        await notifierWB.exportToFile(source.workbookId, pathWithExt);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported "${source.name}"')),
        );

      case WorkbookMenuAction.importFile:
        // FileType.any — Android doesn't recognise 'idl0wb' as a MIME type, so
        // a custom-extension filter shows an empty/greyed picker (or throws),
        // which is why Import looked dead on mobile. Pick any file; the parser
        // validates content (importFromFile → Workbook.fromJson throws on a
        // non-workbook), so a wrong pick fails with a typed error instead of
        // being silently unselectable. Mirrors the .idl0 log-import path
        // (runs_provider.dart importFiles).
        final pick = await FilePicker.platform.pickFiles(
          dialogTitle: 'Import workbook',
          type: FileType.any,
        );
        if (pick == null || pick.files.isEmpty) return;
        final inPath = pick.files.single.path;
        if (inPath == null) return;
        // Remember it so "Reload from file" can re-import in one tap.
        await _rememberReloadPath(inPath);
        try {
          await notifierWB.importFromFile(inPath);
        } on StateError {
          // UUID collision — prompt the user.
          if (!mounted) return;
          final choice = await showDialog<ImportConflictPolicy?>(
            context: context,
            builder: (_) => AlertDialog(
              title: Text(
                'Workbook already exists',
                style: plexMono(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: brandFg,
                ),
              ),
              content: Text(
                'You already have a workbook with the same ID. Replace it, '
                'or import as a copy?',
                style: plexSans(fontSize: 13, color: brandFgDim),
              ),
              actions: [
                QuietButton(
                  label: 'Cancel',
                  onPressed: () => Navigator.of(context).pop(null),
                ),
                QuietButton(
                  label: 'Import as copy',
                  onPressed: () =>
                      Navigator.of(context).pop(ImportConflictPolicy.copy),
                ),
                QuietButton(
                  label: 'Replace',
                  emphasis: ButtonEmphasis.alert,
                  onPressed: () =>
                      Navigator.of(context).pop(ImportConflictPolicy.replace),
                ),
              ],
            ),
          );
          if (choice == null) return;
          if (!mounted) return;
          await notifierWB.importFromFile(inPath, conflictPolicy: choice);
        }

      case WorkbookMenuAction.reloadFromFile:
        final prefs = await SharedPreferences.getInstance();
        var path = prefs.getString(_kReloadPathKey);
        if (path == null) {
          // No remembered file yet — pick one (and remember it).
          // FileType.any for the same Android MIME-type reason as the Import
          // picker above; the reloaded file is parsed/validated downstream.
          final pick = await FilePicker.platform.pickFiles(
            dialogTitle: 'Reload workbook from file',
            type: FileType.any,
          );
          if (pick == null || pick.files.isEmpty) return;
          path = pick.files.single.path;
          if (path == null) return;
          await prefs.setString(_kReloadPathKey, path);
        }
        await _reloadFrom(path, notifierWB, notifierWS);

      case WorkbookMenuAction.syncSettings:
        final wbs =
            ref.read(workbookProvider).valueOrNull ?? const <Workbook>[];
        final target = _resolveActiveWorkbook(wbs, state);
        if (target == null) {
          _showNoPersistedWorkbook('configure');
          return;
        }
        await showDialog<void>(
          context: context,
          builder: (_) => WorkbookSyncSettingsDialog(
            workbookId: target.workbookId,
            workbookName: target.name,
          ),
        );

      case WorkbookMenuAction.delete:
        final wbs =
            ref.read(workbookProvider).valueOrNull ?? const <Workbook>[];
        final target = _resolveActiveWorkbook(wbs, state);
        if (target == null) {
          _showNoPersistedWorkbook('delete');
          return;
        }
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(
              'Delete "${target.name}"?',
              style: plexMono(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: brandFg,
              ),
            ),
            content: Text(
              'This cannot be undone.',
              style: plexSans(fontSize: 13, color: brandFgDim),
            ),
            actions: [
              QuietButton(
                label: 'Cancel',
                onPressed: () => Navigator.of(context).pop(false),
              ),
              QuietButton(
                label: 'Delete',
                emphasis: ButtonEmphasis.alert,
                filled: true,
                onPressed: () => Navigator.of(context).pop(true),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        await notifierWB.deleteWorkbook(target.workbookId);
        // Ensure SOMETHING remains so the UI always has a workbook to show.
        final remaining =
            ref.read(workbookProvider).valueOrNull ?? const <Workbook>[];
        if (remaining.isEmpty) {
          await notifierWB.createWorkbook(name: 'Workbook 1');
        }
    }
  }

  /// Persists [path] as the last-used `.idl0wb` so "Reload from file" can
  /// re-import it in one tap.
  Future<void> _rememberReloadPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kReloadPathKey, path);
  }

  /// Re-imports the `.idl0wb` at [path] with replace policy — an externally
  /// edited file overwrites its prior copy in place rather than prompting —
  /// and makes the reloaded workbook active so its content shows immediately.
  /// This is the edit-file → reload → preview loop (pairs with the
  /// idl0-workbook-authoring skill).
  Future<void> _reloadFrom(
    String path,
    WorkbookNotifier notifierWB,
    WorkspaceNotifier notifierWS,
  ) async {
    final Workbook stored;
    try {
      stored = await notifierWB.importFromFile(
        path,
        conflictPolicy: ImportConflictPolicy.replace,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reload failed: $e')),
      );
      return;
    }
    // Activate the reloaded workbook so the user sees it immediately.
    final wbs = ref.read(workbookProvider).valueOrNull ?? const <Workbook>[];
    final idx = wbs.indexWhere((w) => w.workbookId == stored.workbookId);
    if (idx >= 0) notifierWS.setActiveWorkbook(idx);
    if (!mounted) return;
    final name = path.split(RegExp(r'[/\\]')).last;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Reloaded "$name"')),
    );
  }

  /// Shows a dialog prompting for a workbook name.
  ///
  /// Returns the trimmed name string, or null when the user cancels.
  Future<String?> _promptForName(
    BuildContext context,
    String title,
    String initialValue,
  ) async {
    final controller = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(
          title,
          style: plexMono(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: brandFg,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: plexMono(fontSize: 14, color: brandFg),
          cursorColor: brandFg,
          decoration: InputDecoration(
            hintText: 'Workbook name',
            hintStyle: plexSans(fontSize: 13, color: brandFgFaint),
          ),
        ),
        actions: [
          QuietButton(
            label: 'Cancel',
            onPressed: () => Navigator.of(context).pop(null),
          ),
          QuietButton(
            label: 'Create',
            filled: true,
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  void _startWorksheetRename(int worksheetIndex, String currentName) {
    setState(() {
      _renamingWorksheetIndex = worksheetIndex;
      _worksheetEditCtrl = TextEditingController(text: currentName)
        ..selection =
            TextSelection(baseOffset: 0, extentOffset: currentName.length);
    });
  }

  void _commitWorksheetRename(int worksheetIndex) {
    final name = _worksheetEditCtrl?.text.trim() ?? '';
    if (name.isNotEmpty) {
      ref
          .read(workspaceProvider.notifier)
          .renameWorksheet(worksheetIndex, name);
    }
    setState(() {
      _renamingWorksheetIndex = null;
      _worksheetEditCtrl?.dispose();
      _worksheetEditCtrl = null;
    });
  }

  /// Shows a Rename / Duplicate popup menu at [globalPosition] for the
  /// worksheet tab at [worksheetIndex]. Desktop-only — wired via
  /// `onSecondaryTapDown` on each non-renaming `Tab`.
  Future<void> _showSheetContextMenu(
    Offset globalPosition,
    int worksheetIndex,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final ws =
        ref.read(workspaceProvider).activeWorkbook.worksheets[worksheetIndex];
    final choice = await showMenu<_SheetMenuAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<_SheetMenuAction>(
          value: _SheetMenuAction.rename,
          child: _menuTile(Icons.edit, 'Rename', iconSize: 16),
        ),
        PopupMenuItem<_SheetMenuAction>(
          value: _SheetMenuAction.duplicate,
          child: _menuTile(Icons.copy, 'Duplicate', iconSize: 16),
        ),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case null:
        return;
      case _SheetMenuAction.rename:
        _startWorksheetRename(worksheetIndex, ws.name);
      case _SheetMenuAction.duplicate:
        ref.read(workspaceProvider.notifier).duplicateWorksheet(worksheetIndex);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(workspaceProvider);
    final worksheets = state.activeWorkbook.worksheets;

    // Rebuild TabController when worksheet count changes (e.g. after "+" tap).
    // Floor length at 1: TabController.length must be >= 1, and with length < 2
    // Flutter sets _animationController to null, making index assignment throw.
    final controllerLength = worksheets.isEmpty ? 1 : worksheets.length;
    if (_tabController.length != controllerLength) {
      _tabController.dispose();
      _tabController = TabController(
        length: controllerLength,
        vsync: this,
        initialIndex: worksheets.isEmpty
            ? 0
            : state.activeWorksheetIndex.clamp(0, worksheets.length - 1),
      );
    }

    // Keep controller in sync when worksheet changes programmatically.
    // Guard the assignment: with length == 1 the internal _animationController
    // is null and `index =` calls `_animationController!.value`, which throws.
    if (_tabController.length > 1 &&
        _tabController.index != state.activeWorksheetIndex &&
        state.activeWorksheetIndex < worksheets.length) {
      _tabController.index = state.activeWorksheetIndex;
    }

    return Container(
      decoration: const BoxDecoration(
        color: brandSurface,
        border: Border(
          bottom: BorderSide(color: brandRule, width: brandHairlineWidth),
        ),
      ),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: _workbookEditCtrl != null
                  ? _WorkbookNameField(
                      controller: _workbookEditCtrl!,
                      onSubmit: () =>
                          _commitWorkbookRename(state.activeWorkbookIndex),
                    )
                  : WorkbookDropdownMenu(
                      activeWorkbookName:
                          state.workbooks[state.activeWorkbookIndex].name,
                      activeWorkbookId: _activeWorkbookId(state) ?? '',
                      onAction: (action, {workbookId}) =>
                          _onMenuAction(action, workbookId: workbookId),
                    ),
            ),
            const VerticalDivider(
              width: 1,
              thickness: brandHairlineWidth,
              color: brandRule,
            ),
            Expanded(
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                onTap: (i) =>
                    ref.read(workspaceProvider.notifier).setActiveWorksheet(i),
                tabs: [
                  for (var i = 0; i < worksheets.length; i++)
                    _renamingWorksheetIndex == i
                        ? Tab(
                            child: _WorksheetNameField(
                              controller: _worksheetEditCtrl!,
                              onSubmit: () => _commitWorksheetRename(i),
                            ),
                          )
                        : GestureDetector(
                            onDoubleTap: () =>
                                _startWorksheetRename(i, worksheets[i].name),
                            onSecondaryTapDown: (details) =>
                                _showSheetContextMenu(
                              details.globalPosition,
                              i,
                            ),
                            child: Tab(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (worksheets[i].kind ==
                                      WorksheetKind.sessionSheet) ...[
                                    const Icon(
                                      Icons.list_alt,
                                      size: 12,
                                      color: brandFgDim,
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                  Text(
                                    worksheets[i].name.toUpperCase(),
                                    style: plexMono(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500,
                                      letterSpacing: brandLabelTracking,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                ],
              ),
            ),
            PopupMenuButton<WorksheetKind>(
              icon: const Icon(Icons.add, size: 20, color: brandFgDim),
              tooltip: 'Add worksheet',
              onSelected: (kind) {
                final notifier = ref.read(workspaceProvider.notifier);
                final nextNum = notifier.totalWorksheetCount + 1;
                final defaultName = kind == WorksheetKind.sessionSheet
                    ? 'Session $nextNum'
                    : 'Sheet $nextNum';
                notifier.addWorksheet(defaultName, kind: kind);
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: WorksheetKind.standard,
                  child: _menuTile(Icons.insert_chart_outlined, 'Standard'),
                ),
                PopupMenuItem(
                  value: WorksheetKind.sessionSheet,
                  child: _menuTile(Icons.list_alt, 'Session Sheet'),
                ),
              ],
            ),
            const VerticalDivider(
              width: 1,
              thickness: brandHairlineWidth,
              color: brandRule,
            ),
            const _XAxisDropdown(),
          ],
        ),
      ),
    );
  }
}

/// A brand-styled dense [ListTile] for the workbook-bar popup menus — dim
/// leading icon, mono [brandFg] label.
Widget _menuTile(IconData icon, String label, {double iconSize = 18}) =>
    ListTile(
      leading: Icon(icon, size: iconSize, color: brandFgDim),
      title: Text(label, style: plexMono(fontSize: 13, color: brandFg)),
      dense: true,
      contentPadding: EdgeInsets.zero,
    );

/// Inline text field shown in place of the workbook dropdown while renaming.
class _WorkbookNameField extends StatelessWidget {
  const _WorkbookNameField({
    required this.controller,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 120,
        child: TextField(
          controller: controller,
          autofocus: true,
          style: plexMono(fontSize: 14, color: brandFg),
          cursorColor: brandFg,
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          ),
          onSubmitted: (_) => onSubmit(),
          onTapOutside: (_) => onSubmit(),
          inputFormatters: [LengthLimitingTextInputFormatter(40)],
        ),
      );
}

/// Inline text field shown inside a worksheet [Tab] while renaming.
class _WorksheetNameField extends StatelessWidget {
  const _WorksheetNameField({
    required this.controller,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 80,
        child: TextField(
          controller: controller,
          autofocus: true,
          style: plexMono(fontSize: 12, color: brandFg),
          cursorColor: brandFg,
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          ),
          onSubmitted: (_) => onSubmit(),
          onTapOutside: (_) => onSubmit(),
          inputFormatters: [LengthLimitingTextInputFormatter(30)],
        ),
      );
}

/// Actions in the worksheet-tab right-click context menu (desktop-only).
enum _SheetMenuAction { rename, duplicate }

/// Compact monospace dropdown for the worksheet's X axis mode. Sits in the
/// right edge of [WorkbookBar] beside the "+" add-worksheet button.
class _XAxisDropdown extends ConsumerWidget {
  const _XAxisDropdown();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(workspaceProvider).activeWorksheet.xAxisMode;
    return PopupMenuButton<XAxisMode>(
      tooltip: 'X axis',
      onSelected: (m) => ref.read(workspaceProvider.notifier).setXAxisMode(m),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: XAxisMode.time,
          child: _menuTile(Icons.access_time, 'Time', iconSize: 16),
        ),
        PopupMenuItem(
          value: XAxisMode.wheelDistance,
          child: _menuTile(Icons.tire_repair, 'Wheel', iconSize: 16),
        ),
        PopupMenuItem(
          value: XAxisMode.gpsDistance,
          child: _menuTile(Icons.gps_fixed, 'GPS', iconSize: 16),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _labelFor(mode),
              style: plexMono(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: brandLabelTracking,
                color: brandFg,
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 16, color: brandFgDim),
          ],
        ),
      ),
    );
  }

  static String _labelFor(XAxisMode mode) {
    switch (mode) {
      case XAxisMode.time:
        return 'TIME';
      case XAxisMode.wheelDistance:
        return 'WHEEL';
      case XAxisMode.gpsDistance:
        return 'GPS';
    }
  }
}
