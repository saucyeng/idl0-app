import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/spectral_params.dart';
import 'package:idl0/data/worksheet.dart';
import 'package:idl0/data/fft_options.dart';
import 'package:idl0/src/rust/fft.dart' show FftWindow, Detrend, Scaling, Averaging;

void main() {
  group('SpectralParams', () {
    test('toJson/fromJson — round-trips every field', () {
      // Arrange
      const p = SpectralParams(
        window: FftWindow.hamming,
        segmentLength: 512,
        overlapPercent: 75.0,
        detrend: Detrend.linear,
        scaling: Scaling.density,
        freqScale: FftXScale.linear,
      );

      // Act
      final back = SpectralParams.fromJson(p.toJson());

      // Assert
      expect(back.window, FftWindow.hamming);
      expect(back.segmentLength, 512);
      expect(back.overlapPercent, 75.0);
      expect(back.detrend, Detrend.linear);
      expect(back.scaling, Scaling.density);
      expect(back.freqScale, FftXScale.linear);
    });

    test('spectrogramDefaults — seeds Density scaling; fftDefaults — Magnitude', () {
      expect(SpectralParams.spectrogramDefaults().scaling, Scaling.density);
      expect(SpectralParams.fftDefaults().scaling, Scaling.magnitude);
    });

    test('toJson/fromJson — null segmentLength round-trips as auto', () {
      // Arrange
      const p = SpectralParams(
        window: FftWindow.hann,
        segmentLength: null,
        overlapPercent: 50.0,
        detrend: Detrend.mean,
        scaling: Scaling.magnitude,
        freqScale: FftXScale.log,
      );

      // Act
      final back = SpectralParams.fromJson(p.toJson());

      // Assert
      expect(back.segmentLength, isNull);
    });
  });

  group('ChartSlot legacy migration', () {
    test('fromJson — legacy flat fft* keys migrate into spectral group', () {
      // Arrange — a pre-refactor FFT slot.
      final legacy = {
        'chartType': 'fft',
        'fftWindow': 'hamming',
        'fftXScale': 'linear',
        'fftSegmentLength': 1024,
        'fftOverlapPercent': 25.0,
        'fftDetrend': 'linear',
        'fftScaling': 'density',
        'fftAveraging': 'median',
      };

      // Act
      final slot = ChartSlot.fromJson(legacy);

      // Assert — values land in spectral + averaging.
      expect(slot.spectral.window, FftWindow.hamming);
      expect(slot.spectral.freqScale, FftXScale.linear);
      expect(slot.spectral.segmentLength, 1024);
      expect(slot.spectral.overlapPercent, 25.0);
      expect(slot.spectral.detrend, Detrend.linear);
      expect(slot.spectral.scaling, Scaling.density);
      expect(slot.fftAveraging, Averaging.median);
    });
  });
}
