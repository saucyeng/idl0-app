/// A user-defined derived channel computed from a math expression. See §10, §15.
///
/// Expressions are evaluated lazily on demand — never pre-computed. Store the
/// expression string; evaluate via the Rust processing layer.
///
/// Math channels live on the owning [Workbook] (they travel with the portable
/// `.idl0wb`); there is no separate global store.
class MathChannel {
  /// Stable identifier, preserved across renames. App-created channels use a
  /// UUID; a hand-authored `.idl0wb` that omits `id` defaults it to [name] (see
  /// [MathChannel.fromJson]).
  ///
  /// Charts reference math channels by [id] (`ChartSlot.mathChannelIds`), so a
  /// rename does not break chart membership. Expressions reference by [name].
  final String id;

  /// Registry name shown in the channel list and chart legend, and referenced
  /// from other expressions as `[Name]`.
  final String name;

  /// Physical quantity, e.g. `"Velocity"` or `"Position"`. Used for axis
  /// grouping in the Maths/Analyze tabs.
  final String quantity;

  /// Engineering units, e.g. `"m/s"` or `"m"`.
  final String units;

  /// Output sample rate in Hz. `0.0` = inherit from the expression's primary
  /// source channel.
  final double sampleRateHz;

  /// Number of decimal places shown in UI and exported values.
  final int decimalPlaces;

  /// Channel colour as a hex string, e.g. `"#FF2196F3"` (`#AARRGGBB`, or
  /// `#RRGGBB` with assumed opaque alpha). The portable, human-editable form
  /// the `.idl0wb` uses. UI converts via [colorValue].
  final String color;

  /// Expression string. Evaluated lazily on demand — never pre-computed.
  ///
  /// Reference session channels and other math channels with `[ChannelName]`
  /// syntax. Validate with [MathChannelValidator.validate] before evaluation.
  /// See §10 for the full function table.
  final String expression;

  /// Creates a [MathChannel].
  const MathChannel({
    required this.id,
    required this.name,
    required this.quantity,
    required this.units,
    required this.sampleRateHz,
    required this.decimalPlaces,
    required this.color,
    required this.expression,
  });

  /// The channel colour as a Flutter-compatible ARGB integer (`Color.value`).
  ///
  /// Parses [color] (`#AARRGGBB` or `#RRGGBB`); falls back to a default blue
  /// when [color] is malformed so the UI never throws on a bad hex string.
  int get colorValue => _hexToArgb(color);

  /// Returns a copy with the given fields replaced.
  MathChannel copyWith({
    String? id,
    String? name,
    String? quantity,
    String? units,
    double? sampleRateHz,
    int? decimalPlaces,
    String? color,
    String? expression,
  }) =>
      MathChannel(
        id: id ?? this.id,
        name: name ?? this.name,
        quantity: quantity ?? this.quantity,
        units: units ?? this.units,
        sampleRateHz: sampleRateHz ?? this.sampleRateHz,
        decimalPlaces: decimalPlaces ?? this.decimalPlaces,
        color: color ?? this.color,
        expression: expression ?? this.expression,
      );

  /// Serializes to a JSON map for the `.idl0wb` payload.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'expression': expression,
        'quantity': quantity,
        'units': units,
        'sample_rate_hz': sampleRateHz,
        'decimal_places': decimalPlaces,
        'color': color,
      };

  /// Deserializes from a `.idl0wb` math-channel map.
  ///
  /// Tolerant of hand-authored files: `id` defaults to `name`, `quantity` /
  /// `units` to empty, `sample_rate_hz` to `0`, `decimal_places` to `2`, and
  /// `color` to opaque white.
  factory MathChannel.fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String;
    return MathChannel(
      id: (json['id'] as String?) ?? name,
      name: name,
      expression: json['expression'] as String,
      quantity: json['quantity'] as String? ?? '',
      units: json['units'] as String? ?? '',
      sampleRateHz: (json['sample_rate_hz'] as num? ?? 0).toDouble(),
      decimalPlaces: json['decimal_places'] as int? ?? 2,
      color: json['color'] as String? ?? '#FFFFFFFF',
    );
  }

  /// Returns the `#AARRGGBB` hex string for an ARGB integer (UI → model).
  static String hexFromArgb(int argb) =>
      '#${(argb & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase()}';
}

/// Parses a `#AARRGGBB` or `#RRGGBB` hex colour to an ARGB integer. Returns a
/// default blue (`0xFF2196F3`) when [hex] is malformed.
int _hexToArgb(String hex) {
  var h = hex.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length == 6) h = 'FF$h';
  if (h.length != 8) return 0xFF2196F3;
  return int.tryParse(h, radix: 16) ?? 0xFF2196F3;
}

