import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/lap_detector.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/data/track.dart';
import 'package:idl0/data/workspace.dart';
import 'package:idl0/providers/lap_provider.dart';
import 'package:idl0/providers/session_provider.dart';
import 'package:idl0/providers/session_workspace_provider.dart';
import 'package:idl0/providers/track_provider.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

SessionMetadata _meta(String id, String workspacePath) => SessionMetadata(
      sessionId: id,
      filePath: '/sessions/$id.idl0',
      workspacePath: workspacePath,
      createdTimestampMs: DateTime(2026, 4, 20).millisecondsSinceEpoch,
      fileSizeBytes: 0,
      rider: '',
      bike: '',
      bikeComment: '',
      venueName: '',
      eventName: '',
      shortComment: '',
      longComment: '',
      deviceId: '',
      eventSession: '',
    );

/// Builds three GPS channels (lat, lon, epoch) at the firmware × 1e7 scale
/// matching the v2 binary parser convention.
List<ChannelData> _gpsChannels({
  required List<double> latDeg,
  required List<double> lonDeg,
  required List<int> epochMs,
}) {
  return [
    ChannelData(
      channelId: 'GPS_Latitude',
      sampleRateHz: 0,
      samples: latDeg.map((d) => d * 1e7).toList(),
    ),
    ChannelData(
      channelId: 'GPS_Longitude',
      sampleRateHz: 0,
      samples: lonDeg.map((d) => d * 1e7).toList(),
    ),
    ChannelData(
      channelId: 'GPS_EpochMs',
      sampleRateHz: 0,
      samples: epochMs.map((m) => m.toDouble()).toList(),
    ),
  ];
}

/// Vertical gate line at [lonDeg] spanning [lat1Deg]..[lat2Deg], stored at
/// the firmware × 1e7 scale.
LapGate _vGate(double lonDeg, double lat1Deg, double lat2Deg,
        {String name = '',}) =>
    LapGate(
      lat1Deg: lat1Deg * 1e7,
      lon1Deg: lonDeg * 1e7,
      lat2Deg: lat2Deg * 1e7,
      lon2Deg: lonDeg * 1e7,
      name: name,
    );

/// Persists [workspace] to a freshly-created temp `.idl0w` file. Returns the
/// path. Test must clean up via [_cleanup].
Future<String> _writeWorkspace(String id, Workspace workspace) async {
  final path =
      '${Directory.systemTemp.path}/idl0_lap_test_${id}_${DateTime.now().microsecondsSinceEpoch}.idl0w';
  await workspace.save(path);
  return path;
}

void _cleanup(String path) {
  final f = File(path);
  if (f.existsSync()) f.deleteSync();
}

ProviderContainer _container({
  required SessionMetadata meta,
  // Retained for call-site readability of the GPS fixtures these tests describe.
  // Lap detection now reads GPS from the retained session handle (`gpsTrack`),
  // not a Dart channel list, so there is no channel-data override to apply here;
  // the workspace's cached laps / gates drive these assertions.
  AsyncValue<List<ChannelData>> channels = const AsyncData([]),
  List<Track> tracks = const [],
}) {
  return ProviderContainer(
    overrides: [
      // Make saver a no-op — we never mutate in these tests, but the
      // notifier reads the factory in build() before deciding to load.
      workspaceSaverFactoryProvider.overrideWith(
        (_) => (_) => _NoopSaver(),
      ),
      trackProvider.overrideWith(() => _StaticTrackNotifier(tracks)),
    ],
  )..read(sessionProvider.notifier).addSession(meta);
}

class _NoopSaver implements WorkspaceSaver {
  @override
  Future<void> save(Workspace workspace) async {}
}

/// Minimal [TrackNotifier] override that returns a fixed list without touching
/// SQLite or Drive — used to inject synthetic Tracks into lap-detection tests.
class _StaticTrackNotifier extends TrackNotifier {
  _StaticTrackNotifier(this._tracks);

  final List<Track> _tracks;

