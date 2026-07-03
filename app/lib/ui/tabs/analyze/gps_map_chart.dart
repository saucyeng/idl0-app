import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../data/cursor_lookup.dart';
import '../../../data/lap_detector.dart';
import '../../../data/lap_timing.dart';
import '../../../data/session_model.dart';
import '../../../data/track.dart';
import '../../../providers/channel_provider.dart';
import '../../../providers/cursor_provider.dart';
import '../../../providers/lap_provider.dart';
import '../../../providers/selection_provider.dart';
import '../../../providers/session_workspace_provider.dart';
import '../../../providers/track_provider.dart';
import '../../../src/rust/tracks.dart' show GpsFixArg;
import '../../brand/brand.dart';
import '../data/track_editor_modal.dart';
import 'map_tile_source.dart';
import 'tracks_popup.dart';
import 'turbo_colormap.dart';

/// Per-session polyline palette — the shared [brandChartPalette], so a session
/// keeps the same colour here as on the time-series / FFT / progression charts.
const List<Color> _sessionColors = brandChartPalette;

/// Scale factor to convert raw i32 GPS coordinates to decimal degrees.
///
/// Firmware stores lat/lon as integers × 1e7 (e.g. 51.5074° N → 515074000).
/// The GPX importer also multiplies by this factor so both sources render
/// identically; see §12.
const double _coordScale = 1e7;

/// Amber ([brandHivis]) for the primary lap-timing gate polylines.
const Color _lapGateColor = brandHivis;

/// Warm orange (the [brandChartPalette] orange) for sector-gate polylines —
/// distinct from the amber lap gate.
const Color _sectorGateColor = Color(0xFFE8964B);

/// Blue ([brandInfo]) for neutral-zone enter/exit gate polylines.
const Color _neutralZoneColor = brandInfo;

/// Width in logical pixels for lap-gate polylines.
const double _lapGateStrokeWidth = 8;

/// Width in logical pixels for sector-gate polylines.
const double _sectorGateStrokeWidth = 5;

/// Width in logical pixels for neutral-zone gate polylines.
const double _neutralZoneStrokeWidth = 5;

/// Min / max zoom levels for the map. flutter_map clamps to these via
/// [MapOptions], and the +/- zoom buttons clamp to the same range so the
/// UI stays consistent.
const double _minZoom = 1;
const double _maxZoom = 19;

/// Renders GPS track data from selected sessions as polylines on a raster
/// basemap, renders read-only Track gate overlays for all detected
/// [TrackVisit]s, and provides a "Tracks…" toolbar button that opens the
/// [TracksPopup]. When the user selects "Create new Track…",
/// [TrackEditorModal.createFromSessionAndShow] is called directly.
///
/// Gate placement / drag / delete UI has been removed. All gate editing
/// is done via the Track editor modal, accessed through the Tracks… button.
///
/// Sources each session's polyline from the engine via [gpsTrackProvider] (the
/// handle's fix list — lat/lon/`timestampMs`, no-fix sentinels already dropped).
/// Each session is drawn as a separate [Polyline] in a distinct colour. When no
/// session has GPS fixes the widget shows an informational message.
///
/// Tile basemap is selectable via the top-right [SegmentedButton]:
/// OSM | Esri satellite | Esri satellite + labels. See [map_tile_source.dart].
///
/// Camera is fitted to the bounding box of all coordinates on first build
/// via [MapOptions.initialCameraFit].
class GpsMapChart extends ConsumerStatefulWidget {
  /// Creates a [GpsMapChart].
  const GpsMapChart({
    super.key,
    required this.selectedIds,
    this.channelColors = const {},
    this.worksheetId,
    this.colorChannelId,
    this.colorMin,
    this.colorMax,
  });

  /// Session UUIDs currently selected in the Analyze tab.
  final Set<String> selectedIds;

  /// Per-session polyline colour overrides keyed by session UUID, as ARGB ints.
  ///
  /// Sessions absent from this map use the auto-assigned palette colour.
  final Map<String, int> channelColors;

  /// Worksheet UUID — used to read/write [cursorProvider] for cross-chart
  /// cursor sync. When null (e.g. previews/tests) cursor markers and
  /// tap-to-set-cursor are disabled.
  final String? worksheetId;

  /// Channel id colouring the trace as a Turbo heatmap, or null for solid
  /// per-session colours.
  final String? colorChannelId;

