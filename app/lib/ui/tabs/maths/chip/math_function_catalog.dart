import 'package:flutter/material.dart';

import '../../../brand/brand.dart';

/// Catalogue of math-channel functions for the chip-driven expression editor.
///
/// PROTOTYPE: this is a single, richer source of truth for the function set —
/// argument slots (with labels + kinds), one-line summary, long-form docs, the
/// colour category, and the output-unit rule. It deliberately overlaps with the
/// three hand-maintained lists in the legacy editor (`knownFunctions` in
/// `math_channel.dart`, `_kFunctions` in `insert_panels.dart`, `_kFunctionHelp`
/// in `function_help_panel.dart`); once the chip editor settles, those should
/// read from here instead of being kept in sync by hand.
///
/// The unit rules ([UnitTransform]) are prototype-grade dimensional analysis
/// evaluated in `unit_inference.dart`. Real dimensional propagation belongs in
/// the Rust `idl-rs` engine per the thin-Dart rule — this proves the UX first.

/// What kind of value an argument slot expects. Drives the slot label colour
/// and the default insert affordance; slots are permissive (accept any node).
enum ArgKind {
  /// A channel or sub-expression (the common case).
  channel,

  /// A numeric scalar — window width, cutoff, exponent.
  number,

  /// A fixed-choice string literal — filter type, FFT window.
  string,
}

/// Colour category for a function chip. Five legible families on the warm
/// near-black canvas, grouped so related operations share a hue.
enum FnCategory {
  /// Filters, reconstruction, frequency, correlation, resampling.
  signal,

  /// Integration, differentiation, rolling statistics.
  timeDomain,

  /// Element-wise math and trig.
  math,

  /// Conditionals, lap-aware, variance.
  logic,
}

/// How a function transforms the physical dimension of its primary input to
/// produce the output unit. Interpreted in `unit_inference.dart`.
enum UnitTransform {
  /// Output unit = the primary channel arg's unit (rms, abs, filters, fft…).
  preserve,

  /// Multiply dimension by time: accel → velocity → position.
  integrate,

  /// Divide dimension by time: position → velocity → accel.
  differentiate,

  /// Output is dimensionless (sin, sign, comparisons).
  unitless,

  /// Output is an angle in radians (asin, atan, atan2).
  radians,

  /// Degrees → radians.
  degToRad,

  /// Radians → degrees.
  radToDeg,

  /// Output is seconds (lap_start_time).
  seconds,

  /// Output is metres (lap_start_distance).
  metres,

  /// Output is a dimensionless count (current_lap, sector_number).
  count,

  /// Output is the square root of the input dimension.
  sqrt,
}

/// One argument slot of a function.
class ArgSpec {
  /// Short slot label shown in the empty drop target, e.g. `"ch"`, `"cutoff"`.
  final String label;

  /// What the slot expects.
  final ArgKind kind;

  /// Fixed string choices for [ArgKind.string] slots (e.g. `["low","high"]`).
  final List<String>? choices;

  /// Creates an [ArgSpec].
  const ArgSpec(this.label, this.kind, {this.choices});
}

/// A function the chip editor can place: its slots, docs, colour, and unit rule.
class MathFunctionSpec {
  /// Function name as written in the expression, e.g. `"integrate"`.
  final String name;

  /// Ordered argument slots. Empty for nullary functions (`current_lap()`).
  final List<ArgSpec> args;

  /// Colour category.
  final FnCategory category;

  /// One-line description shown on the chip's definition card.
  final String summary;

  /// Optional long-form documentation revealed by "More" on the card.
  final String? docs;

  /// Output-unit rule.
  final UnitTransform unit;

  /// Index of the argument that carries the primary unit for [UnitTransform]s
  /// that reference an input dimension (preserve / integrate / differentiate /
  /// sqrt). Defaults to 0.
  final int unitArg;

  /// Creates a [MathFunctionSpec].
  const MathFunctionSpec({
    required this.name,
    required this.args,
    required this.category,
    required this.summary,
    required this.unit,
    this.docs,
    this.unitArg = 0,
  });

  /// The display signature, e.g. `integrate(ch)`.
  String get signature => '$name(${args.map((a) => a.label).join(', ')})';
}

/// Resolved fill colour for a function category.
Color colorForCategory(FnCategory c) {
  switch (c) {
    case FnCategory.signal:
      return const Color(0xFFB98AE6); // violet
    case FnCategory.timeDomain:
      return const Color(0xFF5BA6F0); // azure
    case FnCategory.math:
      return const Color(0xFF3FC9C0); // teal
    case FnCategory.logic:
      return const Color(0xFFE8964B); // orange
  }
}

/// Leaf-chip colour: a channel reference. Green = data.
const Color chipChannelColor = brandGood;

