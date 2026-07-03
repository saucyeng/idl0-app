import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/cached_session_laps.dart';
import '../data/session_model.dart';
import '../data/track.dart';
import '../data/workspace.dart';
import 'data_filters_provider.dart';
import 'session_provider.dart';
import 'session_workspace_provider.dart';
import 'track_provider.dart';

/// Pseudo-entry value used by the Bike / Rider / Tag facets to represent
/// "(none)" — sessions whose corresponding string field is empty. Stored
/// as the empty string both in [DataFilters] and in [FacetCounts] so the
/// matching code does not need a discriminated union.
const String kNoneSentinel = '';

/// One session row rendered in the Sessions tree. Carries the source
/// metadata plus the laps that survived the active filters and a few
/// derived stats so the UI does not need to recompute them per row.
class SessionRow {
  /// Source metadata.
  final SessionMetadata meta;

  /// All visit-detected laps for the session, paired with the Track they
  /// belong to. Ordered by [Lap.startTimestampMs] ascending.
  final List<SessionRowLap> laps;

  /// Lap times collapsed to milliseconds, used for the day-best ★ rendering
  /// and best-lap sort. Equal to `laps.map((e) => e.lap.lapTimeMs).toList()`
  /// — pre-cached because both UI sites need it.
  final List<int> lapTimesMs;

  /// Sum of every visible lap's `lapTimeMs`. May be 0 when the session has
  /// no detected laps after filtering.
  final int totalLapMs;

  /// Fastest visible lap time in milliseconds, or null when no laps.
  final int? bestLapMs;

  /// Creates a [SessionRow].
  const SessionRow({
    required this.meta,
    required this.laps,
    required this.lapTimesMs,
    required this.totalLapMs,
    required this.bestLapMs,
  });

  /// Local-time midnight that owns this session — used by the date heading
  /// in the Sessions tree.
  DateTime get localDate {
    final dt =
        DateTime.fromMillisecondsSinceEpoch(meta.createdTimestampMs).toLocal();
    return DateTime(dt.year, dt.month, dt.day);
  }

  /// Venue label for the Sessions-tree heading.
  ///
  /// Prefers the explicit [SessionMetadata.venueName]; when that is empty it
  /// falls back to the first non-empty `venueName` among the visited Tracks
  /// (in lap order). This mirrors the venue-facet match semantics in
  /// [sessionMatchesFilters] — a session whose venue is known only via a
  /// matched Track ("GNCC 26" → its venue) reads under that venue instead of
  /// "(no venue)". Empty only when neither the metadata nor any matched Track
  /// carries a venue.
  String get displayVenueName {
    if (meta.venueName.isNotEmpty) return meta.venueName;
    for (final l in laps) {
      final v = l.track?.venueName;
      if (v != null && v.isNotEmpty) return v;
    }
    return '';
  }
}

/// One lap inside a [SessionRow], with the Track it belongs to so the UI
/// can display "Lap 3 · A-Line".
class SessionRowLap {
  /// The detected lap.
  final Lap lap;

  /// Track this lap was matched to. May be null when the visit's
  /// `trackId` no longer resolves (skip-on-resolve per §12.3).
  final Track? track;

  /// `true` when this lap is in `Workspace.ignoredLapNumbers`.
  final bool isIgnored;

  /// `true` when this lap is the session's best non-ignored lap. Computed
  /// in the row builder so the UI does not re-traverse.
  final bool isSessionBest;

  /// Creates a [SessionRowLap].
  const SessionRowLap({
    required this.lap,
    required this.track,
    required this.isIgnored,
    required this.isSessionBest,
  });
}

/// One Track row rendered in the Tracks table. Aggregates per-Track stats
/// across every contributing session.
class TrackRow {
  /// The Track entity from [trackProvider].
  final Track track;

  /// Number of distinct sessions whose `trackVisits` reference this Track.
  final int sessionCount;

