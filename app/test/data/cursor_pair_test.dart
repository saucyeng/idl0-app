import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/cursor_pair.dart';

void main() {
  test('CursorPair — default constructor — both cursors null', () {
    // Arrange / Act
    const pair = CursorPair();

    // Assert
    expect(pair.aSecs, isNull);
    expect(pair.bSecs, isNull);
  });

  test('CursorPair — equality — same values are equal', () {
    // Arrange / Act
    const a = CursorPair(aSecs: 1.0, bSecs: 2.0);
    const b = CursorPair(aSecs: 1.0, bSecs: 2.0);

    // Assert
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
  });

  test('CursorPair — copyWith with sentinel — clears aSecs but keeps bSecs',
      () {
    // Arrange
    const original = CursorPair(aSecs: 1.0, bSecs: 2.0);

    // Act
    final cleared = original.copyWith(aSecs: null);

    // Assert
    expect(cleared.aSecs, isNull);
    expect(cleared.bSecs, equals(2.0));
  });

  test('CursorPair — copyWith with no args — preserves both values', () {
    // Arrange
    const original = CursorPair(aSecs: 1.0, bSecs: 2.0);

    // Act
    final copy = original.copyWith();

    // Assert
    expect(copy.aSecs, equals(1.0));
    expect(copy.bSecs, equals(2.0));
  });

  test('CursorPair — toJson — omits null fields', () {
    // Arrange
    const pair = CursorPair(aSecs: 3.5);

    // Act
    final json = pair.toJson();

    // Assert
    expect(json, equals({'aSecs': 3.5}));
  });

  test('CursorPair — fromJson — round-trip preserves values', () {
    // Arrange
    const original = CursorPair(aSecs: 3.5, bSecs: 7.25);

    // Act
    final round = CursorPair.fromJson(original.toJson());

    // Assert
    expect(round, equals(original));
  });

  test('CursorPair — fromJson empty map — both null', () {
    // Arrange / Act
    final pair = CursorPair.fromJson({});

    // Assert
    expect(pair.aSecs, isNull);
    expect(pair.bSecs, isNull);
  });
}
