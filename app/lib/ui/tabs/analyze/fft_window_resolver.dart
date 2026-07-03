/// Pure resolution of which time windows the FFT chart should transform, from
/// the worksheet's current zoom + lap selection. The chart issues one windowed
/// Welch per returned [SpectrumRequest]. Kept pure (no Riverpod, no bridge) so
/// it is unit-testable; the widget feeds it state and renders the result. §26.10.
library;

/// One windowed spectrum to compute and draw as a single line.
typedef SpectrumRequest = ({
  String sessionId,
  String channelId,
  double t0Secs,
  double t1Secs,
  String label,
});

/// Maximum overlaid FFT lines before truncation — one distinct palette colour
/// each, so the overlay stays readable. Beyond this the chart surfaces a note.
const int kMaxFftSpectra = 10;

/// Resolves [SpectrumRequest]s for the FFT chart.
///
/// Session-mode: one request per channel over the [zoom] span, or the whole
/// session (`[0, duration]`) when [zoom] is null. Lap-mode: one request per
/// (channel × selected lap), each over that lap's `[startSecs, endSecs]`,
/// labelled `"<channel> · Lap N"`. Truncates to [kMaxFftSpectra] and reports it.
({List<SpectrumRequest> requests, bool truncated}) resolveFftWindows({
  required List<({String sessionId, String channelId})> channels,
  required bool lapMode,
  required Map<String, List<({int lapNumber, double startSecs, double endSecs})>> lapsBySession,
  required Set<({String sessionId, int lapNumber})> selectedLaps,
  required ({double startSecs, double endSecs})? zoom,
  required double Function(String sessionId) sessionDurationSecs,
}) {
  final out = <SpectrumRequest>[];
  if (lapMode) {
    // Stable order: by channel, then ascending lap number.
    for (final c in channels) {
      final laps = lapsBySession[c.sessionId] ?? const [];
      final selected = laps
          .where((l) => selectedLaps.contains((sessionId: c.sessionId, lapNumber: l.lapNumber)))
          .toList()
        ..sort((a, b) => a.lapNumber.compareTo(b.lapNumber));
      for (final l in selected) {
        out.add((
          sessionId: c.sessionId,
          channelId: c.channelId,
          t0Secs: l.startSecs,
          t1Secs: l.endSecs,
          label: '${c.channelId} · Lap ${l.lapNumber}',
        ));
      }
    }
  } else {
    for (final c in channels) {
      final t0 = zoom?.startSecs ?? 0.0;
      final t1 = zoom?.endSecs ?? sessionDurationSecs(c.sessionId);
      out.add((sessionId: c.sessionId, channelId: c.channelId, t0Secs: t0, t1Secs: t1, label: c.channelId));
    }
  }
  if (out.length > kMaxFftSpectra) {
    return (requests: out.sublist(0, kMaxFftSpectra), truncated: true);
  }
  return (requests: out, truncated: false);
}
