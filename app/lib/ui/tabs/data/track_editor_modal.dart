import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_dragmarker/flutter_map_dragmarker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../data/lap_detector.dart';
import '../../../data/lap_timing.dart';
import '../../../data/track.dart';
import '../../../data/track_artifact_io.dart';
import '../../../data/track_matching_bridge.dart';
import '../../../providers/channel_provider.dart';
import '../../../providers/runs_provider.dart';
import '../../../providers/track_provider.dart';
import '../../../src/rust/lib.dart' as rust;
import '../../../src/rust/tracks.dart' as rust;
import '../analyze/map_tile_source.dart';
import 'track_editor_lap_timing_tabs.dart';
import 'track_editor_neutral_zone_list.dart';
import 'track_editor_sector_list.dart';
import 'track_editor_sidebar.dart';

// ---------------------------------------------------------------------------
// Scale factor — firmware / GPX stores lat/lon as degrees × 1e7.
// ---------------------------------------------------------------------------

/// Scale factor to convert raw i32 GPS coordinates (degrees × 1e7) to
/// decimal degrees. Matches the value used in [GpsMapChart].
const double _coordScale = 1e7;

// ---------------------------------------------------------------------------
// Colour / stroke constants
// ---------------------------------------------------------------------------

/// Orange used for the lap-timing gate polylines.
const Color _lapGateColor = Color(0xFFFF6F00);

/// Yellow used for sector gate polylines.
const Color _sectorGateColor = Color(0xFFFFD600);

/// Red used for neutral-zone gate polylines.
const Color _neutralGateColor = Color(0xFFF44336);

/// Stroke width in logical pixels for gate polylines.
const double _gateStrokeWidth = 5;

/// Zoom limits for the embedded map.
const double _minZoom = 1;
const double _maxZoom = 19;

// ---------------------------------------------------------------------------
// Gate reference — identifies a single gate within the draft Track
// ---------------------------------------------------------------------------

/// Identifies one gate within the draft Track for drag-to-move purposes.
///
/// Each [_GateRef] is paired with an endpoint index (0 = post 1, 1 = post 2)
/// when building [DragMarker]s.  [_updateGateEndpoint] switches on the ref to
/// produce the correctly-updated [_draft].
sealed class _GateRef {
  const _GateRef();
}

/// The Circuit's single start/finish gate, or the P2P start gate.
class _LapTimingStart extends _GateRef {
  const _LapTimingStart();
}

/// The P2P finish gate. Only meaningful when [_draft.lapTiming] is [PointToPoint].
class _LapTimingFinish extends _GateRef {
  const _LapTimingFinish();
}

/// A sector gate identified by its position in [_draft.sectorGates].
class _SectorRef extends _GateRef {
  /// Index into [Track.sectorGates].
  final int index;

  const _SectorRef(this.index);
}

/// The enter gate of a neutral zone, identified by its position in
/// [_draft.neutralZones].
class _NeutralEnter extends _GateRef {
  /// Index into [Track.neutralZones].
  final int index;

  const _NeutralEnter(this.index);
}

/// The exit gate of a neutral zone, identified by its position in
/// [_draft.neutralZones].
class _NeutralExit extends _GateRef {
  /// Index into [Track.neutralZones].
  final int index;

  const _NeutralExit(this.index);
}

// ---------------------------------------------------------------------------
// Placement-mode enum + state struct
// ---------------------------------------------------------------------------

/// Identifies which gate endpoint pair the user is currently placing.
enum _PlacementTarget {
  none,
  circuit,
  lapStart,
  lapFinish,
  sector,
  neutralEnter,
  neutralExit,
}

/// Accumulates the two-tap state while the user is defining a gate on the map.
class _PendingPlacement {
  /// Creates a [_PendingPlacement] for [target].
  _PendingPlacement(this.target, {this.zoneName, this.sectorName});

  /// Which gate is being placed.
  final _PlacementTarget target;

  /// The first endpoint captured from the map tap, stored as degrees × 1e7
  /// to match the [LapGate] encoding. `null` before the first tap.
  ({double lat, double lon})? firstPoint;

  /// For neutral zones: name bound at creation time so enter/exit pair up.
  final String? zoneName;

  /// For sector gates: name prompt captured before map interaction starts.
  final String? sectorName;
}

// ---------------------------------------------------------------------------
// Modal widget
// ---------------------------------------------------------------------------