  @override
  Future<List<Track>> build() async => _tracks;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('sessionLapsProvider —', () {
    test('workspace has zero gates — emits AsyncData with empty list',
        () async {
      // Arrange
      final wsPath = await _writeWorkspace('zero', Workspace.empty('uuid-1'));
      addTearDown(() => _cleanup(wsPath));

      final container = _container(
        meta: _meta('uuid-1', wsPath),
        channels: AsyncData(
          _gpsChannels(
            latDeg: [47.6, 47.6, 47.6],
            lonDeg: [-122.0, -122.0001, -122.0002],
            epochMs: [0, 1000, 2000],
          ),
        ),
      );
      addTearDown(container.dispose);

      await container.read(sessionWorkspaceProvider('uuid-1').future);

      // Act
      final laps = container.read(sessionLapsProvider('uuid-1'));

      // Assert
      expect(laps, isA<AsyncData<List<Lap>>>());
      expect(laps.requireValue, isEmpty);
    });

    // NOTE: end-to-end gate-crossing lap detection (circuit + point-to-point)
    // now runs entirely in the idl-rs engine (`rust.detectLaps`, Phase-4a). The
    // former Dart tests here injected GPS via a `channels:` override that no
    // longer feeds detection (GPS is read from the retained session handle's
    // `gpsTrack`), so they could not exercise the real path under `flutter
    // test` (no bridge native library). Detection is covered by the rust/core
    // lap suite (`idl_rs::laps::detect` — circuit_two_crossings_two_laps,
    // point_to_point_start_then_finish_one_lap, and siblings).

    group('resolveGhostReferenceLapNumber —', () {
      Lap lap(int n, int timeMs) => Lap(
            lapNumber: n,
            startTimestampMs: 0,
            endTimestampMs: timeMs,
            rawElapsedMs: timeMs,
            lapTimeMs: timeMs,
          );

      test('no laps — returns null', () {
        // Arrange / Act
        final result = resolveGhostReferenceLapNumber(
          laps: const [],
          ignored: const {},
          pinned: null,
        );

        // Assert
        expect(result, isNull);
      });

      test('all laps ignored — returns null', () {
        // Arrange
        final laps = [lap(1, 100000), lap(2, 95000)];

        // Act
        final result = resolveGhostReferenceLapNumber(
          laps: laps,
          ignored: const {1, 2},
          pinned: null,
        );

        // Assert
        expect(result, isNull);
      });

      test('no pin — fastest non-ignored is reference (skips ignored fastest)',
          () {
        // Arrange — lap 1 is fastest but ignored; lap 3 is fastest non-ignored.
        final laps = [
          lap(1, 80000),
          lap(2, 105000),
          lap(3, 95000),
        ];

        // Act
        final result = resolveGhostReferenceLapNumber(
          laps: laps,
          ignored: const {1},
          pinned: null,
        );

        // Assert
        expect(result, equals(3));
      });

      test('pin honoured when not ignored', () {
        // Arrange
        final laps = [lap(1, 100000), lap(2, 90000), lap(3, 95000)];

        // Act
        final result = resolveGhostReferenceLapNumber(
          laps: laps,
          ignored: const {},
          pinned: 3,
        );

        // Assert — pinned 3 used even though lap 2 is faster.
        expect(result, equals(3));
      });

      test('pin ignored — falls back to fastest non-ignored', () {
        // Arrange
        final laps = [lap(1, 100000), lap(2, 90000), lap(3, 95000)];

        // Act
        final result = resolveGhostReferenceLapNumber(
          laps: laps,
          ignored: const {3},
          pinned: 3,
        );

        // Assert — pinned ignored → fall back to lap 2 (fastest non-ignored).
        expect(result, equals(2));
      });

      test('pin not in laps list — falls back to fastest non-ignored', () {
        // Arrange — pin references lap 99 which doesn't exist.
        final laps = [lap(1, 100000), lap(2, 95000)];

        // Act
        final result = resolveGhostReferenceLapNumber(
          laps: laps,
          ignored: const {},
          pinned: 99,
        );

        // Assert
        expect(result, equals(2));
      });
    });

    test('lapDistanceAccumulatorProvider — lap not in session — returns null',
        () async {
      // Arrange — empty workspace, no laps detected.
      final wsPath = await _writeWorkspace(
        'lda-empty',
        Workspace.empty('uuid-lda'),
      );
      addTearDown(() => _cleanup(wsPath));

      final container = _container(
        meta: _meta('uuid-lda', wsPath),
        channels: const AsyncData<List<ChannelData>>([]),
      );
      addTearDown(container.dispose);

      await container.read(sessionWorkspaceProvider('uuid-lda').future);

      // Act — request the accumulator for a lap number that doesn't
      // exist; the provider must short-circuit to null instead of
      // throwing or stalling.
      final result = await container.read(
        lapDistanceAccumulatorProvider(
          (sessionId: 'uuid-lda', lapNumber: 1),
        ).future,
      );

      // Assert
      expect(result, isNull);
    });

    test('GPS channels missing — emits AsyncData with empty list', () async {
      // Arrange — workspace has a gate but channels include no GPS data.
      final ws = Workspace(
        workspaceVersion: Workspace.supportedVersion,
        sessionId: 'uuid-4',
        lapGates: [_vGate(-122.0, 47.59, 47.61)],
        sectorGates: const [],
        mathChannels: const [],
        workbookLayout: const WorkbookLayout(worksheets: []),
      );
      final wsPath = await _writeWorkspace('no-gps', ws);
      addTearDown(() => _cleanup(wsPath));

      final container = _container(
        meta: _meta('uuid-4', wsPath),
        channels: const AsyncData<List<ChannelData>>([]),
      );
      addTearDown(container.dispose);

      await container.read(sessionWorkspaceProvider('uuid-4').future);

      // Act
      final laps = container.read(sessionLapsProvider('uuid-4'));

      // Assert
      expect(laps, isA<AsyncData<List<Lap>>>());
      expect(laps.requireValue, isEmpty);
    });
  });

