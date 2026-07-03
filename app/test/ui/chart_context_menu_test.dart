import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/cursor_provider.dart';
import 'package:idl0/providers/workspace_provider.dart';
import 'package:idl0/ui/widgets/chart_context_menu.dart';

void main() {
  testWidgets(
    'ChartContextMenu — menu → Horizontal Zoom In — sets a narrower X range',
    (tester) async {
      // Arrange
      const wsId = 'menu-zoom-ws';
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: ChartContextMenu(
                  worksheetId: wsId,
                  slotIndex: 0,
                  fullDataRange: const (0.0, 100.0),
                  pixelToTimeSecs: (dx) => dx,
                  child: Container(
                    key: const Key('canvas'),
                    width: 400,
                    height: 200,
                    color: Colors.grey,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      // Act — long-press to open menu, open the Zoom submenu, pick the item
      await tester.longPress(find.byKey(const Key('canvas')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zoom'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Horizontal Zoom In'));
      await tester.pumpAndSettle();

      // Assert — span 100 × 0.5 = 50, center 50 ⇒ 25..75
      final range = container.read(workspaceProvider).worksheetRanges[wsId];
      expect(
        range,
        isNotNull,
        reason: 'menu Horizontal Zoom In should set a worksheet X range',
      );
      expect(range!.startSecs, closeTo(25.0, 1e-9));
      expect(range.endSecs, closeTo(75.0, 1e-9));
    },
  );

  testWidgets(
    'ChartContextMenu — long-press opens menu with Cursor / Zoom / Pan submenus',
    (tester) async {
      // Arrange
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: ChartContextMenu(
                  worksheetId: 'test-ws',
                  slotIndex: 0,
                  fullDataRange: const (0.0, 100.0),
                  pixelToTimeSecs: (dx) => dx,
                  child: Container(
                    key: const Key('canvas'),
                    width: 400,
                    height: 200,
                    color: Colors.grey,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      // Act — long-press at the canvas center
      await tester.longPress(find.byKey(const Key('canvas')));
      await tester.pumpAndSettle();

      // Assert — top-level submenu buttons and Reset View visible
      expect(find.text('Cursor'), findsOneWidget);
      expect(find.text('Zoom'), findsOneWidget);
      expect(find.text('Pan'), findsOneWidget);
      expect(find.text('Reset View'), findsOneWidget);
    },
  );

  testWidgets(
    'ChartContextMenu — right-click → Place active here — writes click position to cursor A',
    (tester) async {
      // Arrange
      const wsId = 'rt-ws';
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: ChartContextMenu(
                  worksheetId: wsId,
                  slotIndex: 0,
                  fullDataRange: const (0.0, 400.0),
                  // identity for predictable assertion
                  pixelToTimeSecs: (dx) => dx,
                  child: Container(
                    key: const Key('canvas'),
                    width: 400,
                    height: 200,
                    color: Colors.grey,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      // Act — long-press at canvas center to open the menu, then tap
      // "Place active here" (the renamed Cursor A action).
      final canvas = find.byKey(const Key('canvas'));
      await tester.longPressAt(tester.getCenter(canvas));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cursor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Place active here'));
      await tester.pumpAndSettle();

      // Assert — cursor A written; value within the canvas's local-x extent.
      final pair = container.read(cursorProvider(wsId));
      expect(pair.aSecs, isNotNull);
      expect(pair.aSecs!, inInclusiveRange(0.0, 400.0));
      expect(pair.bSecs, isNull);
    },
  );

  testWidgets(
    'ChartContextMenu — Maximise menu item is disabled (v2 placeholder)',
    (tester) async {
      // Arrange
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: ChartContextMenu(
                  worksheetId: 'test-ws',
                  slotIndex: 0,
                  fullDataRange: const (0.0, 100.0),
                  pixelToTimeSecs: (dx) => dx,
                  child: Container(
                    key: const Key('canvas'),
                    width: 400,
                    height: 200,
                    color: Colors.grey,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      // Act — open the menu, then the "More" submenu that holds v2 items
      await tester.longPress(find.byKey(const Key('canvas')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();

      // Assert — Maximise visible but disabled (onPressed == null).
      final maximise = find.text('Maximise');
      expect(maximise, findsOneWidget);
      final button = tester.widget<MenuItemButton>(
        find.ancestor(of: maximise, matching: find.byType(MenuItemButton)),
      );
      expect(button.onPressed, isNull);
    },
  );

  testWidgets('ChartContextMenu — F2 — clears X range', (tester) async {
    // Arrange
    const wsId = 'kb-ws';
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(workspaceProvider.notifier).setXAxisRange(wsId, 1.0, 5.0);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: ChartContextMenu(
                worksheetId: wsId,
                slotIndex: 0,
                fullDataRange: const (0.0, 100.0),
                pixelToTimeSecs: (dx) => dx,
                child: Container(
                  key: const Key('canvas'),
                  width: 400,
                  height: 200,
                  color: Colors.grey,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // Act — focus the chart by tapping it, then press F2
    await tester.tap(find.byKey(const Key('canvas')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();

    // Assert — X range cleared via hZoomFullOut
    expect(container.read(workspaceProvider).worksheetRanges[wsId], isNull);
  });

  testWidgets(
    'ChartContextMenu — right-click drag — applies X+Y from rect corners',
    (tester) async {
      // Arrange
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(workspaceProvider.notifier).setActiveWorksheet(1);
      container.read(workspaceProvider.notifier).addChart();
      final activeWs = container.read(workspaceProvider).activeWorksheet;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: ChartContextMenu(
                  worksheetId: activeWs.id,
                  slotIndex: 0,
                  fullDataRange: const (0.0, 400.0),
                  // identity for predictable assertions
                  pixelToTimeSecs: (dx) => dx,
                  // top-down Y coordinate: y=0 at top → value 200; y=200 → value 0
                  pixelToYValue: (dy) => 200.0 - dy,
                  child: Container(
                    key: const Key('canvas'),
                    width: 400,
                    height: 200,
                    color: Colors.grey,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      // Act — right-click drag from (50,150) to (150,50) within canvas-local coords
      final canvasRect = tester.getRect(find.byKey(const Key('canvas')));
      final start = canvasRect.topLeft + const Offset(50, 150);
      final end = canvasRect.topLeft + const Offset(150, 50);

      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await tester.pump();
      await gesture.moveTo(end);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // Assert — X range is 50..150 (pixelToTimeSecs identity)
      // and Y range is 50..150 (pixelToYValue inverts so top=high-value)
      final state = container.read(workspaceProvider);
      final range = state.worksheetRanges[activeWs.id]!;
      expect(range.startSecs, equals(50.0));
      expect(range.endSecs, equals(150.0));
      final slot = state.activeWorksheet.charts[0];
      expect(slot.yScaleMode, equals(YScaleMode.manual));
      expect(slot.yMin, equals(50.0));
      expect(slot.yMax, equals(150.0));
    },
  );
}
