import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/cursor_pair.dart';
import 'package:idl0/data/workbook.dart';
import 'package:idl0/providers/workbook_provider.dart';
import 'package:idl0/providers/workspace_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Fake WorkbookNotifier — in-memory backend, tracks updateWorkbook calls.
// ---------------------------------------------------------------------------

/// Fake WorkbookNotifier — records mutation calls but does NOT emit new state.
///
/// Silent mode is intentional: state-mutation tests care only about in-memory
/// [WorkspaceState] correctness; preventing [workbookProvider] from emitting
/// avoids spurious rebuilds that would overwrite workspace state mid-test.
/// Bridge-behaviour tests assert on [updatedWorkbooks] to verify persistence
/// routing without needing a reactive fake.
class _FakeWorkbookNotifier extends WorkbookNotifier {
  /// Workbooks injected at construction; returned from [build] immediately.
  final List<Workbook> _initial;

  /// All [updateWorkbook] calls recorded in order.
  final List<Workbook> updatedWorkbooks = [];

  _FakeWorkbookNotifier({List<Workbook>? initial}) : _initial = initial ?? [];

  @override
  Future<List<Workbook>> build() async => _initial;

  @override
  Future<void> updateWorkbook(Workbook workbook) async {
    updatedWorkbooks.add(workbook);
    // Intentionally silent — do not mutate state so workspaceProvider is
    // not rebuilt mid-test.
  }

  @override
  Future<Workbook> createWorkbook({required String name}) async {
    // Intentionally silent — workspace tests don't need Drive-side creation.
    return Workbook.create(name: name);
  }
}

// ---------------------------------------------------------------------------
// Helper — builds a ProviderContainer with workbookProvider overridden.
// ---------------------------------------------------------------------------

