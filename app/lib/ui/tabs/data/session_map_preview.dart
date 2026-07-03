import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../data/lap_detector.dart' show GpsFix;
import '../../../providers/session_gps_preview_provider.dart';
import '../../brand/brand.dart';
import '../analyze/map_tile_source.dart';

/// Scale factor — GPS fixes are stored as degrees × 1e7. Matches the
/// conversion used by the track editor and the Analyze GPS map chart.
const double _coordScale = 1e7;

/// A small, non-interactive GPS map thumbnail for a session.
///
/// Shown at the top of the Data-tab detail card so the user can recognise
/// *where* a session was recorded before naming a Track (SPEC §24). Reuses the
/// app basemap (`tileSpecsFor`) and the session polyline from
/// [sessionGpsPreviewProvider]. Renders a spinner while the session parses, a
/// "No GPS data" placeholder when the session has no GPS, and "Map unavailable"
/// on a parse error.
class SessionMapPreview extends ConsumerWidget {
  /// Creates a [SessionMapPreview].
  const SessionMapPreview({super.key, required this.sessionId});

  /// Session whose GPS polyline is previewed.
  final String sessionId;

  /// Fixed thumbnail height in logical pixels.
  static const double _height = 160;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sessionGpsPreviewProvider(sessionId));
    final radius = BorderRadius.circular(brandControlRadius);
    return ClipRRect(
      borderRadius: radius,
      child: Container(
        height: _height,
        decoration: BoxDecoration(
          color: brandSurface2,
          border: Border.all(color: brandRule, width: brandHairlineWidth),
          borderRadius: radius,
        ),
        child: async.when(
          loading: () => const Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: brandFgDim,
              ),
            ),
          ),
          error: (e, _) => Center(
            child: Text(
              'Map unavailable',
              style: plexMono(fontSize: 12, color: brandFgDim),
            ),
          ),
          data: (fixes) => fixes.isEmpty
              ? Center(
                  child: Text(
                    'No GPS data',
                    style: plexMono(fontSize: 12, color: brandFgFaint),
                  ),
                )
              : _map(fixes),
        ),
      ),
    );
  }

  Widget _map(List<GpsFix> fixes) {
    final points = [
      for (final f in fixes)
        LatLng(f.latitudeDeg / _coordScale, f.longitudeDeg / _coordScale),
    ];
    final tileSpecs = tileSpecsFor(MapTileSource.osmStandard);
    // IgnorePointer + InteractiveFlag.none keep the thumbnail fully static.
    return IgnorePointer(
      child: FlutterMap(
        options: MapOptions(
          initialCameraFit: CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(points),
            padding: const EdgeInsets.all(20),
          ),
          initialCenter: const LatLng(0, 0),
          initialZoom: 14,
          interactionOptions:
              const InteractionOptions(flags: InteractiveFlag.none),
        ),
        children: [
          for (final spec in tileSpecs)
            TileLayer(
              urlTemplate: spec.urlTemplate,
              userAgentPackageName: spec.userAgentPackageName,
            ),
          PolylineLayer(
            polylines: [
              Polyline(points: points, color: brandInfo, strokeWidth: 3),
            ],
          ),
        ],
      ),
    );
  }
}
