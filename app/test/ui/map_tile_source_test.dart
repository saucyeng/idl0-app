import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/ui/tabs/analyze/map_tile_source.dart';

void main() {
  group('tileSpecsFor —', () {
    test('osmStandard — single layer with OSM URL template', () {
      // Arrange / Act
      final specs = tileSpecsFor(MapTileSource.osmStandard);

      // Assert
      expect(specs, hasLength(1));
      expect(specs.first.urlTemplate, contains('tile.openstreetmap.org'));
      expect(specs.first.attribution, contains('OpenStreetMap'));
      expect(specs.first.userAgentPackageName, isNotEmpty);
    });

    test('esriSatellite — single layer with World_Imagery path', () {
      // Arrange / Act
      final specs = tileSpecsFor(MapTileSource.esriSatellite);

      // Assert
      expect(specs, hasLength(1));
      expect(specs.first.urlTemplate, contains('World_Imagery'));
      expect(specs.first.attribution, contains('Esri'));
    });

    test('esriHybrid — two layers, satellite first, boundaries overlay second',
        () {
      // Arrange / Act
      final specs = tileSpecsFor(MapTileSource.esriHybrid);

      // Assert
      expect(specs, hasLength(2));
      expect(specs[0].urlTemplate, contains('World_Imagery'));
      expect(
        specs[1].urlTemplate,
        contains('World_Boundaries_and_Places'),
      );
    });

    test('every enum value — returns at least one spec', () {
      // Guard rail so adding a new enum entry without updating the helper
      // surfaces immediately rather than at runtime.
      for (final source in MapTileSource.values) {
        // Act
        final specs = tileSpecsFor(source);

        // Assert
        expect(
          specs,
          isNotEmpty,
          reason: 'tileSpecsFor must handle ${source.name}',
        );
      }
    });
  });
}
