import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/runs_provider.dart';

void main() {
  test('rescanAllTrackVisits — empty session list returns (0, 0, null)',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final result =
        await container.read(runsProvider.notifier).rescanAllTrackVisits();

    expect(result.rescanned, 0);
    expect(result.failed, 0);
    expect(result.firstError, isNull);
  });
}
