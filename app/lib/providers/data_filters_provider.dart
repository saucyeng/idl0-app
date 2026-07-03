import 'package:flutter/material.dart' show DateTimeRange, RangeValues;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/session_model.dart';

/// Result-panel layout choice in the Data tab. `sessions` is the default tree;
/// `tracks` is the flat track-metadata table.
enum DataView {
  /// Date-grouped session tree with per-session lap rows.
  sessions,

  /// Flat sortable Track table with side-panel detail.
  tracks,
}

/// Sortable field shared between the Sessions and Tracks views. Some apply to
/// only one view — the UI hides irrelevant choices. Direction is carried
/// separately by [DataFilters.sortAscending] so any field can be sorted either
/// way; each field also has a sensible [DataSortFieldX.defaultAscending].
enum DataSortField {
  /// Session start timestamp. Sessions view (default field).
  date,

  /// Best matching lap time. Sessions or Tracks view.
  bestLap,

  /// Total session duration. Sessions view only.
  duration,

  /// Lap count. Either view.
  lapCount,

  /// Most-recent contributing-lap timestamp. Tracks view (default field).
  lastRidden,

  /// Track name. Tracks view only.
  name,
}

/// Labels and default directions for [DataSortField].
extension DataSortFieldX on DataSortField {
  /// Human label for the sort menu and trigger.
  String get label => switch (this) {
        DataSortField.date => 'Date',
        DataSortField.bestLap => 'Best lap',
        DataSortField.duration => 'Duration',
        DataSortField.lapCount => 'Lap count',
        DataSortField.lastRidden => 'Last ridden',
        DataSortField.name => 'Name',
      };

  /// The direction this field sorts in by default (`false` = descending).
  ///
  /// Best-lap and name read most-usefully ascending (fastest lap / A→Z first);
  /// everything else (date, duration, lap count, last-ridden) defaults to
  /// descending so the "most" or "most-recent" rows lead.
  bool get defaultAscending => switch (this) {
        DataSortField.bestLap => true,
        DataSortField.name => true,
        _ => false,
      };
}

/// Sort fields exposed for [view], in menu order. The first entry is that
/// view's default field.
List<DataSortField> sortFieldsForView(DataView view) => view == DataView.tracks
    ? const [
        DataSortField.lastRidden,
        DataSortField.name,
        DataSortField.lapCount,
        DataSortField.bestLap,
      ]
    : const [
        DataSortField.date,
        DataSortField.bestLap,
        DataSortField.duration,
        DataSortField.lapCount,
      ];

/// Immutable state for [dataFiltersProvider].
///
/// Filters compose with AND across categories — a session matches when it
/// passes every active facet. Within a multi-select facet, matching is
/// "any of the selected values" (logical OR).
///
/// `null` / empty values mean the facet is inactive (passes through all
/// rows). Empty-string entries in [bikes], [riders] and [tags] represent
/// the synthetic "(none)" pseudo-entry — so the user can filter for
/// sessions that have not yet been labelled.
class DataFilters {
  /// Inclusive date range to include, or null for no date filter.
  final DateTimeRange? dateRange;

  /// Active Track-id whitelist; empty = pass-through.
  final Set<String> trackIds;

  /// Active bike-name whitelist; empty = pass-through. `''` represents
  /// "(none)".
  final Set<String> bikes;

  /// Active rider-name whitelist; empty = pass-through. `''` represents
  /// "(none)".
  final Set<String> riders;

  /// Active tag whitelist; empty = pass-through. `''` represents "(none)".
  final Set<String> tags;

  /// Active venue-name whitelist; empty = pass-through. `''` represents
  /// "(none)" — sessions/Tracks whose venueName is the empty string.
  final Set<String> venues;

  /// Inclusive lap-time range in milliseconds, or null = no filter.
  ///
  /// Null when the user has not narrowed the slider; the result providers
  /// treat null as "match every lap regardless of time".
  final RangeValues? lapTimeMs;

  /// Active source-type whitelist; empty = pass-through.
  final Set<SessionSourceType> sources;

  /// When `true`, exclude sessions whose visited Tracks all have empty
  /// `lapGates` lists.
  final bool requireGates;

  /// When `true`, exclude sessions that did not produce at least one
  /// detected `TrackVisit` (used as a proxy for "has GPS" — see
  /// [filteredSessionRowsProvider]).
  final bool requireGps;

