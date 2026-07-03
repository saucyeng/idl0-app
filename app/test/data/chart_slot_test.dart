import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/fft_options.dart';
import 'package:idl0/data/spectral_params.dart';
import 'package:idl0/data/worksheet.dart';
import 'package:idl0/data/y_scale.dart';
import 'package:idl0/src/rust/fft.dart'
    show FftWindow, Detrend, Averaging, Scaling;

void main() {
  group('ChartSlot yScale', () {
    test('yScale — round-trips through JSON', () {
      // Arrange
      final slot =
          ChartSlot(chartType: ChartType.timeSeries, yScale: YScale.sqrtSigned);

      // Act
      final restored = ChartSlot.fromJson(slot.toJson());

      // Assert
      expect(restored.yScale, YScale.sqrtSigned);
    });

    test('yScale — defaults to linear and is omitted from JSON when linear', () {
      // Arrange / Act
      final json = ChartSlot(chartType: ChartType.timeSeries).toJson();

      // Assert
      expect(json.containsKey('yScale'), isFalse);
      expect(ChartSlot.fromJson(json).yScale, YScale.linear);
    });

    test('fromJson — legacy fftYScale: log migrates to yScale: log', () {
      // Arrange — a pre-unification FFT slot.
      final legacy = {
        'chartType': 'fft',
        'channelIds': <String>[],
        'fftYScale': 'log',
      };

      // Act / Assert
      expect(ChartSlot.fromJson(legacy).yScale, YScale.log);
    });

    test('fromJson — legacy histogramLogCount: true migrates to yScale: log',
        () {
      // Arrange — a pre-unification histogram slot.
      final legacy = {
        'chartType': 'histogram',
        'channelIds': <String>[],
        'histogramLogCount': true,
      };

      // Act / Assert
      expect(ChartSlot.fromJson(legacy).yScale, YScale.log);
    });
  });
  group('ChartSlot FFT Welch fields', () {
    test('toJson/fromJson — fft slot — round-trips spectral group + averaging',
        () {
      // Arrange
      final slot = ChartSlot(
        chartType: ChartType.fft,
        channelIds: ['imu1_accel_x'],
        spectral: const SpectralParams(
          window: FftWindow.hamming,
          segmentLength: 1024,
          overlapPercent: 75.0,
          detrend: Detrend.linear,
          scaling: Scaling.density,
          freqScale: FftXScale.log,
        ),
        fftAveraging: Averaging.median,
      );

      // Act
      final restored = ChartSlot.fromJson(slot.toJson());

      // Assert — the nested spectral group and FFT-only averaging both survive.
      expect(restored.spectral.window, FftWindow.hamming);
      expect(restored.spectral.segmentLength, 1024);
      expect(restored.spectral.overlapPercent, 75.0);
      expect(restored.spectral.detrend, Detrend.linear);
      expect(restored.spectral.scaling, Scaling.density);
      expect(restored.spectral.freqScale, FftXScale.log);
      expect(restored.fftAveraging, Averaging.median);
    });

    test('fromJson — fft slot with no spectral group — applies FFT defaults',
        () {
      // Arrange — a minimal slot: no grouped `spectral` and no legacy fft* keys.
      final json = {
        'chartType': 'fft',
        'channelIds': ['imu1_accel_x'],
      };

      // Act
      final slot = ChartSlot.fromJson(json);

      // Assert — seeded from SpectralParams.fftDefaults + default averaging.
      final d = SpectralParams.fftDefaults();
      expect(slot.spectral.segmentLength, isNull);
      expect(slot.spectral.overlapPercent, d.overlapPercent);
      expect(slot.spectral.detrend, d.detrend);
      expect(slot.spectral.scaling, d.scaling);
      expect(slot.fftAveraging, Averaging.mean);
    });

    test('toJson — fft slot auto segment length — spectral omits the key', () {
      // Arrange — an explicitly auto (null) segment length. The FFT default is
      // now a fixed 2048 (SpectralParams.fftDefaults), so auto is requested by
      // clearing the segment length rather than relying on the constructor.
      final slot = ChartSlot(
        chartType: ChartType.fft,
        channelIds: ['imu1_accel_x'],
        spectral: SpectralParams.fftDefaults().copyWith(clearSegmentLength: true),
      );

      // Act
      final spectralJson = slot.toJson()['spectral'] as Map<String, dynamic>;

      // Assert — auto length is omitted from the nested spectral map.
      expect(spectralJson.containsKey('segmentLength'), isFalse);
    });

    test('copyWith — clears segment length back to auto via spectral', () {
      // Arrange
      final slot = ChartSlot(
        chartType: ChartType.fft,
        channelIds: ['imu1_accel_x'],
        spectral: SpectralParams.fftDefaults().copyWith(segmentLength: 2048),
      );

      // Act
      final cleared = slot.copyWith(
        spectral: slot.spectral.copyWith(clearSegmentLength: true),
      );

      // Assert
      expect(cleared.spectral.segmentLength, isNull);
    });

    test('autoFftSegmentLength — long record — power of two ≤ n/8, capped', () {
      // Arrange — 60 s at 1 kHz
      const n = 60000;

      // Act
      final seg = ChartSlot.autoFftSegmentLength(n);

      // Assert — largest pow2 ≤ 7500 is 4096, within [256, 8192]
      expect(seg, 4096);
    });

    test('autoFftSegmentLength — short record — floored at min but ≤ n', () {
      // Arrange — fewer samples than the 256 floor
      const n = 100;

      // Act
      final seg = ChartSlot.autoFftSegmentLength(n);

      // Assert — never exceeds the record length
      expect(seg, 100);
    });
  });

  group('ChartSlot autoSpectrogramOverlap', () {
    // Mirrors the engine: n_times = (winLen - seg) ~/ step + 1, step = seg - ov.
    int frameCount(int winLen, int seg, int noverlap) =>
        (winLen - seg) ~/ (seg - noverlap) + 1;

    test('autoSpectrogramOverlap — long window — fills ~target time columns',
        () {
      // Arrange — 60 s at 1 kHz, auto segment length (4096).
      const winLen = 60000;
      final seg = ChartSlot.autoFftSegmentLength(winLen); // 4096

      // Act
      final overlap = ChartSlot.autoSpectrogramOverlap(winLen, seg);
      final columns = frameCount(winLen, seg, overlap);

      // Assert — flooring the hop never under-fills the target, and overshoot
      // is bounded; far more than the FFT chart's fixed 50% overlap would give.
      const target = ChartSlot.kSpectrogramTargetColumns;
      expect(columns, greaterThanOrEqualTo(target));
      expect(columns, lessThan(target + 10));
      // Welch's 50% overlap over the same window/segment yields ~28 columns —
      // the coarseness this auto hop replaces.
      final welch50 = frameCount(winLen, seg, seg ~/ 2);
      expect(columns, greaterThan(welch50 * 4));
    });

    test('autoSpectrogramOverlap — overlap stays within [0, seg-1]', () {
      // Arrange
      const winLen = 60000;
      final seg = ChartSlot.autoFftSegmentLength(winLen);

      // Act
      final overlap = ChartSlot.autoSpectrogramOverlap(winLen, seg);

      // Assert — hop ≥ 1 (overlap ≤ seg-1) and non-negative.
      expect(overlap, greaterThanOrEqualTo(0));
      expect(overlap, lessThanOrEqualTo(seg - 1));
    });

    test('autoSpectrogramOverlap — short window — hop 1, near-full overlap', () {
      // Arrange — only 50 samples longer than one segment.
      const seg = 256;
      const winLen = seg + 50;

      // Act
      final overlap = ChartSlot.autoSpectrogramOverlap(winLen, seg);

      // Assert — hop collapses to 1 (overlap = seg-1), packing the maximum
      // number of frames the window allows.
      expect(overlap, seg - 1);
      expect(frameCount(winLen, seg, overlap), winLen - seg + 1);
    });

    test('autoSpectrogramOverlap — window ≤ one segment — returns 0', () {
      // Arrange / Act / Assert — a single full-window frame, no overlap.
      expect(ChartSlot.autoSpectrogramOverlap(256, 256), 0);
      expect(ChartSlot.autoSpectrogramOverlap(100, 256), 0);
      expect(ChartSlot.autoSpectrogramOverlap(0, 256), 0);
      expect(ChartSlot.autoSpectrogramOverlap(60000, 0), 0);
    });
  });

  group('ChartSlot histogram fields', () {
    test('toJson/fromJson — histogram slot — round-trips bin/symmetric/log', () {
      // Arrange
      final slot = ChartSlot(
        chartType: ChartType.histogram,
        channelIds: ['fork_velocity'],
        histogramBinCount: 60,
        histogramSymmetric: true,
        histogramSmooth: true,
      );

      // Act
      final restored = ChartSlot.fromJson(slot.toJson());

      // Assert
      expect(restored.chartType, ChartType.histogram);
      expect(restored.histogramBinCount, 60);
      expect(restored.histogramSymmetric, isTrue);
      expect(restored.histogramSmooth, isTrue);
    });

    test('toJson — non-histogram slot — omits histogram keys', () {
      // Arrange — a time-series slot carries the default histogram fields but
      // must not serialize them (keeps other chart-type JSON untouched).
      final slot = ChartSlot(
        chartType: ChartType.timeSeries,
        channelIds: ['imu1_accel_x'],
      );

      // Act
      final json = slot.toJson();

      // Assert
      expect(json.containsKey('histogramBinCount'), isFalse);
      expect(json.containsKey('histogramSymmetric'), isFalse);
    });

    test('toJson — histogram slot with defaults — omits the off toggles', () {
      // Arrange — default symmetric/log are false, so only bin count emits.
      final slot = ChartSlot(
        chartType: ChartType.histogram,
        channelIds: ['fork_velocity'],
      );

      // Act
      final json = slot.toJson();

      // Assert — bin count always present; the false toggles are omitted.
      expect(json['histogramBinCount'], 40);
      expect(json.containsKey('histogramSymmetric'), isFalse);
    });

    test('fromJson — histogram slot missing keys — applies defaults', () {
      // Arrange — JSON predating the histogram fields.
      final json = {
        'chartType': 'histogram',
        'channelIds': ['fork_velocity'],
      };

      // Act
      final slot = ChartSlot.fromJson(json);

      // Assert
      expect(slot.histogramBinCount, 40);
      expect(slot.histogramSymmetric, isFalse);
      expect(slot.histogramSmooth, isFalse);
    });
  });

  group('ChartSlot.slotId', () {
    test('constructor — generates a UUID when slotId is omitted', () {
      // Arrange + Act
      final a = ChartSlot();
      final b = ChartSlot();

      // Assert — non-empty and distinct
      expect(a.slotId, isNotEmpty);
      expect(b.slotId, isNotEmpty);
      expect(a.slotId, isNot(equals(b.slotId)));
    });

    test('copyWith — preserves slotId by default', () {
      // Arrange
      final original = ChartSlot();

      // Act
      final copy = original.copyWith(channelIds: const ['foo']);

      // Assert
      expect(copy.slotId, equals(original.slotId));
    });

    test('toJson / fromJson — round-trips slotId', () {
      // Arrange
      final original = ChartSlot();

      // Act
      final restored = ChartSlot.fromJson(original.toJson());

      // Assert
      expect(restored.slotId, equals(original.slotId));
    });

    test('fromJson — generates a slotId when JSON omits it', () {
      // Arrange — legacy JSON predating slotId
      final json = {
        'chartType': 'timeSeries',
        'channelIds': <String>[],
        'mathChannelIds': <String>[],
        'yScaleMode': 'auto',
        'heightFactor': 1.0,
        'channelColors': <String, dynamic>{},
        'scope': 'auto',
      };

      // Act
      final slot = ChartSlot.fromJson(json);

      // Assert
      expect(slot.slotId, isNotEmpty);
    });
  });
}
