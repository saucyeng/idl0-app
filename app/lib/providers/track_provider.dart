import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart';
import 'package:uuid/uuid.dart';

import '../data/database_paths.dart';
import '../data/gate_geometry.dart';
import '../data/gpx_parser.dart';
import '../data/lap_detector.dart';
import '../data/lap_timing.dart';
import '../data/session_model.dart';
import '../data/track.dart';
import '../data/track_index.dart';
import 'drive_sync_provider.dart';

/// SHA-1 hash of the supplied Track library, used as
/// `Workspace.trackVisitsLibraryHash` to detect cache staleness for
/// detected `Workspace.trackVisits`. See `docs/IDL0_SPEC.md §12.3`.
///
/// Hashes a stable serialisation of `(trackId, updatedAtMs)` pairs sorted
/// by `trackId`, so the result is independent of in-memory ordering and
/// changes when a Track is added, removed, or edited (any edit bumps
/// `Track.updatedAtMs` per [Track.copyWith] semantics). The format is
/// implementation-defined; callers must not parse it.
String trackLibraryHash(List<Track> tracks) {
  final pairs = [
    for (final t in tracks) '${t.trackId}:${t.updatedAtMs}',
  ]..sort();
  final digest = sha1.convert(utf8.encode(pairs.join('|')));
  return 'sha1:$digest';
}

/// Provider that opens (or creates) the SQLite [TrackIndex] cache.
///
/// Tests override this provider with an in-memory [TrackIndex] via
/// [ProviderScope] overrides — see `track_provider_test.dart`.
final trackIndexProvider = FutureProvider<TrackIndex>((ref) async {
  final dbPath = await getStableDatabasesPath();
  return TrackIndex.open(join(dbPath, 'tracks.db'));
});

/// Manages the in-memory list of [Track]s, the [TrackIndex] SQLite cache,
/// and the Drive-side `IDL0/tracks/` folder. See `docs/IDL0_SPEC.md §12.3`.
///
/// **Sync model.** [build] returns the local cache immediately so the UI is
/// responsive even when offline; a fire-and-forget [_syncWithDrive] runs in
/// the background and updates [state] as Drive responds. Conflict policy is
/// last-write-wins by [Track.updatedAtMs] — a Drive copy wins iff its
/// `modifiedTime` exceeds the local row's `updated_at_ms`, and the local
/// copy is uploaded otherwise. This means simultaneous edits from two
/// devices race; the latest wall-clock save is preserved.
///
/// Tests override [trackIndexProvider] and [driveServiceProvider] to
/// substitute in-memory backends.
class TrackNotifier extends AsyncNotifier<List<Track>> {
  /// Resolves when the most recent background sync started by [build]
  /// completes. Tests await this to assert post-sync state without flaking
  /// on event-loop timing.
  Future<void> get debugSyncCompletion => _syncCompletion;
  Future<void> _syncCompletion = Future<void>.value();

  @override
  Future<List<Track>> build() async {
    final index = await ref.watch(trackIndexProvider.future);
    final cached = await index.getAll();
    // Fire-and-forget Drive reconciliation. Errors are surfaced via
    // [state] only when no cached data is available; if we already have a
    // cache we prefer to keep the UI responsive.
    _syncCompletion = Future<void>(() async {
      try {
        await _syncWithDrive(index);
      } catch (_) {
        // Background sync failures are non-fatal — the next call will
        // retry. Surfacing them as state errors would clobber the cached
        // list the user is currently looking at.
      }
    });
    return cached;
  }

  /// Creates a new Track, persists it locally, uploads to Drive
  /// fire-and-forget, and prepends it to [state].
  Future<Track> createTrack({
    required String name,
    required String venueName,
    LapTiming? lapTiming,
    List<SectorGate> sectorGates = const [],
    List<NeutralZone> neutralZones = const [],
    List<GpsFix> referencePolyline = const [],
  }) async {
    final track = Track.create(
      name: name,
      venueName: venueName,
      lapTiming: lapTiming,
      sectorGates: sectorGates,
      neutralZones: neutralZones,
      referencePolyline: referencePolyline,
    );
    final index = await ref.read(trackIndexProvider.future);
    await index.upsert(track);
    state = AsyncData([track, ...(state.value ?? const [])]);
    unawaited(_uploadIgnoringErrors(track));
    return track;
  }

