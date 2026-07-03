import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/cursor_pair.dart';
import 'package:idl0/providers/cursor_provider.dart';

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  test('cursorProvider — initial state — empty CursorPair for all worksheets',
      () {
    // Arrange / Act
    final ws0 = container.read(cursorProvider('ws-a'));
    final ws1 = container.read(cursorProvider('ws-b'));

    // Assert
    expect(ws0, equals(const CursorPair()));
    expect(ws1, equals(const CursorPair()));
  });

  test('cursorProvider — setA on worksheet A — worksheet B cursor unchanged',
      () {
    // Arrange
    expect(container.read(cursorProvider('ws-b')), equals(const CursorPair()));

    // Act
    container.read(cursorProvider('ws-a').notifier).setA(5.0);

    // Assert
    expect(container.read(cursorProvider('ws-a')).aSecs, equals(5.0));
    expect(container.read(cursorProvider('ws-a')).bSecs, isNull);
    expect(container.read(cursorProvider('ws-b')), equals(const CursorPair()));
  });

  test('cursorProvider — setB after setA — both cursors set independently', () {
    // Arrange
    container.read(cursorProvider('ws-a').notifier).setA(2.0);

    // Act
    container.read(cursorProvider('ws-a').notifier).setB(7.0);

    // Assert
    final pair = container.read(cursorProvider('ws-a'));
    expect(pair.aSecs, equals(2.0));
    expect(pair.bSecs, equals(7.0));
  });

  test('cursorProvider — clearA — keeps B', () {
    // Arrange
    container.read(cursorProvider('ws-a').notifier).setA(2.0);
    container.read(cursorProvider('ws-a').notifier).setB(7.0);

    // Act
    container.read(cursorProvider('ws-a').notifier).clearA();

    // Assert
    final pair = container.read(cursorProvider('ws-a'));
    expect(pair.aSecs, isNull);
    expect(pair.bSecs, equals(7.0));
  });

  test('cursorProvider — clearB — keeps A', () {
    // Arrange
    container.read(cursorProvider('ws-a').notifier).setA(2.0);
    container.read(cursorProvider('ws-a').notifier).setB(7.0);

    // Act
    container.read(cursorProvider('ws-a').notifier).clearB();

    // Assert
    final pair = container.read(cursorProvider('ws-a'));
    expect(pair.aSecs, equals(2.0));
    expect(pair.bSecs, isNull);
  });

  test('cursorProvider — clearBoth — both null', () {
    // Arrange
    container.read(cursorProvider('ws-a').notifier).setA(2.0);
    container.read(cursorProvider('ws-a').notifier).setB(7.0);

    // Act
    container.read(cursorProvider('ws-a').notifier).clearBoth();

    // Assert
    expect(container.read(cursorProvider('ws-a')), equals(const CursorPair()));
  });

  test('cursorProvider — independent worksheets — each holds its own pair', () {
    // Arrange / Act
    container.read(cursorProvider('ws-a').notifier).setA(1.0);
    container.read(cursorProvider('ws-b').notifier).setA(2.0);
    container.read(cursorProvider('ws-c').notifier).setB(3.0);

    // Assert
    expect(container.read(cursorProvider('ws-a')).aSecs, equals(1.0));
    expect(container.read(cursorProvider('ws-b')).aSecs, equals(2.0));
    expect(container.read(cursorProvider('ws-c')).bSecs, equals(3.0));
  });
}
