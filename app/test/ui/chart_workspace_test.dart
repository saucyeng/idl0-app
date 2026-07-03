import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/math_channel.dart';
import 'package:idl0/data/workbook.dart';
import 'package:idl0/providers/channel_provider.dart';
import 'package:idl0/providers/math_channel_provider.dart';
import 'package:idl0/providers/selection_provider.dart';
import 'package:idl0/providers/workbook_provider.dart';
import 'package:idl0/providers/workspace_provider.dart';
import 'package:idl0/src/rust/session.dart' show ChannelMeta;
import 'package:idl0/ui/tabs/analyze/chart_workspace.dart';
import 'package:idl0/ui/tabs/analyze/time_series_chart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Known channel *metadata* the charts self-source against in data tests — the
/// charts read this from [sessionChannelMetaProvider] and pull bounded views
/// from the handle by id (no Dart-side samples).
const _mockMeta = ChannelMeta(
  channelId: 'IMU0_AccelZ',
  sampleRateHz: 100,
  length: 3,
  isEventDriven: false,
  synthesized: false,
);

/// In-memory [WorkbookNotifier] stand-in: holds a mutable workbook list and
/// reflects [updateWorkbook] into [state], so the math-channel provider (backed
/// by the active workbook) works without the SQLite cache / Drive stack.
class _FakeWorkbookNotifier extends WorkbookNotifier {
  _FakeWorkbookNotifier(this._workbooks);

  final List<Workbook> _workbooks;

  @override
  Future<List<Workbook>> build() async => List.of(_workbooks);

  @override
  Future<void> updateWorkbook(Workbook workbook) async {
    final i = _workbooks.indexWhere((w) => w.workbookId == workbook.workbookId);
    if (i >= 0) {
      _workbooks[i] = workbook;
    } else {
      _workbooks.add(workbook);
    }
    state = AsyncData(List.of(_workbooks));
  }
}

