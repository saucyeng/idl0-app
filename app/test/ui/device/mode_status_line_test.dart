import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/mode.dart';
import 'package:idl0/ui/tabs/device/mode_status_line.dart';

void main() {
  testWidgets('ModeStatusLine — shows Idle label for Mode.idle', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [modeProvider.overrideWithValue(Mode.idle)],
        child: const MaterialApp(home: Scaffold(body: ModeStatusLine())),
      ),
    );

    expect(find.text('Idle'), findsOneWidget);
  });

  testWidgets('ModeStatusLine — shows Recording for Mode.recording',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [modeProvider.overrideWithValue(Mode.recording)],
        child: const MaterialApp(home: Scaffold(body: ModeStatusLine())),
      ),
    );

    expect(find.text('Recording'), findsOneWidget);
  });
}
