import 'expression_node.dart';
import 'math_function_catalog.dart';

/// PROTOTYPE unit inference for the chip expression editor.
///
/// Propagates a physical dimension through the expression tree and formats the
/// result as a display unit, so the editor can show the output unit it produces
/// automatically (`integrate([accel])` → `m/s`). This is intentionally a
/// lightweight, mechanical-domain dimensional analysis (length / time / angle);
/// it covers the suspension chain (acceleration ↔ velocity ↔ position, angular
/// rates) precisely and degrades gracefully elsewhere.
///
/// The real propagation engine belongs in Rust `idl-rs` per the thin-Dart rule;
/// this Dart version exists to validate the UX. Calibrated conversions the
/// engine can't know (e.g. wheel pulses → metres) are not inferred — the user
/// overrides the unit in the metadata bar.

/// The inferred output unit plus an optional warning (e.g. a unit mismatch).
class InferredUnit {
  /// Display unit: a unit string, `''` for dimensionless, or null if unknown.
  final String? unit;

  /// Non-null when the expression is dimensionally inconsistent.
  final String? warning;

  /// Creates an [InferredUnit].
  const InferredUnit(this.unit, {this.warning});
}

/// A physical dimension as integer exponents over base symbols.
///
/// Mechanical bases are `m` (length), `s` (time), `rad` (angle). Unrecognised
/// units become a single opaque symbol so they survive unit-preserving
/// operations without claiming a false dimension. `mismatch` latches when an
/// add/subtract sees incompatible operands.
class _Dim {
  final Map<String, int> exp;
  final bool mismatch;

  _Dim(this.exp, {this.mismatch = false});

  static final _Dim dimensionless = _Dim({});
}

/// Infers the output unit of [node], resolving channel units via [channelUnit]
/// (which returns null for unknown channels). Returns an [InferredUnit] whose
/// [InferredUnit.unit] is null when the dimension can't be determined.
InferredUnit inferUnit(ExprNode node, String? Function(String) channelUnit) {
  final d = _dim(node, channelUnit);
  if (d == null) return const InferredUnit(null);
  if (d.mismatch) {
    return const InferredUnit(null, warning: 'operands have different units');
  }
  return InferredUnit(_dimToUnit(d.exp));
}

_Dim? _dim(ExprNode node, String? Function(String) channelUnit) {
  switch (node) {
    case NumberNode():
      return _Dim.dimensionless;
    case StringNode():
      return null;
    case ChannelNode(:final name):
      final u = channelUnit(name);
      if (u == null) return null;
      return _unitToDim(u);
    case UnaryNode(:final op, :final operand):
      if (op == 'not') return _Dim.dimensionless;
      if (operand == null) return null;
      return _dim(operand, channelUnit);
    case BinaryNode(:final op, :final left, :final right):
      if (left == null || right == null) return null;
      final l = _dim(left, channelUnit);
      final r = _dim(right, channelUnit);
      if (l == null || r == null) return null;
      if (l.mismatch || r.mismatch) return _Dim({}, mismatch: true);
      return _combineBinary(op, l, r);
    case FunctionNode(:final name, :final args):
      final spec = kMathFunctionsByName[name];
      if (spec == null) return null;
      return _applyFunction(spec, args, channelUnit);
  }
}

_Dim? _combineBinary(String op, _Dim l, _Dim r) {
  switch (op) {
    case '+':
    case '-':
      // Same dimension required. A dimensionless literal added to a
      // dimensioned channel is treated as compatible (e.g. offsetting).
      if (_mapEquals(l.exp, r.exp)) return _Dim(Map.of(l.exp));
      if (l.exp.isEmpty) return _Dim(Map.of(r.exp));
      if (r.exp.isEmpty) return _Dim(Map.of(l.exp));
      return _Dim({}, mismatch: true);
    case '*':
      return _Dim(_addExp(l.exp, r.exp, 1));
    case '/':
      return _Dim(_addExp(l.exp, r.exp, -1));
    default:
      // Comparisons and logical operators yield a dimensionless 0/1 mask.
      return _Dim.dimensionless;
  }
}

_Dim? _applyFunction(
  MathFunctionSpec spec,
  List<ExprNode?> args,
  String? Function(String) channelUnit,
) {
  _Dim? primary() {
    if (spec.unitArg >= args.length) return null;
    final a = args[spec.unitArg];
    if (a == null) return null;
    return _dim(a, channelUnit);
  }

  switch (spec.unit) {
    case UnitTransform.preserve:
      return primary();
    case UnitTransform.integrate:
      final p = primary();
      return p == null
          ? null
          : _Dim(_shiftTime(p.exp, 1), mismatch: p.mismatch);
    case UnitTransform.differentiate:
      final p = primary();
      return p == null
          ? null
          : _Dim(_shiftTime(p.exp, -1), mismatch: p.mismatch);
    case UnitTransform.unitless:
    case UnitTransform.count:
      return _Dim.dimensionless;
    case UnitTransform.radians:
    case UnitTransform.degToRad:
    case UnitTransform.radToDeg:
      return _Dim({'rad': 1});
    case UnitTransform.seconds:
      return _Dim({'s': 1});
    case UnitTransform.metres:
      return _Dim({'m': 1});
    case UnitTransform.sqrt:
      final p = primary();
      if (p == null) return null;
      final half = <String, int>{};
      for (final e in p.exp.entries) {
        if (e.value % 2 != 0) return null; // not cleanly representable
        if (e.value != 0) half[e.key] = e.value ~/ 2;
      }
      return _Dim(half);
  }
}

