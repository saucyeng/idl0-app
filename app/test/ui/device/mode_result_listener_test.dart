import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/mode.dart';
import 'package:idl0/providers/mode_controller.dart';
import 'package:idl0/ui/tabs/device/mode_result_listener.dart';

void main() {
  testWidgets('ModeResultListener — shows a SnackBar on a policy refusal',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: ModeResultListener(child: SizedBox())),
        ),
      ),
    );

    // No device connected → switchTo emits RefusedByPolicy on the results
    // stream the listener is subscribed to.
    final ctx = tester.element(find.byType(ModeResultListener));
    final container = ProviderScope.containerOf(ctx);
    await container.read(modeControllerProvider.notifier).switchTo(Mode.wifi);
    await tester.pump(); // deliver stream event
    await tester.pump(); // animate the SnackBar in

    expect(find.text('Connect to the device first.'), findsOneWidget);
  });
}
