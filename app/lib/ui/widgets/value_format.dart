/// Smart sig-fig formatter for channel values shown in chart tooltips.
///
/// Rules, by magnitude:
/// - `|v| >= 1000` → 0 decimals (`12346`)
/// - `|v| >= 100`  → 1 decimal  (`345.7`)
/// - `|v| >= 10`   → 2 decimals (`12.35`)
/// - `|v| >= 1`    → 3 decimals (`1.235`)
/// - `0 < |v| < 1` → trailing significant digits to 3 (`0.123`, `0.0123`)
/// - `v == 0`       → `"0"`
/// - `v.isNaN`      → `"—"` (dim em dash)
/// - `v.isInfinite` → `"∞"` / `"-∞"`
///
/// Units are not appended — the chart palette swatch identifies the
/// channel and units live in chart properties / spec metadata.
String formatChannelValue(double v) {
  if (v.isNaN) return '—';
  if (v.isInfinite) return v.isNegative ? '-∞' : '∞';
  if (v == 0) return '0';

  final magnitude = v.abs();
  if (magnitude >= 1000) return v.toStringAsFixed(0);
  if (magnitude >= 100) return v.toStringAsFixed(1);
  if (magnitude >= 10) return v.toStringAsFixed(2);
  if (magnitude >= 1) return v.toStringAsFixed(3);

  // |v| < 1: number of decimal places needed so three significant
  // digits survive. 0.123 → 3, 0.0123 → 4, 0.00123 → 5.
  // decimals = 3 + (number of leading zeros after the decimal point)
  var leadingZeros = 0;
  var n = magnitude;
  while (n < 0.1) {
    n *= 10;
    leadingZeros += 1;
  }
  return v.toStringAsFixed(3 + leadingZeros);
}
