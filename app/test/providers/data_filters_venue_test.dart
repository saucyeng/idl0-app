import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/data_filters_provider.dart';

void main() {
  test('toggleVenue — adds and removes from venues set', () {
    // Arrange
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(dataFiltersProvider.notifier);

    // Act / Assert — add first
    notifier.toggleVenue('Whistler');
    expect(container.read(dataFiltersProvider).venues, {'Whistler'});

    // Act / Assert — add second
    notifier.toggleVenue('Squamish');
    expect(
      container.read(dataFiltersProvider).venues,
      {'Whistler', 'Squamish'},
    );

    // Act / Assert — remove first
    notifier.toggleVenue('Whistler');
    expect(container.read(dataFiltersProvider).venues, {'Squamish'});
  });

  test('hasAnyActiveFilter / activeCount include venues', () {
    // Arrange
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final n = container.read(dataFiltersProvider.notifier);

    // Act
    n.toggleVenue('Whistler');
    final s = container.read(dataFiltersProvider);

    // Assert
    expect(s.hasAnyActiveFilter, isTrue);
    expect(s.activeCount, 1);
  });

  test('clearAll — drops venues alongside other facets', () {
    // Arrange
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final n = container.read(dataFiltersProvider.notifier);
    n.toggleVenue('Whistler');
    n.toggleBike('V10');

    // Act
    n.clearAll();

    // Assert
    expect(container.read(dataFiltersProvider).venues, isEmpty);
  });
}