/// Leaf-chip colour: a numeric literal. Amber.
const Color chipNumberColor = brandHivis;

/// Leaf-chip colour: a string literal. Rose.
const Color chipStringColor = Color(0xFFE86FA6);

/// Leaf-chip colour: an operator. Neutral.
const Color chipOperatorColor = brandFgDim;

// ---------------------------------------------------------------------------
// The catalogue
// ---------------------------------------------------------------------------

/// Common channel arg.
const _ch = ArgSpec('ch', ArgKind.channel);

/// All functions, keyed by name. Order within is preserved for the palette.
const List<MathFunctionSpec> kMathFunctions = [
  // --- Signal -------------------------------------------------------------
  MathFunctionSpec(
    name: 'butter',
    args: [
      ArgSpec('order', ArgKind.number),
      ArgSpec('cutoff', ArgKind.number),
      ArgSpec('type', ArgKind.string, choices: ['low', 'high', 'band']),
      ArgSpec('ch', ArgKind.channel),
    ],
    category: FnCategory.signal,
    summary: 'Butterworth filter. type: low | high | band.',
    docs: 'Zero-phase Butterworth filter (forward-backward, no phase '
        'distortion). order sets steepness; cutoff is in Hz. '
        'Equivalent to scipy.signal.butter + sosfiltfilt.',
    unit: UnitTransform.preserve,
    unitArg: 3,
  ),
  MathFunctionSpec(
    name: 'sosfilt',
    args: [ArgSpec('sos', ArgKind.channel), _ch],
    category: FnCategory.signal,
    summary: 'Apply a second-order-sections filter to ch.',
    unit: UnitTransform.preserve,
    unitArg: 1,
  ),
  MathFunctionSpec(
    name: 'declip',
    args: [_ch],
    category: FnCategory.signal,
    summary: 'Reconstruct IMU peaks clipped at the ±32 g rail.',
    docs: 'Fits a smooth asymmetric pulse to each clipped peak to recover '
        'the true acceleration. Returns ch unchanged where nothing is '
        'clipped. Run before integrate() so velocity is not under-counted.',
    unit: UnitTransform.preserve,
  ),
  MathFunctionSpec(
    name: 'fft',
    args: [
      _ch,
      ArgSpec('window', ArgKind.string, choices: ['hann', 'hamming', 'rect']),
    ],
    category: FnCategory.signal,
    summary: 'One-sided magnitude spectrum. window: hann | hamming | rect.',
    unit: UnitTransform.preserve,
  ),
  MathFunctionSpec(
    name: 'spectrogram',
    args: [_ch],
    category: FnCategory.signal,
    summary: 'Short-time Fourier transform spectrogram. (Not yet implemented.)',
    unit: UnitTransform.preserve,
  ),
  MathFunctionSpec(
    name: 'hilbert',
    args: [_ch],
    category: FnCategory.signal,
    summary: 'Analytic signal via Hilbert transform → instantaneous amplitude.',
    unit: UnitTransform.preserve,
  ),
  MathFunctionSpec(
    name: 'correlate',
    args: [ArgSpec('a', ArgKind.channel), ArgSpec('b', ArgKind.channel)],
    category: FnCategory.signal,
    summary: 'Cross-correlation of channels a and b.',
    unit: UnitTransform.preserve,
  ),
  MathFunctionSpec(
    name: 'convolve',
    args: [_ch, ArgSpec('kernel', ArgKind.channel)],
    category: FnCategory.signal,
    summary: 'Convolution of ch with a kernel channel.',
    unit: UnitTransform.preserve,
  ),
  MathFunctionSpec(
    name: 'resample',
    args: [_ch, ArgSpec('hz', ArgKind.number)],
    category: FnCategory.signal,
    summary: 'Resample ch to hz Hz (polyphase).',
    unit: UnitTransform.preserve,
  ),
  // --- Time-domain --------------------------------------------------------
  MathFunctionSpec(
    name: 'integrate',
    args: [_ch],
    category: FnCategory.timeDomain,
    summary: 'Cumulative trapezoidal integration.',
    docs: 'Integrates over time (cumtrapz). Raises the dimension by one '
        'power of time: acceleration → velocity, velocity → position. '
        'Drift accumulates — high-pass the input or the result.',
    unit: UnitTransform.integrate,
  ),
  MathFunctionSpec(
    name: 'differentiate',
    args: [_ch],
    category: FnCategory.timeDomain,
    summary: 'Numerical differentiation (central differences).',
    docs: 'Lowers the dimension by one power of time: position → velocity, '
        'velocity → acceleration. Amplifies high-frequency noise — filter '
        'first if the signal is noisy.',
    unit: UnitTransform.differentiate,
  ),
  MathFunctionSpec(
    name: 'rms',
    args: [_ch, ArgSpec('w', ArgKind.number)],
    category: FnCategory.timeDomain,
    summary: 'Rolling root-mean-square over w samples.',
    unit: UnitTransform.preserve,
  ),
  MathFunctionSpec(
    name: 'mean',
    args: [_ch, ArgSpec('w', ArgKind.number)],
    category: FnCategory.timeDomain,
    summary: 'Rolling mean over w samples.',
    unit: UnitTransform.preserve,
  ),
  MathFunctionSpec(
    name: 'std',
    args: [_ch, ArgSpec('w', ArgKind.number)],
    category: FnCategory.timeDomain,
    summary: 'Rolling standard deviation over w samples.',
    unit: UnitTransform.preserve,
  ),
  MathFunctionSpec(
    name: 'median',
    args: [_ch, ArgSpec('w', ArgKind.number)],
    category: FnCategory.timeDomain,
    summary: 'Rolling median over w samples.',
    unit: UnitTransform.preserve,
  ),
  // --- Math & trig --------------------------------------------------------
  MathFunctionSpec(
    name: 'abs',
    args: [_ch],
    category: FnCategory.math,
    summary: 'Element-wise absolute value.',
    unit: UnitTransform.preserve,
  ),
  MathFunctionSpec(
    name: 'sqrt',
    args: [_ch],
    category: FnCategory.math,
    summary: 'Element-wise square root.',
    unit: UnitTransform.sqrt,
  ),
  MathFunctionSpec(
    name: 'pow',
    args: [_ch, ArgSpec('n', ArgKind.number)],
    category: FnCategory.math,
    summary: 'Element-wise exponentiation: ch^n.',
    unit: UnitTransform.preserve,
  ),
  MathFunctionSpec(
    name: 'sign',
    args: [_ch],
    category: FnCategory.math,
    summary: 'Element-wise sign: -1, 0, or 1.',
    unit: UnitTransform.unitless,
  ),
  MathFunctionSpec(
    name: 'min',
    args: [ArgSpec('a', ArgKind.channel), ArgSpec('b', ArgKind.channel)],
    category: FnCategory.math,
    summary: 'Element-wise minimum of a and b.',
    unit: UnitTransform.preserve,
  ),
  MathFunctionSpec(
    name: 'max',
    args: [ArgSpec('a', ArgKind.channel), ArgSpec('b', ArgKind.channel)],
    category: FnCategory.math,
    summary: 'Element-wise maximum of a and b.',
    unit: UnitTransform.preserve,
  ),
  MathFunctionSpec(
    name: 'clamp',
    args: [
      _ch,
      ArgSpec('low', ArgKind.number),
      ArgSpec('high', ArgKind.number),
    ],
    category: FnCategory.math,
    summary: 'Clamp values to [low, high].',
    unit: UnitTransform.preserve,
  ),
  MathFunctionSpec(
    name: 'floor',
    args: [_ch],
    category: FnCategory.math,
    summary: 'Element-wise floor.',
    unit: UnitTransform.preserve,
  ),
  MathFunctionSpec(
    name: 'ceil',
    args: [_ch],
    category: FnCategory.math,
    summary: 'Element-wise ceiling.',
    unit: UnitTransform.preserve,
  ),
  MathFunctionSpec(
    name: 'round',
    args: [_ch],
    category: FnCategory.math,
    summary: 'Element-wise round to nearest integer.',
    unit: UnitTransform.preserve,
  ),
  MathFunctionSpec(
    name: 'sin',
    args: [_ch],
    category: FnCategory.math,
    summary: 'Element-wise sine (radians in).',
    unit: UnitTransform.unitless,
  ),
  MathFunctionSpec(
    name: 'cos',
    args: [_ch],
    category: FnCategory.math,
    summary: 'Element-wise cosine (radians in).',
    unit: UnitTransform.unitless,
  ),
  MathFunctionSpec(
    name: 'tan',
    args: [_ch],
    category: FnCategory.math,
    summary: 'Element-wise tangent (radians in).',
    unit: UnitTransform.unitless,
  ),
  MathFunctionSpec(
    name: 'asin',
    args: [_ch],
    category: FnCategory.math,
    summary: 'Element-wise arcsine → radians.',
    unit: UnitTransform.radians,
  ),
  MathFunctionSpec(
    name: 'acos',
    args: [_ch],
    category: FnCategory.math,
    summary: 'Element-wise arccosine → radians.',
    unit: UnitTransform.radians,
  ),
  MathFunctionSpec(
    name: 'atan',
    args: [_ch],
    category: FnCategory.math,
    summary: 'Element-wise arctangent → radians.',
    unit: UnitTransform.radians,
  ),
  MathFunctionSpec(
    name: 'atan2',
    args: [ArgSpec('y', ArgKind.channel), ArgSpec('x', ArgKind.channel)],
    category: FnCategory.math,
    summary: 'Four-quadrant arctangent → radians.',
    unit: UnitTransform.radians,
  ),
  MathFunctionSpec(
    name: 'sinh',
    args: [_ch],
    category: FnCategory.math,
    summary: 'Element-wise hyperbolic sine.',
    unit: UnitTransform.unitless,
  ),
  MathFunctionSpec(
    name: 'cosh',
    args: [_ch],
    category: FnCategory.math,
    summary: 'Element-wise hyperbolic cosine.',
    unit: UnitTransform.unitless,
  ),
  MathFunctionSpec(
    name: 'tanh',
    args: [_ch],
    category: FnCategory.math,
    summary: 'Element-wise hyperbolic tangent.',
    unit: UnitTransform.unitless,
  ),
  MathFunctionSpec(
    name: 'deg2rad',
    args: [_ch],
    category: FnCategory.math,
    summary: 'Degrees to radians: ch × π/180.',
    unit: UnitTransform.degToRad,
  ),
  MathFunctionSpec(
    name: 'rad2deg',
    args: [_ch],
    category: FnCategory.math,
    summary: 'Radians to degrees: ch × 180/π.',
    unit: UnitTransform.radToDeg,
  ),
  // --- Logic / lap / variance --------------------------------------------
  MathFunctionSpec(
    name: 'if',
    args: [
      ArgSpec('cond', ArgKind.channel),
      ArgSpec('t', ArgKind.channel),
      ArgSpec('f', ArgKind.channel),
    ],
    category: FnCategory.logic,
    summary: 'Element-wise conditional: t where cond is true, f elsewhere.',
    unit: UnitTransform.preserve,
    unitArg: 1,
  ),
  MathFunctionSpec(
    name: 'current_lap',
    args: [],
    category: FnCategory.logic,
    summary: '1-based lap number of each sample, or 0 outside any lap.',
    unit: UnitTransform.count,
  ),
  MathFunctionSpec(
    name: 'lap_start_time',
    args: [ArgSpec('n', ArgKind.number)],
    category: FnCategory.logic,
    summary: "Session-relative time of lap n's start, in seconds.",
    unit: UnitTransform.seconds,
  ),
  MathFunctionSpec(
    name: 'lap_start_distance',
    args: [ArgSpec('n', ArgKind.number)],
    category: FnCategory.logic,
    summary: "Cumulative distance at lap n's start, in metres.",
    unit: UnitTransform.metres,
  ),
  MathFunctionSpec(
    name: 'sector_number',
    args: [],
    category: FnCategory.logic,
    summary: '0-based sector index of each sample, or NaN outside a sector.',
    unit: UnitTransform.count,
  ),
  MathFunctionSpec(
    name: 'variance_time',
    args: [_ch],
    category: FnCategory.logic,
    summary: 'Main−overlay delta at the same projected reference time.',
    unit: UnitTransform.preserve,
  ),
  MathFunctionSpec(
    name: 'variance_dist',
    args: [_ch],
    category: FnCategory.logic,
    summary: 'Main−overlay delta at the same arc-length distance.',
    unit: UnitTransform.preserve,
  ),
];