  /// Total non-ignored lap count across every contributing session.
  final int lapCount;

  /// Fastest non-ignored lap time on this Track in milliseconds, or null.
  final int? bestLapMs;

  /// Most-recent contributing-lap timestamp in UTC ms. Null when the Track
  /// has no laps yet.
  final int? lastRiddenMs;

  /// Creates a [TrackRow].
  const TrackRow({
    required this.track,
    required this.sessionCount,
    required this.lapCount,
    required this.bestLapMs,
    required this.lastRiddenMs,
  });
}

/// Per-facet "count of rows that would still match if the user toggled this
/// option on" map. Drives the `(N)` badges next to each facet entry. Empty
/// maps mean the facet has no candidate values.
///
/// The counts are computed against the post-filter session set excluding
/// the facet itself — i.e. they answer "how many rows would I see if I
/// added this option to the active filter?" Standard search-app idiom.
class FacetCounts {
  /// `trackId → match count`.
  final Map<String, int> tracks;

  /// `bike (`''` for none) → match count`.
  final Map<String, int> bikes;

  /// `rider (`''` for none) → match count`.
  final Map<String, int> riders;

  /// `tag (`''` for none) → match count`.
  final Map<String, int> tags;

  /// `venue (`''` for none) → match count`.
  final Map<String, int> venues;

  /// `source → match count`.
  final Map<SessionSourceType, int> sources;

  /// Creates a [FacetCounts].
  const FacetCounts({
    this.tracks = const {},
    this.bikes = const {},
    this.riders = const {},
    this.tags = const {},
    this.venues = const {},
    this.sources = const {},
  });
}

/// Internal aggregate that survives the per-session async fan-out — one
/// entry per loaded session with everything the row + facet builders need.
class _SessionAggregate {
  _SessionAggregate({
    required this.meta,
    required this.workspace,
    required this.laps,
  });

  final SessionMetadata meta;
  final Workspace workspace;
  final List<({Lap lap, Track? track, bool isIgnored})> laps;

  /// Distinct trackIds visited in the session whose Track currently
  /// resolves. Empty when the session has no visits.
  Set<String> get visitedTrackIds =>
      workspace.trackVisits.map((v) => v.trackId).toSet();
}

/// Loads + caches the per-session aggregate (workspace + lap list +
/// matched Track per lap). Each contributing session resolves in parallel
/// via `Future.wait`; failures collapse to an empty aggregate so one bad
/// file does not block the rest of the result panel.
final _sessionAggregatesProvider =
    FutureProvider<List<_SessionAggregate>>((ref) async {
  final sessions = ref.watch(sessionProvider).sessions;
  if (sessions.isEmpty) return const [];

  final tracksList = await ref.watch(trackProvider.future);
  final tracksById = {for (final t in tracksList) t.trackId: t};

  Future<_SessionAggregate?> resolveOne(SessionMetadata meta) async {
    try {
      final ws = await ref.watch(
        sessionWorkspaceProvider(meta.sessionId).future,
      );
      // Cached laps (§17.4), renumbered session-wide so lap numbers and
      // ignored-lap matching agree with the Analyze lap table (§24.7). No
      // session parse on Data-tab open.
      final lapsOut = cachedSessionLaps(ws, tracksById);
      return _SessionAggregate(meta: meta, workspace: ws, laps: lapsOut);
    } catch (_) {
      // Missing / corrupt workspace → empty aggregate so the session still
      // appears in the row list (carrying just its metadata).
      return _SessionAggregate(
        meta: meta,
        workspace: Workspace.empty(meta.sessionId),
        laps: const [],
      );
    }
  }

  final futures = sessions.map(resolveOne).toList();
  final results = await Future.wait(futures);
  return [
    for (final r in results)
      if (r != null) r,
  ];
});

