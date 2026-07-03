import 'package:flutter/material.dart' show Color;

/// Maps a normalised value `t ∈ [0, 1]` to a colour on Google's **Turbo**
/// colormap (Anton Mikhailov, 2019) — a saturated, perceptually-ordered scale
/// running blue → cyan → green → yellow → red. Used to colour the GPS trace by
/// a channel value.
///
/// `t` is clamped to `[0, 1]`. Non-finite `t` (e.g. a `NaN` from an unsampled
/// GPS fix) returns [noData] (default fully transparent).
///
/// Implemented as the standard degree-5 polynomial approximation of the Turbo
/// table — visually faithful across the range (the only notable deviation is
/// `t < 0.05`, where the true table is a slightly deeper blue-purple).
Color turboColor(double t, {Color noData = const Color(0x00000000)}) {
  if (t.isNaN || t.isInfinite) return noData;
  final x = t.clamp(0.0, 1.0);
  final x2 = x * x;
  final x3 = x2 * x;
  final x4 = x2 * x2;
  final x5 = x4 * x;
  final r = 0.13572138 +
      4.61539260 * x +
      -42.66032258 * x2 +
      132.13108234 * x3 +
      -152.94239396 * x4 +
      59.28637943 * x5;
  final g = 0.09140261 +
      2.19418839 * x +
      4.84296658 * x2 +
      -14.18503333 * x3 +
      4.27729857 * x4 +
      2.82956604 * x5;
  final b = 0.10667330 +
      12.64194608 * x +
      -60.58204836 * x2 +
      110.36276771 * x3 +
      -89.90310912 * x4 +
      27.34824973 * x5;
  int q(double v) => (v.clamp(0.0, 1.0) * 255.0).round();
  return Color.fromARGB(255, q(r), q(g), q(b));
}
