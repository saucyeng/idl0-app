import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/lap_detector.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/data/workspace.dart';
import 'package:idl0/providers/session_provider.dart';
import 'package:idl0/providers/session_workspace_provider.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

SessionMetadata _meta(String id, String workspacePath) => SessionMetadata(
      sessionId: id,
      filePath: '/sessions/$id.idl0',
      workspacePath: workspacePath,
      createdTimestampMs: DateTime(2026, 4, 27).millisecondsSinceEpoch,
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

LapGate _gate(double offset) => LapGate(
      lat1Deg: offset,
      lon1Deg: offset,
      lat2Deg: offset + 1,
      lon2Deg: offset + 1,
    );

SectorGate _sector(String name) => SectorGate(name: name, gate: _gate(0));

class _NoopSaver implements WorkspaceSaver {
  @override
  Future<void> save(Workspace workspace) async {}
}

Future<String> _writeWorkspace(Workspace workspace, String tag) async {
  final path =
      '${Directory.systemTemp.path}/idl0_swp_test_${tag}_${DateTime.now().microsecondsSinceEpoch}.idl0w';
  await workspace.save(path);
  return path;
}

void _cleanup(String path) {
  final f = File(path);
  if (f.existsSync()) f.deleteSync();
}

ProviderContainer _container(SessionMetadata meta) => ProviderContainer(
      overrides: [
        workspaceSaverFactoryProvider.overrideWith(
          (_) => (_) => _NoopSaver(),
        ),
      ],
    )..read(sessionProvider.notifier).addSession(meta);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('SessionWorkspaceNotifier.reorderSectorGates —', () {
    test(
        'move from index 0 to index 2 — applies ReorderableListView convention',
        () async {
      // Arrange — three sector gates A, B, C.
      final ws = Workspace(
        workspaceVersion: Workspace.supportedVersion,
        sessionId: 'uuid-1',
        lapGates: const [],
        sectorGates: [_sector('A'), _sector('B'), _sector('C')],
        mathChannels: const [],
        workbookLayout: const WorkbookLayout(worksheets: []),
      );
      final wsPath = await _writeWorkspace(ws, 'reorder-forward');
      addTearDown(() => _cleanup(wsPath));

      final container = _container(_meta('uuid-1', wsPath));
      addTearDown(container.dispose);
      await container.read(sessionWorkspaceProvider('uuid-1').future);

      // Act — drag A from position 0 to "after C". ReorderableListView reports
      // newIndex = 3 because newIndex > oldIndex includes the source slot.
      await container
          .read(sessionWorkspaceProvider('uuid-1').notifier)
          .reorderSectorGates(0, 3);

      // Assert
      final result =
          container.read(sessionWorkspaceProvider('uuid-1')).requireValue;
      expect(
        result.sectorGates.map((s) => s.name).toList(),
        equals(['B', 'C', 'A']),
      );
    });

    test(
        'move from index 2 to index 0 — backward move keeps newIndex unchanged',
        () async {
      // Arrange
      final ws = Workspace(
        workspaceVersion: Workspace.supportedVersion,
        sessionId: 'uuid-2',
        lapGates: const [],
        sectorGates: [_sector('A'), _sector('B'), _sector('C')],
        mathChannels: const [],
        workbookLayout: const WorkbookLayout(worksheets: []),
      );
      final wsPath = await _writeWorkspace(ws, 'reorder-backward');
      addTearDown(() => _cleanup(wsPath));

      final container = _container(_meta('uuid-2', wsPath));
      addTearDown(container.dispose);
      await container.read(sessionWorkspaceProvider('uuid-2').future);

      // Act — drag C to the very front.
      await container
          .read(sessionWorkspaceProvider('uuid-2').notifier)
          .reorderSectorGates(2, 0);

      // Assert
      final result =
          container.read(sessionWorkspaceProvider('uuid-2')).requireValue;
      expect(
        result.sectorGates.map((s) => s.name).toList(),
        equals(['C', 'A', 'B']),
      );
    });

    test('updateLapGate — replaces entry at index, preserves others', () async {
      // Arrange
      final ws = Workspace(
        workspaceVersion: Workspace.supportedVersion,
        sessionId: 'uuid-update-lap',
        lapGates: [_gate(1), _gate(2), _gate(3)],
        sectorGates: const [],
        mathChannels: const [],
        workbookLayout: const WorkbookLayout(worksheets: []),
      );
      final wsPath = await _writeWorkspace(ws, 'update-lap');
      addTearDown(() => _cleanup(wsPath));

      final container = _container(_meta('uuid-update-lap', wsPath));
      addTearDown(container.dispose);
      await container.read(sessionWorkspaceProvider('uuid-update-lap').future);

      // Act — move endpoint of middle gate.
      const updated = LapGate(
        lat1Deg: 99,
        lon1Deg: 99,
        lat2Deg: 100,
        lon2Deg: 100,
        name: 'Moved',
      );
      await container
          .read(sessionWorkspaceProvider('uuid-update-lap').notifier)
          .updateLapGate(1, updated);

      // Assert
      final result = container
          .read(sessionWorkspaceProvider('uuid-update-lap'))
          .requireValue;
      expect(result.lapGates.length, equals(3));
      expect(result.lapGates[1].lat1Deg, equals(99));
      expect(result.lapGates[1].name, equals('Moved'));
      expect(result.lapGates[0].lat1Deg, equals(1));
      expect(result.lapGates[2].lat1Deg, equals(3));
    });

    test('updateLapGate — out-of-range index is a no-op', () async {
      // Arrange
      final ws = Workspace(
        workspaceVersion: Workspace.supportedVersion,
        sessionId: 'uuid-update-oob',
        lapGates: [_gate(1)],
        sectorGates: const [],
        mathChannels: const [],
        workbookLayout: const WorkbookLayout(worksheets: []),
      );
      final wsPath = await _writeWorkspace(ws, 'update-lap-oob');
      addTearDown(() => _cleanup(wsPath));

      final container = _container(_meta('uuid-update-oob', wsPath));
      addTearDown(container.dispose);
      await container.read(sessionWorkspaceProvider('uuid-update-oob').future);

      // Act
      await container
          .read(sessionWorkspaceProvider('uuid-update-oob').notifier)
          .updateLapGate(5, _gate(99));

      // Assert
      final result = container
          .read(sessionWorkspaceProvider('uuid-update-oob'))
          .requireValue;
      expect(result.lapGates.length, equals(1));
      expect(result.lapGates[0].lat1Deg, equals(1));
    });

    test('updateSectorGate — replaces entry at index', () async {
      // Arrange
      final ws = Workspace(
        workspaceVersion: Workspace.supportedVersion,
        sessionId: 'uuid-update-sector',
        lapGates: const [],
        sectorGates: [_sector('A'), _sector('B')],
        mathChannels: const [],
        workbookLayout: const WorkbookLayout(worksheets: []),
      );
      final wsPath = await _writeWorkspace(ws, 'update-sector');
      addTearDown(() => _cleanup(wsPath));

      final container = _container(_meta('uuid-update-sector', wsPath));
      addTearDown(container.dispose);
      await container
          .read(sessionWorkspaceProvider('uuid-update-sector').future);

      // Act — keep name, move endpoints.
      final updated = SectorGate(name: 'A', gate: _gate(50));
      await container
          .read(sessionWorkspaceProvider('uuid-update-sector').notifier)
          .updateSectorGate(0, updated);

      // Assert
      final result = container
          .read(sessionWorkspaceProvider('uuid-update-sector'))
          .requireValue;
      expect(result.sectorGates[0].gate.lat1Deg, equals(50));
      expect(result.sectorGates[1].name, equals('B'));
    });

    test('swapLapGates — two gates — exchanges indices 0 and 1', () async {
      // Arrange
      final ws = Workspace(
        workspaceVersion: Workspace.supportedVersion,
        sessionId: 'uuid-swap-2',
        lapGates: [_gate(1), _gate(2)],
        sectorGates: const [],
        mathChannels: const [],
        workbookLayout: const WorkbookLayout(worksheets: []),
      );
      final wsPath = await _writeWorkspace(ws, 'swap-two');
      addTearDown(() => _cleanup(wsPath));

      final container = _container(_meta('uuid-swap-2', wsPath));
      addTearDown(container.dispose);
      await container.read(sessionWorkspaceProvider('uuid-swap-2').future);

      // Act
      await container
          .read(sessionWorkspaceProvider('uuid-swap-2').notifier)
          .swapLapGates();

      // Assert
      final result =
          container.read(sessionWorkspaceProvider('uuid-swap-2')).requireValue;
      expect(result.lapGates[0].lat1Deg, equals(2));
      expect(result.lapGates[1].lat1Deg, equals(1));
    });

    test('swapLapGates — fewer than two gates — no-op', () async {
      // Arrange
      final ws = Workspace(
        workspaceVersion: Workspace.supportedVersion,
        sessionId: 'uuid-swap-1',
        lapGates: [_gate(1)],
        sectorGates: const [],
        mathChannels: const [],
        workbookLayout: const WorkbookLayout(worksheets: []),
      );
      final wsPath = await _writeWorkspace(ws, 'swap-one');
      addTearDown(() => _cleanup(wsPath));

      final container = _container(_meta('uuid-swap-1', wsPath));
      addTearDown(container.dispose);
      await container.read(sessionWorkspaceProvider('uuid-swap-1').future);

      // Act
      await container
          .read(sessionWorkspaceProvider('uuid-swap-1').notifier)
          .swapLapGates();

      // Assert
      final result =
          container.read(sessionWorkspaceProvider('uuid-swap-1')).requireValue;
      expect(result.lapGates.length, equals(1));
      expect(result.lapGates[0].lat1Deg, equals(1));
    });

    test('ignoreLap then unignoreLap — round-trips ignoredLapNumbers',
        () async {
      // Arrange
      const ws = Workspace(
        workspaceVersion: Workspace.supportedVersion,
        sessionId: 'uuid-ignore',
        lapGates: [],
        sectorGates: [],
        mathChannels: [],
        workbookLayout: WorkbookLayout(worksheets: []),
      );
      final wsPath = await _writeWorkspace(ws, 'ignore-lap');
      addTearDown(() => _cleanup(wsPath));

      final container = _container(_meta('uuid-ignore', wsPath));
      addTearDown(container.dispose);
      await container.read(sessionWorkspaceProvider('uuid-ignore').future);

      final notifier =
          container.read(sessionWorkspaceProvider('uuid-ignore').notifier);

      // Act — ignore 2, then 5, then unignore 2.
      await notifier.ignoreLap(2);
      await notifier.ignoreLap(5);
      await notifier.unignoreLap(2);

      // Assert
      final result =
          container.read(sessionWorkspaceProvider('uuid-ignore')).requireValue;
      expect(result.ignoredLapNumbers, equals({5}));
    });

    test('ignoreLap — duplicate is a no-op', () async {
      // Arrange
      const ws = Workspace(
        workspaceVersion: Workspace.supportedVersion,
        sessionId: 'uuid-ignore-dup',
        lapGates: [],
        sectorGates: [],
        mathChannels: [],
        workbookLayout: WorkbookLayout(worksheets: []),
        ignoredLapNumbers: {3},
      );
      final wsPath = await _writeWorkspace(ws, 'ignore-dup');
      addTearDown(() => _cleanup(wsPath));

      final container = _container(_meta('uuid-ignore-dup', wsPath));
      addTearDown(container.dispose);
      await container.read(sessionWorkspaceProvider('uuid-ignore-dup').future);

      // Act
      await container
          .read(sessionWorkspaceProvider('uuid-ignore-dup').notifier)
          .ignoreLap(3);

      // Assert
      final result = container
          .read(sessionWorkspaceProvider('uuid-ignore-dup'))
          .requireValue;
      expect(result.ignoredLapNumbers, equals({3}));
    });

    test('clearIgnoredLaps — empties the ignored set', () async {
      // Arrange
      const ws = Workspace(
        workspaceVersion: Workspace.supportedVersion,
        sessionId: 'uuid-ignore-clear',
        lapGates: [],
        sectorGates: [],
        mathChannels: [],
        workbookLayout: WorkbookLayout(worksheets: []),
        ignoredLapNumbers: {1, 4, 7},
      );
      final wsPath = await _writeWorkspace(ws, 'ignore-clear');
      addTearDown(() => _cleanup(wsPath));

      final container = _container(_meta('uuid-ignore-clear', wsPath));
      addTearDown(container.dispose);
      await container
          .read(sessionWorkspaceProvider('uuid-ignore-clear').future);

      // Act
      await container
          .read(sessionWorkspaceProvider('uuid-ignore-clear').notifier)
          .clearIgnoredLaps();

      // Assert
      final result = container
          .read(sessionWorkspaceProvider('uuid-ignore-clear'))
          .requireValue;
      expect(result.ignoredLapNumbers, isEmpty);
    });

    test('out-of-range oldIndex — no-op', () async {
      // Arrange
      final ws = Workspace(
        workspaceVersion: Workspace.supportedVersion,
        sessionId: 'uuid-3',
        lapGates: const [],
        sectorGates: [_sector('A'), _sector('B')],
        mathChannels: const [],
        workbookLayout: const WorkbookLayout(worksheets: []),
      );
      final wsPath = await _writeWorkspace(ws, 'reorder-oob');
      addTearDown(() => _cleanup(wsPath));

      final container = _container(_meta('uuid-3', wsPath));
      addTearDown(container.dispose);
      await container.read(sessionWorkspaceProvider('uuid-3').future);

      // Act
      await container
          .read(sessionWorkspaceProvider('uuid-3').notifier)
          .reorderSectorGates(5, 0);

      // Assert — order preserved
      final result =
          container.read(sessionWorkspaceProvider('uuid-3')).requireValue;
      expect(
        result.sectorGates.map((s) => s.name).toList(),
        equals(['A', 'B']),
      );
    });
  });
}