/// Builds a [ProviderContainer] with [workbookProvider] overridden by a
/// [_FakeWorkbookNotifier] seeded with [initialWorkbooks].
///
/// When [initialWorkbooks] is null or empty, [workspaceProvider] falls back
/// to [WorkspaceNotifier._defaultState] (Workbook 1 with Session + Charts).
ProviderContainer _buildContainer({
  _FakeWorkbookNotifier? fakeNotifier,
}) {
  SharedPreferences.setMockInitialValues(const {});
  final notifier = fakeNotifier ?? _FakeWorkbookNotifier();
  final container = ProviderContainer(
    overrides: [
      workbookProvider.overrideWith(() => notifier),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  test(
      'workspaceProvider — initial state — Workbook 1 with Session Sheet + Charts',
      () {
    // Arrange / Act — read initial state; workbookProvider returns empty list
    // so WorkspaceNotifier falls back to _defaultState.
    final container = _buildContainer();
    final state = container.read(workspaceProvider);

    // Assert — one workbook, two worksheets: Session (pinned gpsMap +
    // lapTable + lapProgression) at index 0, blank Charts at index 1.
    expect(state.workbooks, hasLength(1));
    expect(state.workbooks.first.name, equals('Workbook 1'));
    expect(state.workbooks.first.worksheets, hasLength(2));
    final session = state.workbooks.first.worksheets[0];
    final charts = state.workbooks.first.worksheets[1];
    expect(session.kind, equals(WorksheetKind.sessionSheet));
    expect(session.name, equals('Session'));
    expect(
      session.charts.map((c) => c.chartType),
      equals([
        ChartType.gpsMap,
        ChartType.lapTable,
        ChartType.lapProgression,
      ]),
    );
    expect(charts.kind, equals(WorksheetKind.standard));
    expect(charts.name, equals('Charts'));
    expect(charts.charts, isEmpty);
    expect(state.activeWorkbookIndex, equals(0));
    expect(state.activeWorksheetIndex, equals(0));
  });

  test(
      'workspaceProvider — editing the default workbook persists it '
      '(regression: phantom default reset on restart)', () {
    // Arrange — empty library, so workspaceProvider shows the in-memory default
    // ("Workbook 1" with Session + Charts). Nothing is persisted yet.
    final notifier = _FakeWorkbookNotifier();
    final container = _buildContainer(fakeNotifier: notifier);
    expect(notifier.updatedWorkbooks, isEmpty);

    // Act — any content edit on the default routes through
    // _persistActiveWorkbook; rename is the simplest.
    container.read(workspaceProvider.notifier).renameWorkbook(0, 'My Setup');

    // Assert — the default was materialized + persisted as a real Workbook
    // carrying the edit + the default worksheets. Previously the empty-library
    // early-return dropped this, so the edit was lost on the next launch.
    expect(notifier.updatedWorkbooks, hasLength(1));
    final persisted = notifier.updatedWorkbooks.single;
    expect(persisted.name, equals('My Setup'));
    expect(persisted.worksheets, hasLength(2));
  });

  test('workspaceProvider — setActiveWorksheet — updates activeWorksheetIndex',
      () {
    // Arrange
    final container = _buildContainer();
    container.read(workspaceProvider.notifier).addWorksheet('Sheet 2');

    // Act
    container.read(workspaceProvider.notifier).setActiveWorksheet(1);

    // Assert
    expect(container.read(workspaceProvider).activeWorksheetIndex, equals(1));
  });

  test('workspaceProvider — setActiveWorkbook — resets worksheet index to 0',
      () {
    // Arrange
    final container = _buildContainer();
    container.read(workspaceProvider.notifier).addWorkbook('Workbook 2');

    // Act
    container.read(workspaceProvider.notifier).setActiveWorkbook(1);

    // Assert
    expect(container.read(workspaceProvider).activeWorkbookIndex, equals(1));
    expect(container.read(workspaceProvider).activeWorksheetIndex, equals(0));
  });

  test(
      'workspaceProvider — addWorksheet — appends standard sheet to active workbook',
      () {
    // Arrange / Act
    final container = _buildContainer();
    container.read(workspaceProvider.notifier).addWorksheet('Sheet 3');

    // Assert — default Session + Charts + appended Sheet 3 = three worksheets.
    final worksheets =
        container.read(workspaceProvider).activeWorkbook.worksheets;
    expect(worksheets, hasLength(3));
    expect(
      worksheets.map((w) => w.name),
      equals(['Session', 'Charts', 'Sheet 3']),
    );
    // Default kind is standard.
    expect(worksheets.last.kind, equals(WorksheetKind.standard));
  });

  test(
      'workspaceProvider — addWorksheet(kind: sessionSheet) — pinned slots pre-populated',
      () {
    // Arrange / Act
    final container = _buildContainer();
    container.read(workspaceProvider.notifier).addWorksheet(
          'Session 2',
          kind: WorksheetKind.sessionSheet,
        );

    // Assert
    final added =
        container.read(workspaceProvider).activeWorkbook.worksheets.last;
    expect(added.kind, equals(WorksheetKind.sessionSheet));
    expect(
      added.charts.map((c) => c.chartType),
      equals([
        ChartType.gpsMap,
        ChartType.lapTable,
        ChartType.lapProgression,
      ]),
    );
  });

  test('workspaceProvider — addWorksheet — worksheet count increments', () {
    // Arrange — initial count is 2 (Session + Charts).
    final container = _buildContainer();
    expect(
      container.read(workspaceProvider.notifier).totalWorksheetCount,
      equals(2),
    );

    // Act
    container.read(workspaceProvider.notifier).addWorksheet('Sheet 3');

    // Assert
    expect(
      container.read(workspaceProvider).activeWorkbook.worksheets,
      hasLength(3),
    );
    expect(
      container.read(workspaceProvider.notifier).totalWorksheetCount,
      equals(3),
    );
  });

  test(
      'workspaceProvider — addWorkbook — new workbook ships with Session Sheet + Charts',
      () {
    // Arrange / Act
    final container = _buildContainer();
    container.read(workspaceProvider.notifier).addWorkbook('Workbook 2');

    // Assert
    expect(container.read(workspaceProvider).workbooks, hasLength(2));
    final newWb = container.read(workspaceProvider).workbooks.last;
    expect(newWb.worksheets, hasLength(2));
    expect(newWb.worksheets.first.name, equals('Session'));
    expect(newWb.worksheets.first.kind, equals(WorksheetKind.sessionSheet));
    expect(newWb.worksheets.last.name, equals('Charts'));
    expect(newWb.worksheets.last.kind, equals(WorksheetKind.standard));
  });

  test('workspaceProvider — setXAxisMode — persists mode on active worksheet',
      () {
    // Arrange — default mode is time
    final container = _buildContainer();
    expect(
      container.read(workspaceProvider).activeWorksheet.xAxisMode,
      equals(XAxisMode.time),
    );

    // Act
    container
        .read(workspaceProvider.notifier)
        .setXAxisMode(XAxisMode.gpsDistance);

    // Assert
    expect(
      container.read(workspaceProvider).activeWorksheet.xAxisMode,
      equals(XAxisMode.gpsDistance),
    );
  });

  test(
      'workspaceProvider — addChart — appends empty ChartSlot to active worksheet',
      () {
    // Arrange — switch to the standard "Charts" worksheet (index 1) which
    // starts blank; index 0 is the Session Sheet with two pinned charts.
    final container = _buildContainer();
    container.read(workspaceProvider.notifier).setActiveWorksheet(1);
    expect(
      container.read(workspaceProvider).activeWorksheet.charts,
      isEmpty,
    );

    // Act
    container.read(workspaceProvider.notifier).addChart();

    // Assert
    expect(
      container.read(workspaceProvider).activeWorksheet.charts,
      hasLength(1),
    );
    expect(
      container.read(workspaceProvider).activeWorksheet.charts.last.channelIds,
      isEmpty,
    );
  });

  test('workspaceProvider — addChannelToChart — adds channelId to correct slot',
      () {
    // Arrange
    final container = _buildContainer();
    container.read(workspaceProvider.notifier).addChart();
    final notifier = container.read(workspaceProvider.notifier);

    // Act — add to slot 0, not slot 1
    notifier.addChannelToChart(0, 'IMU0_AccelZ');

    // Assert
    final charts = container.read(workspaceProvider).activeWorksheet.charts;
    expect(charts[0].channelIds, equals(['IMU0_AccelZ']));
    expect(charts[1].channelIds, isEmpty);
  });

  test('workspaceProvider — removeChannelFromChart — removes channelId', () {
    // Arrange
    final container = _buildContainer();
    container
        .read(workspaceProvider.notifier)
        .addChannelToChart(0, 'IMU0_AccelZ');
    container
        .read(workspaceProvider.notifier)
        .addChannelToChart(0, 'IMU1_AccelZ');
    expect(
      container.read(workspaceProvider).activeWorksheet.charts[0].channelIds,
      equals(['IMU0_AccelZ', 'IMU1_AccelZ']),
    );

    // Act
    container
        .read(workspaceProvider.notifier)
        .removeChannelFromChart(0, 'IMU0_AccelZ');

    // Assert
    expect(
      container.read(workspaceProvider).activeWorksheet.charts[0].channelIds,
      equals(['IMU1_AccelZ']),
    );
  });

  test('workspaceProvider — addChannelToChart — duplicate channelId is no-op',
      () {
    // Arrange
    final container = _buildContainer();
    container
        .read(workspaceProvider.notifier)
        .addChannelToChart(0, 'WheelFront');
    expect(
      container.read(workspaceProvider).activeWorksheet.charts[0].channelIds,
      equals(['WheelFront']),
    );

    // Act — add the same channel again
    container
        .read(workspaceProvider.notifier)
        .addChannelToChart(0, 'WheelFront');

    // Assert — still only one entry
    expect(
      container.read(workspaceProvider).activeWorksheet.charts[0].channelIds,
      equals(['WheelFront']),
    );
  });

  test(
      'workspaceProvider — setXAxisMode on worksheet 0 — worksheet 1 mode unchanged',
      () {
    // Arrange — two worksheets; activate worksheet 0
    final container = _buildContainer();
    container.read(workspaceProvider.notifier).addWorksheet('Sheet 2');
    container.read(workspaceProvider.notifier).setActiveWorksheet(0);

    // Act — change mode on worksheet 0
    container
        .read(workspaceProvider.notifier)
        .setXAxisMode(XAxisMode.wheelDistance);

    // Assert — worksheet 1 still has default mode
    container.read(workspaceProvider.notifier).setActiveWorksheet(1);
    expect(
      container.read(workspaceProvider).activeWorksheet.xAxisMode,
      equals(XAxisMode.time),
    );
  });

  test('ChartSlot — default values — all new fields have expected defaults',
      () {
    // Arrange / Act
    final slot = ChartSlot();

    // Assert
    expect(slot.mathChannelIds, isEmpty);
    expect(slot.yScaleMode, equals(YScaleMode.auto));
    expect(slot.yMin, isNull);
    expect(slot.yMax, isNull);
    expect(slot.heightFactor, equals(1.0));
    expect(slot.channelColors, isEmpty);
  });

  test('ChartSlot — copyWith — updates all new fields independently', () {
    // Arrange
    final original = ChartSlot();

    // Act
    final updated = original.copyWith(
      mathChannelIds: ['mc-1'],
      yScaleMode: YScaleMode.manual,
      yMin: -5.0,
      yMax: 5.0,
      heightFactor: 2.0,
      channelColors: {'ch1': 0xFFFF0000},
    );

    // Assert — updated slot has new values
    expect(updated.mathChannelIds, equals(['mc-1']));
    expect(updated.yScaleMode, equals(YScaleMode.manual));
    expect(updated.yMin, equals(-5.0));
    expect(updated.yMax, equals(5.0));
    expect(updated.heightFactor, equals(2.0));
    expect(updated.channelColors, equals({'ch1': 0xFFFF0000}));
    // Original is unchanged (immutable)
    expect(original.mathChannelIds, isEmpty);
    expect(original.yMin, isNull);
    expect(original.heightFactor, equals(1.0));
  });

  test('workspaceProvider — addMathChannelToChart — adds mathChannelId to slot',
      () {
    // Arrange — initial slot has no math channels
    final container = _buildContainer();
    expect(
      container
          .read(workspaceProvider)
          .activeWorksheet
          .charts[0]
          .mathChannelIds,
      isEmpty,
    );

    // Act
    container.read(workspaceProvider.notifier).addMathChannelToChart(0, 'mc-1');

    // Assert
    expect(
      container
          .read(workspaceProvider)
          .activeWorksheet
          .charts[0]
          .mathChannelIds,
      equals(['mc-1']),
    );
  });

  test('workspaceProvider — removeMathChannelFromChart — removes mathChannelId',
      () {
    // Arrange
    final container = _buildContainer();
    container.read(workspaceProvider.notifier).addMathChannelToChart(0, 'mc-1');
    container.read(workspaceProvider.notifier).addMathChannelToChart(0, 'mc-2');

    // Act
    container
        .read(workspaceProvider.notifier)
        .removeMathChannelFromChart(0, 'mc-1');

    // Assert — only mc-2 remains
    expect(
      container
          .read(workspaceProvider)
          .activeWorksheet
          .charts[0]
          .mathChannelIds,
      equals(['mc-2']),
    );
  });

  test(
      'workspaceProvider — updateChartProperties — replaces slot at chartIndex',
      () {
    // Arrange
    final container = _buildContainer();
    container
        .read(workspaceProvider.notifier)
        .addChannelToChart(0, 'IMU0_AccelZ');
    final updated = ChartSlot(
      channelIds: ['IMU0_AccelZ'],
      yScaleMode: YScaleMode.manual,
      yMin: -10.0,
      yMax: 10.0,
      heightFactor: 1.5,
    );

    // Act
    container
        .read(workspaceProvider.notifier)
        .updateChartProperties(0, updated);

    // Assert
    final slot = container.read(workspaceProvider).activeWorksheet.charts[0];
    expect(slot.yScaleMode, equals(YScaleMode.manual));
    expect(slot.yMin, equals(-10.0));
    expect(slot.yMax, equals(10.0));
    expect(slot.heightFactor, equals(1.5));
  });

  test('workspaceProvider — removeChart — drops slot at index', () {
    // Arrange — switch to the standard "Charts" worksheet (blank), then
    // add two default charts. Two-slot scenario.
    final container = _buildContainer();
    container.read(workspaceProvider.notifier).setActiveWorksheet(1);
    container.read(workspaceProvider.notifier).addChart();
    container.read(workspaceProvider.notifier).addChart(ChartType.fft);
    expect(
      container.read(workspaceProvider).activeWorksheet.charts,
      hasLength(2),
    );

    // Act — drop the second slot.
    container.read(workspaceProvider.notifier).removeChart(1);

    // Assert
    expect(
      container.read(workspaceProvider).activeWorksheet.charts,
      hasLength(1),
    );
    expect(
      container.read(workspaceProvider).activeWorksheet.charts.first.chartType,
      equals(ChartType.timeSeries),
    );
  });

  test('workspaceProvider — removeChart — out-of-range is a no-op', () {
    // Arrange — Session Sheet has 2 pinned charts.
    final container = _buildContainer();
    final before =
        container.read(workspaceProvider).activeWorksheet.charts.length;

    // Act
    container.read(workspaceProvider.notifier).removeChart(99);

    // Assert
    expect(
      container.read(workspaceProvider).activeWorksheet.charts,
      hasLength(before),
    );
  });

  test(
      'workspaceProvider — removeChart — pinned slot of Session Sheet is no-op',
      () {
    // Arrange — active worksheet is the Session Sheet (index 0).
    final container = _buildContainer();
    expect(
      container.read(workspaceProvider).activeWorksheet.kind,
      equals(WorksheetKind.sessionSheet),
    );
    final beforeCharts =
        container.read(workspaceProvider).activeWorksheet.charts.length;
    expect(beforeCharts, equals(3)); // gpsMap + lapTable + lapProgression

    // Act — try to drop each pinned slot.
    container.read(workspaceProvider.notifier).removeChart(0);
    container.read(workspaceProvider.notifier).removeChart(1);
    container.read(workspaceProvider.notifier).removeChart(2);

    // Assert — no-op on all three, list unchanged.
    final after = container.read(workspaceProvider).activeWorksheet.charts;
    expect(after, hasLength(beforeCharts));
    expect(
      after.map((c) => c.chartType),
      equals([
        ChartType.gpsMap,
        ChartType.lapTable,
        ChartType.lapProgression,
      ]),
    );
  });

  test(
      'workspaceProvider — removeChart — non-pinned slot of Session Sheet is removable',
      () {
    // Arrange — active is Session Sheet; user has added a fourth chart.
    final container = _buildContainer();
    container.read(workspaceProvider.notifier).addChart(ChartType.fft);
    expect(
      container.read(workspaceProvider).activeWorksheet.charts,
      hasLength(4),
    );

    // Act — drop the user-added (non-pinned) chart at index 3.
    container.read(workspaceProvider.notifier).removeChart(3);

    // Assert
    final after = container.read(workspaceProvider).activeWorksheet.charts;
    expect(after, hasLength(3));
    expect(
      after.map((c) => c.chartType),
      equals([
        ChartType.gpsMap,
        ChartType.lapTable,
        ChartType.lapProgression,
      ]),
    );
  });

  test('workspaceProvider — removeWorksheet — drops worksheet at index', () {
    // Arrange — Workbook 1 has Session + Charts; activate index 1.
    final container = _buildContainer();
    container.read(workspaceProvider.notifier).setActiveWorksheet(1);

    // Act — drop the Session sheet at index 0.
    container.read(workspaceProvider.notifier).removeWorksheet(0);

    // Assert — Charts is now at index 0 and the active sheet was clamped.
    final wb = container.read(workspaceProvider).activeWorkbook;
    expect(wb.worksheets, hasLength(1));
    expect(wb.worksheets.first.name, equals('Charts'));
    expect(
      container.read(workspaceProvider).activeWorksheetIndex,
      equals(0),
    );
  });

  test(
      'workspaceProvider — removeWorksheet — refuses to drop the last worksheet',
      () {
    // Arrange — drop down to one worksheet first.
    final container = _buildContainer();
    container.read(workspaceProvider.notifier).removeWorksheet(0);
    expect(
      container.read(workspaceProvider).activeWorkbook.worksheets,
      hasLength(1),
    );

    // Act — try to drop the only remaining worksheet.
    container.read(workspaceProvider.notifier).removeWorksheet(0);

    // Assert
    expect(
      container.read(workspaceProvider).activeWorkbook.worksheets,
      hasLength(1),
    );
  });

  test(
      'workspaceProvider — duplicateWorksheet — inserts a copy after source '
      'with "(copy)" suffix and switches to it', () {
    // Arrange
    final container = _buildContainer();
    final notifier = container.read(workspaceProvider.notifier);
    notifier.addWorksheet('Source', kind: WorksheetKind.standard);
    final state0 = container.read(workspaceProvider);
    final srcIndex = state0.activeWorkbook.worksheets.length - 1;
    final srcSheet = state0.activeWorkbook.worksheets[srcIndex];

    // Act
    notifier.duplicateWorksheet(srcIndex);

    // Assert
    final state1 = container.read(workspaceProvider);
    final sheets = state1.activeWorkbook.worksheets;
    expect(sheets.length, equals(state0.activeWorkbook.worksheets.length + 1));
    expect(sheets[srcIndex].name, equals('Source'));
    expect(sheets[srcIndex + 1].name, equals('Source (copy)'));
    expect(sheets[srcIndex + 1].id, isNot(equals(srcSheet.id)));
    expect(
      sheets[srcIndex + 1].charts.length,
      equals(srcSheet.charts.length),
    );
    expect(sheets[srcIndex + 1].xAxisMode, equals(srcSheet.xAxisMode));
    expect(sheets[srcIndex + 1].kind, equals(srcSheet.kind));
    expect(state1.activeWorksheetIndex, equals(srcIndex + 1));
  });

  test('workspaceProvider — duplicateWorksheet — out-of-range index is a no-op',
      () {
    // Arrange
    final container = _buildContainer();
    final notifier = container.read(workspaceProvider.notifier);
    final initialLen =
        container.read(workspaceProvider).activeWorkbook.worksheets.length;

    // Act
    notifier.duplicateWorksheet(-1);
    notifier.duplicateWorksheet(999);

    // Assert
    final state = container.read(workspaceProvider);
    expect(state.activeWorkbook.worksheets.length, equals(initialLen));
  });

  test('workspaceProvider — moveChart — moves a slot on a standard worksheet',
      () {
    // Arrange — standard "Charts" sheet starts empty; add three charts.
    final container = _buildContainer();
    final notifier = container.read(workspaceProvider.notifier);
    notifier.setActiveWorksheet(1); // Charts (standard) sheet.
    notifier.addChart(ChartType.timeSeries);
    notifier.addChart(ChartType.fft);
    notifier.addChart(ChartType.timeSeries);
    final state0 = container.read(workspaceProvider);
    final slotIds = state0.activeWorksheet.charts.map((c) => c.slotId).toList();
    expect(slotIds.length, equals(3));

    // Act — move index 0 to the end. ReorderableListView semantics:
    // newIndex is the position before source removal, so to move the
    // first element to the end we pass charts.length.
    notifier.moveChart(0, slotIds.length);

    // Assert
    final state1 = container.read(workspaceProvider);
    final newOrder =
        state1.activeWorksheet.charts.map((c) => c.slotId).toList();
    expect(newOrder.last, equals(slotIds.first));
    expect(newOrder.length, equals(slotIds.length));
  });

  test('workspaceProvider — moveChart — out-of-range from or to is a no-op',
      () {
    // Arrange
    final container = _buildContainer();
    final notifier = container.read(workspaceProvider.notifier);
    notifier.setActiveWorksheet(1);
    notifier.addChart(ChartType.timeSeries);
    final state0 = container.read(workspaceProvider);
    final initialIds =
        state0.activeWorksheet.charts.map((c) => c.slotId).toList();

    // Act
    notifier.moveChart(-1, 0);
    notifier.moveChart(0, 999);

    // Assert
    final state1 = container.read(workspaceProvider);
    final after = state1.activeWorksheet.charts.map((c) => c.slotId).toList();
    expect(after, equals(initialIds));
  });

  test(
      'workspaceProvider — moveChart — Session Sheet refuses to move INTO a '
      'pinned index', () {
    // Arrange — Session Sheet has kSessionSheetPinnedSlotCount pinned slots.
    final container = _buildContainer();
    final notifier = container.read(workspaceProvider.notifier);
    notifier.setActiveWorksheet(0); // Session Sheet.
    notifier.addChart(ChartType.timeSeries);
    final state0 = container.read(workspaceProvider);
    final preIds = state0.activeWorksheet.charts.map((c) => c.slotId).toList();

    // Act — try to move the new chart on top of a pinned slot.
    notifier.moveChart(preIds.length - 1, 0);

    // Assert — order unchanged.
    final state1 = container.read(workspaceProvider);
    final postIds = state1.activeWorksheet.charts.map((c) => c.slotId).toList();
    expect(postIds, equals(preIds));
  });

  test(
      'workspaceProvider — moveChart — Session Sheet refuses to move OUT OF '
      'a pinned index', () {
    // Arrange
    final container = _buildContainer();
    final notifier = container.read(workspaceProvider.notifier);
    notifier.setActiveWorksheet(0);
    notifier.addChart(ChartType.timeSeries);
    final state0 = container.read(workspaceProvider);
    final preIds = state0.activeWorksheet.charts.map((c) => c.slotId).toList();

    // Act — try to move pinned slot 0 down past the pinned region.
    notifier.moveChart(0, preIds.length - 1);

    // Assert
    final state1 = container.read(workspaceProvider);
    final postIds = state1.activeWorksheet.charts.map((c) => c.slotId).toList();
    expect(postIds, equals(preIds));
  });

  test('Worksheet.fromJson — old layout without kind — defaults to standard',
      () {
    // Arrange — JSON predating the kind field.
    final json = {
      'id': 'old-ws-uuid',
      'name': 'Legacy',
      'xAxisMode': 'time',
      'charts': <dynamic>[],
    };

    // Act
    final ws = Worksheet.fromJson(json);

    // Assert
    expect(ws.kind, equals(WorksheetKind.standard));
    expect(ws.name, equals('Legacy'));
  });

  test('Worksheet.fromJson — kind field round-trip — sessionSheet survives',
      () {
    // Arrange
    final original = Worksheet.sessionSheet(name: 'Session A');

    // Act
    final restored = Worksheet.fromJson(original.toJson());

    // Assert
    expect(restored.kind, equals(WorksheetKind.sessionSheet));
    expect(restored.name, equals('Session A'));
    expect(
      restored.charts.map((c) => c.chartType),
      equals([
        ChartType.gpsMap,
        ChartType.lapTable,
        ChartType.lapProgression,
      ]),
    );
  });

  test(
      'Worksheet.fromJson — sessionSheet without gpsMap — migrates by prepending one',
      () {
    // Arrange — JSON shape from before gpsMap became a pinned slot.
    final json = {
      'id': 'legacy-session',
      'name': 'Session',
      'xAxisMode': 'time',
      'kind': 'sessionSheet',
      'charts': [
        ChartSlot(chartType: ChartType.lapTable).toJson(),
        ChartSlot(chartType: ChartType.lapProgression).toJson(),
      ],
    };

    // Act
    final ws = Worksheet.fromJson(json);

    // Assert — gpsMap prepended at index 0; existing charts shifted down.
    expect(
      ws.charts.map((c) => c.chartType),
      equals([
        ChartType.gpsMap,
        ChartType.lapTable,
        ChartType.lapProgression,
      ]),
    );
  });

  test(
      'Worksheet.fromJson — sessionSheet with manual gpsMap — no duplicate added',
      () {
    // Arrange — user already added a gpsMap chart in some non-pinned slot.
    final json = {
      'id': 'manual-map',
      'name': 'Session',
      'xAxisMode': 'time',
      'kind': 'sessionSheet',
      'charts': [
        ChartSlot(chartType: ChartType.lapTable).toJson(),
        ChartSlot(chartType: ChartType.lapProgression).toJson(),
        ChartSlot(chartType: ChartType.gpsMap).toJson(),
      ],
    };

    // Act
    final ws = Worksheet.fromJson(json);

    // Assert — list unchanged; migration skipped because a gpsMap already exists.
    expect(
      ws.charts.map((c) => c.chartType),
      equals([
        ChartType.lapTable,
        ChartType.lapProgression,
        ChartType.gpsMap,
      ]),
    );
  });

  test(
      'WorkspaceState load — workbook with no Session Sheet — fromJson preserves legacy shape',
      () {
    // fromJson alone does NOT migrate legacy workbooks; that is done by
    // WorkbookMigration (Task 7). Verify the JSON round-trip is faithful.
    final legacy = WorkspaceState(
      workbooks: [
        WorkbookData(
          name: 'Legacy WB',
          worksheets: [Worksheet(name: 'Old Sheet')],
        ),
      ],
      activeWorkbookIndex: 0,
      activeWorksheetIndex: 0,
    );

    // Act — round-trip through JSON.
    final restored = WorkspaceState.fromJson(legacy.toJson());

    // Assert — shape is preserved faithfully.
    expect(restored.workbooks.first.worksheets, hasLength(1));
    expect(
      restored.workbooks.first.worksheets.first.kind,
      equals(WorksheetKind.standard),
    );
  });

  test(
      'ChartSlot — fromJson — unknown chartType string falls back to timeSeries',
      () {
    // Arrange — a future chart type this build doesn't know about, or an
    // old `ghostDelta` slot from before the chart type was removed.
    final json = {
      'chartType': 'someFutureType',
      'channelIds': <String>[],
      'mathChannelIds': <String>[],
      'yScaleMode': 'auto',
      'heightFactor': 1.0,
      'channelColors': <String, dynamic>{},
    };

    // Act
    final slot = ChartSlot.fromJson(json);

    // Assert
    expect(slot.chartType, equals(ChartType.timeSeries));
  });

  test('WorkspaceState — persists worksheetRanges through toJson/fromJson', () {
    // Arrange
    const range = XAxisRange(startSecs: 1.0, endSecs: 5.0);
    final state = WorkspaceState(
      workbooks: WorkspaceNotifier.testDefaultState().workbooks,
      activeWorkbookIndex: 0,
      activeWorksheetIndex: 0,
      worksheetRanges: const {'ws-a': range},
    );

    // Act
    final round = WorkspaceState.fromJson(state.toJson());

    // Assert
    expect(round.worksheetRanges['ws-a']?.startSecs, equals(1.0));
    expect(round.worksheetRanges['ws-a']?.endSecs, equals(5.0));
  });

  test('WorkspaceState — persists worksheetCursors through toJson/fromJson',
      () {
    // Arrange
    const pair = CursorPair(aSecs: 2.5, bSecs: 9.75);
    final state = WorkspaceState(
      workbooks: WorkspaceNotifier.testDefaultState().workbooks,
      activeWorkbookIndex: 0,
      activeWorksheetIndex: 0,
      worksheetCursors: const {'ws-a': pair},
    );

    // Act
    final round = WorkspaceState.fromJson(state.toJson());

    // Assert
    expect(round.worksheetCursors['ws-a']?.aSecs, equals(2.5));
    expect(round.worksheetCursors['ws-a']?.bSecs, equals(9.75));
  });

  test(
      'WorkspaceState — fromJson missing keys — empty maps for ranges and cursors',
      () {
    // Arrange
    final json = {
      'workbooks': WorkspaceNotifier.testDefaultState()
          .workbooks
          .map((wb) => wb.toJson())
          .toList(),
      'activeWorkbookIndex': 0,
      'activeWorksheetIndex': 0,
    };

    // Act
    final state = WorkspaceState.fromJson(json);

    // Assert
    expect(state.worksheetRanges, isEmpty);
    expect(state.worksheetCursors, isEmpty);
  });

  // ── Bridge behaviour tests ────────────────────────────────────────────────

  test(
      'workspaceProvider bridge — workbookProvider loaded with one workbook — workspace reflects it',
      () async {
    // Arrange — seed workbookProvider with one Workbook entity.
    final wb = Workbook.create(
      name: 'My Workbook',
      worksheets: [
        Worksheet.sessionSheet(name: 'Session'),
        Worksheet(name: 'Charts', blocks: const []),
      ],
      now: DateTime.utc(2026, 1, 1),
    );
    final fake = _FakeWorkbookNotifier(initial: [wb]);
    final container = _buildContainer(fakeNotifier: fake);

    // workbookProvider is async; wait for it to resolve.
    await container.read(workbookProvider.future);

    // Act — read workspace state (will be rebuilt once workbookProvider emits).
    final state = container.read(workspaceProvider);

    // Assert — workspace picks up the workbook name from workbookProvider.
    expect(state.workbooks.first.name, equals('My Workbook'));
    expect(state.workbooks.first.worksheets, hasLength(2));
  });

  test(
      'workspaceProvider bridge — renameWorkbook — routes to workbookProvider.updateWorkbook',
      () async {
    // Arrange — seed with one workbook entity.
    final wb = Workbook.create(
      name: 'Original',
      worksheets: [Worksheet(name: 'Sheet 1')],
      now: DateTime.utc(2026, 1, 1),
    );
    final fake = _FakeWorkbookNotifier(initial: [wb]);
    final container = _buildContainer(fakeNotifier: fake);
    await container.read(workbookProvider.future);

    // Act
    container.read(workspaceProvider.notifier).renameWorkbook(0, 'Renamed');

    // Flush microtasks for the fire-and-forget _persistActiveWorkbook.
    await Future<void>.delayed(Duration.zero);

    // Assert — workspaceProvider reflects the rename immediately.
    expect(
      container.read(workspaceProvider).workbooks.first.name,
      equals('Renamed'),
    );

    // Assert — workbookProvider.updateWorkbook was called with the new name.
    expect(fake.updatedWorkbooks, hasLength(1));
    expect(fake.updatedWorkbooks.first.name, equals('Renamed'));
  });

  test(
      'workspaceProvider bridge — addWorksheet — routes to workbookProvider.updateWorkbook',
      () async {
    // Arrange
    final wb = Workbook.create(
      name: 'WB',
      worksheets: [Worksheet.sessionSheet(name: 'Session')],
      now: DateTime.utc(2026, 1, 1),
    );
    final fake = _FakeWorkbookNotifier(initial: [wb]);
    final container = _buildContainer(fakeNotifier: fake);
    await container.read(workbookProvider.future);

    // Act
    container.read(workspaceProvider.notifier).addWorksheet('New Sheet');
    await Future<void>.delayed(Duration.zero);

    // Assert — workspaceProvider reflects the new sheet.
    expect(
      container.read(workspaceProvider).activeWorkbook.worksheets,
      hasLength(2),
    );
    expect(
      container.read(workspaceProvider).activeWorkbook.worksheets.last.name,
      equals('New Sheet'),
    );

    // Assert — update was propagated to workbookProvider.
    expect(fake.updatedWorkbooks, isNotEmpty);
    final updatedWb = fake.updatedWorkbooks.last;
    expect(updatedWb.worksheets.last.name, equals('New Sheet'));
  });
}
