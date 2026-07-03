import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:idl0/data/cursor_pair.dart';
import 'package:idl0/data/workbook.dart';
import 'package:idl0/data/worksheet.dart';
import 'package:idl0/data/worksheet_block.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'workbook_provider.dart';

// Data classes moved to data/worksheet.dart. Re-exported so the many UI
// imports of "package:idl0/providers/workspace_provider.dart" that pull
// Worksheet / ChartSlot / enums keep compiling without churn. Prefer
// importing directly from data/worksheet.dart in new code.
export 'package:idl0/data/worksheet.dart';

// ---------------------------------------------------------------------------
// WorkbookData
// ---------------------------------------------------------------------------

/// A single workbook containing one or more worksheets. See §15.5.
class WorkbookData {
  /// Display name shown in the workbook selector, e.g. `Workbook 1`.
  final String name;

  /// Ordered list of worksheets for this workbook.
  final List<Worksheet> worksheets;

  /// Creates a [WorkbookData].
  const WorkbookData({required this.name, required this.worksheets});

  /// Returns a copy with the given fields replaced.
  WorkbookData copyWith({String? name, List<Worksheet>? worksheets}) =>
      WorkbookData(
        name: name ?? this.name,
        worksheets: worksheets ?? this.worksheets,
      );

  /// Serializes to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
        'name': name,
        'worksheets': worksheets.map((w) => w.toJson()).toList(),
      };

  /// Deserializes from a JSON map produced by [toJson].
  factory WorkbookData.fromJson(Map<String, dynamic> json) => WorkbookData(
        name: json['name'] as String,
        worksheets: (json['worksheets'] as List?)
                ?.map((w) => Worksheet.fromJson(w as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

// ---------------------------------------------------------------------------
// WorkspaceState
// ---------------------------------------------------------------------------

/// Immutable state for [workspaceProvider].
class WorkspaceState {
  /// All workbooks in this workspace.
  final List<WorkbookData> workbooks;

  /// Index of the currently displayed workbook within [workbooks].
  final int activeWorkbookIndex;

  /// Index of the currently displayed worksheet within the active workbook.
  final int activeWorksheetIndex;

  /// Per-worksheet zoom ranges keyed by worksheet UUID.
  ///
  /// A missing key (or null value) means full view. Persisted alongside
  /// [worksheetCursors] so zoom and cursor restore together on app reopen.
  final Map<String, XAxisRange?> worksheetRanges;

  /// Per-worksheet A/B cursor pair keyed by worksheet UUID.
  ///
  /// A missing key means an empty pair (`CursorPair()`). Persisted to
  /// SharedPreferences via [WorkspaceNotifier._persistUiState].
  final Map<String, CursorPair> worksheetCursors;

  /// Creates a [WorkspaceState].
  const WorkspaceState({
    required this.workbooks,
    required this.activeWorkbookIndex,
    required this.activeWorksheetIndex,
    this.worksheetRanges = const {},
    this.worksheetCursors = const {},
  });

  /// The currently active [WorkbookData].
  WorkbookData get activeWorkbook => workbooks[activeWorkbookIndex];

  /// The currently active [Worksheet].
  Worksheet get activeWorksheet =>
      activeWorkbook.worksheets[activeWorksheetIndex];

  /// Returns a copy with the given fields replaced.
  WorkspaceState copyWith({
    List<WorkbookData>? workbooks,
    int? activeWorkbookIndex,
    int? activeWorksheetIndex,
    Map<String, XAxisRange?>? worksheetRanges,
    Map<String, CursorPair>? worksheetCursors,
  }) =>
      WorkspaceState(
        workbooks: workbooks ?? this.workbooks,
        activeWorkbookIndex: activeWorkbookIndex ?? this.activeWorkbookIndex,
        activeWorksheetIndex: activeWorksheetIndex ?? this.activeWorksheetIndex,
        worksheetRanges: worksheetRanges ?? this.worksheetRanges,
        worksheetCursors: worksheetCursors ?? this.worksheetCursors,
      );

  /// Serializes persistent fields to JSON, including [worksheetRanges] and
  /// [worksheetCursors] so zoom and cursor state restore on app reopen.
  ///
  /// Note: [workbooks] is intentionally excluded — workbook content is owned
  /// by [workbookProvider] and persisted there. Only UI navigation state
  /// (active indices, ranges, cursors) is serialized here.
  Map<String, dynamic> toJson() => {
        'workbooks': workbooks.map((wb) => wb.toJson()).toList(),
        'activeWorkbookIndex': activeWorkbookIndex,
        'activeWorksheetIndex': activeWorksheetIndex,
        'worksheetRanges': {
          for (final entry in worksheetRanges.entries)
            if (entry.value != null)
              entry.key: {
                'startSecs': entry.value!.startSecs,
                'endSecs': entry.value!.endSecs,
              },
        },
        'worksheetCursors': {
          for (final entry in worksheetCursors.entries)
            entry.key: entry.value.toJson(),
        },
      };

  /// Deserializes from a JSON map produced by [toJson]. Missing or corrupt
  /// fields fall back to defaults so old or partial JSON loads without crash.
  factory WorkspaceState.fromJson(Map<String, dynamic> json) {
    final workbooks = (json['workbooks'] as List?)
        ?.map((wb) => WorkbookData.fromJson(wb as Map<String, dynamic>))
        .where((wb) => wb.worksheets.isNotEmpty)
        .toList();
    if (workbooks == null || workbooks.isEmpty) {
      return WorkspaceNotifier._defaultState();
    }
    final wbIndex = ((json['activeWorkbookIndex'] as int?) ?? 0)
        .clamp(0, workbooks.length - 1);
    final wsIndex = ((json['activeWorksheetIndex'] as int?) ?? 0)
        .clamp(0, workbooks[wbIndex].worksheets.length - 1);
    final ranges = <String, XAxisRange?>{};
    final rangesJson = json['worksheetRanges'] as Map<String, dynamic>? ?? {};
    rangesJson.forEach((k, v) {
      if (v is Map<String, dynamic>) {
        ranges[k] = XAxisRange(
          startSecs: (v['startSecs'] as num).toDouble(),
          endSecs: (v['endSecs'] as num).toDouble(),
        );
      }
    });
    final cursors = <String, CursorPair>{};
    final cursorsJson = json['worksheetCursors'] as Map<String, dynamic>? ?? {};
    cursorsJson.forEach((k, v) {
      if (v is Map<String, dynamic>) {
        cursors[k] = CursorPair.fromJson(v);
      }
    });
    return WorkspaceState(
      workbooks: workbooks,
      activeWorkbookIndex: wbIndex,
      activeWorksheetIndex: wsIndex,
      worksheetRanges: ranges,
      worksheetCursors: cursors,
    );
  }
}

// ---------------------------------------------------------------------------
// WorkspaceNotifier
// ---------------------------------------------------------------------------

/// SharedPreferences key for UI-only navigation state (active workbook/
/// worksheet indices, zoom ranges, cursors). Workbook content (name,
/// worksheets) is owned by [workbookProvider] and persisted there.
const _kWorkspaceUiState = 'workspace_ui_state';

/// Manages [WorkspaceState] — active workbook, active worksheet, chart layout,
/// per-chart properties, and X-axis zoom ranges.
///
/// **Bridge model.** Workbook content (name, worksheets, chart slots) is owned
/// by [workbookProvider] — mutations that change content call
/// [WorkbookNotifier.updateWorkbook] and the resulting Drive sync is handled
/// there. UI navigation state (active indices, zoom ranges, cursors) continues
/// to live in [WorkspaceState] and persists to SharedPreferences under the
/// `workspace_ui_state` key.
///
/// [workspaceProvider] rebuilds automatically whenever [workbookProvider]
/// emits a new list (e.g. after a Drive sync update).
class WorkspaceNotifier extends Notifier<WorkspaceState> {
  // ── UI navigation state — stored as instance fields so build() can read
  // them without accessing `state` (which is invalid during build). ──────────

  /// Index of the currently displayed workbook. Kept in sync with
  /// [WorkspaceState.activeWorkbookIndex] on every state mutation.
  int _activeWorkbookIndex = 0;

  /// Index of the currently displayed worksheet. Kept in sync with
  /// [WorkspaceState.activeWorksheetIndex] on every state mutation.
  int _activeWorksheetIndex = 0;

  /// Per-worksheet zoom ranges, keyed by worksheet UUID.
  Map<String, XAxisRange?> _worksheetRanges = const {};

  /// Per-worksheet A/B cursor pairs, keyed by worksheet UUID.
  Map<String, CursorPair> _worksheetCursors = const {};

  @override
  WorkspaceState build() {
    // Watch workbook list — UI rebuilds whenever workbookProvider changes.
    final wbs = ref.watch(workbookProvider).valueOrNull;

    // Restore UI navigation state (active indices, ranges, cursors)
    // asynchronously from the small UI prefs key.
    _loadUiStateFromPrefs();

    if (wbs == null || wbs.isEmpty) {
      // workbookProvider is still loading, errored, or has no workbooks yet.
      // Return the default state so the UI is immediately usable. The
      // instance-field indices stay at their defaults (0, 0).
      return WorkspaceState(
        workbooks: _defaultState().workbooks,
        activeWorkbookIndex: _activeWorkbookIndex,
        activeWorksheetIndex: _activeWorksheetIndex,
        worksheetRanges: _worksheetRanges,
        worksheetCursors: _worksheetCursors,
      );
    }

    // Translate Workbook → WorkbookData for the existing UI surface.
    final dataList = [
      for (final wb in wbs)
        WorkbookData(name: wb.name, worksheets: wb.worksheets),
    ];

    // Clamp active indices to the new list lengths in case a workbook or
    // worksheet was deleted externally (e.g. Drive sync). Update the
    // instance fields so subsequent mutations use the clamped values.
    // Guard against empty worksheets lists (workbooks from workbookProvider
    // may have no worksheets before the workspace notifier adds them).
    _activeWorkbookIndex = _activeWorkbookIndex.clamp(0, dataList.length - 1);
    final wsLen = dataList[_activeWorkbookIndex].worksheets.length;
    _activeWorksheetIndex =
        wsLen == 0 ? 0 : _activeWorksheetIndex.clamp(0, wsLen - 1);

    return WorkspaceState(
      workbooks: dataList,
      activeWorkbookIndex: _activeWorkbookIndex,
      activeWorksheetIndex: _activeWorksheetIndex,
      worksheetRanges: _worksheetRanges,
      worksheetCursors: _worksheetCursors,
    );
  }

  /// Default state returned synchronously before [workbookProvider] loads, or
  /// when it is empty. Every new workbook ships with a Session Sheet at
  /// index 0 (Lap Table + Lap Progression pinned) and a blank Standard Sheet
  /// at index 1 — the Standard Sheet is where the user adds their own charts.
  static WorkspaceState _defaultState() => WorkspaceState(
        workbooks: [
          WorkbookData(
            name: 'Workbook 1',
            worksheets: [
              Worksheet.sessionSheet(name: 'Session'),
              Worksheet(name: 'Charts', blocks: const []),
            ],
          ),
        ],
        activeWorkbookIndex: 0,
        activeWorksheetIndex: 0,
      );

  /// Test-only accessor for the default state. Production code reaches it
  /// through Riverpod build().
  @visibleForTesting
  static WorkspaceState testDefaultState() => _defaultState();

  // ── Persistence ──────────────────────────────────────────────────────────

  /// Restores UI navigation state (active indices, ranges, cursors) from the
  /// `workspace_ui_state` SharedPreferences key. Fire-and-forget; errors are
  /// silently swallowed so a prefs failure never blocks the UI.
  Future<void> _loadUiStateFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kWorkspaceUiState);
      if (raw == null) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;

      final wbIdx = (map['activeWorkbookIndex'] as int?) ?? 0;
      final wsIdx = (map['activeWorksheetIndex'] as int?) ?? 0;

      final ranges = <String, XAxisRange?>{};
      final rangesJson = map['worksheetRanges'] as Map<String, dynamic>? ?? {};
      rangesJson.forEach((k, v) {
        if (v is Map<String, dynamic>) {
          ranges[k] = XAxisRange(
            startSecs: (v['startSecs'] as num).toDouble(),
            endSecs: (v['endSecs'] as num).toDouble(),
          );
        }
      });

      final cursors = <String, CursorPair>{};
      final cursorsJson =
          map['worksheetCursors'] as Map<String, dynamic>? ?? {};
      cursorsJson.forEach((k, v) {
        if (v is Map<String, dynamic>) {
          cursors[k] = CursorPair.fromJson(v);
        }
      });

      // Clamp indices to the current workbook/worksheet list lengths.
      final wbs = state.workbooks;
      if (wbs.isEmpty) return;
      final clampedWbIdx = wbIdx.clamp(0, wbs.length - 1);
      final clampedWsIdx =
          wsIdx.clamp(0, wbs[clampedWbIdx].worksheets.length - 1);

      // Update instance fields first — build() reads these, not state.
      _activeWorkbookIndex = clampedWbIdx;
      _activeWorksheetIndex = clampedWsIdx;
      _worksheetRanges = ranges;
      _worksheetCursors = cursors;
      state = state.copyWith(
        activeWorkbookIndex: clampedWbIdx,
        activeWorksheetIndex: clampedWsIdx,
        worksheetRanges: ranges,
        worksheetCursors: cursors,
      );
    } catch (_) {
      // Corrupt or unreadable UI state → keep current state silently.
    }
  }

  /// Persists UI-only navigation state (active indices, ranges, cursors) to
  /// SharedPreferences under [_kWorkspaceUiState]. Fire-and-forget — errors
  /// are silently swallowed so a prefs failure never blocks the UI.
  void _persistUiState() {
    final uiJson = <String, dynamic>{
      'activeWorkbookIndex': state.activeWorkbookIndex,
      'activeWorksheetIndex': state.activeWorksheetIndex,
      'worksheetRanges': {
        for (final entry in state.worksheetRanges.entries)
          if (entry.value != null)
            entry.key: {
              'startSecs': entry.value!.startSecs,
              'endSecs': entry.value!.endSecs,
            },
      },
      'worksheetCursors': {
        for (final entry in state.worksheetCursors.entries)
          entry.key: entry.value.toJson(),
      },
    };
    SharedPreferences.getInstance()
        .then(
          (prefs) => prefs.setString(_kWorkspaceUiState, jsonEncode(uiJson)),
        )
        .ignore();
  }

  /// Single-flight guard for materializing the default workbook into an empty
  /// library (see [_persistActiveWorkbook]). Holds the in-flight seed upsert so
  /// back-to-back edits don't mint duplicate default workbooks before the first
  /// one lands in [workbookProvider].
  Future<void>? _seedFuture;

  /// Writes the active workbook's current content (name + worksheets) back to
  /// [workbookProvider] so changes are persisted to SQLite and Drive.
  ///
  /// **First-run seeding.** While the library is empty, the displayed workbook
  /// is the in-memory [_defaultState] phantom — it has no persisted entity yet.
  /// The first edit materializes it as a real [Workbook] (carrying the
  /// default's name + worksheets) so the edit survives an app restart.
  /// Previously this early-returned on an empty library, silently dropping
  /// every edit to the default workbook so it reset to the phantom on every
  /// relaunch. Single-flight ([_seedFuture]) so rapid edits create exactly one
  /// default rather than racing to mint duplicates.
  Future<void> _persistActiveWorkbook() async {
    final wbs = ref.read(workbookProvider).valueOrNull ?? const [];
    final activeData = state.workbooks[state.activeWorkbookIndex];

    if (wbs.isEmpty) {
      // A seed is already in flight — wait for it, then persist via the now
      // non-empty path so this edit's (possibly newer) content is written too.
      if (_seedFuture != null) {
        await _seedFuture;
        await _persistActiveWorkbook();
        return;
      }
      final seeded = Workbook.create(
        name: activeData.name,
        worksheets: activeData.worksheets,
      );
      _seedFuture = ref.read(workbookProvider.notifier).updateWorkbook(seeded);
      try {
        await _seedFuture;
      } finally {
        _seedFuture = null;
      }
      return;
    }

    final idx = state.activeWorkbookIndex.clamp(0, wbs.length - 1);
    final source = wbs[idx];
    final updated = source.copyWith(
      name: activeData.name,
      worksheets: activeData.worksheets,
    );
    await ref.read(workbookProvider.notifier).updateWorkbook(updated);
  }

  // ── Workbook navigation ───────────────────────────────────────────────────

  /// The index of the currently displayed workbook, mirroring
  /// [WorkspaceState.activeWorkbookIndex].
  ///
  /// Public read accessor so a collaborating notifier (e.g.
  /// [MathChannelNotifier]) can resolve the active workbook without `ref.read`,
  /// which throws while the caller's own provider is mid-rebuild after a
  /// workbook write. Reads the instance field, not `state`, so it is valid even
  /// during another provider's rebuild.
  int get activeWorkbookIndex => _activeWorkbookIndex;

  /// Switches to the workbook at [index] and resets the worksheet to 0.
  void setActiveWorkbook(int index) {
    _activeWorkbookIndex = index;
    _activeWorksheetIndex = 0;
    state = state.copyWith(
      activeWorkbookIndex: index,
      activeWorksheetIndex: 0,
    );
    _persistUiState();
  }

  /// Switches to the worksheet at [index] within the active workbook.
  void setActiveWorksheet(int index) {
    _activeWorksheetIndex = index;
    state = state.copyWith(activeWorksheetIndex: index);
    _persistUiState();
  }

  /// Renames the workbook at [workbookIndex].
  void renameWorkbook(int workbookIndex, String name) {
    final newWorkbooks = List<WorkbookData>.from(state.workbooks)
      ..[workbookIndex] = state.workbooks[workbookIndex].copyWith(name: name);
    state = state.copyWith(workbooks: newWorkbooks);
    _persistActiveWorkbook().ignore();
  }

  /// Renames the worksheet at [worksheetIndex] within the active workbook.
  void renameWorksheet(int worksheetIndex, String name) {
    final newSheets = List<Worksheet>.from(state.activeWorkbook.worksheets)
      ..[worksheetIndex] =
          state.activeWorkbook.worksheets[worksheetIndex].copyWith(name: name);
    final newWorkbook = state.activeWorkbook.copyWith(worksheets: newSheets);
    final newWorkbooks = List<WorkbookData>.from(state.workbooks)
      ..[state.activeWorkbookIndex] = newWorkbook;
    state = state.copyWith(workbooks: newWorkbooks);
    _persistActiveWorkbook().ignore();
  }

  /// Appends a new worksheet named [name] of [kind] to the active workbook.
  ///
  /// [WorksheetKind.standard] (default) creates a blank slate. Pass
  /// [WorksheetKind.sessionSheet] to mint a worksheet pre-populated with the
  /// pinned `lapTable` + `lapProgression` slots.
  void addWorksheet(
    String name, {
    WorksheetKind kind = WorksheetKind.standard,
  }) {
    final newSheet = kind == WorksheetKind.sessionSheet
        ? Worksheet.sessionSheet(name: name)
        : Worksheet(name: name);
    final updated = state.activeWorkbook.copyWith(
      worksheets: [...state.activeWorkbook.worksheets, newSheet],
    );
    final newWorkbooks = List<WorkbookData>.from(state.workbooks);
    newWorkbooks[state.activeWorkbookIndex] = updated;
    state = state.copyWith(workbooks: newWorkbooks);
    _persistActiveWorkbook().ignore();
  }

  /// Inserts a deep copy of the worksheet at [worksheetIndex] immediately
  /// after the source, names it `"{original} (copy)"`, switches the active
  /// worksheet to the new copy, and persists.
  ///
  /// Out-of-range [worksheetIndex] is a no-op. The new worksheet receives a
  /// fresh UUID (generated by [Worksheet]'s default constructor) so all
  /// worksheet-scoped state (cursors, zoom ranges) starts clean.
  ///
  /// Charts are copied by reference — [ChartSlot] is immutable so this is
  /// safe and matches how [addWorksheet] handles its initial chart list.
  void duplicateWorksheet(int worksheetIndex) {
    final wb = state.activeWorkbook;
    if (worksheetIndex < 0 || worksheetIndex >= wb.worksheets.length) return;
    final src = wb.worksheets[worksheetIndex];
    final copy = Worksheet(
      name: '${src.name} (copy)',
      xAxisMode: src.xAxisMode,
      blocks: List<WorksheetBlock>.from(src.blocks),
      kind: src.kind,
    );
    final newSheets = List<Worksheet>.from(wb.worksheets)
      ..insert(worksheetIndex + 1, copy);
    final newWorkbooks = List<WorkbookData>.from(state.workbooks);
    newWorkbooks[state.activeWorkbookIndex] =
        wb.copyWith(worksheets: newSheets);
    _activeWorksheetIndex = worksheetIndex + 1;
    state = state.copyWith(
      workbooks: newWorkbooks,
      activeWorksheetIndex: _activeWorksheetIndex,
    );
    _persistActiveWorkbook().ignore();
  }

  /// Removes the worksheet at [worksheetIndex] from the active workbook.
  ///
  /// No-op when [worksheetIndex] is out of range OR when removing it would
  /// leave the workbook with zero worksheets (a workbook always has at
  /// least one). Adjusts [activeWorksheetIndex] to keep it inside the new
  /// list.
  void removeWorksheet(int worksheetIndex) {
    final wb = state.activeWorkbook;
    if (worksheetIndex < 0 || worksheetIndex >= wb.worksheets.length) return;
    if (wb.worksheets.length <= 1) return;
    final newSheets = List<Worksheet>.from(wb.worksheets)
      ..removeAt(worksheetIndex);
    final newActive = state.activeWorksheetIndex >= newSheets.length
        ? newSheets.length - 1
        : state.activeWorksheetIndex;
    final newWorkbooks = List<WorkbookData>.from(state.workbooks)
      ..[state.activeWorkbookIndex] = wb.copyWith(worksheets: newSheets);
    _activeWorksheetIndex = newActive;
    state = state.copyWith(
      workbooks: newWorkbooks,
      activeWorksheetIndex: newActive,
    );
    _persistActiveWorkbook().ignore();
  }

  /// Appends a new workbook named [name] pre-populated with a Session Sheet
  /// + a blank Standard sheet (matches [_defaultState] for new workspaces).
  void addWorkbook(String name) {
    final newSheets = [
      Worksheet.sessionSheet(name: 'Session'),
      Worksheet(name: 'Charts', blocks: const []),
    ];
    state = state.copyWith(
      workbooks: [
        ...state.workbooks,
        WorkbookData(name: name, worksheets: newSheets),
      ],
    );
    // addWorkbook creates a new Workbook entity with the correct worksheets
    // and delegates to workbookProvider so the entity is persisted and synced.
    // updateWorkbook handles the "insert if not present" case via its upsert.
    final entity = Workbook.create(name: name, worksheets: newSheets);
    ref.read(workbookProvider.notifier).updateWorkbook(entity).ignore();
  }

  // ── X axis ────────────────────────────────────────────────────────────────

  /// Sets the [XAxisMode] for the currently active worksheet.
  void setXAxisMode(XAxisMode mode) {
    _replaceActiveWorksheet(state.activeWorksheet.copyWith(xAxisMode: mode));
    _persistActiveWorkbook().ignore();
  }

  /// Sets the visible X range for [worksheetId] to [[start], [end]] seconds.
  ///
  /// All time-series charts in that worksheet clip their X axis to this range.
  /// Call [resetXAxisRange] to restore the full view.
  void setXAxisRange(String worksheetId, double start, double end) {
    final updated = Map<String, XAxisRange?>.from(state.worksheetRanges)
      ..[worksheetId] = XAxisRange(startSecs: start, endSecs: end);
    _worksheetRanges = updated;
    state = state.copyWith(worksheetRanges: updated);
    _persistUiState();
  }

  /// Clears the zoom range for [worksheetId], restoring the full-data view.
  void resetXAxisRange(String worksheetId) {
    final updated = Map<String, XAxisRange?>.from(state.worksheetRanges)
      ..[worksheetId] = null;
    _worksheetRanges = updated;
    state = state.copyWith(worksheetRanges: updated);
    _persistUiState();
  }

  // ── Chart management ──────────────────────────────────────────────────────

  /// Appends a new [ChartSlot] of [chartType] to the active worksheet.
  void addChart([ChartType chartType = ChartType.timeSeries]) {
    final ws = state.activeWorksheet;
    _replaceActiveWorksheet(
      ws.withChartSlots([...ws.charts, ChartSlot(chartType: chartType)]),
    );
    _persistActiveWorkbook().ignore();
  }

  /// Removes the chart slot at [chartIndex] from the active worksheet.
  ///
  /// No-op when [chartIndex] is out of range OR when the active worksheet is
  /// a [WorksheetKind.sessionSheet] and [chartIndex] is one of the pinned
  /// slots (`< [kSessionSheetPinnedSlotCount]`). The pinned-slot guard logs
  /// a `debugPrint` so a stray caller surfaces in tooling without crashing.
  void removeChart(int chartIndex) {
    final ws = state.activeWorksheet;
    if (chartIndex < 0 || chartIndex >= ws.charts.length) return;
    if (ws.kind == WorksheetKind.sessionSheet &&
        chartIndex < kSessionSheetPinnedSlotCount) {
      debugPrint(
        'workspaceProvider.removeChart: refused to drop pinned slot '
        '$chartIndex of Session Sheet "${ws.name}".',
      );
      return;
    }
    final newCharts = List<ChartSlot>.from(ws.charts)..removeAt(chartIndex);
    _replaceActiveWorksheet(ws.withChartSlots(newCharts));
    _persistActiveWorkbook().ignore();
  }

  /// Moves the chart slot at [from] to position [to] on the active
  /// worksheet.
  ///
  /// `to` is the destination index **before** the source is removed —
  /// matching the [ReorderableListView.onReorder] convention. Callers can
  /// pass `onReorder` arguments verbatim; this method compensates
  /// internally.
  ///
  /// No-op when [from] or [to] is out of range, [from] equals the resolved
  /// insert index, or the move would involve a pinned index on a Session
  /// Sheet (`< [kSessionSheetPinnedSlotCount]`).
  void moveChart(int from, int to) {
    final ws = state.activeWorksheet;
    final charts = ws.charts;
    if (from < 0 || from >= charts.length) return;
    if (to < 0 || to > charts.length) return;
    if (ws.kind == WorksheetKind.sessionSheet) {
      if (from < kSessionSheetPinnedSlotCount ||
          to <= kSessionSheetPinnedSlotCount) {
        debugPrint(
          'workspaceProvider.moveChart: refused move involving pinned '
          'slot on Session Sheet "${ws.name}" (from=$from, to=$to).',
        );
        return;
      }
    }
    final insertAt = to > from ? to - 1 : to;
    if (insertAt == from) return;
    final newCharts = List<ChartSlot>.from(charts);
    final moved = newCharts.removeAt(from);
    newCharts.insert(insertAt, moved);
    _replaceActiveWorksheet(ws.withChartSlots(newCharts));
    _persistActiveWorkbook().ignore();
  }

  /// Adds [channelId] to `charts[chartIndex]` of the active worksheet.
  ///
  /// No-op if [channelId] is already present in the slot.
  void addChannelToChart(int chartIndex, String channelId) {
    final ws = state.activeWorksheet;
    final slot = ws.charts[chartIndex];
    if (slot.channelIds.contains(channelId)) return;
    final newSlot = slot.copyWith(channelIds: [...slot.channelIds, channelId]);
    final newCharts = List<ChartSlot>.from(ws.charts)..[chartIndex] = newSlot;
    _replaceActiveWorksheet(ws.withChartSlots(newCharts));
    _persistActiveWorkbook().ignore();
  }

  /// Removes [channelId] from `charts[chartIndex]` of the active worksheet.
  ///
  /// No-op if [channelId] is not present in the slot.
  void removeChannelFromChart(int chartIndex, String channelId) {
    final ws = state.activeWorksheet;
    final slot = ws.charts[chartIndex];
    if (!slot.channelIds.contains(channelId)) return;
    final newSlot = slot.copyWith(
      channelIds: slot.channelIds.where((id) => id != channelId).toList(),
    );
    final newCharts = List<ChartSlot>.from(ws.charts)..[chartIndex] = newSlot;
    _replaceActiveWorksheet(ws.withChartSlots(newCharts));
    _persistActiveWorkbook().ignore();
  }

  /// Adds [mathChannelId] to `charts[chartIndex].mathChannelIds`.
  ///
  /// No-op if [mathChannelId] is already present in the slot.
  void addMathChannelToChart(int chartIndex, String mathChannelId) {
    final ws = state.activeWorksheet;
    final slot = ws.charts[chartIndex];
    if (slot.mathChannelIds.contains(mathChannelId)) return;
    final newSlot = slot.copyWith(
      mathChannelIds: [...slot.mathChannelIds, mathChannelId],
    );
    final newCharts = List<ChartSlot>.from(ws.charts)..[chartIndex] = newSlot;
    _replaceActiveWorksheet(ws.withChartSlots(newCharts));
    _persistActiveWorkbook().ignore();
  }

  /// Removes [mathChannelId] from `charts[chartIndex].mathChannelIds`.
  ///
  /// No-op if [mathChannelId] is not present in the slot.
  void removeMathChannelFromChart(int chartIndex, String mathChannelId) {
    final ws = state.activeWorksheet;
    final slot = ws.charts[chartIndex];
    if (!slot.mathChannelIds.contains(mathChannelId)) return;
    final newSlot = slot.copyWith(
      mathChannelIds:
          slot.mathChannelIds.where((id) => id != mathChannelId).toList(),
    );
    final newCharts = List<ChartSlot>.from(ws.charts)..[chartIndex] = newSlot;
    _replaceActiveWorksheet(ws.withChartSlots(newCharts));
    _persistActiveWorkbook().ignore();
  }

  /// Replaces `charts[chartIndex]` in the active worksheet with [updated].
  ///
  /// Used by [_ChartPropertiesDialog] to apply Y-axis, height, colour,
  /// and channel-order changes atomically.
  void updateChartProperties(int chartIndex, ChartSlot updated) {
    final ws = state.activeWorksheet;
    final newCharts = List<ChartSlot>.from(ws.charts)..[chartIndex] = updated;
    _replaceActiveWorksheet(ws.withChartSlots(newCharts));
    _persistActiveWorkbook().ignore();
  }

  // ── Block management (charts + tables) ───────────────────────────────────

  /// Appends [block] to the active worksheet (the add-table flow). Tables
  /// land after the charts via the charts-before-tables invariant.
  void addBlock(WorksheetBlock block) {
    final ws = state.activeWorksheet;
    _replaceActiveWorksheet(ws.copyWith(blocks: [...ws.blocks, block]));
    _persistActiveWorkbook().ignore();
  }

  /// Replaces the block identified by [blockId] in the active worksheet with
  /// [updated]. No-op if no block carries that id. Used by the table editor to
  /// write an edited [TableModel] back into its block.
  void updateBlock(String blockId, WorksheetBlock updated) {
    final ws = state.activeWorksheet;
    final i = ws.blocks.indexWhere((b) => b.id == blockId);
    if (i < 0) return;
    final blocks = List<WorksheetBlock>.from(ws.blocks)..[i] = updated;
    _replaceActiveWorksheet(ws.copyWith(blocks: blocks));
    _persistActiveWorkbook().ignore();
  }

  /// Removes the block identified by [blockId] from the active worksheet.
  void removeBlock(String blockId) {
    final ws = state.activeWorksheet;
    final blocks = ws.blocks.where((b) => b.id != blockId).toList();
    if (blocks.length == ws.blocks.length) return;
    _replaceActiveWorksheet(ws.copyWith(blocks: blocks));
    _persistActiveWorkbook().ignore();
  }

  // ── Cursor management ─────────────────────────────────────────────────────

  /// Updates the A/B cursor pair for [worksheetId].
  ///
  /// Changes are UI-only navigation state and route to [_persistUiState].
  void setWorksheetCursor(String worksheetId, CursorPair pair) {
    final updated = Map<String, CursorPair>.from(state.worksheetCursors)
      ..[worksheetId] = pair;
    _worksheetCursors = updated;
    state = state.copyWith(worksheetCursors: updated);
    _persistUiState();
  }

  // ── View-state reset ─────────────────────────────────────────────────────

  /// Clears every worksheet's cached X-axis range + cursor.
  ///
  /// Called by [WorkbookViewContextNotifier.setPrimary] when the primary
  /// session changes — cursor/zoom from the prior session would otherwise
  /// bleed onto the new one. Persists the cleared UI state.
  ///
  /// Per-(workbook, session) restore lands in a follow-up; v1 ships with a
  /// clean reset per spec §7.
  void clearAllWorksheetViewState() {
    if (state.worksheetRanges.isEmpty && state.worksheetCursors.isEmpty) {
      return;
    }
    _worksheetRanges = const {};
    _worksheetCursors = const {};
    state = state.copyWith(
      worksheetRanges: const {},
      worksheetCursors: const {},
    );
    // ignore: unawaited_futures
    _persistUiState();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Total worksheet count across all workbooks.
  ///
  /// Used to auto-name new worksheets: `Sheet N` where N is this value + 1.
  int get totalWorksheetCount =>
      state.workbooks.fold(0, (sum, wb) => sum + wb.worksheets.length);

  void _replaceActiveWorksheet(Worksheet updated) {
    final newSheets = List<Worksheet>.from(state.activeWorkbook.worksheets)
      ..[state.activeWorksheetIndex] = updated;
    final newWorkbook = state.activeWorkbook.copyWith(worksheets: newSheets);
    final newWorkbooks = List<WorkbookData>.from(state.workbooks)
      ..[state.activeWorkbookIndex] = newWorkbook;
    state = state.copyWith(workbooks: newWorkbooks);
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// Provides the active workbook/worksheet state. See §17.
///
/// Content mutations (rename, add/remove worksheet, chart edits) propagate to
/// [workbookProvider] via [WorkspaceNotifier._persistActiveWorkbook]. UI-only
/// state (active indices, zoom ranges, cursors) persists to SharedPreferences
/// under [_kWorkspaceUiState].
final workspaceProvider =
    NotifierProvider<WorkspaceNotifier, WorkspaceState>(WorkspaceNotifier.new);