/// Near-full-screen modal for editing a Track's lap timing, sector gates,
/// and neutral zones. See `docs/IDL0_SPEC.md §16` and `§24`.
///
/// Hosts the GPS map on the left (~70% width on desktop) and a pinned
/// sidebar on the right with three sections (LAP TIMING, SECTOR GATES,
/// NEUTRAL ZONES). Cancel discards unsaved edits with a confirmation;
/// Save calls `TrackNotifier.updateTrack`.
class TrackEditorModal extends ConsumerStatefulWidget {
  /// Creates a [TrackEditorModal] for [track].
  const TrackEditorModal({
    super.key,
    required this.track,
    this.isNew = false,
    this.sourceSessionId,
  });

  /// Track to edit. Snapshot used as initial state — modal mutates a local
  /// copy and calls `updateTrack(local)` on Save. In create mode ([isNew])
  /// this is an in-memory draft (empty name/venue + a reference polyline)
  /// that is not yet in the library; Save calls `createTrack` instead.
  final Track track;

  /// When true the editor is creating a new Track: the "TRACK" sidebar
  /// section's Name/Venue fields drive an empty draft, Save calls
  /// `createTrack` (then rescans [sourceSessionId]), and Cancel discards
  /// without persisting anything.
  final bool isNew;

  /// Session the draft polyline came from, rescanned for visits after a
  /// successful create. Only meaningful when [isNew].
  final String? sourceSessionId;

  /// Convenience launcher. Pass [isNew] + [sourceSessionId] for create mode.
  static Future<void> show(
    BuildContext context,
    Track track, {
    bool isNew = false,
    String? sourceSessionId,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: TrackEditorModal(
          track: track,
          isNew: isNew,
          sourceSessionId: sourceSessionId,
        ),
      ),
    );
  }

  /// Shared "Create Track from session" flow used by the GPS map chart,
  /// the Tracks result panel, and the Tracks-visited empty-state CTA.
  ///
  /// 1. Gets the session handle via [sessionHandleProvider].
  /// 2. Builds the GPS polyline via the engine (`rust.gpsTrack`). Aborts with
  ///    a snackbar if there is no GPS data.
  /// 3. Opens [TrackEditorModal] in **create mode** with an empty draft over
  ///    that polyline. Name/venue are entered in the editor (with the map
  ///    visible); the Track is created — and [sessionId] rescanned — only on
  ///    Save. Cancel discards without creating anything.
  static Future<void> createFromSessionAndShow(
    BuildContext context,
    WidgetRef ref,
    String sessionId,
  ) async {
    final messenger = ScaffoldMessenger.of(context);

    // Step 1 — get the session handle.
    final rust.SessionHandle handle;
    try {
      handle = await ref.read(sessionHandleProvider(sessionId).future);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not load session data; cannot create a Track.'),
        ),
      );
      return;
    }

    // Step 2 — build the GPS polyline via the engine.
    final polyline = [for (final f in await rust.gpsTrack(handle: handle)) gpsFixFromArg(f)];
    if (polyline.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'This session has no GPS data; cannot create a Track.',
          ),
        ),
      );
      return;
    }

    // Step 3 — open the editor in create mode with an empty draft over the
    // polyline. Name/venue are entered there (map visible); createTrack +
    // rescan happen on Save.
    if (!context.mounted) return;
    final draft = Track.create(
      name: '',
      venueName: '',
      referencePolyline: polyline,
    );
    await show(context, draft, isNew: true, sourceSessionId: sessionId);
  }

  @override
  ConsumerState<TrackEditorModal> createState() => _TrackEditorModalState();
}

class _TrackEditorModalState extends ConsumerState<TrackEditorModal> {
  late Track _draft;
  bool _saving = false;

  /// Name field controller for the sidebar's "TRACK" section. Venue uses the
  /// [Autocomplete]'s own controller.
  late final TextEditingController _nameCtrl;