/// Domain for the lap-time RangeSlider. Returns `(min: 60_000, max: ms)`
/// where `ms` is the actual maximum lap time across the library, ceiling
/// to the next 5-minute boundary, then clamped to `[60_000, 10_800_000]`
/// (1 minute floor, 3 hour ceiling per Q6).
final lapTimeDomainProvider =
    FutureProvider<({int minMs, int maxMs})>((ref) async {
  final aggregates = await ref.watch(_sessionAggregatesProvider.future);
  var observedMaxMs = 0;
  for (final agg in aggregates) {
    for (final l in agg.laps) {
      if (l.lap.lapTimeMs > observedMaxMs) observedMaxMs = l.lap.lapTimeMs;
    }
  }
  // Ceil to next 5-minute boundary (300 000 ms) so the slider lands on a
  // round number even when the longest lap is mid-bracket.
  const fiveMinMs = 5 * 60 * 1000;
  final ceiled = ((observedMaxMs + fiveMinMs - 1) ~/ fiveMinMs) * fiveMinMs;
  final maxMs = ceiled.clamp(60 * 1000, 3 * 60 * 60 * 1000);
  return (minMs: 60 * 1000, maxMs: maxMs);
});

/// The post-filter Session row list, sorted per [DataFilters.sort]. Sessions
/// whose laps all get filtered out are dropped from the list.
final filteredSessionRowsProvider =
    FutureProvider<List<SessionRow>>((ref) async {
  final aggregates = await ref.watch(_sessionAggregatesProvider.future);
  final filters = ref.watch(dataFiltersProvider);
  final tracksById = {
    for (final t in await ref.watch(trackProvider.future)) t.trackId: t,
  };

  final rows = <SessionRow>[];
  for (final agg in aggregates) {
    if (!_sessionPassesNonLapFilters(agg, filters, tracksById)) continue;

    // Filter laps by the active Track / lap-time facets.
    final visibleLaps = <SessionRowLap>[];
    final lapTimesMs = <int>[];
    for (final l in agg.laps) {
      if (filters.trackIds.isNotEmpty &&
          (l.track == null || !filters.trackIds.contains(l.track!.trackId))) {
        continue;
      }
      if (filters.lapTimeMs != null) {
        final t = l.lap.lapTimeMs.toDouble();
        if (t < filters.lapTimeMs!.start || t > filters.lapTimeMs!.end) {
          continue;
        }
      }
      visibleLaps.add(
        SessionRowLap(
          lap: l.lap,
          track: l.track,
          isIgnored: l.isIgnored,
          // Filled in once we know the row's best.
          isSessionBest: false,
        ),
      );
      lapTimesMs.add(l.lap.lapTimeMs);
    }

    // If the user has narrowed by Track / lap-time AND the session ended up
    // with no laps, drop the row entirely.
    final lapNarrowing =
        filters.trackIds.isNotEmpty || filters.lapTimeMs != null;
    if (lapNarrowing && visibleLaps.isEmpty) continue;

    // Compute best non-ignored lap and flag it.
    int? bestMs;
    int bestIndex = -1;
    for (var i = 0; i < visibleLaps.length; i++) {
      final l = visibleLaps[i];
      if (l.isIgnored) continue;
      if (bestMs == null || l.lap.lapTimeMs < bestMs) {
        bestMs = l.lap.lapTimeMs;
        bestIndex = i;
      }
    }
    if (bestIndex >= 0) {
      final winner = visibleLaps[bestIndex];
      visibleLaps[bestIndex] = SessionRowLap(
        lap: winner.lap,
        track: winner.track,
        isIgnored: winner.isIgnored,
        isSessionBest: true,
      );
    }

    rows.add(
      SessionRow(
        meta: agg.meta,
        laps: visibleLaps,
        lapTimesMs: lapTimesMs,
        totalLapMs: lapTimesMs.fold<int>(0, (a, b) => a + b),
        bestLapMs: bestMs,
      ),
    );
  }

  _sortSessionRows(rows, filters.sortField, filters.sortAscending);
  return rows;
});

