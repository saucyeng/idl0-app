import 'package:intl/intl.dart';

import '../src/rust/session.dart' show FitLap;
import 'session_model.dart';
import 'workspace.dart';

/// All laps across [ws]'s track visits, in chronological order, mapped to the
/// engine's FIT lap input. Each lap's `elapsedMs` is its **effective** lap time
/// ([Lap.lapTimeMs], neutral zones removed) — the split Strava displays.
///
/// Empty when no track is assigned (the engine then emits a single whole-ride
/// lap). Start/end are wall-clock unix milliseconds.
List<FitLap> collectFitLaps(Workspace ws) {
  final laps = [
    for (final visit in ws.trackVisits) ...visit.laps,
  ]..sort((a, b) => a.startTimestampMs.compareTo(b.startTimestampMs));
  return [
    for (final l in laps)
      FitLap(
        startMs: l.startTimestampMs,
        endMs: l.endTimestampMs,
        elapsedMs: l.lapTimeMs,
      ),
  ];
}

/// Default export filename: `YYYY-MM-DD_<venue>.fit`, or `YYYY-MM-DD_HHMM.fit`
/// when [venue] is blank.
///
/// [venue] is the session's *resolved* display venue (caller passes the same
/// value the detail card shows — `meta.venueName` or a matched Track's venue).
/// When it is blank there is no meaningful venue, so the local creation time
/// disambiguates instead of a vague `unknown`. The date/time are local (to
/// match the card header); spaces in the venue become `_`.
String fitExportFileName(SessionMetadata meta, String venue) {
  final dt = DateTime.fromMillisecondsSinceEpoch(meta.createdTimestampMs);
  final date = DateFormat('yyyy-MM-dd').format(dt);
  final trimmed = venue.trim();
  if (trimmed.isEmpty) {
    return '${date}_${DateFormat('HHmm').format(dt)}.fit';
  }
  return '${date}_${trimmed.replaceAll(' ', '_')}.fit';
}
