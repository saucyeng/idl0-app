import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/ui/brand/brand_tokens.dart';

void main() {
  group('brand_tokens — colors', () {
    test('palette values match spec', () {
      // Arrange / Act / Assert — these are the canonical brand colors.
      // If the values change, the brand has changed.
      expect(brandBg, const Color(0xFF121412));
      expect(brandSurface, const Color(0xFF1A1E18));
      expect(brandSurface2, const Color(0xFF161915));
      expect(brandFg, const Color(0xFFEFEAE0));
      expect(brandFgDim, const Color(0xFF9A968A));
      expect(brandRule, const Color(0xFF353A32));
      expect(brandAccent, const Color(0xFFE63946));
      expect(brandHivis, const Color(0xFFF5D547));
    });
  });

  group('brand_tokens — geometry', () {
    test(
      'control radius is 2 px (max allowed for interactive controls)',
      () {
        // Arrange / Act / Assert
        expect(brandControlRadius, 2.0);
      },
    );

    test('hairline width is 1 px', () {
      // Arrange / Act / Assert
      expect(brandHairlineWidth, 1.0);
    });
  });

  group('brand_tokens — typography', () {
    test('tabular figures are part of the brand feature list', () {
      // Arrange / Act / Assert — every TextStyle the brand emits must
      // include this feature so digits align in tables and charts.
      expect(
        brandTabularFeatures,
        contains(const FontFeature.tabularFigures()),
      );
    });

    test('label tracking values match spec (NATOPS-style spacing)', () {
      // Arrange / Act / Assert
      expect(brandLabelTracking, 1.6);
      expect(brandKickerTracking, 2.0);
    });
  });
}
