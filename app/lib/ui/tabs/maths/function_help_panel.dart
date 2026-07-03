import 'package:flutter/material.dart';

import '../../brand/brand.dart';

/// Context-sensitive help panel showing the signature of a §10 function.
///
/// Appears in [ExpressionEditor] when the cursor is inside a function call.
/// [functionName] drives which signature and description are shown.
class FunctionHelpPanel extends StatelessWidget {
  /// The §10 function name detected at the cursor, e.g. `"butter"`.
  final String functionName;

  /// Creates a [FunctionHelpPanel].
  const FunctionHelpPanel({super.key, required this.functionName});

  @override
  Widget build(BuildContext context) {
    final entry = _kFunctionHelp[functionName];
    if (entry == null) return const SizedBox.shrink();

    return NoteBlock(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 14, color: brandFgDim),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.signature,
                  style: plexMono(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: brandFg,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  entry.description,
                  style: plexMono(fontSize: 11, color: brandFgDim),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Help content — §10 function table
// ---------------------------------------------------------------------------

class _HelpEntry {
  final String signature;
  final String description;

  const _HelpEntry(this.signature, this.description);
}

/// Signature and one-line description for each §10 function.
///
/// Keys match [MathChannelValidator.knownFunctions].
const Map<String, _HelpEntry> _kFunctionHelp = {
  // Filters
  'butter': _HelpEntry(
    'butter(order, cutoff, type, ch)',
    'Butterworth filter. type: "low" | "high" | "band". scipy.signal.butter equivalent.',
  ),
  'sosfilt': _HelpEntry(
    'sosfilt(sos, ch)',
    'Apply second-order sections filter to ch. Use with butter() output.',
  ),
  // Reconstruction
  'declip': _HelpEntry(
    'declip(ch)',
    'Reconstructs IMU acceleration peaks clipped at the ±32 g sensor rail '
        'by fitting a smooth asymmetric pulse to each clipped peak. '
        'Returns ch unchanged where nothing is clipped.',
  ),
  // Time-domain
  'integrate': _HelpEntry(
    'integrate(ch)',
    'Cumulative trapezoidal integration. Equivalent to scipy.integrate.cumtrapz.',
  ),
  'differentiate': _HelpEntry(
    'differentiate(ch)',
    'Numerical differentiation (central differences).',
  ),
  'rms': _HelpEntry(
    'rms(ch, w)',
    'Root mean square over window w samples.',
  ),
  'mean': _HelpEntry(
    'mean(ch, w)',
    'Rolling mean over window w samples.',
  ),
  'std': _HelpEntry(
    'std(ch, w)',
    'Rolling standard deviation over window w samples.',
  ),
  'median': _HelpEntry(
    'median(ch, w)',
    'Rolling median over window w samples.',
  ),
  // Frequency
  'fft': _HelpEntry(
    'fft(ch, window)',
    'One-sided magnitude spectrum. window: "hann" | "hamming" | "rect".',
  ),
  'spectrogram': _HelpEntry(
    'spectrogram(ch)',
    'Short-time Fourier transform spectrogram.',
  ),
  'hilbert': _HelpEntry(
    'hilbert(ch)',
    'Analytic signal via Hilbert transform. Returns instantaneous amplitude.',
  ),
  // Correlation
  'correlate': _HelpEntry(
    'correlate(a, b)',
    'Cross-correlation of channels a and b.',
  ),
  'convolve': _HelpEntry(
    'convolve(ch, kernel)',
    'Convolution of ch with a kernel channel.',
  ),
  // Resampling
  'resample': _HelpEntry(
    'resample(ch, hz)',
    'Resample ch to hz Hz. Uses polyphase filtering.',
  ),
  // Math
  'abs': _HelpEntry('abs(ch)', 'Element-wise absolute value.'),
  'sqrt': _HelpEntry('sqrt(ch)', 'Element-wise square root.'),
  'pow': _HelpEntry('pow(ch, n)', 'Element-wise exponentiation: ch^n.'),
  'sign': _HelpEntry('sign(ch)', 'Element-wise sign: -1, 0, or 1.'),
  'min': _HelpEntry('min(a, b)', 'Element-wise minimum of a and b.'),
  'max': _HelpEntry('max(a, b)', 'Element-wise maximum of a and b.'),
  'clamp': _HelpEntry('clamp(ch, low, high)', 'Clamp values to [low, high].'),
  'floor': _HelpEntry('floor(ch)', 'Element-wise floor.'),
  'ceil': _HelpEntry('ceil(ch)', 'Element-wise ceiling.'),
  'round': _HelpEntry('round(ch)', 'Element-wise round to nearest integer.'),
  // Trig
  'sin': _HelpEntry('sin(ch)', 'Element-wise sine (radians).'),
  'cos': _HelpEntry('cos(ch)', 'Element-wise cosine (radians).'),
  'tan': _HelpEntry('tan(ch)', 'Element-wise tangent (radians).'),
  'asin': _HelpEntry('asin(ch)', 'Element-wise arcsine → radians.'),
  'acos': _HelpEntry('acos(ch)', 'Element-wise arccosine → radians.'),
  'atan': _HelpEntry('atan(ch)', 'Element-wise arctangent → radians.'),
  'atan2': _HelpEntry('atan2(y, x)', 'Four-quadrant arctangent → radians.'),
  'sinh': _HelpEntry('sinh(ch)', 'Element-wise hyperbolic sine.'),
  'cosh': _HelpEntry('cosh(ch)', 'Element-wise hyperbolic cosine.'),
  'tanh': _HelpEntry('tanh(ch)', 'Element-wise hyperbolic tangent.'),
  'deg2rad': _HelpEntry('deg2rad(ch)', 'Degrees to radians: ch × π/180.'),
  'rad2deg': _HelpEntry('rad2deg(ch)', 'Radians to degrees: ch × 180/π.'),
  // Logic
  'if': _HelpEntry(
    'if(cond, t, f)',
    'Element-wise conditional: t where cond is true, f elsewhere.',
  ),
  // Lap-aware (read lap/sector gates from workspace)
  'current_lap': _HelpEntry(
    'current_lap()',
    '1-based lap number containing each sample, or 0 outside any lap. '
        'Reads lap gates from the per-session workspace.',
  ),
  'lap_start_time': _HelpEntry(
    'lap_start_time(n)',
    'Session-relative time of lap n\'s start, in seconds. NaN when n is '
        '0 or beyond the last detected lap.',
  ),
  'lap_start_distance': _HelpEntry(
    'lap_start_distance(n)',
    'Cumulative [Distance] at lap n\'s start, in metres. NaN when n is '
        '0, beyond the last detected lap, or the session has no '
        '[Distance] channel (GPS_SpeedKmh missing).',
  ),
  'sector_number': _HelpEntry(
    'sector_number()',
    '0-based sector index containing each sample, or NaN outside any '
        'sector. Reads sector gates from the Track on the workspace.',
  ),
  // Variance (ghost-lap comparison)
  'variance_time': _HelpEntry(
    'variance_time(channel)',
    'Per-sample difference between main and overlay laps at the same '
        'projected reference time. NaN where projection fails (heading '
        'mismatch, out of range). Requires main + overlay designations '
        'on the workspace.',
  ),
  'variance_dist': _HelpEntry(
    'variance_dist(channel)',
    'Per-sample difference between main and overlay laps at the same '
        'arc-length distance. NaN where main\'s distance exceeds the '
        'overlay\'s range. Requires main + overlay designations on the '
        'workspace.',
  ),
};
