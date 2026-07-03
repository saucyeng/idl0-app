import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/ui/tabs/device/device_files_entry.dart';

void main() {
  testWidgets('DeviceFilesEntry — renders a Files row', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: DeviceFilesEntry())),
      ),
    );
    await tester.pump();

    expect(find.text('Files'), findsOneWidget);
  });
}