  /// Manual lower colour-scale bound for the heatmap; null ⇒ auto (shared min
  /// across every visible trace).
  final double? colorMin;

  /// Manual upper colour-scale bound for the heatmap; null ⇒ auto (shared max
  /// across every visible trace).
  final double? colorMax;

  @override
  ConsumerState<GpsMapChart> createState() => _GpsMapChartState();
}

class _GpsMapChartState extends ConsumerState<GpsMapChart> {
  final MapController _mapController = MapController();

  /// Active basemap. OSM is the default — best MTB-trail data among the
  /// no-key options.
  MapTileSource _tileSource = MapTileSource.osmStandard;

  /// Last time the map hover handler wrote to [hoverCursorProvider]. Used
  /// to throttle to ~30 Hz — raw mouse-move can fire on every pixel of
  /// motion, and each write rebuilds every chart subscribing to the
  /// provider.
  DateTime _lastMapHoverWrite = DateTime.fromMillisecondsSinceEpoch(0);

  /// Active session for lap-count queries and track creation — the first
  /// session in [widget.selectedIds]. `null` when no sessions are selected.
  String? get _activeSessionId =>
      widget.selectedIds.isEmpty ? null : widget.selectedIds.first;

  /// Returns the windowed lap for [sessionId] when a single lap is in focus
  /// (either via the Analyze-tab lap-table M checkbox or the Data-tab
  /// single-lap selection); null otherwise. Mirrors the time-series chart's
  /// resolution in `chart_workspace._resolveLapPairChannels`. Polyline clipping
  /// uses the lap's absolute `start`/`endTimestampMs` directly against each
  /// fix's `timestampMs`; cursor rebasing converts those to session-relative
  /// seconds with the GPS-track view's `startEpochMs`.
  Lap? _activeLapFor(String sessionId) {
    if (widget.selectedIds.length != 1 ||
        widget.selectedIds.first != sessionId) {
      return null;
    }
    final ws = ref.watch(sessionWorkspaceProvider(sessionId)).valueOrNull;
    if (ws == null) return null;
    int? mainLapNum = ws.mainLapNumber;
    if (mainLapNum == null) {
      final selection = ref.watch(selectionProvider);
      if (selection.mode == SelectionMode.lap) {
        final lapsForThisSession =
            selection.lapKeys.where((k) => k.sessionId == sessionId).toList();
        if (lapsForThisSession.length == 1) {
          mainLapNum = lapsForThisSession.first.lapNumber;
        }
      }
    }
    if (mainLapNum == null) return null;
    final laps = ref.watch(sessionLapsProvider(sessionId)).valueOrNull;
    if (laps == null) return null;
    return laps.where((l) => l.lapNumber == mainLapNum).firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final activeId = _activeSessionId;

    final trackPolylines = <Polyline>[];
    LatLngBounds? bounds;

    // Heatmap mode: resolve each session's per-fix channel values and the
    // shared colour scale. Manual bounds win; otherwise auto min/max folded
    // across every visible trace, ignoring NaN. perFixValues is aligned 1:1 to
    // each session's gpsTrackProvider fix list (both come from build_gps_track).
    final colorChannelId = widget.colorChannelId;
    final perFixValues = <String, List<double>>{};
    double? autoMin;
    double? autoMax;
    if (colorChannelId != null) {
      for (final sessionId in widget.selectedIds) {
        final key = (sessionId: sessionId, channelId: colorChannelId);
        final vals = ref.watch(gpsChannelValuesProvider(key)).valueOrNull;
        if (vals == null) continue;
        perFixValues[sessionId] = vals;
        for (final v in vals) {
          if (v.isNaN || v.isInfinite) continue;
          if (autoMin == null || v < autoMin) autoMin = v;
          if (autoMax == null || v > autoMax) autoMax = v;
        }
      }
    }
    final scaleMin = widget.colorMin ?? autoMin;
    final scaleMax = widget.colorMax ?? autoMax;
    final scaleSpan =
        (scaleMin != null && scaleMax != null && scaleMax > scaleMin)
            ? scaleMax - scaleMin
            : null;
    final heatmapActive = colorChannelId != null && scaleSpan != null;

    var sessionIndex = 0;
    for (final sessionId in widget.selectedIds) {
      final view = ref.watch(gpsTrackProvider(sessionId)).valueOrNull;
      if (view == null || view.fixes.isEmpty) {
        sessionIndex++;
        continue;
      }

      // If a single lap is windowed for this session, clip the polyline to the
      // lap's absolute time range — each fix carries its `timestampMs`, so we
      // clip by timestamp rather than sample index (the engine fix list drops
      // no-fix sentinels, so index math no longer aligns). Otherwise render the
      // full track.
      final lap = _activeLapFor(sessionId);
      final colorOverride = widget.channelColors[sessionId];
      final sessionColor = colorOverride != null
          ? Color(colorOverride)
          : _sessionColors[sessionIndex % _sessionColors.length];

      // Heatmap: colour each retained fix by its channel value. `vals` is
      // aligned to the *unfiltered* fix list, so iterate fixes with a running
      // index and apply the same lap clip used for the solid path below.
      final vals = perFixValues[sessionId];
      if (heatmapActive && vals != null) {
        final gradPoints = <LatLng>[];
        final gradColors = <Color>[];
        for (var i = 0; i < view.fixes.length; i++) {
          final f = view.fixes[i];
          if (lap != null &&
              (f.timestampMs < lap.startTimestampMs ||
                  f.timestampMs > lap.endTimestampMs)) {
            continue;
          }
          gradPoints.add(LatLng(f.lat / _coordScale, f.lon / _coordScale));
          final v = i < vals.length ? vals[i] : double.nan;
          final t = (v - scaleMin!) / scaleSpan;
          gradColors.add(
            turboColor(t, noData: sessionColor.withValues(alpha: 0.25)),
          );
        }
        if (gradPoints.length >= 2) {
          // flutter_map's `gradientColors` paints ONE straight-line screen-space
          // gradient from the first to the last point (`ui.Gradient.linear`),
          // distributing the colours by even fraction along that axis — it does
          // NOT map colour[i] to vertex[i], so it reprojects the time-ordered
          // per-fix colours onto the start→end line (high-speed colours bunch in
          // the middle). Draw one solid-colour segment per consecutive fix pair
          // instead, so each colour lands on its actual track position.
          for (var s = 0; s + 1 < gradPoints.length; s++) {
            trackPolylines.add(
              Polyline(
                points: [gradPoints[s], gradPoints[s + 1]],
                color: gradColors[s],
                strokeWidth: 4,
              ),
            );
          }
          bounds = _expandBounds(bounds, gradPoints);
        }
        sessionIndex++;
        continue;
      }

      // Solid mode: one colour for the whole (optionally lap-clipped) track.
      final points = <LatLng>[];
      for (final f in view.fixes) {
        if (lap != null &&
            (f.timestampMs < lap.startTimestampMs ||
                f.timestampMs > lap.endTimestampMs)) {
          continue;
        }
        points.add(LatLng(f.lat / _coordScale, f.lon / _coordScale));
      }
      if (points.isEmpty) {
        sessionIndex++;
        continue;
      }
      trackPolylines.add(
        Polyline(
          points: points,
          color: sessionColor,
          strokeWidth: 3,
        ),
      );

      bounds = _expandBounds(bounds, points);

      sessionIndex++;
    }

    if (trackPolylines.isEmpty) {
      return Center(
        child: Text(
          'No GPS data in this session.',
          style: plexMono(fontSize: 12, color: brandFgDim),
        ),
      );
    }

    // Read-only Track gate overlays from detected TrackVisits.
    final gatePolylines = <Polyline>[];
    final gateMarkers = <Marker>[];
    if (activeId != null) {
      final wsAsync = ref.watch(sessionWorkspaceProvider(activeId));
      final tracksAsync = ref.watch(trackProvider);
      wsAsync.whenData((ws) {
        tracksAsync.whenData((tracks) {
          for (final visit in ws.trackVisits) {
            final track =
                tracks.where((t) => t.trackId == visit.trackId).firstOrNull;
            if (track == null) continue;
            _addTrackGateOverlays(track, gatePolylines, gateMarkers);
          }
        });
      });
    }

    // Cursor markers — one per session per visible cursor. Active cursor
    // (A) wins over hover so a clicked cursor stays put when the user
    // moves the mouse to another chart; hover is only a preview when
    // nothing is pinned. Datum cursor (B) is rendered alongside as a
    // second marker so the user can compare two track positions at once.
    final cursorMarkers = <Marker>[];
    final wsId = widget.worksheetId;
    if (wsId != null) {
      final pair = ref.watch(cursorProvider(wsId));
      final hover = ref.watch(hoverCursorProvider(wsId));
      final activeSeconds = pair.aSecs ?? hover;
      // (cursor seconds, isDatum) tuples in render order — active first
      // so the datum marker draws on top when both coincide.
      final cursors = <({double seconds, bool isDatum})>[
        if (activeSeconds != null) (seconds: activeSeconds, isDatum: false),
        if (pair.bSecs != null) (seconds: pair.bSecs!, isDatum: true),
      ];
      for (final cursor in cursors) {
        var idx = 0;
        for (final sessionId in widget.selectedIds) {
          final view = ref.watch(gpsTrackProvider(sessionId)).valueOrNull;
          if (view != null && view.fixes.isNotEmpty) {
            // When a lap is windowed for this session, the cursor's seconds
            // value is lap-relative (the time-series chart's x-axis is
            // rebased to 0 at lap start). Convert back to session-relative
            // before looking up the GPS fix.
            final lap = _activeLapFor(sessionId);
            final lapStartSec = lap == null
                ? null
                : (lap.startTimestampMs - view.startEpochMs) / 1000.0;
            final lookupSeconds = lapStartSec == null
                ? cursor.seconds
                : cursor.seconds + lapStartSec;
            final pos = _gpsAtCursor(
              view.fixes,
              view.startEpochMs,
              lookupSeconds,
            );
            if (pos != null) {
              final overrideArgb = widget.channelColors[sessionId];
              final sessionColor = overrideArgb != null
                  ? Color(overrideArgb)
                  : _sessionColors[idx % _sessionColors.length];
              // Active cursor = the session's own colour ring on a warm
              // off-white disc. Datum cursor = amber ([brandHivis]) disc with
              // a dark ([brandBg]) ring, so the two are distinguishable on the
              // map without a legend.
              final fillColor = cursor.isDatum ? brandHivis : brandFg;
              final ringColor = cursor.isDatum ? brandBg : sessionColor;
              cursorMarkers.add(
                Marker(
                  point: pos,
                  width: 18,
                  height: 18,
                  child: Container(
                    decoration: BoxDecoration(
                      color: fillColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: ringColor, width: 3),
                    ),
                  ),
                ),
              );
            }
          }
          idx++;
        }
      }
    }

