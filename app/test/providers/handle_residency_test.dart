import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/handle_residency.dart';

void main() {
  group('HandleResidencyController', () {
    test('register — warm bytes exceed budget — evicts LRU until under budget',
        () {
      // Arrange — 100-byte budget; three 60-byte deselected handles.
      final closed = <String>[];
      final tilesDropped = <String>[];
      final c = HandleResidencyController(
        invalidateTiles: tilesDropped.add,
        maxWarmBytes: 100,
      );

      // Act
      c.register('a', () => closed.add('a'), residentBytes: 60);
      c.register('b', () => closed.add('b'), residentBytes: 60);
      c.register('c', () => closed.add('c'), residentBytes: 60);

      // Assert — a then b evicted (LRU first); c alone fits the budget.
      expect(closed, equals(['a', 'b']));
      expect(tilesDropped, equals(['a', 'b']));
    });

    test('register — small handles within budget — nothing evicted', () {
      // Arrange — three 10-byte handles fit a 100-byte budget together.
      final closed = <String>[];
      final c = HandleResidencyController(
        invalidateTiles: (_) {},
        maxWarmBytes: 100,
      );

      // Act
      c.register('a', () => closed.add('a'), residentBytes: 10);
      c.register('b', () => closed.add('b'), residentBytes: 10);
      c.register('c', () => closed.add('c'), residentBytes: 10);

      // Assert
      expect(closed, isEmpty);
    });

    test('sync — selected session is never evicted regardless of bytes', () {
      // Arrange — one handle far over the budget, but selected (pinned).
      // Selection syncs before the handle provider builds (the residency
      // provider listens to effectiveSessionIds), so select-then-register
      // mirrors the real wiring.
      final closed = <String>[];
      final c = HandleResidencyController(
        invalidateTiles: (_) {},
        maxWarmBytes: 10,
      );

      // Act
      c.sync({'big'});
      c.register('big', () => closed.add('big'), residentBytes: 1000);

      // Assert — pinned handles never count against the warm budget.
      expect(closed, isEmpty);
    });

    test('sync — re-touching a warm session promotes it past the LRU victim',
        () {
      // Arrange — budget fits two 50-byte handles.
      final closed = <String>[];
      final c = HandleResidencyController(
        invalidateTiles: (_) {},
        maxWarmBytes: 100,
      );

      // Act — a,b warm (full). Select 'a' (promoted MRU, pinned), deselect it
      // ('a' warm again, still MRU); register 'd' to force a cut.
      c.register('a', () => closed.add('a'), residentBytes: 50);
      c.register('b', () => closed.add('b'), residentBytes: 50);
      c.sync({'a'}); // 'a' selected → promoted MRU, pinned
      c.sync(<String>{}); // deselect all → 'a' warm again, still MRU
      c.register('d', () => closed.add('d'), residentBytes: 50);

      // Assert — warm order is [b, a, d]; 'b' evicted, 'a' survives.
      expect(closed, equals(['b']));
    });
  });
}
