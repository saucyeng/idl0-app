import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/math_channel.dart';

void main() {
  // ---------------------------------------------------------------------------
  // MathChannelValidator.validate
  // ---------------------------------------------------------------------------

  group('MathChannelValidator.validate —', () {
    test(
        'validate — all [ChannelName] references exist in session — returns null',
        () {
      // Arrange
      const expression = 'integrate([IMU1_AccelZ]) + mean([WheelFront], 50)';
      const available = ['IMU1_AccelZ', 'WheelFront'];

      // Act
      final result = MathChannelValidator.validate(expression, available);

      // Assert
      expect(result, isNull);
    });

    test('validate — unknown [ChannelName] reference — returns error string',
        () {
      // Arrange
      const expression = 'integrate([NoSuchChannel])';
      const available = ['IMU1_AccelZ'];

      // Act
      final result = MathChannelValidator.validate(expression, available);

      // Assert
      expect(result, isNotNull);
      expect(result, contains('[NoSuchChannel]'));
    });

    test('validate — empty expression — returns error string', () {
      // Arrange
      const expression = '';
      const available = <String>[];

      // Act
      final result = MathChannelValidator.validate(expression, available);

      // Assert
      expect(result, isNotNull);
      expect(result, contains('empty'));
    });

    test('validate — whitespace-only expression — returns error string', () {
      // Arrange
      const expression = '   ';

      // Act
      final result = MathChannelValidator.validate(expression, const []);

      // Assert
      expect(result, isNotNull);
    });

    test('validate — unbalanced open square bracket — returns syntax error',
        () {
      // Arrange
      const expression = 'integrate([IMU1_AccelZ';

      // Act
      final result = MathChannelValidator.validate(expression, const []);

      // Assert
      expect(result, isNotNull);
      expect(result, contains('Syntax error'));
      expect(result, contains('unclosed ['));
    });

    test(
        'validate — unexpected closing bracket — returns syntax error with position',
        () {
      // Arrange
      const expression = ']IMU1_AccelZ';

      // Act
      final result = MathChannelValidator.validate(expression, const []);

      // Assert
      expect(result, isNotNull);
      expect(result, contains('Syntax error at position 0'));
    });

    test('validate — unknown function name — returns syntax error', () {
      // Arrange
      const expression = 'unknownFunc([IMU1_AccelZ])';

      // Act
      final result = MathChannelValidator.validate(expression, const []);

      // Assert
      expect(result, isNotNull);
      expect(result, contains('unknown function "unknownFunc"'));
    });

    test('validate — known function name — passes function check', () {
      // Arrange — empty available channels, skip ref check
      const expression = 'butter(2, 0.3, "low", x)';

      // Act
      final result = MathChannelValidator.validate(expression, const []);

      // Assert — no function-name error (syntax errors from unbalanced parens
      // are not expected here since butter() itself is balanced)
      expect(result, isNull);
    });

    test('validate — declip([IMU1_AccelZ]) — passes with channel in scope', () {
      // Arrange
      const expression = 'declip([IMU1_AccelZ])';

      // Act
      final result =
          MathChannelValidator.validate(expression, const ['IMU1_AccelZ']);

      // Assert — declip is a registered function and the channel resolves
      expect(result, isNull);
    });

    test('validate — available channels empty — skips channel reference check',
        () {
      // Arrange — template with channel refs, but no available list
      const expression = 'integrate([IMU1_AccelZ])';
      const available = <String>[];

      // Act
      final result = MathChannelValidator.validate(expression, available);

      // Assert — skipped, not an error
      expect(result, isNull);
    });

    test('validate — unbalanced open paren — returns syntax error', () {
      // Arrange
      const expression = 'integrate(rms(x)';

      // Act
      final result = MathChannelValidator.validate(expression, const []);

      // Assert
      expect(result, isNotNull);
      expect(result, contains('unclosed ('));
    });
  });

  // ---------------------------------------------------------------------------
  // MathChannelValidator.insertAtOffset
  // ---------------------------------------------------------------------------

  group('MathChannelValidator.insertAtOffset —', () {
    test(
        'insertAtOffset — cursor at middle of expression — inserts at cursor position',
        () {
      // Arrange
      const text = 'abs + rms';
      const offset = 4; // after "abs "
      const insertion = '[Speed]';

      // Act
      final result =
          MathChannelValidator.insertAtOffset(text, offset, insertion);

      // Assert — inserted at position 4, not appended
      expect(result, equals('abs [Speed]+ rms'));
    });

    test('insertAtOffset — cursor at start — prepends insertion', () {
      // Arrange
      const text = 'rms(ch)';

      // Act
      final result = MathChannelValidator.insertAtOffset(text, 0, 'integrate(');

      // Assert
      expect(result, equals('integrate(rms(ch)'));
    });

    test('insertAtOffset — cursor at end — appends insertion', () {
      // Arrange
      const text = 'integrate(';

      // Act
      final result =
          MathChannelValidator.insertAtOffset(text, text.length, '[Speed]');

      // Assert
      expect(result, equals('integrate([Speed]'));
    });

    test('insertAtOffset — offset past end — clamped to end, appends insertion',
        () {
      // Arrange
      const text = 'abs';

      // Act
      final result = MathChannelValidator.insertAtOffset(text, 999, '(ch)');

      // Assert
      expect(result, equals('abs(ch)'));
    });
  });

  // ---------------------------------------------------------------------------
  // MathChannelValidator.functionAtCursor
  // ---------------------------------------------------------------------------

  group('MathChannelValidator.functionAtCursor —', () {
    test('functionAtCursor — cursor inside known function call — returns name',
        () {
      // Arrange
      const text = 'integrate(';
      // cursor is after '('

      // Act
      final result = MathChannelValidator.functionAtCursor(text, text.length);

      // Assert
      expect(result, equals('integrate'));
    });

    test(
        'functionAtCursor — cursor inside unknown function call — returns null',
        () {
      // Arrange
      const text = 'badFunc(';

      // Act
      final result = MathChannelValidator.functionAtCursor(text, text.length);

      // Assert
      expect(result, isNull);
    });

    test('functionAtCursor — no function call in expression — returns null',
        () {
      // Arrange — plain arithmetic, no call-site parens
      const text = 'x + y * 2';

      // Act
      final result = MathChannelValidator.functionAtCursor(text, text.length);

      // Assert
      expect(result, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // MathChannelLibrary.shipped
  // ---------------------------------------------------------------------------

  group('MathChannelLibrary.shipped —', () {
    test('shipped — contains exactly six templates', () {
      // Arrange / Act
      final lib = MathChannelLibrary.shipped;

      // Assert
      expect(lib.templates, hasLength(6));
    });

    test('shipped — all template ids are unique', () {
      // Arrange / Act
      final ids = MathChannelLibrary.shipped.templates.map((t) => t.id);

      // Assert
      expect(ids.toSet().length, equals(ids.length));
    });

    test('shipped — suspension travel uses double integration', () {
      // Arrange / Act
      final tpl = MathChannelLibrary.shipped.templates
          .firstWhere((t) => t.name == 'Suspension travel');

      // Assert — two nested integrate() calls, per design_rationale.md
      expect(tpl.expression, equals('integrate(integrate([IMU1_AccelZ]))'));
    });
  });

  // ---------------------------------------------------------------------------
  // MathChannel serialization
  // ---------------------------------------------------------------------------

  group('MathChannel —', () {
    test('toJson / fromJson — round-trips all fields', () {
      // Arrange
      const ch = MathChannel(
        id: 'uuid-1',
        name: 'Fork velocity',
        quantity: 'Velocity',
        units: 'm/s',
        sampleRateHz: 100.0,
        decimalPlaces: 3,
        color: '#FF2196F3',
        expression: 'integrate([IMU1_AccelZ])',
      );

      // Act
      final json = ch.toJson();
      final restored = MathChannel.fromJson(json);

      // Assert
      expect(restored.id, equals(ch.id));
      expect(restored.name, equals(ch.name));
      expect(restored.quantity, equals(ch.quantity));
      expect(restored.units, equals(ch.units));
      expect(restored.sampleRateHz, equals(ch.sampleRateHz));
      expect(restored.decimalPlaces, equals(ch.decimalPlaces));
      expect(restored.color, equals(ch.color));
      expect(restored.expression, equals(ch.expression));
    });

    test('fromJson — hand-authored map without id — id defaults to name', () {
      // Arrange — the `.idl0wb` authoring skill omits id.
      const json = {
        'name': 'Fork velocity',
        'expression': 'integrate([IMU1_AccelZ])',
      };

      // Act
      final ch = MathChannel.fromJson(json);

      // Assert — id falls back to the name so chart refs resolve.
      expect(ch.id, equals('Fork velocity'));
    });

    test('colorValue / hexFromArgb — round-trip an ARGB integer', () {
      // Arrange
      const argb = 0xFF2196F3;

      // Act — int → hex → MathChannel → back to int.
      final hex = MathChannel.hexFromArgb(argb);
      const ch = MathChannel(
        id: 'c',
        name: 'c',
        quantity: '',
        units: '',
        sampleRateHz: 0,
        decimalPlaces: 2,
        color: '#FF2196F3',
        expression: '1',
      );

      // Assert
      expect(hex, equals('#FF2196F3'));
      expect(ch.colorValue, equals(argb));
    });

    test('colorValue — malformed hex falls back to a default colour', () {
      // Arrange
      const ch = MathChannel(
        id: 'c',
        name: 'c',
        quantity: '',
        units: '',
        sampleRateHz: 0,
        decimalPlaces: 2,
        color: 'not-a-colour',
        expression: '1',
      );

      // Act + Assert — never throws; returns the default blue.
      expect(ch.colorValue, equals(0xFF2196F3));
    });

    test('copyWith — replaces only specified fields', () {
      // Arrange
      const ch = MathChannel(
        id: 'uuid-1',
        name: 'Original',
        quantity: 'Velocity',
        units: 'm/s',
        sampleRateHz: 0.0,
        decimalPlaces: 3,
        color: '#FF2196F3',
        expression: 'integrate([IMU1_AccelZ])',
      );

      // Act
      final updated = ch.copyWith(name: 'Updated', units: 'km/h');

      // Assert
      expect(updated.name, equals('Updated'));
      expect(updated.units, equals('km/h'));
      expect(updated.id, equals(ch.id)); // unchanged
      expect(updated.expression, equals(ch.expression)); // unchanged
    });
  });
}
