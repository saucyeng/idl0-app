import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/ui/tabs/analyze/turbo_colormap.dart';

void main() {
  test('turboColor — low end — blue dominates', () {
    // Arrange / Act — Turbo's cool end (t≈0.1) is blue.
    final c = turboColor(0.1);

    // Assert
    expect(c.b, greaterThan(c.r));
    expect(c.b, greaterThan(c.g));
  });

  test('turboColor — middle — green dominates', () {
    // Act
    final c = turboColor(0.5);

    // Assert — Turbo's midpoint is green/yellow.
    expect(c.g, greaterThan(c.r));
    expect(c.g, greaterThan(c.b));
  });

  test('turboColor — high end — red dominates', () {
    // Act
    final c = turboColor(1.0);

    // Assert
    expect(c.r, greaterThan(c.g));
    expect(c.r, greaterThan(c.b));
  });

  test('turboColor — out of range — clamps', () {
    // Act + Assert — below 0 / above 1 clamp to the endpoints.
    expect(turboColor(-3.0), equals(turboColor(0.0)));
    expect(turboColor(5.0), equals(turboColor(1.0)));
  });

  test('turboColor — NaN — returns the no-data colour', () {
    // Act + Assert
    expect(turboColor(double.nan), equals(const Color(0x00000000)));
    expect(
      turboColor(double.nan, noData: const Color(0xFF202020)),
      equals(const Color(0xFF202020)),
    );
  });
}
