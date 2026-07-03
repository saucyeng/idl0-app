import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/detail_selection_provider.dart';

void main() {
  test('default state is none', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);

    expect(c.read(detailSelectionProvider).kind, DetailKind.none);
    expect(c.read(detailSelectionProvider).entityId, isNull);
  });

  test('showSession sets kind=session and entityId', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(detailSelectionProvider.notifier).showSession('s1');

    final s = c.read(detailSelectionProvider);
    expect(s.kind, DetailKind.session);
    expect(s.entityId, 's1');
  });

  test('clear restores none', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(detailSelectionProvider.notifier).showVenue('Whistler');
    c.read(detailSelectionProvider.notifier).clear();

    expect(c.read(detailSelectionProvider).kind, DetailKind.none);
  });

  test('toggle on same id clears', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(detailSelectionProvider.notifier);

    n.showSession('s1');
    n.showSession('s1');

    expect(c.read(detailSelectionProvider).kind, DetailKind.none);
  });
}