/// Functions indexed by name for O(1) lookup.
final Map<String, MathFunctionSpec> kMathFunctionsByName = {
  for (final f in kMathFunctions) f.name: f,
};

/// Binary/infix operators offered in the palette, with a one-line meaning.
class OperatorSpec {
  /// The glyph as written, e.g. `"+"`.
  final String op;

  /// One-line description for the definition card.
  final String summary;

  /// Creates an [OperatorSpec].
  const OperatorSpec(this.op, this.summary);
}

/// Arithmetic, comparison, and logical operators for the Operators palette.
const List<OperatorSpec> kMathOperators = [
  OperatorSpec('+', 'Add. Operands must share a unit.'),
  OperatorSpec('-', 'Subtract. Operands must share a unit.'),
  OperatorSpec('*', 'Multiply. Units multiply.'),
  OperatorSpec('/', 'Divide. Units divide.'),
  OperatorSpec('<', 'Less than → 1.0 / 0.0.'),
  OperatorSpec('>', 'Greater than → 1.0 / 0.0.'),
  OperatorSpec('<=', 'Less than or equal → 1.0 / 0.0.'),
  OperatorSpec('>=', 'Greater than or equal → 1.0 / 0.0.'),
  OperatorSpec('==', 'Equal → 1.0 / 0.0.'),
  OperatorSpec('!=', 'Not equal → 1.0 / 0.0.'),
  OperatorSpec('and', 'Logical AND of truthy channels.'),
  OperatorSpec('or', 'Logical OR of truthy channels.'),
];