  /// Free-text search box; matched case-insensitively as a substring across
  /// venue / comments / Track name / tag.
  final String searchText;

  /// Active result-panel view.
  final DataView view;

  /// Active sort field.
  final DataSortField sortField;

  /// Sort direction (`true` = ascending). Defaults per field via
  /// [DataSortFieldX.defaultAscending]; the user can flip it independently.
  final bool sortAscending;

  /// Creates a [DataFilters].
  const DataFilters({
    this.dateRange,
    this.trackIds = const <String>{},
    this.bikes = const <String>{},
    this.riders = const <String>{},
    this.tags = const <String>{},
    this.venues = const <String>{},
    this.lapTimeMs,
    this.sources = const <SessionSourceType>{},
    this.requireGates = false,
    this.requireGps = false,
    this.searchText = '',
    this.view = DataView.sessions,
    this.sortField = DataSortField.date,
    this.sortAscending = false,
  });

  /// `true` when at least one row-affecting facet is active. Excludes
  /// [view] / [sort] (those reorder, never filter).
  bool get hasAnyActiveFilter =>
      dateRange != null ||
      trackIds.isNotEmpty ||
      bikes.isNotEmpty ||
      riders.isNotEmpty ||
      tags.isNotEmpty ||
      venues.isNotEmpty ||
      lapTimeMs != null ||
      sources.isNotEmpty ||
      requireGates ||
      requireGps ||
      searchText.isNotEmpty;

  /// Total count of active facets — used by the "Filter" button badge on
  /// narrow layouts.
  int get activeCount {
    var n = 0;
    if (dateRange != null) n++;
    if (trackIds.isNotEmpty) n++;
    if (bikes.isNotEmpty) n++;
    if (riders.isNotEmpty) n++;
    if (tags.isNotEmpty) n++;
    if (venues.isNotEmpty) n++;
    if (lapTimeMs != null) n++;
    if (sources.isNotEmpty) n++;
    if (requireGates) n++;
    if (requireGps) n++;
    if (searchText.isNotEmpty) n++;
    return n;
  }

  /// Returns a copy with the given fields replaced. Pass an empty value
  /// (e.g. `{}` or `''`) to clear a facet; pass `null` for [dateRange] /
  /// [lapTimeMs] when you want to clear the optional range — the
  /// [DataFiltersNotifier] uses the explicit clear methods for that.
  DataFilters copyWith({
    DateTimeRange? dateRange,
    Set<String>? trackIds,
    Set<String>? bikes,
    Set<String>? riders,
    Set<String>? tags,
    Set<String>? venues,
    RangeValues? lapTimeMs,
    Set<SessionSourceType>? sources,
    bool? requireGates,
    bool? requireGps,
    String? searchText,
    DataView? view,
    DataSortField? sortField,
    bool? sortAscending,
  }) =>
      DataFilters(
        dateRange: dateRange ?? this.dateRange,
        trackIds: trackIds ?? this.trackIds,
        bikes: bikes ?? this.bikes,
        riders: riders ?? this.riders,
        tags: tags ?? this.tags,
        venues: venues ?? this.venues,
        lapTimeMs: lapTimeMs ?? this.lapTimeMs,
        sources: sources ?? this.sources,
        requireGates: requireGates ?? this.requireGates,
        requireGps: requireGps ?? this.requireGps,
        searchText: searchText ?? this.searchText,
        view: view ?? this.view,
        sortField: sortField ?? this.sortField,
        sortAscending: sortAscending ?? this.sortAscending,
      );
}

/// Manages [DataFilters]. Each user interaction (chip tap, slider drag,
/// search keystroke) goes through one of the small mutator methods so the
/// notifier stays the single owner of the filter state.
class DataFiltersNotifier extends Notifier<DataFilters> {
  @override
  DataFilters build() => const DataFilters();

  /// Replaces the date range. Pass `null` to clear (e.g. when the user
  /// switches from Custom back to a preset that conflicts).
  void setDateRange(DateTimeRange? range) {
    state = DataFilters(
      dateRange: range,
      trackIds: state.trackIds,
      bikes: state.bikes,
      riders: state.riders,
      tags: state.tags,
      venues: state.venues,
      lapTimeMs: state.lapTimeMs,
      sources: state.sources,
      requireGates: state.requireGates,
      requireGps: state.requireGps,
      searchText: state.searchText,
      view: state.view,
      sortField: state.sortField,
      sortAscending: state.sortAscending,
    );
  }

