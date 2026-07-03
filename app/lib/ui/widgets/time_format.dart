// Formatters for chart axes and readouts that show times measured in
// seconds. Race telemetry mixes short intervals (deltas, sub-second) and
// longer stretches (lap times, session elapsed time); a flat "seconds"
// label becomes hard to read past a minute or so. These helpers switch
// to M:SS (or M:SS.fff for readouts) once the magnitude crosses a
// minute, while keeping short values as plain decimal seconds with an
// 's' suffix.

/// Formats [seconds] for an axis tick label.
///
/// - `|seconds| < 60` → decimal seconds with adaptive precision and an
///   `s` suffix (e.g. `0.50s`, `5.5s`, `45s`).
/// - `|seconds| >= 60` → `M:SS` when the seconds value is a whole number,
///   `M:SS.f` otherwise (e.g. `1:30`, `2:07.5`).
/// - Negative values get a leading `-` (e.g. `-1:23`).
///
/// [intervalSecs] is the tick spacing (when known). Precision is driven by it
/// so adjacent ticks stay distinct as the user zooms in — without it, a value
/// like `12.0`/`12.1`/`12.2` would all render `12s` (the magnitude heuristic
/// drops decimals above 10 s). When [intervalSecs] is null the original
/// value-magnitude heuristic applies (used by axes that don't zoom).
///
/// Designed for fl_chart `SideTitles.getTitlesWidget`.
String formatTimeAxisLabel(double seconds, {double? intervalSecs}) {
  final negative = seconds < 0;
  final abs = seconds.abs();
  final sign = negative ? '-' : '';

  // Decimal places needed to keep ticks `intervalSecs` apart distinguishable.
  int? forced;
  if (intervalSecs != null && intervalSecs > 0) {
    if (intervalSecs >= 1) {
      forced = 0;
    } else if (intervalSecs >= 0.1) {
      forced = 1;
    } else if (intervalSecs >= 0.01) {
      forced = 2;
    } else {
      forced = 3;
    }
  }

  if (abs < 60) {
    final String body;
    if (forced != null) {
      body = abs.toStringAsFixed(forced);
    } else if (abs < 1) {
      body = abs.toStringAsFixed(2);
    } else if (abs < 10) {
      body = abs.toStringAsFixed(1);
    } else {
      body = abs.toStringAsFixed(0);
    }
    return '$sign${body}s';
  }
  final totalMs = (abs * 1000).round();
  final totalMins = totalMs ~/ 60000;
  final secs = (totalMs % 60000) / 1000.0;
  final secsDecimals = forced ?? (secs == secs.roundToDouble() ? 0 : 1);
  final secsBody = secsDecimals == 0
      ? secs.toStringAsFixed(0).padLeft(2, '0')
      : secs.toStringAsFixed(secsDecimals).padLeft(3 + secsDecimals, '0');
  // For long sessions (>= 1 hour), spell H:MM:SS so a tick like 133 minutes
  // 50 seconds renders as "2:13:50" instead of "133:50" — easier to parse
  // at a glance and prevents the minutes column from getting wide enough
  // to overlap adjacent ticks on a narrow chart.
  if (totalMins >= 60) {
    final h = totalMins ~/ 60;
    final m = (totalMins % 60).toString().padLeft(2, '0');
    return '$sign$h:$m:$secsBody';
  }
  return '$sign$totalMins:$secsBody';
}

/// Formats [seconds] for a numeric readout (cursor chip, copy-to-clipboard,
/// tooltip).
///
/// - `|seconds| < 60` → three-decimal seconds with an `s` suffix
///   (e.g. `1.234 s`, `0.500 s`).
/// - `|seconds| >= 60` → `M:SS.fff` (e.g. `1:23.456`).
/// - Negative values get a leading `-`.
String formatTimeReadout(double seconds) {
  final negative = seconds < 0;
  final abs = seconds.abs();
  final sign = negative ? '-' : '';
  if (abs < 60) {
    return '$sign${abs.toStringAsFixed(3)} s';
  }
  final totalMs = (abs * 1000).round();
  final mins = totalMs ~/ 60000;
  final remMs = totalMs % 60000;
  final secs = remMs ~/ 1000;
  final ms = remMs % 1000;
  final secsStr = secs.toString().padLeft(2, '0');
  final msStr = ms.toString().padLeft(3, '0');
  return '$sign$mins:$secsStr.$msStr';
}