/// Creates a [ProviderContainer] whose active workbook is a default workbook
/// (Session + Charts sheets); the math-channel provider reads/writes its
/// channels. No SQLite store is involved.
Future<ProviderContainer> _mathContainer({
  List<Override> extraOverrides = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  final workbook = Workbook.createDefault(workbookId: 'wb-cw-test');
  final container = ProviderContainer(
    overrides: [
      workbookProvider.overrideWith(() => _FakeWorkbookNotifier([workbook])),
      ...extraOverrides,
    ],
  );
  addTearDown(container.dispose);
  await container.read(workbookProvider.future);
  return container;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets(
    'ChartWorkspace — no sessions selected — shows empty-state message',
    (tester) async {
      // Arrange / Act
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: ChartWorkspace()),
          ),
        ),
      );

      // Assert
      expect(
        find.textContaining('No sessions selected'),
        findsOneWidget,
      );
      expect(find.byType(TimeSeriesChart), findsNothing);
    },
  );

  testWidgets(
    'ChartWorkspace — "Add Chart" button — increases TimeSeriesChart count',
    (tester) async {
      // Arrange — one session selected so the empty-state is skipped.
      // Switch to the standard Charts worksheet (blank), then add an
      // initial TimeSeries slot so the assertion has a baseline.
      final container = ProviderContainer(
        overrides: [
          sessionChannelMetaProvider('sess-1').overrideWith(
            (ref) async => const [_mockMeta],
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(selectionProvider.notifier).toggleSession('sess-1');
      container.read(workspaceProvider.notifier).setActiveWorksheet(1);
      container.read(workspaceProvider.notifier).addChart();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: ChartWorkspace()),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(TimeSeriesChart), findsOneWidget);

      // Act — tap "Add chart" (QuietButton renders the label uppercased),
      // then confirm the type-picker dialog (default: Time Series).
      await tester.tap(find.text('ADD CHART'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ADD'));
      await tester.pump();

      // Assert — second chart slot added
      expect(find.byType(TimeSeriesChart), findsNWidgets(2));
    },
  );

  testWidgets(
    'ChartWorkspace — channel assigned to slot — LineChart widget appears',
    (tester) async {
      // Arrange — session selected; mock provider returns one channel.
      // Switch to the standard Charts worksheet and seed a TimeSeries slot
      // before assigning the channel.
      final container = ProviderContainer(
        overrides: [
          sessionChannelMetaProvider('sess-1').overrideWith(
            (ref) async => const [_mockMeta],
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(selectionProvider.notifier).toggleSession('sess-1');
      container.read(workspaceProvider.notifier).setActiveWorksheet(1);
      container.read(workspaceProvider.notifier).addChart();
      container
          .read(workspaceProvider.notifier)
          .addChannelToChart(0, 'IMU0_AccelZ');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: ChartWorkspace()),
          ),
        ),
      );
      // Pump twice: first to build, second to resolve the FutureProvider.
      await tester.pump();
      await tester.pump();

      // Assert — LineChart is rendered because the slot has channel data.
      expect(find.byType(LineChart), findsOneWidget);
    },
  );

  testWidgets(
    '_ChannelPickerDialog — math channels exist — shows Math Channels section',
    (tester) async {
      // Arrange — one session and one math channel.
      // tester.runAsync drives real async I/O (sqflite FFI) outside FakeAsync.
      final container = (await tester.runAsync(
        () => _mathContainer(
          extraOverrides: [
            sessionChannelMetaProvider('sess-1').overrideWith(
              (ref) async => const [_mockMeta],
            ),
          ],
        ),
      ))!;
      await tester.runAsync(
        () => container.read(mathChannelProvider.notifier).addChannel(
              const MathChannel(
                id: 'mc-1',
                name: 'TestMath',
                quantity: 'Velocity',
                units: 'm/s',
                sampleRateHz: 0,
                decimalPlaces: 3,
                color: '#FF2196F3',
                expression: '2 * IMU0_AccelZ',
              ),
            ),
      );
      container.read(selectionProvider.notifier).toggleSession('sess-1');
      container.read(workspaceProvider.notifier).setActiveWorksheet(1);
      container.read(workspaceProvider.notifier).addChart();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: ChartWorkspace())),
        ),
      );
      await tester.pump();

      // Act — open channel picker
      // pumpAndSettle is avoided here: the math channel DB watcher keeps the
      // widget tree dirty indefinitely, causing pumpAndSettle to spin forever.
      await tester.tap(find.text('ADD CHANNEL'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Assert — Math Channels section header (brand kicker, uppercased) and
      // channel name are visible.
      expect(find.text('MATH CHANNELS'), findsOneWidget);
      expect(find.text('TestMath'), findsOneWidget);
    },
  );

  testWidgets(
    'ChartWorkspace — math channel eval error — shows error overlay, raw channel still renders',
    (tester) async {
      // Arrange — session with a raw channel and a math channel whose
      // evaluation fails. The raw channel should still render as LineChart.
      // tester.runAsync drives real async I/O (sqflite FFI) outside FakeAsync.
      final container = (await tester.runAsync(
        () => _mathContainer(
          extraOverrides: [
            sessionChannelMetaProvider('sess-1').overrideWith(
              (ref) async => const [_mockMeta],
            ),
            mathChannelEvalProvider(
              (channelId: 'mc-1', sessionId: 'sess-1'),
            ).overrideWith((_) async => throw Exception('eval failed')),
          ],
        ),
      ))!;
      await tester.runAsync(
        () => container.read(mathChannelProvider.notifier).addChannel(
              const MathChannel(
                id: 'mc-1',
                name: 'FailingMath',
                quantity: '',
                units: '',
                sampleRateHz: 0,
                decimalPlaces: 3,
                color: '#FFFF0000',
                expression: 'bad()',
              ),
            ),
      );
      container.read(selectionProvider.notifier).toggleSession('sess-1');
      container.read(workspaceProvider.notifier).setActiveWorksheet(1);
      container.read(workspaceProvider.notifier).addChart();
      container
          .read(workspaceProvider.notifier)
          .addChannelToChart(0, 'IMU0_AccelZ');
      container
          .read(workspaceProvider.notifier)
          .addMathChannelToChart(0, 'mc-1');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: ChartWorkspace())),
        ),
      );
      // Pump twice: resolve channel FutureProvider and math eval FutureProvider.
      await tester.pump();
      await tester.pump();

      // Assert — error message is visible and the raw channel LineChart renders.
      expect(find.textContaining('eval failed'), findsOneWidget);
      expect(find.byType(LineChart), findsOneWidget);
    },
  );
}
