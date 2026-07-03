import 'package:flutter/material.dart' show DateTimeRange, RangeValues;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/providers/data_filters_provider.dart';

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  test('initial state — every facet is inactive', () {
    // Arrange / Act
    final s = container.read(dataFiltersProvider);

    // Assert
    expect(s.hasAnyActiveFilter, isFalse);
    expect(s.activeCount, equals(0));
    expect(s.view, equals(DataView.sessions));
    expect(s.sortField, equals(DataSortField.date));
    expect(s.sortAscending, isFalse); // date defaults to newest-first
  });

  test('toggleBike — empty string represents (none) and round-trips', () {
    // Arrange
    final n = container.read(dataFiltersProvider.notifier);

    // Act
    n.toggleBike('');
    n.toggleBike('Trek Session');

    // Assert
    expect(
      container.read(dataFiltersProvider).bikes,
      equals({'', 'Trek Session'}),
    );

    // Act — toggle off the (none) entry
    n.toggleBike('');

    // Assert
    expect(
      container.read(dataFiltersProvider).bikes,
      equals({'Trek Session'}),
    );
  });

  test('toggleSource — adds and removes', () {
    // Arrange
    final n = container.read(dataFiltersProvider.notifier);

    // Act
    n.toggleSource(SessionSourceType.idl0);
    n.toggleSource(SessionSourceType.gpx);

    // Assert
    expect(
      container.read(dataFiltersProvider).sources,
      equals({SessionSourceType.idl0, SessionSourceType.gpx}),
    );

    // Act
    n.toggleSource(SessionSourceType.idl0);

    // Assert
    expect(
      container.read(dataFiltersProvider).sources,
      equals({SessionSourceType.gpx}),
    );
  });

  test('setLapTimeRange — null clears the bound', () {
    // Arrange
    final n = container.read(dataFiltersProvider.notifier);
    n.setLapTimeRange(const RangeValues(60_000, 600_000));
    expect(container.read(dataFiltersProvider).lapTimeMs, isNotNull);

    // Act
    n.setLapTimeRange(null);

    // Assert
    expect(container.read(dataFiltersProvider).lapTimeMs, isNull);
  });

  test('setDateRange — null clears the bound', () {
    // Arrange
    final n = container.read(dataFiltersProvider.notifier);
    n.setDateRange(
      DateTimeRange(start: DateTime(2026, 4), end: DateTime(2026, 5)),
    );
    expect(container.read(dataFiltersProvider).dateRange, isNotNull);

    // Act
    n.setDateRange(null);

    // Assert
    expect(container.read(dataFiltersProvider).dateRange, isNull);
  });

  test('clearAll — drops every facet but keeps view + sort', () {
    // Arrange
    final n = container.read(dataFiltersProvider.notifier);
    n.toggleBike('Trek');
    n.toggleRider('Alice');
    n.setRequireGps(true);
    n.setView(DataView.tracks);
    n.setSortField(DataSortField.bestLap);

    // Act
    n.clearAll();

    // Assert
    final s = container.read(dataFiltersProvider);
    expect(s.bikes, isEmpty);
    expect(s.riders, isEmpty);
    expect(s.requireGps, isFalse);
    expect(s.view, equals(DataView.tracks));
    expect(s.sortField, equals(DataSortField.bestLap));
  });

  test('setSortField — resets direction to the field default', () {
    // Arrange — start at date (default descending).
    final n = container.read(dataFiltersProvider.notifier);

    // Act — best-lap defaults to ascending (fastest first).
    n.setSortField(DataSortField.bestLap);

    // Assert
    var s = container.read(dataFiltersProvider);
    expect(s.sortField, equals(DataSortField.bestLap));
    expect(s.sortAscending, isTrue);

    // Act — lap count defaults to descending (most first).
    n.setSortField(DataSortField.lapCount);

    // Assert
    s = container.read(dataFiltersProvider);
    expect(s.sortField, equals(DataSortField.lapCount));
    expect(s.sortAscending, isFalse);
  });

  test('toggleSortDirection — flips direction without changing the field', () {
    // Arrange
    final n = container.read(dataFiltersProvider.notifier);
    n.setSortField(DataSortField.date); // descending by default

    // Act
    n.toggleSortDirection();

    // Assert
    final s = container.read(dataFiltersProvider);
    expect(s.sortField, equals(DataSortField.date));
    expect(s.sortAscending, isTrue);
  });

  test('setView — snaps sort field to view default when incompatible', () {
    // Arrange — start in Sessions view on the Date field.
    final n = container.read(dataFiltersProvider.notifier);
    expect(
      container.read(dataFiltersProvider).sortField,
      DataSortField.date,
    );

    // Act — switch to Tracks; Date isn't a valid Tracks field.
    n.setView(DataView.tracks);

    // Assert — clamp to the Tracks default field (last-ridden, descending).
    var s = container.read(dataFiltersProvider);
    expect(s.sortField, equals(DataSortField.lastRidden));
    expect(s.sortAscending, isFalse);

    // Act — switch back; last-ridden isn't a Sessions field.
    n.setView(DataView.sessions);

    // Assert — back to the Sessions default field.
    s = container.read(dataFiltersProvider);
    expect(s.sortField, equals(DataSortField.date));
  });

  test('setView — preserves field + direction when valid in both views', () {
    // Arrange — lap count is exposed by both views; flip to ascending.
    final n = container.read(dataFiltersProvider.notifier);
    n.setSortField(DataSortField.lapCount);
    n.toggleSortDirection(); // now ascending, a non-default direction

    // Act
    n.setView(DataView.tracks);

    // Assert — both the field and the user's direction survive the switch.
    final s = container.read(dataFiltersProvider);
    expect(s.sortField, equals(DataSortField.lapCount));
    expect(s.sortAscending, isTrue);
  });

  test('activeCount — counts each active facet exactly once', () {
    // Arrange
    final n = container.read(dataFiltersProvider.notifier);

    // Act — three facets active (bike, lap-time, search)
    n.toggleBike('Trek');
    n.setLapTimeRange(const RangeValues(60_000, 120_000));
    n.setSearchText('whistler');

    // Assert
    expect(container.read(dataFiltersProvider).activeCount, equals(3));
  });
}