    final tileSpecs = tileSpecsFor(_tileSource);
    final attributionText = tileSpecs.last.attribution;

    return Stack(
      children: [
        MouseRegion(
          // Hover updates the worksheet hover cursor — the time-series and
          // ghost charts subscribe to the same provider and move their
          // cursor lines in sync. Throttled to ~30 Hz internally because
          // raw mouse-move can fire every pixel of motion. onExit clears
          // hover so the pinned cursor takes back over.
          onHover: (e) => _onMapHover(e.localPosition),
          onExit: (_) => _clearMapHover(),
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _boundsCenter(bounds!),
              initialZoom: 14,
              minZoom: _minZoom,
              maxZoom: _maxZoom,
              initialCameraFit: CameraFit.bounds(
                bounds: bounds,
                padding: const EdgeInsets.all(32),
              ),
              onTap: (tapPosition, point) => _setCursorFromMapTap(point),
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.drag |
                    InteractiveFlag.pinchZoom |
                    InteractiveFlag.doubleTapZoom |
                    InteractiveFlag.flingAnimation,
              ),
            ),
            children: [
              for (final spec in tileSpecs)
                TileLayer(
                  urlTemplate: spec.urlTemplate,
                  userAgentPackageName: spec.userAgentPackageName,
                ),
              PolylineLayer(
                polylines: [
                  ...trackPolylines,
                  ...gatePolylines,
                ],
              ),
              MarkerLayer(
                markers: [...gateMarkers, ...cursorMarkers],
              ),
            ],
          ),
        ),
        // Bottom-right: zoom controls (above the attribution badge).
        Positioned(
          right: 8,
          bottom: 24,
          child: _ZoomButtons(
            onZoomIn: () => _zoomBy(1),
            onZoomOut: () => _zoomBy(-1),
          ),
        ),
        // Bottom-right: attribution.
        Positioned(
          right: 4,
          bottom: 4,
          child: _AttributionBadge(text: attributionText),
        ),
        // Bottom-left: Turbo colour-scale legend (heatmap mode only).
        if (colorChannelId != null &&
            scaleMin != null &&
            scaleMax != null &&
            scaleSpan != null)
          Positioned(
            left: 8,
            bottom: 24,
            child: _ColorBarLegend(
              label: colorChannelId,
              min: scaleMin,
              max: scaleMax,
            ),
          ),
        // Top-right: layer toggle + Tracks button.
        Positioned(
          right: 8,
          top: 8,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _LayerToggle(
                source: _tileSource,
                onChanged: (next) => setState(() => _tileSource = next),
              ),
              const SizedBox(height: 6),
              _TracksButton(
                enabled: activeId != null,
                onPressed: () => _openTracksPopup(context, activeId: activeId),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // Track gate overlays (read-only)
  // --------------------------------------------------------------------------

  /// Adds read-only gate polylines and flag markers for [track] to [polylines]
  /// and [markers]. Renders:
  /// - `lapTiming` gates (Circuit → startFinish; PointToPoint → start + finish)
  ///   in orange, with green flag icons at each post.
  /// - `sectorGates` in yellow — polylines only, no flags.
  /// - `neutralZones` enter + exit in cyan, with white flag icons at each post.
  ///
  /// Flag markers use [Alignment.bottomCenter] so the icon rises above the
  /// gate post coordinate rather than obscuring it.
  void _addTrackGateOverlays(
    Track track,
    List<Polyline> polylines,
    List<Marker> markers,
  ) {
    /// Adds one 24×24 [flagIcon] marker at each endpoint of [gate].
    void addEndpointFlags(LapGate gate, Widget flagIcon) {
      for (final point in _gatePoints(gate)) {
        markers.add(
          Marker(
            point: point,
            width: 24,
            height: 24,
            alignment: Alignment.bottomCenter,
            child: flagIcon,
          ),
        );
      }
    }

    const Widget greenFlag = Icon(
      Icons.flag,
      color: brandGood,
      size: 20,
      shadows: [Shadow(color: Colors.black54, blurRadius: 2)],
    );
    const Widget checkeredFlag = Icon(
      Icons.sports_score,
      color: brandFg,
      size: 20,
      shadows: [Shadow(color: Colors.black54, blurRadius: 2)],
    );
    const Widget whiteFlag = Icon(
      Icons.flag,
      color: brandFg,
      size: 20,
      shadows: [Shadow(color: Colors.black54, blurRadius: 2)],
    );

    final timing = track.lapTiming;
    if (timing != null) {
      switch (timing) {
        case Circuit(:final startFinish):
          polylines.add(
            Polyline(
              points: _gatePoints(startFinish),
              color: _lapGateColor,
              strokeWidth: _lapGateStrokeWidth,
            ),
          );
          // Two green flags — one at each post of the start/finish gate.
          addEndpointFlags(startFinish, greenFlag);
        case PointToPoint(:final start, :final finish):
          polylines.add(
            Polyline(
              points: _gatePoints(start),
              color: _lapGateColor,
              strokeWidth: _lapGateStrokeWidth,
            ),
          );
          polylines.add(
            Polyline(
              points: _gatePoints(finish),
              color: _lapGateColor,
              strokeWidth: _lapGateStrokeWidth,
            ),
          );
          // Two green flags at start posts; two checkered flags at finish posts.
          addEndpointFlags(start, greenFlag);
          addEndpointFlags(finish, checkeredFlag);
      }
    }

    for (final sg in track.sectorGates) {
      // Sector gates: yellow polyline only — no flags per spec.
      polylines.add(
        Polyline(
          points: _gatePoints(sg.gate),
          color: _sectorGateColor,
          strokeWidth: _sectorGateStrokeWidth,
        ),
      );
    }

    for (final zone in track.neutralZones) {
      polylines.add(
        Polyline(
          points: _gatePoints(zone.enter),
          color: _neutralZoneColor,
          strokeWidth: _neutralZoneStrokeWidth,
        ),
      );
      polylines.add(
        Polyline(
          points: _gatePoints(zone.exit),
          color: _neutralZoneColor,
          strokeWidth: _neutralZoneStrokeWidth,
        ),
      );
      // Two white flags at each neutral-zone gate's posts (enter and exit).
      addEndpointFlags(zone.enter, whiteFlag);
      addEndpointFlags(zone.exit, whiteFlag);
    }
  }

  // --------------------------------------------------------------------------
  // Tracks popup flow
  // --------------------------------------------------------------------------

  /// Opens [TracksPopup] populated with every Track visited in [activeId]'s
  /// session, each paired with its lap count (from [visitLapsProvider]).
  /// When the user selects "Create new Track…",
  /// [TrackEditorModal.createFromSessionAndShow] is called directly.
  Future<void> _openTracksPopup(
    BuildContext context, {
    required String? activeId,
  }) async {
    if (activeId == null) return;

    // Build entries: visited Tracks paired with lap counts.
    final entries = await _buildTracksWithLapCounts(activeId);

    if (!context.mounted) return;
    final result = await TracksPopup.show(
      context,
      tracksWithLapCounts: entries,
    );
    if (result is TracksPopupCreateNew) {
      if (!context.mounted) return;
      await TrackEditorModal.createFromSessionAndShow(context, ref, activeId);
    }
  }

  /// Returns a list of `(track, lapCount)` pairs for all TrackVisits in
  /// [sessionId]. Reads [sessionWorkspaceProvider] and [trackProvider]
  /// synchronously from ref — both are already watched in build, so their
  /// cached values are available.
  Future<List<({Track track, int lapCount})>> _buildTracksWithLapCounts(
    String sessionId,
  ) async {
    final wsAsync = ref.read(sessionWorkspaceProvider(sessionId));
    if (!wsAsync.hasValue) return const [];
    final ws = wsAsync.requireValue;

    final tracks = ref.read(trackProvider).value ?? const [];
    final trackMap = {for (final t in tracks) t.trackId: t};

    final out = <({Track track, int lapCount})>[];
    for (final visit in ws.trackVisits) {
      final track = trackMap[visit.trackId];
      if (track == null) continue;

      // Read lap count from visitLapsProvider if already resolved.
      final lapValue = ref.read(
        visitLapsProvider((sessionId: sessionId, visitId: visit.visitId)),
      );
      final lapCount = lapValue.value?.length ?? 0;
      out.add((track: track, lapCount: lapCount));
    }
    return out;
  }

  // --------------------------------------------------------------------------
  // Zoom controls
  // --------------------------------------------------------------------------

  void _zoomBy(double delta) {
    final cam = _mapController.camera;
    final newZoom = (cam.zoom + delta).clamp(_minZoom, _maxZoom);
    if (newZoom == cam.zoom) return;
    _mapController.move(cam.center, newZoom);
  }

  // --------------------------------------------------------------------------
  // Cursor sync
  // --------------------------------------------------------------------------

  /// Returns the GPS [LatLng] for the fix whose `timestampMs` is closest to
  /// `startEpochMs + cursorSeconds * 1000`, or `null` when [fixes] is empty.
  /// [fixes] is the engine fix list (sentinels already dropped) at the raw
  /// degrees × 1e7 scale; [startEpochMs] is the session-relative-seconds origin.
  LatLng? _gpsAtCursor(
    List<GpsFixArg> fixes,
    double startEpochMs,
    double cursorSeconds,
  ) {
    if (fixes.isEmpty) return null;
    final targetMs = cursorEpochMs(
      sessionStartMs: startEpochMs,
      cursorSeconds: cursorSeconds,
    );
    final idx = nearestEpochIndex(
      [for (final f in fixes) f.timestampMs.toDouble()],
      targetMs,
    );
    if (idx < 0) return null;
    final f = fixes[idx];
    return LatLng(f.lat / _coordScale, f.lon / _coordScale);
  }

  /// Sets the worksheet cursor to the GPS sample of the primary session
  /// (first in [widget.selectedIds]) closest to [tapPoint].
  void _setCursorFromMapTap(LatLng tapPoint) {
    final wsId = widget.worksheetId;
    if (wsId == null) return;
    final cursor = _cursorSecondsForLatLng(tapPoint);
    if (cursor == null) return;
    ref.read(cursorProvider(wsId).notifier).setA(cursor);
  }

  /// MouseRegion onHover handler for the map. Converts the pointer's
  /// pixel position to a LatLng via the active map camera, finds the
  /// nearest GPS sample of the primary session, and writes its session-
  /// relative seconds to [hoverCursorProvider].
  ///
  /// Throttled to ~30 Hz — raw mouse motion can fire dozens of events per
  /// 16 ms frame, and each provider write rebuilds every chart subscribed
  /// to the worksheet hover cursor.
  void _onMapHover(Offset localPosition) {
    final wsId = widget.worksheetId;
    if (wsId == null) return;
    final now = DateTime.now();
    if (now.difference(_lastMapHoverWrite) < const Duration(milliseconds: 33)) {
      return;
    }
    _lastMapHoverWrite = now;

    final latLng = _mapController.camera.pointToLatLng(
      math.Point<double>(localPosition.dx, localPosition.dy),
    );
    final cursor = _cursorSecondsForLatLng(latLng);
    if (cursor == null) return;
    ref.read(hoverCursorProvider(wsId).notifier).state = cursor;
  }

  /// Clears [hoverCursorProvider] when the pointer leaves the map so the
  /// pinned cursor takes back over.
  void _clearMapHover() {
    final wsId = widget.worksheetId;
    if (wsId == null) return;
    ref.read(hoverCursorProvider(wsId).notifier).state = null;
  }

  /// Looks up the GPS sample of the primary session closest to [point]
  /// (squared flat-earth distance in raw lat/lon units) and returns its
  /// timestamp in session-relative seconds, or null when GPS data is
  /// missing for the active session.
  double? _cursorSecondsForLatLng(LatLng point) {
    final activeId = _activeSessionId;
    if (activeId == null) return null;
    final view = ref.read(gpsTrackProvider(activeId)).valueOrNull;
    if (view == null || view.fixes.isEmpty) return null;
    final fixes = view.fixes;

    var bestIdx = -1;
    var bestDist2 = double.infinity;
    final tx = point.latitude;
    final ty = point.longitude;
    for (var i = 0; i < fixes.length; i++) {
      final la = fixes[i].lat / _coordScale;
      final lo = fixes[i].lon / _coordScale;
      final dx = la - tx;
      final dy = ty - lo; // sign doesn't matter for distance²
      final d2 = dx * dx + dy * dy;
      if (d2 < bestDist2) {
        bestDist2 = d2;
        bestIdx = i;
      }
    }
    if (bestIdx < 0) return null;

    final sessionSeconds = cursorSecondsFromEpoch(
      sessionStartMs: view.startEpochMs,
      sampleEpochMs: fixes[bestIdx].timestampMs.toDouble(),
    );
    // When a lap is windowed for the active session, the time-series chart
    // expects lap-relative cursor seconds. Convert by subtracting the lap
    // window's start offset.
    final lap = _activeLapFor(activeId);
    if (lap == null) return sessionSeconds;
    final lapStartSec = (lap.startTimestampMs - view.startEpochMs) / 1000.0;
    return sessionSeconds - lapStartSec;
  }

  // --------------------------------------------------------------------------
  // Geometry helpers
  // --------------------------------------------------------------------------

  /// Two LatLng points for [gate], converting from the firmware × 1e7 scale.
  static List<LatLng> _gatePoints(LapGate gate) => [
        LatLng(gate.lat1Deg / _coordScale, gate.lon1Deg / _coordScale),
        LatLng(gate.lat2Deg / _coordScale, gate.lon2Deg / _coordScale),
      ];

  /// Expands [current] to include all [points], or returns a new tight bounds.
  static LatLngBounds _expandBounds(
    LatLngBounds? current,
    List<LatLng> points,
  ) {
    if (current == null) {
      return LatLngBounds.fromPoints(points);
    }
    var minLat = current.south;
    var maxLat = current.north;
    var minLon = current.west;
    var maxLon = current.east;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    return LatLngBounds(
      LatLng(minLat, minLon),
      LatLng(maxLat, maxLon),
    );
  }

  static LatLng _boundsCenter(LatLngBounds b) => LatLng(
        (b.south + b.north) / 2,
        (b.west + b.east) / 2,
      );
}

// ---------------------------------------------------------------------------
// Layer toggle (Map / Satellite / Hybrid)
// ---------------------------------------------------------------------------

class _LayerToggle extends StatelessWidget {
  const _LayerToggle({required this.source, required this.onChanged});

  final MapTileSource source;
  final ValueChanged<MapTileSource> onChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: brandSurface,
        borderRadius: BorderRadius.circular(brandControlRadiusSoft),
        border: Border.all(color: brandRule, width: brandHairlineWidth),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: SegmentedButton<MapTileSource>(
          style: ButtonStyle(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            padding: WidgetStateProperty.all(
              const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            ),
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? brandControlActive
                  : brandControlFill,
            ),
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) =>
                  states.contains(WidgetState.selected) ? brandFg : brandFgDim,
            ),
            side: WidgetStateProperty.all(
              const BorderSide(color: brandRule, width: brandHairlineWidth),
            ),
            textStyle: WidgetStateProperty.all(
              plexMono(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: brandLabelTracking,
              ),
            ),
          ),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: MapTileSource.osmStandard,
              label: Text('MAP'),
            ),
            ButtonSegment(
              value: MapTileSource.esriSatellite,
              label: Text('SAT'),
            ),
            ButtonSegment(
              value: MapTileSource.esriHybrid,
              label: Text('HYBRID'),
            ),
          ],
          selected: {source},
          onSelectionChanged: (set) => onChanged(set.first),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tracks button