  /// Toggles a Track id in the Track facet.
  void toggleTrack(String trackId) =>
      state = state.copyWith(trackIds: _toggle(state.trackIds, trackId));

  /// Toggles a bike name in the Bike facet (`''` = "(none)").
  void toggleBike(String bike) =>
      state = state.copyWith(bikes: _toggle(state.bikes, bike));

  /// Toggles a rider name in the Rider facet (`''` = "(none)").
  void toggleRider(String rider) =>
      state = state.copyWith(riders: _toggle(state.riders, rider));

  /// Toggles a tag value in the Tag facet (`''` = "(none)").
  void toggleTag(String tag) =>
      state = state.copyWith(tags: _toggle(state.tags, tag));

  /// Toggles a venue name in the Venue facet (`''` = "(none)").
  void toggleVenue(String venue) =>
      state = state.copyWith(venues: _toggle(state.venues, venue));

  /// Toggles a source type in the Source facet.
  void toggleSource(SessionSourceType source) {
    final next = {...state.sources};
    if (next.contains(source)) {
      next.remove(source);
    } else {
      next.add(source);
    }
    state = state.copyWith(sources: next);
  }

  /// Replaces the lap-time range (or clears it when [range] is null).
  void setLapTimeRange(RangeValues? range) {
    // Clearing requires an explicit replacement because copyWith treats
    // `null` as "no change" for [DataFilters.lapTimeMs].
    state = DataFilters(
      dateRange: state.dateRange,
      trackIds: state.trackIds,
      bikes: state.bikes,
      riders: state.riders,
      tags: state.tags,
      venues: state.venues,
      lapTimeMs: range,
      sources: state.sources,
      requireGates: state.requireGates,
      requireGps: state.requireGps,
      searchText: state.searchText,
      view: state.view,
      sortField: state.sortField,
      sortAscending: state.sortAscending,
    );
  }

  /// Toggles the "matched Track has lap gates" requirement.
  void setRequireGates(bool value) =>
      state = state.copyWith(requireGates: value);

  /// Toggles the "session has at least one TrackVisit" requirement (a v1
  /// proxy for "has GPS").
  void setRequireGps(bool value) => state = state.copyWith(requireGps: value);

  /// Replaces the free-text search.
  void setSearchText(String text) => state = state.copyWith(searchText: text);

  /// Switches the result-panel view (Sessions tree vs. Tracks table). Also
  /// snaps [DataFilters.sortField] back to the new view's default field when
  /// the current field is not one that view exposes (e.g. Date on the Tracks
  /// view), resetting the direction to that field's default; an
  /// already-valid field keeps both its identity and the user's direction.
  void setView(DataView v) {
    if (v == state.view) return;
    final field = _validFieldFor(v, state.sortField);
    final ascending =
        field == state.sortField ? state.sortAscending : field.defaultAscending;
    state = state.copyWith(
      view: v,
      sortField: field,
      sortAscending: ascending,
    );
  }

  /// Selects the sort field and resets the direction to that field's default
  /// (best-lap/name → ascending, everything else → descending). The user can
  /// then flip it with [toggleSortDirection].
  void setSortField(DataSortField field) => state = state.copyWith(
        sortField: field,
        sortAscending: field.defaultAscending,
      );

  /// Flips the sort direction without changing the field.
  void toggleSortDirection() =>
      state = state.copyWith(sortAscending: !state.sortAscending);

  /// Returns [requested] when it is exposed for [view], or that view's default
  /// (first) field when it is not.
  static DataSortField _validFieldFor(
    DataView view,
    DataSortField requested,
  ) {
    final allowed = sortFieldsForView(view);
    return allowed.contains(requested) ? requested : allowed.first;
  }

  /// Drops every active facet. View and sort (field + direction) are
  /// preserved — those are presentation, not filtering.
  void clearAll() {
    state = DataFilters(
      view: state.view,
      sortField: state.sortField,
      sortAscending: state.sortAscending,
    );
  }

  static Set<String> _toggle(Set<String> current, String value) {
    final next = {...current};
    if (next.contains(value)) {
      next.remove(value);
    } else {
      next.add(value);
    }
    return next;
  }
}

/// Provider exposing [DataFilters].
final dataFiltersProvider =
    NotifierProvider<DataFiltersNotifier, DataFilters>(DataFiltersNotifier.new);
