import '../../../data/session_model.dart';

/// Human-facing label for a session: `YYYY-MM-DD HH:MM` in UTC, derived from
/// [SessionMetadata.createdTimestampMs]. The shared session-labelling
/// convention for the Analyze tab (lap-progression legend, GPS colour rows).
String formatSessionLabel(SessionMetadata meta) {
  final dt = DateTime.fromMillisecondsSinceEpoch(
    meta.createdTimestampMs,
    isUtc: true,
  );
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')} '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}';
}

/// [formatSessionLabel] for the session in [sessions] whose `sessionId` matches
/// [sessionId]; falls back to the first 8 characters of [sessionId] when the
/// session is not in the list (e.g. still loading).
String sessionDisplayLabel(
  Iterable<SessionMetadata> sessions,
  String sessionId,
) {
  for (final s in sessions) {
    if (s.sessionId == sessionId) return formatSessionLabel(s);
  }
  return sessionId.length > 8 ? sessionId.substring(0, 8) : sessionId;
}
