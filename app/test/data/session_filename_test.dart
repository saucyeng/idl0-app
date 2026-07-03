import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/session_filename.dart';

void main() {
  group('formatSessionFileBase', () {
    test('local DateTime — formats as YYYY-MM-DD_HH-MM-SS, zero-padded', () {
      // Arrange
      final t = DateTime(2026, 6, 22, 14, 32, 5);

      // Act
      final base = formatSessionFileBase(t);

      // Assert
      expect(base, equals('2026-06-22_14-32-05'));
    });

    test('single-digit month/day/time components — all padded to two', () {
      // Arrange
      final t = DateTime(2026, 1, 3, 9, 4, 7);

      // Act
      final base = formatSessionFileBase(t);

      // Assert
      expect(base, equals('2026-01-03_09-04-07'));
    });
  });

  group('sessionFileBase', () {
    test('non-positive timestamp — falls back to the provided base', () {
      // Arrange / Act / Assert — unknown recording time never yields a 1970 name.
      expect(sessionFileBase(0, fallbackBase: 'uuid-abc'), equals('uuid-abc'));
      expect(sessionFileBase(-1, fallbackBase: 'uuid-abc'), equals('uuid-abc'));
    });

    test('positive timestamp — matches the local-time formatter', () {
      // Arrange
      const ms = 1_750_000_000_000; // arbitrary positive epoch ms
      final expected = formatSessionFileBase(
        DateTime.fromMillisecondsSinceEpoch(ms).toLocal(),
      );

      // Act
      final base = sessionFileBase(ms, fallbackBase: 'uuid-abc');

      // Assert
      expect(base, equals(expected));
      expect(base, isNot(equals('uuid-abc')));
    });
  });

  group('uniqueFileBase', () {
    test('base free — returned unchanged', () {
      // Arrange / Act / Assert
      expect(uniqueFileBase('2026-06-22_14-32-05', (_) => false),
          equals('2026-06-22_14-32-05'));
    });

    test('base taken — appends -2', () {
      // Arrange
      const base = '2026-06-22_14-32-05';
      bool taken(String c) => c == base;

      // Act / Assert
      expect(uniqueFileBase(base, taken), equals('$base-2'));
    });

    test('base and -2 taken — returns -3', () {
      // Arrange
      const base = '2026-06-22_14-32-05';
      bool taken(String c) => c == base || c == '$base-2';

      // Act / Assert
      expect(uniqueFileBase(base, taken), equals('$base-3'));
    });
  });
}