/// Tutorial math channels seeded into a fresh default workbook
/// ([Workbook.createDefault]). After seeding they are ordinary workbook
/// channels — editable, renamable, deletable. See §25.
///
/// IDs are namespaced with `builtin:` so they stay stable across a rename; the
/// names are what expressions and the lap-delta charts reference.
const List<MathChannel> kBuiltinMathChannels = [
  MathChannel(
    id: 'builtin:LapNumber',
    name: 'LapNumber',
    quantity: 'count',
    units: '',
    sampleRateHz: 0.0,
    decimalPlaces: 0,
    color: '#FF9E9E9E',
    expression: 'current_lap()',
  ),
  MathChannel(
    id: 'builtin:LapTime',
    name: 'LapTime',
    quantity: 'time',
    units: 's',
    sampleRateHz: 0.0,
    decimalPlaces: 3,
    color: '#FF00BCD4',
    expression: '[Time] - lap_start_time(current_lap())',
  ),
  MathChannel(
    id: 'builtin:LapDistance',
    name: 'LapDistance',
    quantity: 'distance',
    units: 'm',
    sampleRateHz: 0.0,
    decimalPlaces: 1,
    color: '#FF4CAF50',
    expression: '[Distance] - lap_start_distance(current_lap())',
  ),
  MathChannel(
    id: 'builtin:LapDeltaT',
    name: 'Lap Delta T',
    quantity: 'time',
    units: 's',
    sampleRateHz: 0.0,
    decimalPlaces: 3,
    color: '#FFFF9800',
    expression: 'variance_time([LapTime])',
  ),
  MathChannel(
    id: 'builtin:LapDeltaD',
    name: 'Lap Delta D',
    quantity: 'time',
    units: 's',
    sampleRateHz: 0.0,
    decimalPlaces: 3,
    color: '#FFFF5722',
    expression: 'variance_dist([LapTime])',
  ),
  // Suspension virtual sensors — outputs of the offline geometry-constrained
  // estimator (idl-rs `estimate`), surfaced as auto-evaluating math channels.
  // mathChannelEvalProvider recognises these by name and routes them to
  // suspensionEstimatorProvider (one ~9 s run per session, off the UI isolate)
  // instead of evaluating the expression — so they load lazily with the normal
  // math-channel spinner. The names must match the Rust bridge's stored ids; the
  // expressions are the spec's `wheel_*()` forms (descriptive, not yet a Rust fn).
  MathChannel(
    id: 'builtin:EstFrontTravel',
    name: 'Front travel (mm)',
    quantity: 'suspension',
    units: 'mm',
    sampleRateHz: 0.0,
    decimalPlaces: 1,
    color: '#FF4FC3F7',
    expression: 'wheel_travel("front")',
  ),
  MathChannel(
    id: 'builtin:EstFrontVelocity',
    name: 'Front velocity (mm/s)',
    quantity: 'suspension',
    units: 'mm/s',
    sampleRateHz: 0.0,
    decimalPlaces: 0,
    color: '#FF29B6F6',
    expression: 'wheel_velocity("front")',
  ),
  MathChannel(
    id: 'builtin:EstRearTravel',
    name: 'Rear travel (mm)',
    quantity: 'suspension',
    units: 'mm',
    sampleRateHz: 0.0,
    decimalPlaces: 1,
    color: '#FFFFB74D',
    expression: 'wheel_travel("rear")',
  ),
  MathChannel(
    id: 'builtin:EstRearVelocity',
    name: 'Rear velocity (mm/s)',
    quantity: 'suspension',
    units: 'mm/s',
    sampleRateHz: 0.0,
    decimalPlaces: 0,
    color: '#FFFF9800',
    expression: 'wheel_velocity("rear")',
  ),
];

/// A named numeric constant for use in math channel expressions. Lives on the
/// owning [Workbook]; travels with the `.idl0wb`.
class MathConstant {
  /// Stable identifier; defaults to [name] for hand-authored files.
  final String id;

  /// Display name, e.g. `"g"` or `"pi"`.
  final String name;

  /// Unitless scalar value.
  final double value;

  /// Creates a [MathConstant].
  const MathConstant({
    required this.id,
    required this.name,
    required this.value,
  });

