import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/exceptions.dart';
import 'package:idl0/data/lap_detector.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/data/workspace.dart';

void main() {
  group('Workspace —', () {
    test('round-trip — lap gates and sector gates survive JSON', () {
      // Arrange — v6 schema: math_channels and workbook_layout are no longer
      // emitted by toJson (channels live on the owning Workbook since v6).
      const original = Workspace(
        workspaceVersion: 1,
        sessionId: 'a1b2c3d4-0000-0000-0000-000000000001',
        lapGates: [
          LapGate(
            lat1Deg: 51.5074,
            lon1Deg: -0.1278,
            lat2Deg: 51.5075,
            lon2Deg: -0.1279,
          ),
        ],
        sectorGates: [
          SectorGate(
            name: 'Rock garden',
            gate: LapGate(
              lat1Deg: 51.5080,
              lon1Deg: -0.1280,
              lat2Deg: 51.5081,
              lon2Deg: -0.1281,
            ),
          ),
        ],
        mathChannels: [],
        workbookLayout: WorkbookLayout(worksheets: []),
      );

      // Act
      final restored = Workspace.fromJson(original.toJson());

      // Assert — workspace_version
      expect(restored.workspaceVersion, equals(1));
      expect(restored.sessionId, equals(original.sessionId));

      // Assert — lap gates
      expect(restored.lapGates.length, equals(1));
      expect(restored.lapGates[0].lat1Deg, equals(51.5074));
      expect(restored.lapGates[0].lon1Deg, equals(-0.1278));
      expect(restored.lapGates[0].lat2Deg, equals(51.5075));
      expect(restored.lapGates[0].lon2Deg, equals(-0.1279));

      // Assert — sector gates
      expect(restored.sectorGates.length, equals(1));
      expect(restored.sectorGates[0].name, equals('Rock garden'));
      expect(restored.sectorGates[0].gate.lat1Deg, equals(51.5080));

      // Assert — math_channels and workbook_layout not emitted (v6 schema)
      expect(original.toJson().containsKey('math_channels'), isFalse);
      expect(original.toJson().containsKey('workbook_layout'), isFalse);
    });

    test(
        'fromJson — workspace_version higher than supported — throws UnsupportedWorkspaceVersionException',
        () {
      // Arrange
      final json = {
        'workspace_version': Workspace.supportedVersion + 1,
        'session_id': 'any-uuid',
        'lap_gates': <dynamic>[],
        'sector_gates': <dynamic>[],
        'math_channels': <dynamic>[],
        'workbook_layout': <String, dynamic>{'worksheets': <dynamic>[]},
      };

      // Act / Assert
      expect(
        () => Workspace.fromJson(json),
        throwsA(isA<UnsupportedWorkspaceVersionException>()),
      );
    });

    test(
        'fromJson — UnsupportedWorkspaceVersionException carries found and supported versions',
        () {
      // Arrange
      const tooNew = 99;
      final json = {
        'workspace_version': tooNew,
        'session_id': 'any-uuid',
        'lap_gates': <dynamic>[],
        'sector_gates': <dynamic>[],
        'math_channels': <dynamic>[],
        'workbook_layout': <String, dynamic>{'worksheets': <dynamic>[]},
      };

      // Act
      UnsupportedWorkspaceVersionException? caught;
      try {
        Workspace.fromJson(json);
      } on UnsupportedWorkspaceVersionException catch (e) {
        caught = e;
      }

      // Assert
      expect(caught, isNotNull);
      expect(caught!.found, equals(tooNew));
      expect(caught.supported, equals(Workspace.supportedVersion));
    });

    test(
        'fromJson — unknown fields in older workspace version — loads silently',
        () {
      // Arrange — version 1 workspace with extra fields that a future app might write
      final json = <String, dynamic>{
        'workspace_version': 1,
        'session_id': 'test-session-uuid',
        'lap_gates': <dynamic>[],
        'sector_gates': <dynamic>[],
        'math_channels': <dynamic>[],
        'workbook_layout': <String, dynamic>{'worksheets': <dynamic>[]},
        // Fields unknown to this version — must be silently ignored
        'unknown_future_field': 'some future value',
        'new_feature_flags': {'enable_xyz': true},
        'extra_list': [1, 2, 3],
      };

      // Act — must not throw
      final workspace = Workspace.fromJson(json);

      // Assert — known fields still loaded correctly
      expect(workspace.sessionId, equals('test-session-uuid'));
      expect(workspace.lapGates, isEmpty);
      expect(workspace.mathChannels, isEmpty);
    });

    test('empty — creates workspace with no gates, channels, or layout', () {
      // Arrange / Act
      final workspace = Workspace.empty('new-session-uuid');

      // Assert
      expect(workspace.sessionId, equals('new-session-uuid'));
      expect(workspace.workspaceVersion, equals(Workspace.supportedVersion));
      expect(workspace.lapGates, isEmpty);
      expect(workspace.sectorGates, isEmpty);
      expect(workspace.mathChannels, isEmpty);
      expect(workspace.workbookLayout.worksheets, isEmpty);
      expect(workspace.referenceLapNumber, isNull);
    });

    test('v2 round-trip — LapGate.name and referenceLapNumber survive JSON',
        () {
      // Arrange
      const original = Workspace(
        workspaceVersion: 2,
        sessionId: 'v2-session',
        lapGates: [
          LapGate(
            lat1Deg: 515074000.0,
            lon1Deg: -1278000.0,
            lat2Deg: 515075000.0,
            lon2Deg: -1279000.0,
            name: 'Top of straight',
          ),
        ],
        sectorGates: [],
        mathChannels: [],
        workbookLayout: WorkbookLayout(worksheets: []),
        referenceLapNumber: 3,
      );

      // Act
      final restored = Workspace.fromJson(original.toJson());

      // Assert
      expect(restored.lapGates.first.name, equals('Top of straight'));
      expect(restored.referenceLapNumber, equals(3));
    });

    test(
        'v1 forward-compat — workspace without name or reference_lap_number '
        '— loads cleanly with defaults', () {
      // Arrange — v1 JSON, predating the v2 fields.
      final json = <String, dynamic>{
        'workspace_version': 1,
        'session_id': 'v1-session',
        'lap_gates': [
          {
            'lat1_deg': 515074000.0,
            'lon1_deg': -1278000.0,
            'lat2_deg': 515075000.0,
            'lon2_deg': -1279000.0,
          },
        ],
        'sector_gates': <dynamic>[],
        'math_channels': <dynamic>[],
        'workbook_layout': <String, dynamic>{'worksheets': <dynamic>[]},
      };

      // Act
      final workspace = Workspace.fromJson(json);

      // Assert — missing fields default
      expect(workspace.workspaceVersion, equals(1));
      expect(workspace.lapGates.first.name, equals(''));
      expect(workspace.referenceLapNumber, isNull);
    });

    test('v3 round-trip — ignoredLapNumbers survives JSON', () {
      // Arrange
      const original = Workspace(
        workspaceVersion: 3,
        sessionId: 'v3-session',
        lapGates: [],
        sectorGates: [],
        mathChannels: [],
        workbookLayout: WorkbookLayout(worksheets: []),
        ignoredLapNumbers: {2, 4, 7},
      );

      // Act
      final restored = Workspace.fromJson(original.toJson());

      // Assert — set survives, sorted in JSON for stable diffs
      expect(restored.ignoredLapNumbers, equals({2, 4, 7}));
      expect(
        original.toJson()['ignored_lap_numbers'],
        equals([2, 4, 7]),
      );
    });

    test('toJson — empty ignoredLapNumbers — key omitted from JSON', () {
      // Arrange — workspace with no ignored laps
      final ws = Workspace.empty('clean-session');

      // Act
      final json = ws.toJson();

      // Assert — empty set is not emitted (keeps file diffs minimal)
      expect(json.containsKey('ignored_lap_numbers'), isFalse);
    });

    test(
        'v2 forward-compat — workspace without ignored_lap_numbers '
        '— loads with empty set', () {
      // Arrange — v2 JSON predating the v3 ignored-laps field.
      final json = <String, dynamic>{
        'workspace_version': 2,
        'session_id': 'v2-session-no-ignored',
        'lap_gates': <dynamic>[],
        'sector_gates': <dynamic>[],
        'math_channels': <dynamic>[],
        'workbook_layout': <String, dynamic>{'worksheets': <dynamic>[]},
        'reference_lap_number': 4,
      };

      // Act
      final workspace = Workspace.fromJson(json);

      // Assert
      expect(workspace.workspaceVersion, equals(2));
      expect(workspace.referenceLapNumber, equals(4));
      expect(workspace.ignoredLapNumbers, isEmpty);
    });

    test('copyWith — replaces ignoredLapNumbers, preserves other fields', () {
      // Arrange
      final ws = Workspace.empty('copy-ignored').copyWith(
        referenceLapNumber: 2,
      );

      // Act
      final updated = ws.copyWith(ignoredLapNumbers: const {1, 3});

      // Assert
      expect(updated.ignoredLapNumbers, equals({1, 3}));
      expect(updated.referenceLapNumber, equals(2));
    });

    test(
        'copyWith / clearReferenceLapNumber — set then clear referenceLapNumber',
        () {
      // Arrange
      final ws = Workspace.empty('copy-session');

      // Act
      final pinned = ws.copyWith(referenceLapNumber: 5);
      final cleared = pinned.clearReferenceLapNumber();

      // Assert
      expect(pinned.referenceLapNumber, equals(5));
      expect(cleared.referenceLapNumber, isNull);
    });

    test('v4 round-trip — trackVisits and trackVisitsLibraryHash survive JSON',
        () {
      // Arrange — workspace with two visits to Track A and one to Track B,
      // and a stored library hash.
      const original = Workspace(
        workspaceVersion: 4,
        sessionId: 'v4-session',
        lapGates: [],
        sectorGates: [],
        mathChannels: [],
        workbookLayout: WorkbookLayout(worksheets: []),
        trackVisits: [
          TrackVisit(
            visitId: 'visit-1',
            trackId: 'track-A',
            startTimestampMs: 1_700_000_000_000,
            endTimestampMs: 1_700_000_120_000,
          ),
          TrackVisit(
            visitId: 'visit-2',
            trackId: 'track-B',
            startTimestampMs: 1_700_000_120_000,
            endTimestampMs: 1_700_000_240_000,
          ),
        ],
        trackVisitsLibraryHash: 'sha1:abcdef',
      );

      // Act
      final restored = Workspace.fromJson(original.toJson());

      // Assert
      expect(restored.trackVisits.length, equals(2));
      expect(restored.trackVisits[0].visitId, equals('visit-1'));
      expect(restored.trackVisits[0].trackId, equals('track-A'));
      expect(restored.trackVisits[0].durationMs, equals(120000));
      expect(restored.trackVisits[1].trackId, equals('track-B'));
      expect(restored.trackVisitsLibraryHash, equals('sha1:abcdef'));
    });

    test(
        'v3 forward-compat — workspace without track_visits — loads with '
        'empty list and null hash', () {
      // Arrange — v3 JSON predating the v4 track_visits fields.
      final json = <String, dynamic>{
        'workspace_version': 3,
        'session_id': 'v3-session-no-visits',
        'lap_gates': <dynamic>[],
        'sector_gates': <dynamic>[],
        'math_channels': <dynamic>[],
        'workbook_layout': <String, dynamic>{'worksheets': <dynamic>[]},
        'ignored_lap_numbers': [1, 2],
      };

      // Act
      final workspace = Workspace.fromJson(json);

      // Assert
      expect(workspace.workspaceVersion, equals(3));
      expect(workspace.trackVisits, isEmpty);
      expect(workspace.trackVisitsLibraryHash, isNull);
      // v3 fields still loaded
      expect(workspace.ignoredLapNumbers, equals({1, 2}));
    });

    test('toJson — empty trackVisits and null hash — keys omitted', () {
      // Arrange — fresh empty workspace.
      final ws = Workspace.empty('clean-session');

      // Act
      final json = ws.toJson();

      // Assert — both v4 keys absent from on-disk diff.
      expect(json.containsKey('track_visits'), isFalse);
      expect(json.containsKey('track_visits_library_hash'), isFalse);
    });

    test('clearTrackVisits — empties visits and clears hash', () {
      // Arrange
      final ws = Workspace.empty('clear-session').copyWith(
        trackVisits: const [
          TrackVisit(
            visitId: 'v',
            trackId: 't',
            startTimestampMs: 1,
            endTimestampMs: 2,
          ),
        ],
        trackVisitsLibraryHash: 'sha1:xxx',
      );

      // Act
      final cleared = ws.clearTrackVisits();

      // Assert
      expect(cleared.trackVisits, isEmpty);
      expect(cleared.trackVisitsLibraryHash, isNull);
    });

    test('v5 round-trip — main/overlay/starred lap fields survive JSON', () {
      // Arrange
      final original = Workspace.empty('s').copyWith(
        mainLapNumber: 3,
        overlayLapKey: (sessionId: 's2', lapNumber: 5),
        starredLapNumber: 1,
      );

      // Act
      final restored = Workspace.fromJson(original.toJson());

      // Assert
      expect(restored.mainLapNumber, equals(3));
      expect(restored.overlayLapKey?.sessionId, equals('s2'));
      expect(restored.overlayLapKey?.lapNumber, equals(5));
      expect(restored.starredLapNumber, equals(1));
    });

    test(
        'v4 forward-compat — workspace without main/overlay/starred fields '
        '— loads with all three null', () {
      // Arrange — v4 JSON predating the v5 main/overlay/starred fields.
      final json = <String, dynamic>{
        'workspace_version': 4,
        'session_id': 'v4-session-no-main-overlay',
        'lap_gates': <dynamic>[],
        'sector_gates': <dynamic>[],
        'math_channels': <dynamic>[],
        'workbook_layout': <String, dynamic>{'worksheets': <dynamic>[]},
      };

      // Act
      final workspace = Workspace.fromJson(json);

      // Assert
      expect(workspace.workspaceVersion, equals(4));
      expect(workspace.mainLapNumber, isNull);
      expect(workspace.overlayLapKey, isNull);
      expect(workspace.starredLapNumber, isNull);
    });

    test('toJson — null main/overlay/starred fields — keys omitted from JSON',
        () {
      // Arrange — fresh empty workspace.
      final ws = Workspace.empty('clean-session');

      // Act
      final json = ws.toJson();

      // Assert — all three v5 keys absent from on-disk diff.
      expect(json.containsKey('main_lap_number'), isFalse);
      expect(json.containsKey('overlay_lap_key'), isFalse);
      expect(json.containsKey('starred_lap_number'), isFalse);
    });

    test('Workspace.empty — uses supported version (v8)', () {
      // Arrange / Act
      final ws = Workspace.empty('s');

      // Assert — bumped to v8; workspaces now carry video links.
      expect(ws.workspaceVersion, equals(8));
      expect(Workspace.supportedVersion, equals(8));
    });

    test(
        'clearMainLapNumber / clearOverlayLapKey / clearStarredLapNumber — '
        'set then clear each field', () {
      // Arrange
      final ws = Workspace.empty('clear-session').copyWith(
        mainLapNumber: 2,
        overlayLapKey: (sessionId: 's2', lapNumber: 4),
        starredLapNumber: 7,
      );

      // Act
      final clearedMain = ws.clearMainLapNumber();
      final clearedOverlay = ws.clearOverlayLapKey();
      final clearedStar = ws.clearStarredLapNumber();

      // Assert — each clears only its own field, leaves others intact.
      expect(clearedMain.mainLapNumber, isNull);
      expect(clearedMain.overlayLapKey?.lapNumber, equals(4));
      expect(clearedMain.starredLapNumber, equals(7));

      expect(clearedOverlay.overlayLapKey, isNull);
      expect(clearedOverlay.mainLapNumber, equals(2));
      expect(clearedOverlay.starredLapNumber, equals(7));

      expect(clearedStar.starredLapNumber, isNull);
      expect(clearedStar.mainLapNumber, equals(2));
      expect(clearedStar.overlayLapKey?.lapNumber, equals(4));
    });

    test('v6 — toJson omits math_channels and workbook_layout', () {
      // Arrange
      const ws = Workspace(
        workspaceVersion: 6,
        sessionId: 'sess',
        lapGates: [],
        sectorGates: [],
        mathChannels: [],
        workbookLayout: WorkbookLayout(worksheets: []),
      );

      // Act
      final json = ws.toJson();

      // Assert — v6 schema: both legacy keys absent from serialised output.
      expect(json.containsKey('math_channels'), isFalse);
      expect(json.containsKey('workbook_layout'), isFalse);
      expect(json['workspace_version'], 6);
    });

    test('v5 fixture — loads cleanly with math_channels reachable in memory',
        () {
      // Arrange — on-disk v5 JSON still carries math_channels; fromJson must
      // hydrate the in-memory field so the migration pass can read it.
      final v5Json = {
        'workspace_version': 5,
        'session_id': 'x',
        'lap_gates': <Map<String, dynamic>>[],
        'sector_gates': <Map<String, dynamic>>[],
        'math_channels': [
          {
            'name': 'F',
            'expression': 'integrate(X)',
            'quantity': 'v',
            'units': 'm/s',
            'sample_rate_hz': 0,
            'decimal_places': 2,
            'color': '#FF0000',
          },
        ],
        'workbook_layout': {'worksheets': <Map<String, dynamic>>[]},
      };

      // Act
      final ws = Workspace.fromJson(v5Json);

      // Assert
      expect(ws.workspaceVersion, 5);
      expect(ws.mathChannels.length, 1);
      expect(ws.mathChannels.first.name, 'F');
    });

    test('Workspace.supportedVersion equals 8', () {
      // Arrange / Act / Assert — locks the bumped constant.
      expect(Workspace.supportedVersion, 8);
    });
  });

  group('TrackVisit laps cache —', () {
    TrackVisit visitWithLaps() => const TrackVisit(
          visitId: 'v1',
          trackId: 't1',
          startTimestampMs: 1000,
          endTimestampMs: 9000,
          laps: [
            Lap(
              lapNumber: 1,
              startTimestampMs: 1000,
              endTimestampMs: 5000,
              rawElapsedMs: 4000,
              lapTimeMs: 4000,
              startTimeSecs: 1.0,
              endTimeSecs: 5.0,
              sectors: [
                Sector(
                  name: 'S1',
                  startTimestampMs: 1000,
                  endTimestampMs: 3000,
                  startTimeSecs: 1.0,
                  endTimeSecs: 3.0,
                ),
              ],
            ),
          ],
        );

    test('toJson/fromJson — round-trips cached laps', () {
      // Arrange
      final visit = visitWithLaps();

      // Act
      final restored = TrackVisit.fromJson(visit.toJson());

      // Assert
      expect(restored.laps, hasLength(1));
      expect(restored.laps.first.lapNumber, 1);
      expect(restored.laps.first.lapTimeMs, 4000);
      expect(restored.laps.first.startTimeSecs, 1.0);
      expect(restored.laps.first.sectors.single.name, 'S1');
    });

    test('fromJson — pre-v7 visit without laps key defaults to empty', () {
      // Arrange — a v6-era TrackVisit JSON has no `laps` key.
      final json = {
        'visit_id': 'v1',
        'track_id': 't1',
        'start_timestamp_ms': 1000,
        'end_timestamp_ms': 9000,
      };

      // Act
      final visit = TrackVisit.fromJson(json);

      // Assert
      expect(visit.laps, isEmpty);
    });

    test('Workspace round-trips visits carrying laps at version 8', () {
      // Arrange
      final ws = Workspace.empty('sess-1').copyWith(
        trackVisits: [visitWithLaps()],
        trackVisitsLibraryHash: 'sha1:abc',
      );

      // Act
      final restored = Workspace.fromJson(ws.toJson());

      // Assert
      expect(restored.workspaceVersion, 8);
      expect(restored.trackVisits.single.laps.single.lapTimeMs, 4000);
    });

    test('clearTrackVisits drops cached laps with their visits', () {
      // Arrange
      final ws = Workspace.empty('sess-1').copyWith(
        trackVisits: [visitWithLaps()],
        trackVisitsLibraryHash: 'sha1:abc',
      );

      // Act
      final cleared = ws.clearTrackVisits();

      // Assert
      expect(cleared.trackVisits, isEmpty);
    });

  });

  group('Workspace v8 — videos —', () {
    Map<String, dynamic> v8Json() => {
          'workspace_version': 8,
          'session_id': 's-1',
          'lap_gates': <dynamic>[],
          'sector_gates': <dynamic>[],
          'videos': [
            {
              'id': 'v-uuid-1',
              'path': 'C:/rides/GX010001.mp4',
              'file_size_bytes': 123456789,
              'file_mtime_ms': 1751000000000,
              'sync_offset_s': 12.34,
              'sync_method': 'gpmf',
              'sync_confidence': 0.9,
              'label': 'Chest cam',
            },
            {
              'id': 'v-uuid-2',
              'path': 'C:/rides/GX020001.mp4',
              'file_size_bytes': 1,
              'file_mtime_ms': 2,
              'sync_offset_s': 0.0,
              'sync_method': 'manual',
            },
          ],
        };

    test('fromJson — v8 with two links — parses fields and null confidence',
        () {
      // Arrange
      final json = v8Json();

      // Act
      final ws = Workspace.fromJson(json);

      // Assert
      expect(ws.videos, hasLength(2));
      expect(ws.videos.first.path, 'C:/rides/GX010001.mp4');
      expect(ws.videos.first.syncOffsetS, closeTo(12.34, 1e-9));
      expect(ws.videos.first.syncMethod, 'gpmf');
      expect(ws.videos.first.syncConfidence, closeTo(0.9, 1e-9));
      expect(ws.videos.last.syncConfidence, isNull);
      expect(ws.videos.last.label, isNull);
    });

    test('toJson/fromJson — round-trip — identical videos', () {
      // Arrange
      final ws = Workspace.fromJson(v8Json());

      // Act
      final back = Workspace.fromJson(ws.toJson());

      // Assert
      expect(back.videos, hasLength(2));
      expect(back.toJson()['videos'], ws.toJson()['videos']);
    });

    test('fromJson — v7 file without videos — defaults to empty', () {
      // Arrange
      final json = v8Json()
        ..['workspace_version'] = 7
        ..remove('videos');

      // Act
      final ws = Workspace.fromJson(json);

      // Assert
      expect(ws.videos, isEmpty);
    });

    test('toJson — no videos — omits the key', () {
      // Arrange
      final ws = Workspace.empty('s-1');

      // Act + Assert
      expect(ws.toJson().containsKey('videos'), isFalse);
      expect(ws.workspaceVersion, 8);
    });
  });
}
