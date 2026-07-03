import 'app_settings.dart';

/// Returns the preferred unit string for [q] under [system].
///
/// For quantities with unit-system–specific conventions (Speed, Distance,
/// Pressure, Temperature, Force, Torque, Power, Spring Constant, Mass),
/// returns the conventional unit for that system. Falls back to the
/// quantity's primary unit (index 0) for all others.
///
/// Used by [ChannelMetadataBar] when the user picks a Quantity to set the
/// default unit according to the user's unit preference.
String defaultUnit(MathQuantity q, UnitSystem system) {
  if (system == UnitSystem.metric) return q.units.first;
  // Imperial overrides — each override must exist in q.units.
  switch (q.name) {
    case 'Speed':
      return 'mph';
    case 'Length & Distance':
      return 'ft';
    case 'Pressure & Stress':
      return 'psi';
    case 'Pressure Delta':
      return 'psi';
    case 'Temperature':
      return '°F';
    case 'Temperature Delta':
      return '°F';
    case 'Force':
      return 'lbf';
    case 'Torque':
      return 'ft·lbf';
    case 'Spring Constant':
      return 'lb/in';
    case 'Mass':
      return 'lb';
    case 'Power':
      return 'hp';
    default:
      return q.units.first;
  }
}

/// A predefined physical quantity with a fixed set of standard units.
///
/// Drives the Quantity / Units dropdowns in [ChannelMetadataBar].
/// [units] is ordered primary-first: the first entry is applied automatically
/// when the user picks a quantity. See §15.4.
class MathQuantity {
  /// Display name shown in the Quantity dropdown, e.g. `"Acceleration"`.
  final String name;

  /// Available units, primary unit first.
  ///
  /// The primary unit (index 0) is applied automatically when this quantity is
  /// selected. All entries are valid [MathChannel.units] values.
  final List<String> units;

  /// Creates a [MathQuantity].
  const MathQuantity({required this.name, required this.units});

  /// Returns the [MathQuantity] whose [name] matches [name] from
  /// [kMathQuantities], or null if [name] is empty or unrecognised.
  static MathQuantity? byName(String name) {
    if (name.isEmpty) return null;
    for (final q in kMathQuantities) {
      if (q.name == name) return q;
    }
    return null;
  }
}

/// All 25 predefined physical quantities available in the Maths tab.
///
/// Ordered by domain relevance — dynamics first, electrical last.
/// Primary unit is always at index 0.
const List<MathQuantity> kMathQuantities = [
  MathQuantity(name: 'Acceleration', units: ['g', 'm/s²', 'ft/s²']),
  MathQuantity(name: 'Speed', units: ['km/h', 'm/s', 'mph', 'ft/s']),
  MathQuantity(name: 'Length & Distance', units: ['m', 'km', 'ft', 'mi']),
  MathQuantity(name: 'Angle', units: ['°', 'rad']),
  MathQuantity(name: 'Angular Speed', units: ['deg/s', 'rad/s', 'rpm']),
  MathQuantity(name: 'Angular Acceleration', units: ['deg/s²', 'rad/s²']),
  MathQuantity(name: 'Frequency', units: ['Hz', 'kHz']),
  MathQuantity(name: 'Time', units: ['s', 'ms', 'μs']),
  MathQuantity(name: 'Pressure & Stress', units: ['kPa', 'psi', 'bar', 'MPa']),
  MathQuantity(name: 'Pressure Delta', units: ['kPa', 'psi', 'bar']),
  MathQuantity(name: 'Temperature', units: ['°C', '°F', 'K']),
  MathQuantity(name: 'Temperature Delta', units: ['°C', '°F', 'K']),
  MathQuantity(name: 'Force', units: ['N', 'kN', 'lbf']),
  MathQuantity(name: 'Force Rate', units: ['N/s', 'kN/s']),
  MathQuantity(name: 'Torque', units: ['N·m', 'ft·lbf']),
  MathQuantity(name: 'Power', units: ['W', 'kW', 'hp']),
  MathQuantity(name: 'Energy & Work', units: ['J', 'kJ', 'Wh', 'kWh']),
  MathQuantity(name: 'Spring Constant', units: ['N/mm', 'lb/in', 'N/m']),
  MathQuantity(name: 'Mass', units: ['kg', 'lb', 'g']),
  MathQuantity(name: 'Current', units: ['A', 'mA']),
  MathQuantity(name: 'Electric Charge', units: ['mAh', 'Ah', 'C']),
  MathQuantity(name: 'Voltage', units: ['V', 'mV']),
  MathQuantity(name: 'Curvature', units: ['1/m']),
  MathQuantity(name: 'Ratio', units: ['']),
  MathQuantity(name: 'Unitless', units: ['count', 'raw', 'ADC']),
];