/// The post-filter Track table. Aggregates across [filteredSessionRowsProvider]
/// so the counts always reflect the active filter set — flipping a filter
/// updates the Tracks view without a separate compute pass.
final filteredTrackRowsProvider = FutureProvider<List<TrackRow>>((ref) async {
  final tracks = await ref.watch(trackProvider.future);
  final rows = await ref.watch(filteredSessionRowsProvider.future);

  final byTrack = <String, _TrackAcc>{
    for (final t in tracks) t.trackId: _TrackAcc(track: t),
  };
  for (final row in rows) {
    final seenTrackIds = <String>{};
    for (final l in row.laps) {
      final trackId = l.track?.trackId;
      if (trackId == null) continue;
      final acc = byTrack[trackId];
      if (acc == null) continue;
      seenTrackIds.add(trackId);
      if (!l.isIgnored) {
        acc.lapCount++;
        if (acc.bestLapMs == null || l.lap.lapTimeMs < acc.bestLapMs!) {
          acc.bestLapMs = l.lap.lapTimeMs;
        }
      }
      if (acc.lastRiddenMs == null ||
          l.lap.endTimestampMs > acc.lastRiddenMs!) {
        acc.lastRiddenMs = l.lap.endTimestampMs;
      }
    }
    for (final tid in seenTrackIds) {
      byTrack[tid]!.sessionCount++;
    }
  }

  final filters = ref.watch(dataFiltersProvider);
  final out = byTrack.values
      .where(
        (acc) =>
            filters.trackIds.isEmpty ||
            filters.trackIds.contains(acc.track.trackId),
      )
      .map(
        (acc) => TrackRow(
          track: acc.track,
          sessionCount: acc.sessionCount,
          lapCount: acc.lapCount,
          bestLapMs: acc.bestLapMs,
          lastRiddenMs: acc.lastRiddenMs,
        ),
      )
      .toList();
  _sortTrackRows(out, filters.sortField, filters.sortAscending);
  return out;
});

/// "(N)" badge counts per facet entry. Computed against the active filter
/// set with the corresponding facet *removed*, so the user sees the count
/// they'd land on after toggling a value.
final facetCountsProvider = FutureProvider<FacetCounts>((ref) async {
  final aggregates = await ref.watch(_sessionAggregatesProvider.future);
  final filters = ref.watch(dataFiltersProvider);
  final tracksById = {
    for (final t in await ref.watch(trackProvider.future)) t.trackId: t,
  };

  // Pre-bucket the helper that "would this session match if facet X were
  // single-valued?" works against. Skip work when nothing's loaded.
  final tracks = <String, int>{};
  final bikes = <String, int>{};
  final riders = <String, int>{};
  final tags = <String, int>{};
  final venues = <String, int>{};
  final sources = <SessionSourceType, int>{};

  // Single-cell facet variants — pretend the facet has been replaced with
  // exactly the candidate value to ask the count question.
  bool passesIgnoringFacet({
    required _SessionAggregate agg,
    Set<String>? trackOverride,
    Set<String>? bikeOverride,
    Set<String>? riderOverride,
    Set<String>? tagOverride,
    Set<String>? venueOverride,
    Set<SessionSourceType>? sourceOverride,
  }) {
    final f = filters.copyWith(
      trackIds: trackOverride ?? filters.trackIds,
      bikes: bikeOverride ?? filters.bikes,
      riders: riderOverride ?? filters.riders,
      tags: tagOverride ?? filters.tags,
      venues: venueOverride ?? filters.venues,
      sources: sourceOverride ?? filters.sources,
    );
    return _sessionPassesNonLapFilters(agg, f, tracksById);
  }

  for (final agg in aggregates) {
    // Track facet — for each visited track, count if the session would
    // pass when filtered to that track only.
    for (final tid in agg.visitedTrackIds) {
      if (passesIgnoringFacet(agg: agg, trackOverride: {tid})) {
        tracks[tid] = (tracks[tid] ?? 0) + 1;
      }
    }

    final bike = agg.meta.bike;
    if (passesIgnoringFacet(agg: agg, bikeOverride: {bike})) {
      bikes[bike] = (bikes[bike] ?? 0) + 1;
    }

    final rider = agg.meta.rider;
    if (passesIgnoringFacet(agg: agg, riderOverride: {rider})) {
      riders[rider] = (riders[rider] ?? 0) + 1;
    }

    final tag = agg.meta.tag;
    if (passesIgnoringFacet(agg: agg, tagOverride: {tag})) {
      tags[tag] = (tags[tag] ?? 0) + 1;
    }

    // Venue facet — gather all candidate venue strings for this session
    // (SessionMetadata.venueName plus every visited Track's venueName),
    // then count each candidate independently so the "(N)" badges reflect
    // the number of sessions reachable via that venue.
    final venueCandidates = <String>{
      agg.meta.venueName,
      for (final tid in agg.visitedTrackIds) tracksById[tid]?.venueName ?? '',
    };
    for (final venue in venueCandidates) {
      if (passesIgnoringFacet(agg: agg, venueOverride: {venue})) {
        venues[venue] = (venues[venue] ?? 0) + 1;
      }
    }

    final src = agg.meta.sourceType;
    if (passesIgnoringFacet(agg: agg, sourceOverride: {src})) {
      sources[src] = (sources[src] ?? 0) + 1;
    }
  }

  return FacetCounts(
    tracks: tracks,
    bikes: bikes,
    riders: riders,
    tags: tags,
    venues: venues,
    sources: sources,
  );
});

