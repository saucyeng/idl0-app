import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/ui/tabs/analyze/browse_workbooks_modal.dart';

void main() {
  Widget wrap() => const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: BrowseWorkbooksModal()),
        ),
      );

  testWidgets(
    'BrowseWorkbooksModal — initial render — shows search field and sort dropdown',
    (tester) async {
      // Arrange / Act
      await tester.pumpWidget(wrap());
      await tester.pump();

      // Assert
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Recent'), findsOneWidget);
    },
  );

  testWidgets(
    'BrowseWorkbooksModal — search filters by name — non-matching rows hidden',
    (tester) async {
      // Arrange — default library has "Workbook 1".
      await tester.pumpWidget(wrap());
      await tester.pump();

      // Act — type a query that matches nothing.
      await tester.enterText(find.byType(TextField), 'zzznomatch');
      await tester.pump();

      // Assert — empty-state message shown, no ListTile rows.
      expect(find.text('No workbooks match.'), findsOneWidget);
    },
  );

  testWidgets(
    'BrowseWorkbooksModal — sort dropdown — can switch to Name order',
    (tester) async {
      // Arrange
      await tester.pumpWidget(wrap());
      await tester.pump();

      // Act — open the sort dropdown and pick Name.
      await tester.tap(find.text('Recent'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Name').last);
      await tester.pumpAndSettle();

      // Assert — dropdown now shows "Name" as selected value.
      expect(find.text('Name'), findsWidgets);
    },
  );
}
