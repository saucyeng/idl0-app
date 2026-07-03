/// On-disk filename derivation for session files (`.idl0` / `.idl0w`).
///
/// Sessions are named by their **recording timestamp** in local time
/// (`YYYY-MM-DD_HH-MM-SS`) rather than the opaque `sessionId` UUID, so the raw
/// files are human-browsable and sort chronologically. The `sessionId` remains
/// the session's internal identity (SQLite index key, Drive naming, workspace
/// ownership); only the filename changes. See SPEC §15.
library;

/// Formats [t] (a **local** time) as the `YYYY-MM-DD_HH-MM-SS` filename base,
/// every component zero-padded. Colons are avoided so the name is valid on
/// every target filesystem.
String formatSessionFileBase(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  final y = t.year.toString().padLeft(4, '0');
  return '$y-${two(t.month)}-${two(t.day)}_${two(t.hour)}-${two(t.minute)}-${two(t.second)}';
}

/// Returns the filename base (no extension) for a session recorded at
/// [createdTimestampMs] (UTC ms since epoch), rendered in local time via
/// [formatSessionFileBase].
///
/// When [createdTimestampMs] is non-positive — an unknown recording time, e.g.
/// a log with no GPS fix to back-fill the start from (SPEC §5.6) — falls back
/// to [fallbackBase] (typically the `sessionId`) so we never mint a misleading
/// `1970-01-01_...` name.
String sessionFileBase(int createdTimestampMs, {required String fallbackBase}) {
  if (createdTimestampMs <= 0) return fallbackBase;
  return formatSessionFileBase(
    DateTime.fromMillisecondsSinceEpoch(createdTimestampMs).toLocal(),
  );
}

/// Returns the first of [base], `<base>-2`, `<base>-3`, … for which [isTaken]
/// reports `false` — disambiguating two recordings that share a wall-clock
/// second (or a [fallbackBase] reused across logs).
///
/// [isTaken] reports whether a candidate base already names a file on disk
/// (the caller checks the relevant extensions, e.g. both `.idl0` and `.idl0w`).
String uniqueFileBase(String base, bool Function(String candidate) isTaken) {
  if (!isTaken(base)) return base;
  for (var n = 2;; n++) {
    final candidate = '$base-$n';
    if (!isTaken(candidate)) return candidate;
  }
}
