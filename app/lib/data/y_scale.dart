import 'dart:math' as math;

/// Y-axis display scale shared by every chart with a continuous Y axis.
/// Persisted per-slot on `ChartSlot.yScale`. The transform is a pure display
/// mapping (it never alters the data); see [YScaleTransform].
enum YScale {
  /// Identity — equal pixel spacing per unit.
  linear,

  /// Signed log (symlog): linear in a small auto band around zero, log in both
  /// tails. Works on zero-crossing data; ≈ log₁₀ on always-positive data.
  log,

  /// Signed square root: `sign(y)·√|y|`. Gently compresses large excursions.
  sqrtSigned,

  /// Signed square: `sign(y)·y²`. Emphasises large excursions.
  squareSigned,
}

/// Maps real data values to display space ([forward]) and back ([inverse]) for
/// a [YScale]. Constructed per render from the chart's effective Y range so the
/// symlog band is stable across pan/zoom. All modes are monotonic and
/// continuous through zero, so transforming the already-decimated min/max spots
/// preserves the envelope. Pure — no Flutter, no I/O.
class YScaleTransform {
  /// Builds a transform for [mode]. [dataMaxAbs] is `max(|rangeMin|,
  /// |rangeMax|)` of the chart's real-unit Y range; it sizes the symlog linear
  /// band and is ignored by the other modes.
  YScaleTransform(this.mode, {required double dataMaxAbs})
      : _linthresh = math.max(dataMaxAbs.abs(), _eps) * _bandFraction;

  /// Smallest magnitude treated as non-zero when sizing the band (guards an
  /// all-zero series from a zero `linthresh`).
  static const double _eps = 1e-30;

  /// Symlog linear-band size as a fraction of `dataMaxAbs`.
  static const double _bandFraction = 1e-3;

  /// The active scale.
  final YScale mode;

  /// Half-width of the symlog linear band, in real units.
  final double _linthresh;

  /// True only for [YScale.linear] — lets callers skip per-spot work.
  bool get isIdentity => mode == YScale.linear;

  /// Maps a real value to display space.
  double forward(double y) {
    switch (mode) {
      case YScale.linear:
        return y;
      case YScale.sqrtSigned:
        return _sign(y) * math.sqrt(y.abs());
      case YScale.squareSigned:
        return _sign(y) * y * y;
      case YScale.log:
        final a = y.abs();
        final m = a <= _linthresh
            ? a / _linthresh
            : 1 + math.log(a / _linthresh) / math.ln10;
        return _sign(y) * _linthresh * m;
    }
  }

  /// Maps a display value back to real space (exact inverse of [forward]).
  double inverse(double d) {
    switch (mode) {
      case YScale.linear:
        return d;
      case YScale.sqrtSigned:
        return _sign(d) * d * d;
      case YScale.squareSigned:
        return _sign(d) * math.sqrt(d.abs());
      case YScale.log:
        final m = d.abs() / _linthresh;
        final a = m <= 1
            ? m * _linthresh
            : _linthresh * math.pow(10, m - 1).toDouble();
        return _sign(d) * a;
    }
  }

  // +1 for zero so forward(0) == 0 across every mode (magnitude is 0 there).
  static double _sign(double v) => v < 0 ? -1.0 : 1.0;
}
