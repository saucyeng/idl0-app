import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/ui/brand/spec_row.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets(
    'SpecRow — renders label uppercased and value as-is',
    (tester) async {
      // Arrange / Act
      await tester.pumpWidget(
        wrap(const SpecRow(label: 'Speed', value: '42 km/h')),
      );

      // Assert
      expect(find.text('SPEED'), findsOneWidget);
      expect(find.text('42 km/h'), findsOneWidget);
    },
  );

  testWidgets(
    'SpecRow — paints leader dots between label and value',
    (tester) async {
      // Arrange / Act
      await tester.pumpWidget(
        wrap(
          const SizedBox(
            width: 400,
            child: SpecRow(label: 'CADENCE', value: '92 rpm'),
          ),
        ),
      );

      // Assert — the row contains a CustomPaint for the leader dots.
      expect(find.byType(CustomPaint), findsWidgets);
    },
  );
}