// ---------------------------------------------------------------------------
// Internal helpers — passes-filter predicates and sort routines.
// ---------------------------------------------------------------------------

bool _sessionPassesNonLapFilters(
  _SessionAggregate agg,
  DataFilters f,
  Map<String, Track> tracksById,
) {
  // Date range — inclusive both ends, against created date in local time.
  if (f.dateRange != null) {
    final created =
        DateTime.fromMillisecondsSinceEpoch(agg.meta.createdTimestampMs)
            .toLocal();
    final day = DateTime(created.year, created.month, created.day);
    final start = DateTime(
      f.dateRange!.start.year,
      f.dateRange!.start.month,
      f.dateRange!.start.day,
    );
    final end = DateTime(
      f.dateRange!.end.year,
      f.dateRange!.end.month,
      f.dateRange!.end.day,
    );
    if (day.isBefore(start) || day.isAfter(end)) return false;
  }

  // Bike / rider / tag — empty string represents "(none)".
  if (f.bikes.isNotEmpty && !f.bikes.contains(agg.meta.bike)) return false;
  if (f.riders.isNotEmpty && !f.riders.contains(agg.meta.rider)) return false;
  if (f.tags.isNotEmpty && !f.tags.contains(agg.meta.tag)) return false;

  // Venue — match against either the SessionMetadata.venueName OR the
  // venueName of any visited Track. A session tagged "Whistler" matches
  // when filtering by Whistler, AND a session whose visited Tracks belong
  // to Whistler matches even if SessionMetadata.venueName is empty.
  if (f.venues.isNotEmpty) {
    final candidates = <String>{
      agg.meta.venueName,
      for (final tid in agg.visitedTrackIds) tracksById[tid]?.venueName ?? '',
    };
    if (!candidates.any(f.venues.contains)) return false;
  }

  // Source type
  if (f.sources.isNotEmpty && !f.sources.contains(agg.meta.sourceType)) {
    return false;
  }

  // Track facet — at least one visited track in the whitelist.
  if (f.trackIds.isNotEmpty) {
    final visited = agg.visitedTrackIds;
    if (visited.isEmpty || !visited.any(f.trackIds.contains)) return false;
  }

  // requireGates — at least one matched Track has lap gates. Approximation
  // matching multi-track model where Track owns the canonical gates.
  if (f.requireGates) {
    final matchedTracks = [
      for (final tid in agg.visitedTrackIds)
        if (tracksById[tid] != null) tracksById[tid]!,
    ];
    if (matchedTracks.every((t) => t.lapTiming == null)) return false;
  }

  // requireGps — proxy via "session has at least one TrackVisit". A session
  // recorded with GPS but no matching tracks slips through this check, which
  // we accept for v1 — see Q5b. If this proves misleading, surface a proper
  // hasGps flag on SessionMetadata.
  if (f.requireGps && agg.workspace.trackVisits.isEmpty) return false;

  // Free-text search
  if (f.searchText.isNotEmpty) {
    final needle = f.searchText.toLowerCase();
    final haystacks = <String>[
      agg.meta.venueName,
      agg.meta.shortComment,
      agg.meta.longComment,
      agg.meta.tag,
      for (final tid in agg.visitedTrackIds) tracksById[tid]?.name ?? '',
    ];
    if (!haystacks.any((s) => s.toLowerCase().contains(needle))) return false;
  }

  return true;
}

