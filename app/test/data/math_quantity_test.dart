import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/app_settings.dart';
import 'package:idl0/data/math_channel.dart';
import 'package:idl0/data/math_quantity.dart';

void main() {
  group('kMathQuantities —', () {
    // 1
    test('contains exactly 25 entries', () {
      expect(kMathQuantities.length, equals(25));
    });

    // 2
    test('every entry has at least one unit', () {
      for (final q in kMathQuantities) {
        expect(
          q.units.isNotEmpty,
          isTrue,
          reason: '${q.name} has an empty units list',
        );
      }
    });

    // 3
    test('all names are unique', () {
      final names = kMathQuantities.map((q) => q.name).toList();
      expect(names.toSet().length, equals(names.length));
    });
  });

  group('MathQuantity.byName —', () {
    // 4
    test('returns correct entry for a known name', () {
      final q = MathQuantity.byName('Acceleration');

      expect(q, isNotNull);
      expect(q!.name, equals('Acceleration'));
      expect(q.units.first, equals('g'));
    });

    // 5
    test('returns null for empty string', () {
      expect(MathQuantity.byName(''), isNull);
    });

    // 6
    test('returns null for unrecognised name', () {
      expect(MathQuantity.byName('Flux Capacitance'), isNull);
    });

    // 7
    test('returns exact instance from kMathQuantities (identity)', () {
      final result = MathQuantity.byName('Speed');

      expect(identical(result, kMathQuantities[1]), isTrue);
    });
  });

  group('defaultUnit —', () {
    // 8 (was 8 — renumbered below to avoid collision with existing tests)
    test('defaultUnit — Speed — imperial → mph', () {
      // Arrange
      final q = MathQuantity.byName('Speed')!;

      // Act
      final unit = defaultUnit(q, UnitSystem.imperial);

      // Assert
      expect(unit, equals('mph'));
    });

    // 9
    test('defaultUnit — Speed — metric → km/h (primary)', () {
      // Arrange
      final q = MathQuantity.byName('Speed')!;

      // Act
      final unit = defaultUnit(q, UnitSystem.metric);

      // Assert
      expect(unit, equals('km/h'));
    });

    // 10
    test('defaultUnit — Temperature — imperial → °F', () {
      // Arrange
      final q = MathQuantity.byName('Temperature')!;

      // Act
      final unit = defaultUnit(q, UnitSystem.imperial);

      // Assert
      expect(unit, equals('°F'));
    });

    // 11
    test('defaultUnit — Temperature — metric → °C (primary)', () {
      // Arrange
      final q = MathQuantity.byName('Temperature')!;

      // Act
      final unit = defaultUnit(q, UnitSystem.metric);

      // Assert
      expect(unit, equals('°C'));
    });

    // 12
    test(
        'defaultUnit — Acceleration — always returns primary unit g regardless of system',
        () {
      // Arrange
      final q = MathQuantity.byName('Acceleration')!;

      // Act / Assert — no imperial override for Acceleration
      expect(defaultUnit(q, UnitSystem.imperial), equals('g'));
      expect(defaultUnit(q, UnitSystem.metric), equals('g'));
    });

    // 13
    test('defaultUnit — Pressure & Stress — imperial → psi', () {
      // Arrange
      final q = MathQuantity.byName('Pressure & Stress')!;

      // Act
      final unit = defaultUnit(q, UnitSystem.imperial);

      // Assert
      expect(unit, equals('psi'));
    });
  });

  group('quantity selection — channel update logic —', () {
    // 8
    test('selecting Acceleration sets quantity name and primary unit g', () {
      // Arrange
      const channel = MathChannel(
        id: 'ch-1',
        name: 'Test',
        quantity: '',
        units: '',
        sampleRateHz: 0.0,
        decimalPlaces: 3,
        color: '#FF2196F3',
        expression: '',
      );
      final q = MathQuantity.byName('Acceleration')!;

      // Act — simulate _onQuantityChanged behaviour
      final updated = channel.copyWith(
        quantity: q.name,
        units: q.units.first,
      );

      // Assert
      expect(updated.quantity, equals('Acceleration'));
      expect(updated.units, equals('g'));
    });

    // 9
    test('switching from Speed to Pressure & Stress resets units to kPa', () {
      // Arrange
      const channel = MathChannel(
        id: 'ch-2',
        name: 'Test',
        quantity: 'Speed',
        units: 'km/h',
        sampleRateHz: 0.0,
        decimalPlaces: 3,
        color: '#FF2196F3',
        expression: '',
      );
      final q = MathQuantity.byName('Pressure & Stress')!;

      // Act
      final updated = channel.copyWith(
        quantity: q.name,
        units: q.units.first,
      );

      // Assert
      expect(updated.quantity, equals('Pressure & Stress'));
      expect(updated.units, equals('kPa'));
    });

    // 10
    test('Ratio quantity has a single empty-string unit', () {
      final q = MathQuantity.byName('Ratio')!;

      expect(q.units.length, equals(1));
      expect(q.units.first, equals(''));
    });
  });
}