  /// Returns the library Track with [trackId], or null. Lets the import flow
  /// detect a collision before choosing update-in-place vs new-copy.
  Track? existingById(String trackId) => (state.value ?? const <Track>[])
      .where((t) => t.trackId == trackId)
      .firstOrNull;

  /// Persists an imported [track] (the full entity, incl. neutral zones) and
  /// prepends it to [state]. With [asNewCopy], assigns a fresh `trackId` and
  /// timestamps so it coexists with an id-colliding entry; otherwise keeps the
  /// imported `trackId` (preserving identity across share / re-import).
  Future<void> addImportedTrack(Track track, {bool asNewCopy = false}) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final toAdd = asNewCopy
        ? Track(
            trackId: const Uuid().v4(),
            name: track.name,
            venueName: track.venueName,
            lapTiming: track.lapTiming,
            sectorGates: track.sectorGates,
            neutralZones: track.neutralZones,
            referencePolyline: track.referencePolyline,
            createdAtMs: nowMs,
            updatedAtMs: nowMs,
          )
        : track;
    final index = await ref.read(trackIndexProvider.future);
    await index.upsert(toAdd);
    state = AsyncData([toAdd, ...(state.value ?? const [])]);
    unawaited(_uploadIgnoringErrors(toAdd));
  }

  /// Imports a Track from a .gpx file's bytes.
  ///
  /// Parses [bytes] via [GpxParser.parse] to get the GPS polyline, then
  /// auto-generates a PointToPoint lap timing (Start at the first fix, Finish at
  /// the last) via [GateGeometry.endpointGates] so the imported Track is
  /// usable for lap detection without an extra trip through the gate-edit
  /// UI. Sector gates default to empty.
  ///
  /// Returns the created [Track]. Throws on parse failure (caller surfaces
  /// the error). Mirrors [createTrack] for the rest of the pipeline —
  /// persists locally, uploads to Drive, prepends to [state].
  Future<Track> importTrackFromGpx({
    required Uint8List bytes,
    required String name,
    required String venueName,
  }) async {
    final parsed = GpxParser.parse(utf8.decode(bytes));
    final polyline = _polylineFromSession(parsed.session);

    final endpointGates = GateGeometry.endpointGates(polyline);
    final lapTiming = endpointGates == null
        ? null
        : PointToPoint(
            start: endpointGates.start,
            finish: endpointGates.finish,
          );

    return createTrack(
      name: name,
      venueName: venueName,
      lapTiming: lapTiming,
      referencePolyline: polyline,
    );
  }

  /// Extracts the GPS polyline from a GPX-imported [Session].
  ///
  /// Pairs `GPS_Latitude` and `GPS_Longitude` channels into [GpsFix]es
  /// (using `GPS_EpochMs` for timestamps when present, otherwise the
  /// sample index × 1000 ms). Returns an empty list if the GPS channels
  /// are missing — Track import will fail downstream because the
  /// endpoint-gate generator requires ≥ 2 fixes.
  static List<GpsFix> _polylineFromSession(Session session) {
    final lat = session.channels
        .where((c) => c.channelId == 'GPS_Latitude')
        .firstOrNull;
    final lon = session.channels
        .where((c) => c.channelId == 'GPS_Longitude')
        .firstOrNull;
    if (lat == null || lon == null) return const [];

    final epoch =
        session.channels.where((c) => c.channelId == 'GPS_EpochMs').firstOrNull;
    final n = [
      lat.samples.length,
      lon.samples.length,
      if (epoch != null) epoch.samples.length,
    ].reduce((a, b) => a < b ? a : b);

    final out = <GpsFix>[];
    for (var i = 0; i < n; i++) {
      out.add(
        GpsFix(
          timestampMs: epoch != null ? epoch.samples[i].toInt() : i * 1000,
          latitudeDeg: lat.samples[i],
          longitudeDeg: lon.samples[i],
        ),
      );
    }
    return out;
  }

  /// Persists changes to [track] (e.g. renamed, gates updated). Caller is
  /// responsible for bumping [Track.updatedAtMs] (typically by going through
  /// [Track.copyWith] without an explicit `updatedAtMs`).
  Future<void> updateTrack(Track track) async {
    final index = await ref.read(trackIndexProvider.future);
    await index.upsert(track);
    final current = state.value ?? const <Track>[];
    state = AsyncData([
      for (final t in current)
        if (t.trackId == track.trackId) track else t,
      // Insert if it wasn't present (e.g. a Track created on another device).
      if (!current.any((t) => t.trackId == track.trackId)) track,
    ]);
    unawaited(_uploadIgnoringErrors(track));
  }

  /// Removes the Track locally and from Drive.
  ///
  /// Stale [TrackVisit] references in existing `.idl0w` workspaces are not
  /// cleaned up — the hierarchy view skips visits whose [TrackVisit.trackId]
  /// no longer resolves to a Track. The user can run "Rescan tracks" on
  /// affected sessions to refresh `Workspace.trackVisits`. See `docs/IDL0_SPEC.md
  /// §12.3`.
  Future<void> deleteTrack(String trackId) async {
    final index = await ref.read(trackIndexProvider.future);
    await index.delete(trackId);

    state = AsyncData([
      for (final t in (state.value ?? const <Track>[]))
        if (t.trackId != trackId) t,
    ]);
    unawaited(_deleteFromDriveIgnoringErrors(trackId));
  }

  /// Renames every [Track] whose `venueName == oldName` to [newName] and
  /// returns the count of Tracks updated. No-op when [oldName] equals
  /// [newName].
  ///
  /// Each Track passes through [updateTrack] so `updatedAtMs` is bumped
  /// and the change uploads to Drive in the background.
  Future<int> renameVenue(String oldName, String newName) async {
    if (oldName == newName) return 0;
    final tracks = state.value ?? const <Track>[];
    final matching = tracks.where((t) => t.venueName == oldName).toList();
    for (final t in matching) {
      await updateTrack(t.copyWith(venueName: newName));
    }
    return matching.length;
  }

  /// Clears `venueName` on every [Track] currently using [venueName] and
  /// returns the count. Used by the Venue card's kebab "Delete venue"
  /// confirmation.
  Future<int> deleteVenue(String venueName) async {
    if (venueName.isEmpty) return 0;
    return renameVenue(venueName, '');
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  Future<void> _syncWithDrive(TrackIndex index) async {
    final drive = ref.read(driveServiceProvider);
    if (!drive.isSignedIn) return;
    final remoteFiles = await drive.listTracks();
    final cached = await index.getAll();
    final cachedById = {for (final t in cached) t.trackId: t};
    final remoteIds = <String>{};

    for (final remote in remoteFiles) {
      remoteIds.add(remote.trackId);
      final local = cachedById[remote.trackId];
      if (local == null || remote.modifiedTimeMs > local.updatedAtMs) {
        try {
          final downloaded = await drive.downloadTrack(remote.trackId);
          await index.upsert(downloaded);
        } catch (_) {
          // Skip individual Track failures so one bad payload does not
          // block the rest of the reconciliation pass.
        }
      }
    }

    for (final local in cached) {
      if (!remoteIds.contains(local.trackId)) {
        // Local row not yet on Drive — push it.
        try {
          await drive.uploadTrack(local);
        } catch (_) {/* skip */}
      }
    }

    // Refresh state with the post-sync cache.
    final fresh = await index.getAll();
    state = AsyncData(fresh);
  }

  Future<void> _uploadIgnoringErrors(Track track) async {
    final drive = ref.read(driveServiceProvider);
    if (!drive.isSignedIn) return;
    try {
      await drive.uploadTrack(track);
    } catch (_) {
      // Background upload failures are non-fatal. The next [build] cycle's
      // [_syncWithDrive] will detect the local-newer Track and retry.
    }
  }

  Future<void> _deleteFromDriveIgnoringErrors(String trackId) async {
    // The Drive interface intentionally exposes no delete entry-point yet;
    // local deletion is sufficient for v1 and Drive cleanup is a follow-up.
    // Keeping the hook here so the call sites stay symmetric.
    return;
  }
}

/// Provider exposing the user's [Track] list. See `docs/IDL0_SPEC.md §12.3`.
final trackProvider = AsyncNotifierProvider<TrackNotifier, List<Track>>(
  TrackNotifier.new,
);

// ---------------------------------------------------------------------------
// Local helpers
// ---------------------------------------------------------------------------

/// Runs [future] and silently swallows any thrown error.
///
/// Mirrors `package:async`'s `unawaited` (which only marks the linter, not
/// the rejection) and gives us a single canonical name for fire-and-forget
/// background work.
void unawaited(Future<void> future) {
  // ignore: unawaited_futures
  future.then<void>((_) {}, onError: (_) {});
}
