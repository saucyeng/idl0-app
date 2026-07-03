import 'package:idl0/data/fft_options.dart';
import 'package:idl0/src/rust/fft.dart' show FftWindow, Detrend, Scaling;

/// The DSP knobs shared by the FFT chart and the spectrogram chart — identical
/// window / segment-length / overlap / detrend / scaling / frequency-axis
/// scale. The FFT chart adds cross-segment `averaging` on top; the spectrogram
/// keeps every frame, so it omits it. See SPEC §26 and the FFT/spectrogram
/// design doc.
class SpectralParams {
  /// Window applied before each segment's FFT.
  final FftWindow window;

  /// Welch/STFT segment length in samples; `null` = auto.
  final int? segmentLength;

  /// Segment overlap percent (0–99). Welch standard is 50%.
  final double overlapPercent;

  /// Per-segment trend removal (suppresses the DC spike).
  final Detrend detrend;

  /// Output units: magnitude (RMS) or density (PSD).
  final Scaling scaling;

  /// Frequency-axis scale — X for the FFT chart, Y for the spectrogram.
  final FftXScale freqScale;

  /// Creates a [SpectralParams].
  const SpectralParams({
    required this.window,
    required this.segmentLength,
    required this.overlapPercent,
    required this.detrend,
    required this.scaling,
    required this.freqScale,
  });

  /// Defaults for an FFT chart slot (Magnitude units, log frequency axis).
  factory SpectralParams.fftDefaults() => const SpectralParams(
        window: FftWindow.hann,
        // 2048-sample Welch segments — many averaged segments (smooth spectrum)
        // while keeping usable low-frequency resolution. `null` here would mean
        // "auto" (zoom-adaptive at render); 2048 is the fixed starting point.
        segmentLength: 2048,
        overlapPercent: 50.0,
        detrend: Detrend.mean,
        scaling: Scaling.magnitude,
        freqScale: FftXScale.log,
      );

  /// Defaults for a spectrogram slot (Density units — a heatmap reads best as PSD).
  factory SpectralParams.spectrogramDefaults() => const SpectralParams(
        window: FftWindow.hann,
        segmentLength: null,
        overlapPercent: 50.0,
        detrend: Detrend.mean,
        scaling: Scaling.density,
        freqScale: FftXScale.log,
      );

  /// Returns a copy with the given fields replaced. Pass `clearSegmentLength`
  /// to set [segmentLength] back to null (auto).
  SpectralParams copyWith({
    FftWindow? window,
    int? segmentLength,
    bool clearSegmentLength = false,
    double? overlapPercent,
    Detrend? detrend,
    Scaling? scaling,
    FftXScale? freqScale,
  }) =>
      SpectralParams(
        window: window ?? this.window,
        segmentLength:
            clearSegmentLength ? null : (segmentLength ?? this.segmentLength),
        overlapPercent: overlapPercent ?? this.overlapPercent,
        detrend: detrend ?? this.detrend,
        scaling: scaling ?? this.scaling,
        freqScale: freqScale ?? this.freqScale,
      );

  /// Serializes to a JSON map (camelCase keys).
  Map<String, dynamic> toJson() => {
        'window': window.name,
        if (segmentLength != null) 'segmentLength': segmentLength,
        'overlapPercent': overlapPercent,
        'detrend': detrend.name,
        'scaling': scaling.name,
        'freqScale': freqScale.name,
      };

  /// Deserializes; unknown values fall back to FFT defaults so old/partial JSON loads.
  factory SpectralParams.fromJson(Map<String, dynamic> json) {
    final d = SpectralParams.fftDefaults();
    return SpectralParams(
      window: FftWindow.values.firstWhere(
        (e) => e.name == json['window'],
        orElse: () => d.window,
      ),
      segmentLength: json['segmentLength'] as int?,
      overlapPercent:
          (json['overlapPercent'] as num?)?.toDouble() ?? d.overlapPercent,
      detrend: Detrend.values.firstWhere(
        (e) => e.name == json['detrend'],
        orElse: () => d.detrend,
      ),
      scaling: Scaling.values.firstWhere(
        (e) => e.name == json['scaling'],
        orElse: () => d.scaling,
      ),
      freqScale: FftXScale.values.firstWhere(
        (e) => e.name == json['freqScale'],
        orElse: () => d.freqScale,
      ),
    );
  }

  /// Migrates a pre-refactor slot's flat `fft*` keys into a group. Used by
  /// [ChartSlot.fromJson] when no `spectral` object is present.
  factory SpectralParams.fromLegacyFftJson(Map<String, dynamic> json) {
    final d = SpectralParams.fftDefaults();
    return SpectralParams(
      window: FftWindow.values.firstWhere(
        (e) => e.name == json['fftWindow'],
        orElse: () => d.window,
      ),
      segmentLength: json['fftSegmentLength'] as int?,
      overlapPercent:
          (json['fftOverlapPercent'] as num?)?.toDouble() ?? d.overlapPercent,
      detrend: Detrend.values.firstWhere(
        (e) => e.name == json['fftDetrend'],
        orElse: () => d.detrend,
      ),
      scaling: Scaling.values.firstWhere(
        (e) => e.name == json['fftScaling'],
        orElse: () => d.scaling,
      ),
      freqScale: FftXScale.values.firstWhere(
        (e) => e.name == json['fftXScale'],
        orElse: () => d.freqScale,
      ),
    );
  }
}
