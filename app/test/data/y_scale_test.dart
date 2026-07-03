import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/y_scale.dart';

void main() {
  // A representative signed sweep including zero and a large spike.
  const samples = <double>[-1000, -12.5, -1, -0.001, 0, 0.001, 1, 12.5, 1000];

  for (final mode in YScale.values) {
    test('YScaleTransform — $mode — inverse undoes forward (round-trip)', () {
      // Arrange
      final t = YScaleTransform(mode, dataMaxAbs: 1000);

      // Act / Assert
      for (final y in samples) {
        final back = t.inverse(t.forward(y));
        expect(back, closeTo(y, 1e-6), reason: '$mode failed at y=$y');
      }
    });

    test('YScaleTransform — $mode — zero maps to zero and sign is preserved',
        () {
      // Arrange
      final t = YScaleTransform(mode, dataMaxAbs: 1000);

      // Act / Assert
      expect(t.forward(0), closeTo(0, 1e-12));
      expect(t.forward(5) > 0, isTrue, reason: '$mode positive stays positive');
      expect(t.forward(-5) < 0, isTrue, reason: '$mode negative stays negative');
    });

    test('YScaleTransform — $mode — forward is monotonic increasing', () {
      // Arrange
      final t = YScaleTransform(mode, dataMaxAbs: 1000);

      // Act / Assert — order-preserving across the sweep.
      var prev = -double.infinity;
      for (final y in samples) {
        final d = t.forward(y);
        expect(d, greaterThan(prev), reason: '$mode not monotonic at y=$y');
        prev = d;
      }
    });
  }

  test('YScaleTransform — linear — isIdentity and forward == input', () {
    // Arrange
    final t = YScaleTransform(YScale.linear, dataMaxAbs: 10);

    // Act / Assert
    expect(t.isIdentity, isTrue);
    expect(t.forward(3.5), 3.5);
    expect(YScaleTransform(YScale.log, dataMaxAbs: 10).isIdentity, isFalse);
  });

  test('YScaleTransform — sqrtSigned — known values', () {
    // Arrange
    final t = YScaleTransform(YScale.sqrtSigned, dataMaxAbs: 100);

    // Act / Assert — sign(y)*sqrt(|y|).
    expect(t.forward(9), closeTo(3, 1e-9));
    expect(t.forward(-16), closeTo(-4, 1e-9));
  });

  test('YScaleTransform — log — large positive value is well above the band',
      () {
    // Arrange — symlog with a tiny auto band; a decade above linthresh maps
    // monotonically far above it.
    final t = YScaleTransform(YScale.log, dataMaxAbs: 1000);

    // Act / Assert — forward(1000) is larger than forward(10) (compression,
    // but still strictly ordered), and positive.
    expect(t.forward(1000), greaterThan(t.forward(10)));
    expect(t.forward(1000), greaterThan(0));
  });
}
