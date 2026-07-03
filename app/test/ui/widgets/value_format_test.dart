import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/ui/widgets/value_format.dart';

void main() {
  test('formatChannelValue — |v| >= 1000 — drops decimals', () {
    expect(formatChannelValue(12345.67), '12346');
    expect(formatChannelValue(-1000.0), '-1000');
    expect(formatChannelValue(99999.4), '99999');
  });

  test('formatChannelValue — |v| in [100, 1000) — uses 1 decimal', () {
    expect(formatChannelValue(345.67), '345.7');
    expect(formatChannelValue(100.0), '100.0');
    expect(formatChannelValue(-999.95), '-1000.0'); // rounds up across band boundary
  });

  test('formatChannelValue — |v| in [10, 100) — uses 2 decimals', () {
    expect(formatChannelValue(12.345), '12.35');
    expect(formatChannelValue(-10.0), '-10.00');
    expect(formatChannelValue(99.999), '100.00');
  });

  test('formatChannelValue — |v| in [1, 10) — uses 3 decimals', () {
    expect(formatChannelValue(1.2345), '1.234');  // IEEE 754: 1.2344999...
    expect(formatChannelValue(-9.9999), '-10.000');
    expect(formatChannelValue(1.0), '1.000');
  });

  test('formatChannelValue — |v| in (0, 1) — keeps three significant figures', () {
    expect(formatChannelValue(0.12345), '0.123');
    expect(formatChannelValue(0.012345), '0.0123');
    expect(formatChannelValue(0.0012345), '0.00123');
    expect(formatChannelValue(-0.5), '-0.500');
  });

  test('formatChannelValue — zero — renders as "0"', () {
    expect(formatChannelValue(0.0), '0');
    expect(formatChannelValue(-0.0), '0');
  });

  test('formatChannelValue — NaN — renders as the dim em dash', () {
    expect(formatChannelValue(double.nan), '—');
  });

  test('formatChannelValue — infinity — renders with sign', () {
    expect(formatChannelValue(double.infinity), '∞');
    expect(formatChannelValue(double.negativeInfinity), '-∞');
  });
}
