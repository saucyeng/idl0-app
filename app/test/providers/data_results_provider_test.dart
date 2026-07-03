import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/lap_detector.dart';
import 'package:idl0/data/lap_timing.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/data/track.dart';
import 'package:idl0/data/workspace.dart';
import 'package:idl0/providers/data_results_provider.dart';
import 'package:idl0/providers/session_provider.dart';
import 'package:idl0/providers/session_workspace_provider.dart';
import 'package:idl0/providers/track_provider.dart';

SessionMetadata _meta(String id) => SessionMetadata(
      sessionId: id,
      filePath: '/sessions/$id.idl0',
      workspacePath: '/sessions/$id.idl0w',
      createdTimestampMs: DateTime(2026, 5, 1).millisecondsSinceEpoch,
      fileSizeBytes: 0,
      rider: '',
      bike: '',
      bikeComment: '',
      venueName: '',
      eventName: '',
      eventSession: '',
      shortComment: '',
      longComment: '',
      deviceId: '',
    );

Lap _lap(int n, int startMs, int endMs) => Lap(
      lapNumber: n,
      startTimestampMs: startMs,
      endTimestampMs: endMs,
      rawElapsedMs: endMs - startMs,
      lapTimeMs: endMs - startMs,
    );

Track _track(String id) => Track(
      trackId: id,
      name: 'Track $id',
      venueName: 'Venue',
      lapTiming: const Circuit(
        startFinish: LapGate(
          lat1Deg: 0,
          lon1Deg: 0,
          lat2Deg: 1,
          lon2Deg: 1,
        ),
      ),
      sectorGates: const [],
      neutralZones: const [],
      referencePolyline: const [],
      createdAtMs: 0,
      updatedAtMs: 0,
    );

class _StaticTrackNotifier extends TrackNotifier {
  _StaticTrackNotifier(this._tracks);
  final List<Track> _tracks;
  @override
  Future<List<Track>> build() async => _tracks;
}

/// Minimal [SessionWorkspaceNotifier] override returning a fixed workspace
/// without file I/O — exercises the Data-tab aggregate's cache-read path with
/// no Rust handle.
class _FakeWorkspace extends SessionWorkspaceNotifier {
  _FakeWorkspace(this._ws);
  final Workspace _ws;
  @override
  Future<Workspace> build(String sessionId) async => _ws;
}

void main() {
  test(
      'filteredSessionRowsProvider — builds rows from cached visit.laps with '
      'no handle/parse', () async {
    // Arrange — one session, one visit on track-A carrying two cached laps.
    final meta = _meta('s1');
    final ws = Workspace.empty('s1').copyWith(
      trackVisits: [
        TrackVisit(
          visitId: 'v1',
          trackId: 'track-A',
          startTimestampMs: 1000,
          endTimestampMs: 20000,
          laps: [_lap(1, 1000, 6000), _lap(2, 6000, 10000)],
        ),
      ],
      trackVisitsLibraryHash: 'sha1:test',
    );

    final container = ProviderContainer(
      overrides: [
        trackProvider
            .overrideWith(() => _StaticTrackNotifier([_track('track-A')])),
        // Feed the cached workspace directly — no file I/O, no Rust handle.
        sessionWorkspaceProvider.overrideWith(() => _FakeWorkspace(ws)),
      ],
    )..read(sessionProvider.notifier).addSession(meta);
    addTearDown(container.dispose);

    // Act
    final rows = await container.read(filteredSessionRowsProvider.future);

    // Assert — best lap = 4000 ms (lap 2), total = 9000 ms, two laps.
    expect(rows, hasLength(1));
    expect(rows.single.laps, hasLength(2));
    expect(rows.single.bestLapMs, 4000);
    expect(rows.single.totalLapMs, 9000);
    expect(rows.single.laps.first.track?.trackId, 'track-A');
  });
}