  group('SessionWorkspaceNotifier — load / save round-trip', () {
    test('build — workspace file does not exist — returns Workspace.empty',
        () async {
      // Arrange — synthetic path that has not been written.
      final wsPath =
          '${Directory.systemTemp.path}/idl0_missing_${DateTime.now().microsecondsSinceEpoch}.idl0w';
      addTearDown(() => _cleanup(wsPath));

      final container = _container(
        meta: _meta('new-1', wsPath),
        channels: const AsyncData<List<ChannelData>>([]),
      );
      addTearDown(container.dispose);

      // Act
      final ws = await container.read(sessionWorkspaceProvider('new-1').future);

      // Assert
      expect(ws.lapGates, isEmpty);
      expect(ws.sectorGates, isEmpty);
      expect(ws.referenceLapNumber, isNull);
      expect(ws.workspaceVersion, equals(Workspace.supportedVersion));
    });

    test('addLapGate then setReferenceLapNumber — round-trips through file',
        () async {
      // Arrange — start with an existing empty file.
      final wsPath = await _writeWorkspace(
        'rt',
        Workspace.empty('rt-1'),
      );
      addTearDown(() => _cleanup(wsPath));

      final container = ProviderContainer()
        ..read(sessionProvider.notifier).addSession(_meta('rt-1', wsPath));
      addTearDown(container.dispose);

      await container.read(sessionWorkspaceProvider('rt-1').future);

      // Act — add a lap gate and pin a reference lap; both are saved
      // synchronously by the notifier.
      final notifier =
          container.read(sessionWorkspaceProvider('rt-1').notifier);
      await notifier.addLapGate(
        _vGate(-122.0, 47.59, 47.61, name: 'Finish line'),
      );
      await notifier.setReferenceLapNumber(2);

      // Re-load the file from disk to verify it persisted.
      final reloaded = await Workspace.load(wsPath);

      // Assert
      expect(reloaded.lapGates, hasLength(1));
      expect(reloaded.lapGates.first.name, equals('Finish line'));
      expect(reloaded.referenceLapNumber, equals(2));
    });
  });
}