  /// Controller for programmatic zoom/pan of the embedded map.
  final MapController _mapController = MapController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _mapController.dispose();
    super.dispose();
  }

  // --------------------------------------------------------------------------
  // Placement-mode state
  // --------------------------------------------------------------------------

  /// Non-null while the user is placing a gate via two map taps.
  _PendingPlacement? _placement;

  /// Stash for the enter gate of a two-step neutral-zone placement. Set when
  /// [_PlacementTarget.neutralEnter] is committed; cleared on exit commit or
  /// cancel.
  LapGate? _stagedNeutralEnter;

  /// Name captured in [_startPlacingNeutralZone] and bound to both the enter
  /// and exit gates of the new neutral zone.
  String? _stagedNeutralName;

  @override
  void initState() {
    super.initState();
    _draft = widget.track;
    _nameCtrl = TextEditingController(text: _draft.name);
  }

  bool get _dirty {
    final t = widget.track;
    return _draft.name != t.name ||
        _draft.venueName != t.venueName ||
        _draft.lapTiming != t.lapTiming ||
        _draft.sectorGates != t.sectorGates ||
        _draft.neutralZones != t.neutralZones;
  }

  /// A Track needs a non-empty name to be saved (both create and edit).
  bool get _canSave => _draft.name.trim().isNotEmpty;

  // --------------------------------------------------------------------------
  // Save / cancel
  // --------------------------------------------------------------------------

  Future<void> _confirmCancel() async {
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard unsaved changes?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) Navigator.of(context).pop();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      if (widget.isNew) {
        // Create mode: persist the draft as a new Track in a single write,
        // then rescan the source session so its visits/venue pick it up.
        await ref.read(trackProvider.notifier).createTrack(
              name: _draft.name.trim(),
              venueName: _draft.venueName.trim(),
              lapTiming: _draft.lapTiming,
              sectorGates: _draft.sectorGates,
              neutralZones: _draft.neutralZones,
              referencePolyline: _draft.referencePolyline,
            );
        final sid = widget.sourceSessionId;
        if (sid != null) {
          await ref.read(runsProvider.notifier).rescanTrackVisits(sid);
        }
      } else {
        await ref.read(trackProvider.notifier).updateTrack(_draft);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // --------------------------------------------------------------------------
  // Placement entry points
  // --------------------------------------------------------------------------

  /// Enters placement mode for a Circuit (single start/finish) gate.
  void _startPlacingCircuit() {
    setState(() => _placement = _PendingPlacement(_PlacementTarget.circuit));
  }

  /// Enters placement mode for a Point-to-Point start gate.
  void _startPlacingStart() {
    setState(() => _placement = _PendingPlacement(_PlacementTarget.lapStart));
  }

  /// Enters placement mode for a Point-to-Point finish gate.
  void _startPlacingFinish() {
    setState(() => _placement = _PendingPlacement(_PlacementTarget.lapFinish));
  }

  /// Prompts for a sector name, then enters placement mode.
  Future<void> _startPlacingSector() async {
    final name = await _promptName('Sector gate name');
    if (name == null) return;
    setState(() => _placement = _PendingPlacement(
          _PlacementTarget.sector,
          sectorName: name,
        ),);
  }

  /// Prompts for a neutral-zone name, then enters placement mode for the
  /// enter gate. The exit gate placement follows automatically.
  Future<void> _startPlacingNeutralZone() async {
    final name = await _promptName('Neutral zone name');
    if (name == null) return;
    setState(() {
      _stagedNeutralName = name;
      _placement = _PendingPlacement(
        _PlacementTarget.neutralEnter,
        zoneName: name,
      );
    });
  }

  // --------------------------------------------------------------------------
  // Map tap handler
  // --------------------------------------------------------------------------

  /// Handles a map tap while in placement mode. First tap records the first
  /// endpoint; second tap calls [_commitPlacement].
  ///
  /// Coordinates from [LatLng] are converted to degrees × 1e7 to match the
  /// [LapGate] encoding used throughout the data layer.
  void _onMapTap(LatLng tapped) {
    final p = _placement;
    if (p == null) return;
    if (p.firstPoint == null) {
      setState(() {
        p.firstPoint = (
          lat: tapped.latitude * _coordScale,
          lon: tapped.longitude * _coordScale,
        );
      });
      return;
    }
    final gate = LapGate(
      lat1Deg: p.firstPoint!.lat,
      lon1Deg: p.firstPoint!.lon,
      lat2Deg: tapped.latitude * _coordScale,
      lon2Deg: tapped.longitude * _coordScale,
    );
    _commitPlacement(gate);
  }

  /// Commits a fully-defined [gate] to the draft Track based on which
  /// [_PlacementTarget] is active.
  void _commitPlacement(LapGate gate) {
    final p = _placement!;
    switch (p.target) {
      case _PlacementTarget.circuit:
        setState(() {
          _draft = _draft.copyWith(lapTiming: Circuit(startFinish: gate));
          _placement = null;
        });
      case _PlacementTarget.lapStart:
        setState(() {
          _draft = _draft.copyWith(
            lapTiming: PointToPoint(start: gate, finish: gate),
          );
          _placement = null;
        });
      case _PlacementTarget.lapFinish:
        final t = _draft.lapTiming;
        if (t is PointToPoint) {
          setState(() {
            _draft = _draft.copyWith(
              lapTiming: PointToPoint(start: t.start, finish: gate),
            );
            _placement = null;
          });
        }
      case _PlacementTarget.sector:
        setState(() {
          _draft = _draft.copyWith(sectorGates: [
            ..._draft.sectorGates,
            SectorGate(name: p.sectorName ?? '', gate: gate),
          ],);
          _placement = null;
        });
      case _PlacementTarget.neutralEnter:
        setState(() {
          _stagedNeutralEnter = gate;
          _placement = _PendingPlacement(
            _PlacementTarget.neutralExit,
            zoneName: p.zoneName,
          );
        });
      case _PlacementTarget.neutralExit:
        setState(() {
          _draft = _draft.copyWith(neutralZones: [
            ..._draft.neutralZones,
            NeutralZone(
              name: _stagedNeutralName ?? '',
              enter: _stagedNeutralEnter!,
              exit: gate,
            ),
          ],);
          _placement = null;
          _stagedNeutralEnter = null;
          _stagedNeutralName = null;
        });
      case _PlacementTarget.none:
        break;
    }
  }

  // --------------------------------------------------------------------------
  // Drag-to-move gate endpoint handler
  // --------------------------------------------------------------------------

  /// Moves one endpoint of an existing gate to [newLatLng] and updates [_draft].
  ///
  /// [ref] identifies which gate; [endpointIndex] is 0 for post 1, 1 for post 2.
  /// Coordinates are stored as degrees × 1e7 to match [LapGate] semantics.
  void _updateGateEndpoint(_GateRef ref, int endpointIndex, LatLng newLatLng) {
    final rawLat = newLatLng.latitude * _coordScale;
    final rawLon = newLatLng.longitude * _coordScale;

    LapGate move(LapGate g) => endpointIndex == 0
        ? LapGate(
            lat1Deg: rawLat,
            lon1Deg: rawLon,
            lat2Deg: g.lat2Deg,
            lon2Deg: g.lon2Deg,
            name: g.name,
          )
        : LapGate(
            lat1Deg: g.lat1Deg,
            lon1Deg: g.lon1Deg,
            lat2Deg: rawLat,
            lon2Deg: rawLon,
            name: g.name,
          );

    setState(() {
      switch (ref) {
        case _LapTimingStart():
          final lt = _draft.lapTiming;
          if (lt is Circuit) {
            _draft = _draft.copyWith(
              lapTiming: Circuit(startFinish: move(lt.startFinish)),
            );
          } else if (lt is PointToPoint) {
            _draft = _draft.copyWith(
              lapTiming: PointToPoint(start: move(lt.start), finish: lt.finish),
            );
          }
        case _LapTimingFinish():
          final lt = _draft.lapTiming;
          if (lt is PointToPoint) {
            _draft = _draft.copyWith(
              lapTiming: PointToPoint(start: lt.start, finish: move(lt.finish)),
            );
          }
        case _SectorRef(:final index):
          if (index < 0 || index >= _draft.sectorGates.length) return;
          final sg = _draft.sectorGates[index];
          final updated = List<SectorGate>.of(_draft.sectorGates)
            ..[index] = SectorGate(name: sg.name, gate: move(sg.gate));
          _draft = _draft.copyWith(sectorGates: updated);
        case _NeutralEnter(:final index):
          if (index < 0 || index >= _draft.neutralZones.length) return;
          final nz = _draft.neutralZones[index];
          final updated = List<NeutralZone>.of(_draft.neutralZones)
            ..[index] = NeutralZone(
              name: nz.name,
              enter: move(nz.enter),
              exit: nz.exit,
            );
          _draft = _draft.copyWith(neutralZones: updated);
        case _NeutralExit(:final index):
          if (index < 0 || index >= _draft.neutralZones.length) return;
          final nz = _draft.neutralZones[index];
          final updated = List<NeutralZone>.of(_draft.neutralZones)
            ..[index] = NeutralZone(
              name: nz.name,
              enter: nz.enter,
              exit: move(nz.exit),
            );
          _draft = _draft.copyWith(neutralZones: updated);
      }
    });
  }

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------

  /// Shows a text-input dialog and returns the trimmed result, or `null` when
  /// the user cancels or enters an empty string.
  Future<String?> _promptName(String label) async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          onSubmitted: (_) => Navigator.of(ctx).pop(ctrl.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    final trimmed = result?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  /// Human-readable text for the placement banner based on the active target
  /// and whether the first point has been tapped.
  String _placementBannerText() {
    final p = _placement;
    if (p == null) return '';
    final targetLabel = switch (p.target) {
      _PlacementTarget.circuit => 'Circuit',
      _PlacementTarget.lapStart => 'Start',
      _PlacementTarget.lapFinish => 'Finish',
      _PlacementTarget.sector => 'Sector',
      _PlacementTarget.neutralEnter => 'Enter',
      _PlacementTarget.neutralExit => 'Exit',
      _PlacementTarget.none => '',
    };
    if (p.firstPoint == null) {
      return 'Click two points to place the $targetLabel gate (first point).';
    }
    return 'Click two points to place the $targetLabel gate (second point).';
  }

  // --------------------------------------------------------------------------
  // Gate geometry helpers (matching GpsMapChart conventions)
  // --------------------------------------------------------------------------

  /// Two [LatLng] points for [gate], converting from degrees × 1e7.
  static List<LatLng> _gatePoints(LapGate gate) => [
        LatLng(gate.lat1Deg / _coordScale, gate.lon1Deg / _coordScale),
        LatLng(gate.lat2Deg / _coordScale, gate.lon2Deg / _coordScale),
      ];

  // --------------------------------------------------------------------------
  // Reference polyline helpers
  // --------------------------------------------------------------------------

  /// Converts the Track's [GpsFix] reference polyline to [LatLng] points.
  /// Track GPS fixes are stored at the firmware × 1e7 scale (matches
  /// [LapGate]); convert to decimal degrees for flutter_map.
  static List<LatLng> _referencePoints(List<GpsFix> fixes) => fixes
      .map((f) => LatLng(
            f.latitudeDeg / _coordScale,
            f.longitudeDeg / _coordScale,
          ),)
      .toList();

  /// Returns a [LatLngBounds] that contains all [points], or `null` when
  /// the list is empty.
  static LatLngBounds? _boundsOf(List<LatLng> points) {
    if (points.isEmpty) return null;
    return LatLngBounds.fromPoints(points);
  }

  // --------------------------------------------------------------------------
  // build
  // --------------------------------------------------------------------------

  /// Exports the current editor contents to a `.idl0t` portable Track file via
  /// a save dialog. Mirrors the workbook `.idl0wb` export — `saveFile` returns
  /// the chosen path, which we then write (it does not write on desktop).
  Future<void> _exportTrack() async {
    final messenger = ScaffoldMessenger.of(context);
    final track = _draft;
    final outPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Export track',
      fileName: '${track.name.isEmpty ? 'track' : track.name}.idl0t',
      type: FileType.custom,
      allowedExtensions: const ['idl0t'],
    );
    if (outPath == null) return;
    final path =
        outPath.toLowerCase().endsWith('.idl0t') ? outPath : '$outPath.idl0t';
    try {
      await File(path).writeAsString(encodeTrackArtifact(track));
      messenger.showSnackBar(
        SnackBar(content: Text('Exported "${track.name}"')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  /// Name + venue fields for the sidebar's "TRACK" section. Edits the draft's
  /// name/venue; [venueOptions] feeds the venue autocomplete (lifted from the
  /// retired TrackCreationDialog).
  Widget _buildTrackDetails(Set<String> venueOptions) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Name',
              isDense: true,
            ),
            onChanged: (v) =>
                setState(() => _draft = _draft.copyWith(name: v)),
          ),
          const SizedBox(height: 8),
          Autocomplete<String>(
            initialValue: TextEditingValue(text: _draft.venueName),
            optionsBuilder: (v) {
              if (v.text.isEmpty) return venueOptions;
              final lc = v.text.toLowerCase();
              return venueOptions.where((o) => o.toLowerCase().contains(lc));
            },
            onSelected: (s) =>
                setState(() => _draft = _draft.copyWith(venueName: s)),
            fieldViewBuilder: (ctx, txt, focus, submit) => TextField(
              controller: txt,
              focusNode: focus,
              decoration: const InputDecoration(
                labelText: 'Venue',
                isDense: true,
              ),
              onChanged: (v) =>
                  setState(() => _draft = _draft.copyWith(venueName: v)),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds the controls sidebar (TRACK / LAP TIMING / SECTOR / NEUTRAL),
  /// shared by the wide layout (pinned right rail) and the narrow layout
  /// (scrollable panel below the map).
  Widget _buildSidebar(Set<String> venueOptions) {
    return TrackEditorSidebar(
      draft: _draft,
      onChanged: (next) => setState(() => _draft = next),
      detailsSlot: _buildTrackDetails(venueOptions),
      lapTimingSlot: TrackEditorLapTimingTabs(
        value: _draft.lapTiming,
        onChanged: (lt) => setState(
          () => _draft = lt == null
              ? _draft.copyWith(lapTiming: Track.clearLapTiming)
              : _draft.copyWith(lapTiming: lt),
        ),
        onPlaceCircuit: _startPlacingCircuit,
        onPlaceStart: _startPlacingStart,
        onPlaceFinish: _startPlacingFinish,
      ),
      sectorListSlot: TrackEditorSectorList(
        gates: _draft.sectorGates,
        onChanged: (next) =>
            setState(() => _draft = _draft.copyWith(sectorGates: next)),
        onAdd: _startPlacingSector,
      ),
      neutralZoneListSlot: TrackEditorNeutralZoneList(
        zones: _draft.neutralZones,
        onChanged: (next) =>
            setState(() => _draft = _draft.copyWith(neutralZones: next)),
        onAdd: _startPlacingNeutralZone,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isWide = width >= 720;
    // Venue suggestions for the "TRACK" section's autocomplete.
    final venueOptions = <String>{
      for (final t in (ref.watch(trackProvider).valueOrNull ?? const <Track>[]))
        if (t.venueName.isNotEmpty) t.venueName,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppBar(
          title: Text(
            widget.isNew ? 'New track' : '${widget.track.name} — Edit',
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.ios_share),
              tooltip: 'Export track (.idl0t)',
              onPressed: _exportTrack,
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: _confirmCancel,
            ),
          ],
        ),
        Expanded(
          child: isWide
              ? Row(
                  children: [
                    Expanded(child: _buildMapArea()),
                    SizedBox(
                      width: 320,
                      child: _buildSidebar(venueOptions),
                    ),
                  ],
                )
              // Narrow: map over a scrollable controls panel. While placing a
              // gate the map takes the whole area so the two taps are precise;
              // the controls return once placement commits or is cancelled.
              : _placement != null
                  ? _buildMapArea()
                  : Column(
                      children: [
                        Expanded(flex: 5, child: _buildMapArea()),
                        Expanded(
                          flex: 6,
                          child: _buildSidebar(venueOptions),
                        ),
                      ],
                    ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _saving ? null : _confirmCancel,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: (_saving || !_canSave) ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // Drag marker construction
  // --------------------------------------------------------------------------

  /// Builds one [DragMarker] for each gate endpoint currently in [_draft].
  ///
  /// Each marker sits at one post of a gate polyline (post 1 or post 2).
  /// Dragging it calls [_updateGateEndpoint] with the new [LatLng], which
  /// stores the result as degrees × 1e7 to match [LapGate] semantics.
  ///
  /// Flag markers (start/finish icons at the gate midpoint) are rendered
  /// separately in [_buildMapArea] and are not draggable.
  List<DragMarker> _buildDragMarkers() {
    final result = <DragMarker>[];

    /// Adds two [DragMarker]s (one per post) for [gate], coloured with [color],
    /// and wired to [ref] so [_updateGateEndpoint] can identify the gate.
    void addEndpoints(LapGate gate, _GateRef ref, Color color) {
      for (final endpointIndex in [0, 1]) {
        final point = endpointIndex == 0
            ? LatLng(gate.lat1Deg / _coordScale, gate.lon1Deg / _coordScale)
            : LatLng(gate.lat2Deg / _coordScale, gate.lon2Deg / _coordScale);
        result.add(DragMarker(
          point: point,
          size: const Size(20, 20),
          builder: (ctx, pos, isDragging) => Icon(
            Icons.circle,
            size: isDragging ? 16 : 12,
            color: color.withValues(alpha: isDragging ? 1.0 : 0.85),
          ),
          onDragEnd: (details, latLng) =>
              _updateGateEndpoint(ref, endpointIndex, latLng),
        ),);
      }
    }

    final lt = _draft.lapTiming;
    if (lt is Circuit) {
      addEndpoints(lt.startFinish, const _LapTimingStart(), _lapGateColor);
    } else if (lt is PointToPoint) {
      addEndpoints(lt.start, const _LapTimingStart(), _lapGateColor);
      addEndpoints(lt.finish, const _LapTimingFinish(), _lapGateColor);
    }

    for (var i = 0; i < _draft.sectorGates.length; i++) {
      addEndpoints(_draft.sectorGates[i].gate, _SectorRef(i), _sectorGateColor);
    }

    for (var i = 0; i < _draft.neutralZones.length; i++) {
      addEndpoints(_draft.neutralZones[i].enter, _NeutralEnter(i), _neutralGateColor);
      addEndpoints(_draft.neutralZones[i].exit, _NeutralExit(i), _neutralGateColor);
    }

    return result;
  }

  /// Builds the map area: placement banner (when active) + [FlutterMap].
  ///
  /// When [_draft.referencePolyline] is empty, shows a placeholder with an
  /// informational message — flutter_map requires at least one valid LatLng
  /// for the camera fit.
  Widget _buildMapArea() {
    // canonicalPolyline removed in lap-delta-rewrite Task 1.3; the
    // editor now always renders the reference polyline. The Polyline
    // section below is slated for removal in Task 1.5.
    final activePolyline = _draft.referencePolyline;
    final refPoints = _referencePoints(activePolyline);

    if (refPoints.isEmpty) {
      return _buildPlaceholderMapArea();
    }

    final bounds = _boundsOf(refPoints);

    // Gate polylines: lap timing gates, sector gates, neutral-zone gates.
    final gatePolylines = <Polyline>[];
    final lapTiming = _draft.lapTiming;
    if (lapTiming is Circuit) {
      gatePolylines.add(Polyline(
        points: _gatePoints(lapTiming.startFinish),
        color: _lapGateColor,
        strokeWidth: _gateStrokeWidth,
      ),);
    } else if (lapTiming is PointToPoint) {
      gatePolylines.add(Polyline(
        points: _gatePoints(lapTiming.start),
        color: _lapGateColor,
        strokeWidth: _gateStrokeWidth,
      ),);
      gatePolylines.add(Polyline(
        points: _gatePoints(lapTiming.finish),
        color: _lapGateColor,
        strokeWidth: _gateStrokeWidth,
      ),);
    }
    for (final sg in _draft.sectorGates) {
      gatePolylines.add(Polyline(
        points: _gatePoints(sg.gate),
        color: _sectorGateColor,
        strokeWidth: _gateStrokeWidth,
      ),);
    }
    for (final nz in _draft.neutralZones) {
      gatePolylines.add(Polyline(
        points: _gatePoints(nz.enter),
        color: _neutralGateColor,
        strokeWidth: _gateStrokeWidth,
      ),);
      gatePolylines.add(Polyline(
        points: _gatePoints(nz.exit),
        color: _neutralGateColor,
        strokeWidth: _gateStrokeWidth,
      ),);
    }

    // Transient marker for the first placement tap.
    final markers = <Marker>[];
    final p = _placement;
    if (p != null && p.firstPoint != null) {
      markers.add(Marker(
        point: LatLng(
          p.firstPoint!.lat / _coordScale,
          p.firstPoint!.lon / _coordScale,
        ),
        width: 24,
        height: 24,
        child: const Icon(Icons.add_location, color: Colors.lightBlue, size: 24),
      ),);
    }

    // Gate flag markers — one flag at each post (endpoint) of every
    // lap-timing and neutral-zone gate. Sector gates keep yellow polylines
    // only (no flags). Flag markers use alignment: bottomCenter so the flag
    // icon rises above the drag-marker dot which sits at the exact coordinate.
    void addEndpointFlags(LapGate gate, Widget flagIcon) {
      for (final point in _gatePoints(gate)) {
        markers.add(Marker(
          point: point,
          width: 24,
          height: 24,
          alignment: Alignment.bottomCenter,
          child: flagIcon,
        ),);
      }
    }

    final lt = _draft.lapTiming;
    if (lt is Circuit) {
      // Circuit: two green flags at the single start/finish gate's posts.
      addEndpointFlags(
        lt.startFinish,
        const Icon(Icons.flag, color: Color(0xFF388E3C), size: 20),
      );
    } else if (lt is PointToPoint) {
      // P2P: two green flags at start gate posts.
      addEndpointFlags(
        lt.start,
        const Icon(Icons.flag, color: Color(0xFF388E3C), size: 20),
      );
      // Two checkered flags at finish gate posts (always render, even when
      // finish == start, so the user can see both gates independently).
      addEndpointFlags(
        lt.finish,
        const Icon(Icons.sports_score, color: Colors.black87, size: 20),
      );
    }

    // Neutral zones: two white flags (with shadow stroke) at each gate's posts.
    const Widget whiteFlag = Icon(
      Icons.flag,
      color: Colors.white,
      size: 20,
      shadows: [Shadow(color: Colors.black54, blurRadius: 2)],
    );
    for (final nz in _draft.neutralZones) {
      addEndpointFlags(nz.enter, whiteFlag);
      addEndpointFlags(nz.exit, whiteFlag);
    }

    final tileSpecs = tileSpecsFor(MapTileSource.osmStandard);
    final attributionText = tileSpecs.last.attribution;
    final dragMarkers = _buildDragMarkers();

    final mapWidget = FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCameraFit: bounds != null
            ? CameraFit.bounds(
                bounds: bounds,
                padding: const EdgeInsets.all(32),
              )
            : null,
        initialCenter: const LatLng(0, 0),
        initialZoom: 14,
        minZoom: _minZoom,
        maxZoom: _maxZoom,
        onTap: (_, point) => _onMapTap(point),
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.drag |
              InteractiveFlag.pinchZoom |
              InteractiveFlag.scrollWheelZoom |
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
        PolylineLayer(polylines: [
          Polyline(
            points: refPoints,
            color: Colors.blue,
            strokeWidth: 3,
          ),
          ...gatePolylines,
        ],),
        if (markers.isNotEmpty) MarkerLayer(markers: markers),
        if (dragMarkers.isNotEmpty) DragMarkers(markers: dragMarkers),
      ],
    );

    return Column(
      children: [
        if (_placement != null)
          Container(
            color: Colors.amber.shade100,
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(child: Text(_placementBannerText())),
                TextButton(
                  onPressed: () => setState(() {
                    _placement = null;
                    _stagedNeutralEnter = null;
                    _stagedNeutralName = null;
                  }),
                  child: const Text('Cancel placement'),
                ),
              ],
            ),
          ),
        Expanded(
          child: Stack(
            children: [
              mapWidget,
              Positioned(
                right: 8,
                bottom: 32,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton.filled(
                      icon: const Icon(Icons.add),
                      tooltip: 'Zoom in',
                      onPressed: () {
                        final z = _mapController.camera.zoom;
                        _mapController.move(
                          _mapController.camera.center,
                          (z + 1).clamp(_minZoom, _maxZoom),
                        );
                      },
                    ),
                    const SizedBox(height: 4),
                    IconButton.filled(
                      icon: const Icon(Icons.remove),
                      tooltip: 'Zoom out',
                      onPressed: () {
                        final z = _mapController.camera.zoom;
                        _mapController.move(
                          _mapController.camera.center,
                          (z - 1).clamp(_minZoom, _maxZoom),
                        );
                      },
                    ),
                  ],
                ),
              ),
              Positioned(
                right: 4,
                bottom: 4,
                child: _AttributionBadge(text: attributionText),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Shown when the Track has no reference polyline — flutter_map needs at
  /// least one coordinate for a meaningful camera fit.
  Widget _buildPlaceholderMapArea() {
    return Column(
      children: [
        if (_placement != null)
          Container(
            color: Colors.amber.shade100,
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(child: Text(_placementBannerText())),
                TextButton(
                  onPressed: () => setState(() {
                    _placement = null;
                    _stagedNeutralEnter = null;
                    _stagedNeutralName = null;
                  }),
                  child: const Text('Cancel placement'),
                ),
              ],
            ),
          ),
        Expanded(
          child: Container(
            color: Colors.grey.shade200,
            child: const Center(
              child: Text(
                'No reference polyline — tap a session in the Analyze tab'
                ' and use "Create Track" to attach one.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Attribution badge (mirrors GpsMapChart's private widget)
// ---------------------------------------------------------------------------

class _AttributionBadge extends StatelessWidget {
  const _AttributionBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.zero,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white, fontSize: 10),
        ),
      ),
    );
  }
}