void _sortSessionRows(
  List<SessionRow> rows,
  DataSortField field,
  bool ascending,
) {
  // Each branch returns the ascending ordering for the field (smallest metric
  // first); the final sort negates it when a descending order is requested.
  int cmp(SessionRow a, SessionRow b) {
    switch (field) {
      case DataSortField.date:
        return a.meta.createdTimestampMs.compareTo(b.meta.createdTimestampMs);
      case DataSortField.bestLap:
        final aBest = a.bestLapMs ?? 1 << 62; // missing best sorts last
        final bBest = b.bestLapMs ?? 1 << 62;
        return aBest.compareTo(bBest);
      case DataSortField.duration:
        final ad = a.meta.durationMs ?? a.totalLapMs;
        final bd = b.meta.durationMs ?? b.totalLapMs;
        return ad.compareTo(bd);
      case DataSortField.lapCount:
        return a.laps.length.compareTo(b.laps.length);
      case DataSortField.lastRidden:
      case DataSortField.name:
        // Track-only fields — fall back to session date on the Sessions view.
        return a.meta.createdTimestampMs.compareTo(b.meta.createdTimestampMs);
    }
  }

  rows.sort((a, b) => ascending ? cmp(a, b) : cmp(b, a));
}

void _sortTrackRows(
  List<TrackRow> rows,
  DataSortField field,
  bool ascending,
) {
  // Ascending ordering per field (smallest first); negated for descending.
  int cmp(TrackRow a, TrackRow b) {
    switch (field) {
      case DataSortField.lastRidden:
        return (a.lastRiddenMs ?? 0).compareTo(b.lastRiddenMs ?? 0);
      case DataSortField.name:
        return a.track.name.toLowerCase().compareTo(b.track.name.toLowerCase());
      case DataSortField.lapCount:
        return a.lapCount.compareTo(b.lapCount);
      case DataSortField.bestLap:
        final aBest = a.bestLapMs ?? 1 << 62; // missing best sorts last
        final bBest = b.bestLapMs ?? 1 << 62;
        return aBest.compareTo(bBest);
      case DataSortField.date:
      case DataSortField.duration:
        // Session-only fields — fall back to last-ridden on the Tracks view.
        return (a.lastRiddenMs ?? 0).compareTo(b.lastRiddenMs ?? 0);
    }
  }

  rows.sort((a, b) => ascending ? cmp(a, b) : cmp(b, a));
}

class _TrackAcc {
  _TrackAcc({required this.track});

  final Track track;
  int sessionCount = 0;
  int lapCount = 0;
  int? bestLapMs;
  int? lastRiddenMs;
}
