import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/ui/brand/brand.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('StatusIcon — renders icon, label and value', (tester) async {
    await tester.pumpWidget(
      host(
        const StatusIcon(
          icon: Icons.sd_card,
          label: 'SD',
          value: 'OK',
          color: brandGood,
        ),
      ),
    );

    expect(find.byIcon(Icons.sd_card), findsOneWidget);
    expect(find.text('SD OK'), findsOneWidget);
  });

  testWidgets('StatusIcon — omits value text when value is null', (tester) async {
    await tester.pumpWidget(
      host(
        const StatusIcon(
          icon: Icons.sd_card,
          label: 'SD',
          value: null,
          color: brandFgDim,
        ),
      ),
    );

    expect(find.byIcon(Icons.sd_card), findsOneWidget);
    expect(find.text('SD'), findsOneWidget);
    // No value: only the label is present as text.
    expect(find.byType(Text), findsOneWidget);
  });
}
