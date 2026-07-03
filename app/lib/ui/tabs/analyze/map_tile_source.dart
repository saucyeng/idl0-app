/// Available basemap tile providers for the GPS map chart.
///
/// To add a provider (e.g. Mapbox, Google Map Tiles API), extend this enum
/// and add an entry to [tileSpecsFor]. No widget changes are required —
/// [GpsMapChart] reads the spec list and stacks one [TileLayer] per entry.
enum MapTileSource {
  /// OpenStreetMap standard raster tiles. Free, no key, includes contributor
  /// attribution. Default choice for MTB-trail content density.
  osmStandard,

  /// Esri World Imagery satellite raster tiles. Free for non-commercial use
  /// per Esri's terms, no key required.
  esriSatellite,

  /// Esri World Imagery + boundaries/labels overlay. The caller stacks both
  /// layers so labels render on top of the satellite imagery.
  esriHybrid,
}

/// One raster tile layer specification — URL template and required metadata.
///
/// Mirrors the subset of `flutter_map`'s `TileLayer` that varies between
/// providers; passed through to a `TileLayer` widget by the consumer.
class MapTileLayerSpec {
  /// Creates a [MapTileLayerSpec].
  const MapTileLayerSpec({
    required this.urlTemplate,
    required this.userAgentPackageName,
    required this.attribution,
  });

  /// `flutter_map` URL template, e.g.
  /// `https://tile.openstreetmap.org/{z}/{x}/{y}.png`.
  final String urlTemplate;

  /// Package identifier sent in the `User-Agent` header. OSM operators
  /// expect this to be a real app identifier so abuse can be traced.
  final String userAgentPackageName;

  /// Human-readable attribution string to display on the map.
  ///
  /// Tile providers' ToS require visible attribution; this string is what
  /// the GPS map chart shows in its corner attribution widget.
  final String attribution;
}

/// Returns the ordered list of tile-layer specs for [source].
///
/// Single-layer sources (OSM, Esri satellite alone) return one entry.
/// Hybrid sources return the base layer first, then any overlay layers
/// in render order — caller stacks them as separate `TileLayer` widgets.
List<MapTileLayerSpec> tileSpecsFor(MapTileSource source) {
  const userAgent = 'com.example.idl0';
  switch (source) {
    case MapTileSource.osmStandard:
      return const [
        MapTileLayerSpec(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: userAgent,
          attribution: '© OpenStreetMap contributors',
        ),
      ];
    case MapTileSource.esriSatellite:
      return const [
        MapTileLayerSpec(
          urlTemplate:
              'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
          userAgentPackageName: userAgent,
          attribution: 'Esri World Imagery',
        ),
      ];
    case MapTileSource.esriHybrid:
      return const [
        MapTileLayerSpec(
          urlTemplate:
              'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
          userAgentPackageName: userAgent,
          attribution: 'Esri World Imagery + Boundaries',
        ),
        MapTileLayerSpec(
          urlTemplate:
              'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
          userAgentPackageName: userAgent,
          attribution: 'Esri World Imagery + Boundaries',
        ),
      ];
  }
}