// ---------------------------------------------------------------------------

/// Toolbar button that opens the "Tracks…" popup. Lists visited Tracks
/// and offers a "Create new Track…" entry that opens [TrackEditorModal].
class _TracksButton extends StatelessWidget {
  const _TracksButton({required this.enabled, required this.onPressed});

  /// False when no session is active.
  final bool enabled;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      shape: const CircleBorder(
        side: BorderSide(color: brandRule, width: brandHairlineWidth),
      ),
      color: enabled ? brandControlActive : brandControlFill,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onPressed : null,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            Icons.terrain,
            size: 20,
            color: enabled ? brandFg : brandFgDim,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Attribution badge
// ---------------------------------------------------------------------------

class _AttributionBadge extends StatelessWidget {
  const _AttributionBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: brandBg.withValues(alpha: 0.6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          text,
          style: plexMono(fontSize: 9, color: brandFgDim),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Zoom buttons (bottom-right)
// ---------------------------------------------------------------------------

class _ZoomButtons extends StatelessWidget {
  const _ZoomButtons({required this.onZoomIn, required this.onZoomOut});

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;

  @override
  Widget build(BuildContext context) {
    const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(brandControlRadiusSoft)),
      side: BorderSide(color: brandRule, width: brandHairlineWidth),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton.small(
          heroTag: null,
          onPressed: onZoomIn,
          tooltip: 'Zoom in',
          backgroundColor: brandSurface,
          foregroundColor: brandFg,
          elevation: 2,
          shape: shape,
          child: const Icon(Icons.add),
        ),
        const SizedBox(height: 6),
        FloatingActionButton.small(
          heroTag: null,
          onPressed: onZoomOut,
          tooltip: 'Zoom out',
          backgroundColor: brandSurface,
          foregroundColor: brandFg,
          elevation: 2,
          shape: shape,
          child: const Icon(Icons.remove),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Colour-scale legend (bottom-left, heatmap mode)
// ---------------------------------------------------------------------------

/// Vertical Turbo colour scale + min/max labels for the GPS heatmap, showing
/// the channel name and the active scale range.
class _ColorBarLegend extends StatelessWidget {
  const _ColorBarLegend({
    required this.label,
    required this.min,
    required this.max,
  });

  final String label;
  final double min;
  final double max;

  @override
  Widget build(BuildContext context) {
    // 24 Turbo stops, low (bottom) → high (top).
    final stops = [for (var i = 0; i < 24; i++) turboColor(i / 23.0)];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: brandBg.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(brandControlRadiusSoft),
        border: Border.all(color: brandRule, width: brandHairlineWidth),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 80,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                border: Border.all(color: brandRule, width: brandHairlineWidth),
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: stops,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  max.toStringAsFixed(1),
                  style: plexMono(fontSize: 10, color: brandFg),
                ),
                SizedBox(
                  height: 56,
                  child: Center(
                    child: Text(
                      label,
                      style: plexMono(fontSize: 9, color: brandFgDim),
                    ),
                  ),
                ),
                Text(
                  min.toStringAsFixed(1),
                  style: plexMono(fontSize: 10, color: brandFg),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
