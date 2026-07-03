import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/ui/tabs/analyze/workbook_bar.dart';

void main() {
  testWidgets(
    'WorkbookBar — tap "+" → choose Standard — appends a new tab without crashing',
    (tester) async {
      // Arrange — default workbook ships with two tabs: SESSION + CHARTS.
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: WorkbookBar()),
          ),
        ),
      );

      expect(find.byType(Tab), findsNWidgets(2));

      // Act — open the "+" PopupMenuButton and pick Standard.
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Standard'));
      await tester.pumpAndSettle();

      // Assert — 3 tabs, no crash.
      expect(find.byType(Tab), findsNWidgets(3));

      // Act — repeat with Session Sheet.
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Session Sheet'));
      await tester.pumpAndSettle();

      // Assert — 4 tabs.
      expect(find.byType(Tab), findsNWidgets(4));
    },
  );

  testWidgets(
    'WorkbookBar — Export with no persisted workbook — no crash, shows snackbar',
    (tester) async {
      // Arrange — default workspace shows the synthetic "Workbook 1" while
      // workbookProvider is empty (fresh user / still loading). Resolving the
      // active workbook by name against an empty list previously threw
      // "Bad state: No element" via orElse: () => wbs.first.
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: WorkbookBar()),
          ),
        ),
      );

      // Act — open the workbook dropdown and pick "Export…".
      await tester.tap(find.text('Workbook 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export…'));
      await tester.pumpAndSettle();

      // Assert — no unhandled exception, and the user is told why nothing
      // happened.
      expect(tester.takeException(), isNull);
      expect(find.byType(SnackBar), findsOneWidget);
    },
  );

  testWidgets(
    'WorkbookBar — initial render — Workbook 1 dropdown + SESSION + CHARTS tabs',
    (tester) async {
      // Arrange / Act
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: WorkbookBar()),
          ),
        ),
      );

      // Assert — brand pass uppercases worksheet tab labels; Session Sheet
      // also renders an Icons.list_alt next to its label. The workbook
      // selector is a PopupMenuButton (WorkbookDropdownMenu), not a
      // DropdownButton<int> (replaced in Task 13).
      expect(find.byType(PopupMenuButton<int>), findsNothing);
      expect(find.text('Workbook 1'), findsOneWidget);
      expect(find.text('SESSION'), findsOneWidget);
      expect(find.text('CHARTS'), findsOneWidget);
      expect(find.byIcon(Icons.list_alt), findsOneWidget);
    },
  );
}