  /// Returns a copy with the given fields replaced.
  MathConstant copyWith({String? id, String? name, double? value}) =>
      MathConstant(
        id: id ?? this.id,
        name: name ?? this.name,
        value: value ?? this.value,
      );

  /// Serializes to a JSON map for the `.idl0wb` payload.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'value': value,
      };

  /// Deserializes from a `.idl0wb` constant map. `id` defaults to `name`.
  factory MathConstant.fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String;
    return MathConstant(
      id: (json['id'] as String?) ?? name,
      name: name,
      value: (json['value'] as num).toDouble(),
    );
  }
}

/// A named collection of [MathChannel] templates the Maths tab can copy into
/// the active workbook.
class MathChannelLibrary {
  /// Ordered list of template channels.
  final List<MathChannel> templates;

  /// Creates a [MathChannelLibrary].
  const MathChannelLibrary({required this.templates});

  /// Shipped templates. Selecting one copies it into the active workbook; the
  /// user then adjusts. Templates reference channels (`[IMU1_AccelZ]`) that may
  /// be absent from the current session — that is expected and surfaces as a
  /// channel-reference validation note until a matching session is loaded.
  static MathChannelLibrary get shipped => const MathChannelLibrary(
        templates: [
          MathChannel(
            id: 'tpl_fork_velocity',
            name: 'Fork velocity',
            quantity: 'Velocity',
            units: 'm/s',
            sampleRateHz: 0.0,
            decimalPlaces: 3,
            color: '#FF2196F3',
            expression: 'integrate([IMU1_AccelZ])',
          ),
          MathChannel(
            id: 'tpl_shock_velocity',
            name: 'Shock velocity',
            quantity: 'Velocity',
            units: 'm/s',
            sampleRateHz: 0.0,
            decimalPlaces: 3,
            color: '#FF4CAF50',
            expression: 'integrate([IMU2_AccelZ])',
          ),
          MathChannel(
            id: 'tpl_suspension_travel',
            name: 'Suspension travel',
            quantity: 'Position',
            units: 'm',
            sampleRateHz: 0.0,
            decimalPlaces: 3,
            color: '#FFFF9800',
            // Double integration: velocity = ∫accel dt, travel = ∫velocity dt.
            // Each stage needs a high-pass filter pass to control drift.
            // See design_rationale.md — Suspension travel double integration.
            expression: 'integrate(integrate([IMU1_AccelZ]))',
          ),
          MathChannel(
            id: 'tpl_wheel_distance',
            name: 'Wheel distance',
            quantity: 'Distance',
            units: 'm',
            sampleRateHz: 0.0,
            decimalPlaces: 2,
            color: '#FF9C27B0',
            expression: 'integrate([WheelFront])',
          ),
          MathChannel(
            id: 'tpl_gps_distance',
            name: 'GPS distance',
            quantity: 'Distance',
            units: 'm',
            sampleRateHz: 0.0,
            decimalPlaces: 2,
            color: '#FFE91E63',
            // GPS_SpeedKmh is in km/h; divide by 3.6 to get m/s before
            // integrating so the result is in metres.
            expression: 'integrate([GPS_SpeedKmh] / 3.6)',
          ),
          MathChannel(
            id: 'tpl_lap_time_delta',
            name: 'Lap time delta',
            quantity: 'Time',
            units: 's',
            sampleRateHz: 0.0,
            decimalPlaces: 3,
            color: '#FFF44336',
            expression: '[LapTime_A] - [LapTime_B]',
          ),
        ],
      );
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/// Validates math channel expressions against the §10 function table.
///
/// Two validation levels applied in order:
/// 1. **Syntax** — unbalanced brackets/parens, unknown function names.
/// 2. **Channel references** — all `[ChannelName]` tokens present in
///    [availableChannels] (skipped when [availableChannels] is empty).
///
/// Semantic correctness (wrong argument types, count mismatches) is deferred
/// to Rust evaluation time. See §16.2 for user-facing error messages.
class MathChannelValidator {
  /// All function names defined in the §10 math channel function table.
  ///
  /// Identifiers followed by `(` that are not in this set are reported as
  /// syntax errors. `and`, `or`, `not` are infix/prefix keywords, not
  /// call-style functions, so they are excluded from the call-site check.
  static const Set<String> knownFunctions = {
    // Filters
    'butter', 'sosfilt',
    // Reconstruction
    'declip',
    // Time-domain
    'integrate', 'differentiate', 'rms', 'mean', 'std', 'median',
    // Frequency
    'fft', 'spectrogram', 'hilbert',
    // Correlation
    'correlate', 'convolve',
    // Resampling
    'resample',
    // Math
    'abs', 'sqrt', 'pow', 'sign', 'min', 'max', 'clamp',
    'floor', 'ceil', 'round',
    // Trig
    'sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'atan2',
    'sinh', 'cosh', 'tanh', 'deg2rad', 'rad2deg',
    // Logic — `if` uses call syntax; `and`/`or`/`not` are keywords
    'if',
    // Lap-aware (read lap/sector gates from workspace)
    'current_lap', 'lap_start_time', 'lap_start_distance', 'sector_number',
    // Variance (ghost-lap comparison; evaluate against main/overlay laps)
    'variance_time', 'variance_dist',
    // Suspension virtual sensors (offline geometry-constrained estimator). These
    // do not evaluate as expressions — mathChannelEvalProvider routes them to the
    // estimator — but they are listed here so the builtin channels' descriptive
    // `wheel_travel("front")` / `wheel_velocity("rear")` forms validate cleanly.
    'wheel_travel', 'wheel_velocity',
  };

