/// X axis scale mode for [FftChart].
///
/// Persisted per-slot via [ChartSlot.fftXScale] so users see the same
/// scale on reopen.
enum FftXScale {
  /// Linear frequency axis — equal pixel spacing per Hz.
  linear,

  /// Logarithmic frequency axis — equal pixel spacing per decade (10×).
  ///
  /// Spot X values are stored as `log₁₀(freq_Hz)` so fl_chart can render
  /// them on its linear canvas. The DC bin (freq = 0) is skipped because
  /// log(0) is undefined. Axis labels are converted back to Hz for
  /// display.
  log,
}
