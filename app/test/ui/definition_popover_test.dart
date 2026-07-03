import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/ui/shell/adaptive_shell.dart' show shellIndexProvider;
import 'package:idl0/ui/tabs/maths/chip/definition_popover.dart';

void main() {
  testWidgets(
    'DefinitionPopover — pinned card is dismissed when the shell tab changes',
    (tester) async {
      // Arrange
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: DefinitionPopover(
                  title: 'butter',
                  summary: 'Butterworth filter',
                  docs: 'Long-form docs about the Butterworth filter.',
                  child: Text('FNCHIP'),
                ),
              ),
            ),
          ),
        ),
      );

      // Pin the card by tapping the chip, then expand "More" (the read-more).
      await tester.tap(find.text('FNCHIP'));
      await tester.pumpAndSettle();
      expect(find.text('Butterworth filter'), findsOneWidget);
      await tester.tap(find.text('More ▾'));
      await tester.pumpAndSettle();
      expect(
        find.text('Long-form docs about the Butterworth filter.'),
        findsOneWidget,
      );

      // Act — the user switches to another tab.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DefinitionPopover)),
      );
      container.read(shellIndexProvider.notifier).state = 3;
      await tester.pumpAndSettle();

      // Assert — the floating card is gone, not orphaned over the new tab.
      expect(find.text('Butterworth filter'), findsNothing);
      expect(
        find.text('Long-form docs about the Butterworth filter.'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'DefinitionPopover — tapping the chip toggles the pinned card open/closed',
    (tester) async {
      // Arrange
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: DefinitionPopover(
                  title: 'integrate',
                  summary: 'Cumulative trapezoidal integration',
                  child: Text('FNCHIP'),
                ),
              ),
            ),
          ),
        ),
      );

      // Act / Assert — first tap pins it open.
      await tester.tap(find.text('FNCHIP'));
      await tester.pumpAndSettle();
      expect(find.text('Cumulative trapezoidal integration'), findsOneWidget);

      // Second tap unpins and closes it.
      await tester.tap(find.text('FNCHIP'));
      await tester.pumpAndSettle();
      expect(find.text('Cumulative trapezoidal integration'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