Map<String, int> _shiftTime(Map<String, int> d, int delta) =>
    _addExp(d, {'s': delta}, 1);

Map<String, int> _addExp(Map<String, int> a, Map<String, int> b, int sign) {
  final out = Map<String, int>.of(a);
  for (final e in b.entries) {
    final v = (out[e.key] ?? 0) + sign * e.value;
    if (v == 0) {
      out.remove(e.key);
    } else {
      out[e.key] = v;
    }
  }
  return out;
}

bool _mapEquals(Map<String, int> a, Map<String, int> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Unit ↔ dimension tables
// ---------------------------------------------------------------------------

const Set<String> _dimensionless = {'', 'count', 'raw', 'ADC', 'ratio', '%'};

_Dim _unitToDim(String unit) {
  final u = unit.trim();
  if (_dimensionless.contains(u)) return _Dim.dimensionless;
  switch (u) {
    case 'g':
    case 'm/s²':
    case 'm/s^2':
    case 'ft/s²':
      return _Dim({'m': 1, 's': -2});
    case 'm/s':
    case 'km/h':
    case 'mph':
    case 'ft/s':
      return _Dim({'m': 1, 's': -1});
    case 'm':
    case 'km':
    case 'ft':
    case 'mi':
    case 'mm':
    case 'cm':
      return _Dim({'m': 1});
    case 'rad':
    case '°':
    case 'deg':
      return _Dim({'rad': 1});
    case 'rad/s':
    case 'deg/s':
    case 'dps':
    case 'rpm':
      return _Dim({'rad': 1, 's': -1});
    case 'rad/s²':
    case 'deg/s²':
      return _Dim({'rad': 1, 's': -2});
    case 'Hz':
    case 'kHz':
      return _Dim({'s': -1});
    case 's':
    case 'ms':
    case 'μs':
    case 'us':
      return _Dim({'s': 1});
    default:
      // Opaque: preserve through unit-preserving ops without a false claim.
      return _Dim({u: 1});
  }
}

/// Formats a dimension map back to a display unit string (SI-ish base forms:
/// `m/s`, `m`, `m/s²`, `rad/s`, `Hz`).
String _dimToUnit(Map<String, int> dim) {
  final pruned = <String, int>{
    for (final e in dim.entries)
      if (e.value != 0) e.key: e.value,
  };
  if (pruned.isEmpty) return '';
  // Friendly special case: pure inverse-time reads as frequency.
  if (pruned.length == 1 && pruned['s'] == -1) return 'Hz';

  final num = <String>[];
  final den = <String>[];
  final keys = pruned.keys.toList()..sort();
  for (final k in keys) {
    final e = pruned[k]!;
    if (e > 0) {
      num.add(_sym(k, e));
    } else {
      den.add(_sym(k, -e));
    }
  }
  if (den.isEmpty) return num.join('·');
  final numStr = num.isEmpty ? '1' : num.join('·');
  return '$numStr/${den.join('·')}';
}

String _sym(String base, int exp) {
  if (exp == 1) return base;
  if (exp == 2) return '$base²';
  if (exp == 3) return '$base³';
  return '$base^$exp';
}

// ---------------------------------------------------------------------------
// Base-channel unit lookup
// ---------------------------------------------------------------------------

final RegExp _imuAccel = RegExp(r'^IMU\d+_Accel[XYZ]$');
final RegExp _imuGyro = RegExp(r'^IMU\d+_Gyro[XYZ]$');

/// Best-effort unit for a built-in session channel by name, or null if unknown.
///
/// Mirrors the parser's channel registry units (`g`, `dps`, `kmh`, `pulse`)
/// for the common channels so the chip editor can infer output units before
/// the real registry is wired through. IMU accel → `g`, IMU gyro → `deg/s`,
/// `GPS_SpeedKmh` → `km/h`, `Time` → `s`, `Distance` → `m`.
String? baseChannelUnit(String name) {
  if (_imuAccel.hasMatch(name)) return 'g';
  if (_imuGyro.hasMatch(name)) return 'deg/s';
  if (name == 'GPS_SpeedKmh') return 'km/h';
  if (name == 'GPS_Altitude' || name == 'GPS_AltitudeM') return 'm';
  if (name.startsWith('Wheel')) return 'pulse';
  if (name == 'Time') return 's';
  if (name == 'Distance') return 'm';
  if (name == 'LapTime') return 's';
  return null;
}