  /// Returns null if [expression] is valid, or a human-readable error string
  /// describing the first detected problem.
  ///
  /// [availableChannels] is the list of channel names in the current session
  /// (and any other math channel names). Pass an empty list to skip channel
  /// reference validation (e.g. when editing templates before a session loads).
  static String? validate(String expression, List<String> availableChannels) {
    if (expression.trim().isEmpty) {
      return 'Expression cannot be empty';
    }

    // Check square bracket balance — used for channel refs and range indexing.
    var depth = 0;
    for (var i = 0; i < expression.length; i++) {
      if (expression[i] == '[') {
        depth++;
      } else if (expression[i] == ']') {
        depth--;
        if (depth < 0) {
          return 'Syntax error at position $i: unexpected ]';
        }
      }
    }
    if (depth != 0) {
      return 'Syntax error at position ${expression.length}: unclosed [';
    }

    // Check parenthesis balance.
    var parenDepth = 0;
    for (var i = 0; i < expression.length; i++) {
      if (expression[i] == '(') {
        parenDepth++;
      } else if (expression[i] == ')') {
        parenDepth--;
        if (parenDepth < 0) {
          return 'Syntax error at position $i: unexpected )';
        }
      }
    }
    if (parenDepth != 0) {
      return 'Syntax error at position ${expression.length}: unclosed (';
    }

    // Any identifier immediately followed by `(` must be a known function.
    final funcCallPattern = RegExp(r'\b([a-zA-Z_][a-zA-Z0-9_]*)\s*\(');
    for (final match in funcCallPattern.allMatches(expression)) {
      final name = match.group(1)!;
      if (!knownFunctions.contains(name)) {
        return 'Syntax error at position ${match.start}: unknown function "$name"';
      }
    }

    // Validate all `[ChannelName]` references against the available list.
    if (availableChannels.isNotEmpty) {
      final channelRefPattern = RegExp(r'\[([^\[\]]+)\]');
      for (final match in channelRefPattern.allMatches(expression)) {
        final name = match.group(1)!;
        if (!availableChannels.contains(name)) {
          return "Channel '[$name]' not in this session";
        }
      }
    }

    return null;
  }

  /// Returns the name of the §10 function whose call site contains
  /// [cursorOffset] in [text], or null if the cursor is not inside a call.
  ///
  /// Example: `rms(|` (| = cursor at offset 4) → `"rms"`.
  /// Used to drive [FunctionHelpPanel] context-sensitive help.
  static String? functionAtCursor(String text, int cursorOffset) {
    if (cursorOffset <= 0) return null;
    final sub = text.substring(0, cursorOffset);
    final parenIdx = sub.lastIndexOf('(');
    if (parenIdx < 0) return null;
    final before = sub.substring(0, parenIdx).trimRight();
    final identPattern = RegExp(r'([a-zA-Z_][a-zA-Z0-9_]*)$');
    final match = identPattern.firstMatch(before);
    final name = match?.group(1);
    if (name == null || !knownFunctions.contains(name)) return null;
    return name;
  }

  /// Returns [text] with [insertion] spliced in at [cursorOffset].
  ///
  /// [cursorOffset] is clamped to `[0, text.length]`. Used when the user taps
  /// Insert in a channel, function, or constants panel.
  static String insertAtOffset(
      String text, int cursorOffset, String insertion,) {
    final safe = cursorOffset.clamp(0, text.length);
    return text.substring(0, safe) + insertion + text.substring(safe);
  }
}
