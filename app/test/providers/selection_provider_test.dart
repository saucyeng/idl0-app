import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/selection_provider.dart';

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  group('SelectionNotifier', () {
    test('initial state — session-mode, both sets empty', () {
      // Arrange / Act — read the build() default

      // Assert
      final s = container.read(selectionProvider);
      expect(s.mode, equals(SelectionMode.session));
      expect(s.sessionIds, isEmpty);
      expect(s.lapKeys, isEmpty);
      expect(s.isEmpty, isTrue);
    });

    test('toggleSession in session-mode — adds, then removes on second tap',
        () {
      // Arrange
      final notifier = container.read(selectionProvider.notifier);

      // Act
      notifier.toggleSession('a');
      notifier.toggleSession('b');

      // Assert — both present
      expect(container.read(selectionProvider).sessionIds, equals({'a', 'b'}));

      // Act — toggle 'a' off
      notifier.toggleSession('a');

      // Assert — only 'b' remains
      expect(container.read(selectionProvider).sessionIds, equals({'b'}));
    });

    test('toggleSession in lap-mode — flips to session-mode and clears laps',
        () {
      // Arrange — start in lap-mode with one lap
      final notifier = container.read(selectionProvider.notifier);
      notifier.toggleLap(const LapKey(sessionId: 's1', lapNumber: 3));
      expect(container.read(selectionProvider).mode, SelectionMode.lap);

      // Act
      notifier.toggleSession('s2');

      // Assert
      final s = container.read(selectionProvider);
      expect(s.mode, equals(SelectionMode.session));
      expect(s.sessionIds, equals({'s2'}));
      expect(s.lapKeys, isEmpty);
    });

    test('toggleLap in lap-mode — adds, then removes on second tap', () {
      // Arrange
      final notifier = container.read(selectionProvider.notifier);
      const k1 = LapKey(sessionId: 's1', lapNumber: 1);
      const k2 = LapKey(sessionId: 's1', lapNumber: 2);

      // Act
      notifier.toggleLap(k1);
      notifier.toggleLap(k2);

      // Assert
      expect(container.read(selectionProvider).lapKeys, equals({k1, k2}));

      // Act — toggle k1 off
      notifier.toggleLap(k1);

      // Assert
      expect(container.read(selectionProvider).lapKeys, equals({k2}));
    });

    test('toggleLap in session-mode — flips to lap-mode and clears sessions',
        () {
      // Arrange
      final notifier = container.read(selectionProvider.notifier);
      notifier.toggleSession('a');
      notifier.toggleSession('b');

      // Act
      notifier.toggleLap(const LapKey(sessionId: 's1', lapNumber: 1));

      // Assert
      final s = container.read(selectionProvider);
      expect(s.mode, equals(SelectionMode.lap));
      expect(s.sessionIds, isEmpty);
      expect(s.lapKeys, hasLength(1));
    });

    test('selectMany(sessions:) — switches mode and replaces set', () {
      // Arrange
      final notifier = container.read(selectionProvider.notifier);
      notifier.toggleLap(const LapKey(sessionId: 's1', lapNumber: 1));

      // Act
      notifier.selectMany(sessions: {'a', 'b'});

      // Assert
      final s = container.read(selectionProvider);
      expect(s.mode, equals(SelectionMode.session));
      expect(s.sessionIds, equals({'a', 'b'}));
      expect(s.lapKeys, isEmpty);
    });

    test('selectMany(laps:) — switches mode and replaces set', () {
      // Arrange
      final notifier = container.read(selectionProvider.notifier);
      notifier.toggleSession('a');

      // Act
      const k1 = LapKey(sessionId: 's1', lapNumber: 1);
      const k2 = LapKey(sessionId: 's2', lapNumber: 4);
      notifier.selectMany(laps: {k1, k2});

      // Assert
      final s = container.read(selectionProvider);
      expect(s.mode, equals(SelectionMode.lap));
      expect(s.sessionIds, isEmpty);
      expect(s.lapKeys, equals({k1, k2}));
    });

    test('setMode — flipping mode clears the now-inactive set', () {
      // Arrange
      final notifier = container.read(selectionProvider.notifier);
      notifier.toggleSession('a');

      // Act
      notifier.setMode(SelectionMode.lap);

      // Assert
      expect(container.read(selectionProvider).mode, SelectionMode.lap);
      expect(container.read(selectionProvider).sessionIds, isEmpty);
    });

    test('clear — empties both sets and resets to session-mode', () {
      // Arrange
      final notifier = container.read(selectionProvider.notifier);
      notifier.toggleLap(const LapKey(sessionId: 's1', lapNumber: 1));

      // Act
      notifier.clear();

      // Assert
      final s = container.read(selectionProvider);
      expect(s.mode, equals(SelectionMode.session));
      expect(s.sessionIds, isEmpty);
      expect(s.lapKeys, isEmpty);
    });

    test('removeSessionFromSelection — drops sessionId from session set', () {
      // Arrange
      final notifier = container.read(selectionProvider.notifier);
      notifier.toggleSession('a');
      notifier.toggleSession('b');

      // Act
      notifier.removeSessionFromSelection('a');

      // Assert
      expect(container.read(selectionProvider).sessionIds, equals({'b'}));
    });

    test(
        'removeSessionFromSelection — drops every lap key whose sessionId matches',
        () {
      // Arrange
      final notifier = container.read(selectionProvider.notifier);
      notifier.toggleLap(const LapKey(sessionId: 's1', lapNumber: 1));
      notifier.toggleLap(const LapKey(sessionId: 's1', lapNumber: 2));
      notifier.toggleLap(const LapKey(sessionId: 's2', lapNumber: 3));

      // Act
      notifier.removeSessionFromSelection('s1');

      // Assert
      expect(
        container.read(selectionProvider).lapKeys,
        equals({const LapKey(sessionId: 's2', lapNumber: 3)}),
      );
    });
  });

  group('mainLapKey (N-lap comparison)', () {
    const a = LapKey(sessionId: 's1', lapNumber: 1);
    const b = LapKey(sessionId: 's2', lapNumber: 3);

    test('setMainLap — pins a selected lap as Main in lap-mode', () {
      // Arrange
      final notifier = container.read(selectionProvider.notifier);
      notifier.toggleLap(a);
      notifier.toggleLap(b);

      // Act
      notifier.setMainLap(b);

      // Assert
      expect(container.read(selectionProvider).mainLapKey, b);
    });

    test('setMainLap — ignores a lap not in the selection', () {
      // Arrange
      final notifier = container.read(selectionProvider.notifier);
      notifier.toggleLap(a);

      // Act
      notifier.setMainLap(b);

      // Assert — b is not selected, so it is not accepted as Main.
      expect(container.read(selectionProvider).mainLapKey, isNull);
    });

    test('toggleLap — removing the Main lap resets mainLapKey to auto', () {
      // Arrange
      final notifier = container.read(selectionProvider.notifier);
      notifier.toggleLap(a);
      notifier.toggleLap(b);
      notifier.setMainLap(b);

      // Act — toggle b off.
      notifier.toggleLap(b);

      // Assert
      expect(container.read(selectionProvider).mainLapKey, isNull);
      expect(container.read(selectionProvider).lapKeys, {a});
    });

    test('switching to session-mode clears mainLapKey', () {
      // Arrange
      final notifier = container.read(selectionProvider.notifier);
      notifier.toggleLap(a);
      notifier.setMainLap(a);

      // Act
      notifier.toggleSession('s1');

      // Assert
      expect(container.read(selectionProvider).mainLapKey, isNull);
    });

    test('removeSessionFromSelection — clears Main when its session is removed',
        () {
      // Arrange
      final notifier = container.read(selectionProvider.notifier);
      notifier.toggleLap(a);
      notifier.toggleLap(b);
      notifier.setMainLap(b);

      // Act — remove b's session.
      notifier.removeSessionFromSelection('s2');

      // Assert
      expect(container.read(selectionProvider).mainLapKey, isNull);
      expect(container.read(selectionProvider).lapKeys, {a});
    });
  });

  group('effectiveSessionIdsProvider', () {
    test('session-mode — returns sessionIds verbatim', () {
      // Arrange
      container.read(selectionProvider.notifier).toggleSession('a');
      container.read(selectionProvider.notifier).toggleSession('b');

      // Act
      final ids = container.read(effectiveSessionIdsProvider);

      // Assert
      expect(ids, equals({'a', 'b'}));
    });

    test('lap-mode — returns the distinct sessionIds across lapKeys', () {
      // Arrange
      final notifier = container.read(selectionProvider.notifier);
      notifier.toggleLap(const LapKey(sessionId: 's1', lapNumber: 1));
      notifier.toggleLap(const LapKey(sessionId: 's1', lapNumber: 2));
      notifier.toggleLap(const LapKey(sessionId: 's2', lapNumber: 5));

      // Act
      final ids = container.read(effectiveSessionIdsProvider);

      // Assert
      expect(ids, equals({'s1', 's2'}));
    });
  });

  group('effectiveLapKeysProvider', () {
    test('session-mode — returns empty', () {
      // Arrange
      container.read(selectionProvider.notifier).toggleSession('a');

      // Assert
      expect(container.read(effectiveLapKeysProvider), isEmpty);
    });

    test('lap-mode — returns lapKeys verbatim', () {
      // Arrange
      const k = LapKey(sessionId: 's1', lapNumber: 1);
      container.read(selectionProvider.notifier).toggleLap(k);

      // Assert
      expect(container.read(effectiveLapKeysProvider), equals({k}));
    });
  });

  group('LapKey value semantics', () {
    test('two keys with the same fields are equal and share a hashCode', () {
      // Arrange / Act
      const a = LapKey(sessionId: 's1', lapNumber: 3);
      const b = LapKey(sessionId: 's1', lapNumber: 3);

      // Assert
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      // ignore: equal_elements_in_set
      expect({a, b}, hasLength(1));
    });
  });
}
