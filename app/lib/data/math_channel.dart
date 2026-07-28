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
  // ---------------------------------------------------------------------
  // Attitude (AHRS) and gravity-removed body acceleration.
  //
  // These are ordinary expressions — no estimator run. They implement a
  // turn-compensated complementary filter over IMU0 + GPS-derived speed:
  //
  //   * an inertially-compensated accelerometer *reference*, which is
  //     memoryless (no phase lag) but noisy, and
  //   * integrated gyro, which has the right dynamics but drifts,
  //
  //   blended by a zero-phase band split at 0.2 Hz (`butter` is sosfiltfilt,
  //   forward-backward), so the crossover adds no phase distortion.
  //
  // The compensation is the whole point: a bare accelerometer is *blind* to
  // lean in a coordinated turn (the resultant runs down the bike's own
  // vertical axis — the turn-and-bank ball stays centred) and reads braking
  // as nose-down pitch that never happened.
  //
  // **These expression strings are load-bearing.** They are mirrored verbatim
  // by `AHRS_CHANNELS` in `rust/core/src/math/tests_ahrs.rs`, which proves
  // them physically correct against a synthetic coordinated-turn ride. Change
  // one, change both.
  //
  // `pi` and `g` are the language's universal constants (SPEC §19) — bare
  // identifiers resolved to literals at parse time, so no magic numbers appear
  // in the expressions.
  //
  // The engine's estimator-backed `attitude()` / `body_accel()` functions
  // still exist and still reflect what the suspension filter believes; they
  // are kept for diagnostics and cross-checking. These channels are the
  // user-facing attitude surface. See docs/IDL0_SPEC.md §19.
  // ---------------------------------------------------------------------
  MathChannel(
    id: 'builtin:SpeedMps',
    name: 'Speed (m/s)',
    quantity: 'velocity',
    units: 'm/s',
    sampleRateHz: 0.0,
    decimalPlaces: 2,
    color: '#FF4DB6AC',
    // `Distance` is synthesized at the IMU rate (a lazy lerp of the 1 Hz GPS
    // integral), so differentiating it yields speed already rate-matched to
    // the gyro — which is what lets the whole chain be expressed without a
    // resample(). Its derivative is a staircase, so smooth once here and
    // reuse; both compensation terms need only the slow component.
    expression: 'butter(2, 0.5, "low", differentiate([Distance]))',
  ),
  MathChannel(
    id: 'builtin:RollRate',
    name: 'Roll rate (deg/s)',
    quantity: 'angular_velocity',
    units: 'deg/s',
    sampleRateHz: 0.0,
    decimalPlaces: 1,
    color: '#FFA5D6A7',
    // IMU0 is mounted X-rear/Y-right — a 180° yaw from the ISO chassis frame
    // (X-forward, Y-left, Z-up) — so chassis X and Y are the negated sensor
    // axes. Positive ⇒ rolling to the right.
    expression: '-[IMU0_GyroX]',
  ),
  MathChannel(
    id: 'builtin:RollReference',
    name: 'Roll reference (deg)',
    quantity: 'angle',
    units: 'deg',
    sampleRateHz: 0.0,
    decimalPlaces: 1,
    color: '#FFC5E1A5',
    // Lateral specific force is f_y = v·ψ̇·cos φ + g·sin φ — the centripetal
    // term is horizontal, so it projects onto the tilted body-y axis through
    // cos φ. The *body* yaw rate carries the same factor (g_z = ψ̇·cos φ), so
    // substituting it cancels the projection exactly:
    //     sin φ = a_y − v·g_z/g
    // No small-angle assumption and no iteration — using the nav-frame turn
    // rate here would be wrong, not more accurate.
    //
    // The lowpass sits INSIDE the asin, not after it. On real trail data the
    // raw argument exceeds ±1 g about 10% of the time, and clamping those to
    // ±90° then averaging biases the level (measured on a real session before
    // this was moved). Filtering in the measurement domain, before the
    // nonlinearity, drops saturation to zero. `declip` repairs samples where
    // the accelerometer railed on a hard hit, matching the estimator path.
    expression:
        'asin(clamp(butter(2, 0.2, "low", declip(-[IMU0_AccelY]) - [Speed (m/s)] * [IMU0_GyroZ] * pi / 180 / g), -1, 1)) * 180 / pi',
  ),
  MathChannel(
    id: 'builtin:EstRoll',
    name: 'Roll (deg)',
    quantity: 'angle',
    units: 'deg',
    sampleRateHz: 0.0,
    decimalPlaces: 1,
    color: '#FF81C784',
    // Reference (already band-limited) + high-passed integrated gyro. The
    // highpass branch strips gyro bias, which would otherwise integrate into
    // unbounded phantom lean. 0.2 Hz sits below cornering dynamics
    // (~0.5–2 Hz), well above drift.
    expression:
        '[Roll reference (deg)] + integrate([Roll rate (deg/s)]) - butter(2, 0.2, "low", integrate([Roll rate (deg/s)]))',
  ),
  MathChannel(
    id: 'builtin:PitchRate',
    name: 'Pitch rate (deg/s)',
    quantity: 'angular_velocity',
    units: 'deg/s',
    sampleRateHz: 0.0,
    decimalPlaces: 1,
    color: '#FFDCE775',
    // NOT simply the body Y rate. The Euler rate is θ̇ = cos φ·q − sin φ·r,
    // and our convention is nose-up-positive (−θ), giving sin φ·r − cos φ·q;
    // with q = −[IMU0_GyroY] that is the form below. Skipping this coupling
    // injects a large false pitch rate through a sustained corner — at 20° of
    // lean the sin φ·r term is ~8 deg/s, which is the entire signal.
    expression:
        'sin([Roll (deg)] * pi / 180) * [IMU0_GyroZ] + cos([Roll (deg)] * pi / 180) * [IMU0_GyroY]',
  ),
  MathChannel(
    id: 'builtin:PitchReference',
    name: 'Pitch reference (deg)',
    quantity: 'angle',
    units: 'deg',
    sampleRateHz: 0.0,
    decimalPlaces: 1,
    color: '#FFE6EE9C',
    // f_x = a_x + g·sin θ, so sin θ = (f_x − dv/dt)/g. Without removing dv/dt
    // a bare accelerometer reads every brake as nose-down pitch. Lowpass sits
    // inside the asin for the same reason as the roll reference above.
    expression:
        'asin(clamp(butter(2, 0.2, "low", declip(-[IMU0_AccelX]) - differentiate([Speed (m/s)]) / g), -1, 1)) * 180 / pi',
  ),
  MathChannel(
    id: 'builtin:EstPitch',
    name: 'Pitch (deg)',
    quantity: 'angle',
    units: 'deg',
    sampleRateHz: 0.0,
    decimalPlaces: 1,
    color: '#FFAED581',
    expression:
        '[Pitch reference (deg)] + integrate([Pitch rate (deg/s)]) - butter(2, 0.2, "low", integrate([Pitch rate (deg/s)]))',
  ),
  // Gravity-removed body acceleration. Attitude is what tells us how much of
  // each accelerometer axis is gravity; subtracting it leaves real acceleration.
  MathChannel(
    id: 'builtin:EstAccelLong',
    name: 'Longitudinal accel (g)',
    quantity: 'acceleration',
    units: 'g',
    sampleRateHz: 0.0,
    decimalPlaces: 2,
    color: '#FFE57373',
    // Positive ⇒ accelerating forward.
    expression:
        'declip(-[IMU0_AccelX]) - sin([Pitch (deg)] * pi / 180)',
  ),
  MathChannel(
    id: 'builtin:EstAccelLat',
    name: 'Lateral accel (g)',
    quantity: 'acceleration',
    units: 'g',
    sampleRateHz: 0.0,
    decimalPlaces: 2,
    color: '#FFBA68C8',
    // Positive ⇒ accelerating right. a_lat = sin φ − a_y, and a_y is
    // −[IMU0_AccelY], which folds the sign into a plain addition.
    expression:
        'sin([Roll (deg)] * pi / 180) - declip(-[IMU0_AccelY])',
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
    // Estimator-backed virtual sensors (offline geometry-constrained
    // estimator). `wheel_*` are still routed by mathChannelEvalProvider;
    // `attitude`/`body_accel` evaluate for real in the engine.
    'wheel_travel', 'wheel_velocity', 'attitude', 'body_accel',
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
