import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/device_provider.dart';
import 'package:idl0/providers/runs_provider.dart';
import 'package:idl0/providers/session_provider.dart';
import 'package:idl0/providers/settings_provider.dart';
import 'package:idl0/providers/sync_controller.dart';
import 'package:idl0/providers/wifi_bind_controller.dart';
import 'package:idl0/transport/ble_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_wifi_service.dart';
import '../helpers/mock_ble_service.dart';
import '../helpers/session_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeWifiService wifi;

  ProviderContainer makeContainer({List<String> libraryIds = const []}) {
    final c = ProviderContainer(
      overrides: [wifiServiceProvider.overrideWithValue(wifi)],
    );
    c.read(sessionProvider.notifier).loadSessions(
      [for (final id in libraryIds) sessionMeta(id)],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() => wifi = FakeWifiService());

  group('SyncController.list —', () {
    test('classifies NEW / IN LIBRARY / unknown, all unchecked by default',
        () async {
      // Arrange
      wifi.files = const [
        (name: 'a.idl0', size: 100, sessionId: 'sid-A'), // in library
        (name: 'b.idl0', size: 200, sessionId: 'sid-B'), // new
        (name: 'c.idl0', size: 300, sessionId: ''), // unknown
      ];
      final c = makeContainer(libraryIds: ['sid-A']);

      // Act
      await c.read(syncControllerProvider.notifier).list();

      // Assert — look up by name (entries are sorted, so don't assume index)
      final entries = c.read(syncControllerProvider).entries;
      SyncEntry byName(String n) => entries.firstWhere((e) => e.file.name == n);
      expect(byName('a.idl0').status, SyncEntryStatus.inLibrary);
      expect(byName('b.idl0').status, SyncEntryStatus.newPending);
      expect(byName('c.idl0').status, SyncEntryStatus.unknownIdentity);
      // Picker semantics: nothing is pre-selected.
      expect(entries.every((e) => !e.selected), isTrue);
      expect(c.read(syncControllerProvider).newCount, 2);
    });

    test('sorts entries newest-first (filename descending)', () async {
      // Arrange — timestamp filenames (§15.1) sort chronologically.
      wifi.files = const [
        (name: '2026-05-01_10-00-00.idl0', size: 1, sessionId: 's1'),
        (name: '2026-05-03_10-00-00.idl0', size: 1, sessionId: 's3'),
        (name: '2026-05-02_10-00-00.idl0', size: 1, sessionId: 's2'),
      ];
      final c = makeContainer();

      // Act
      await c.read(syncControllerProvider.notifier).list();

      // Assert
      final names = c
          .read(syncControllerProvider)
          .entries
          .map((e) => e.file.name)
          .toList();
      expect(
        names,
        equals([
          '2026-05-03_10-00-00.idl0',
          '2026-05-02_10-00-00.idl0',
          '2026-05-01_10-00-00.idl0',
        ]),
      );
    });

    test('transport failure sets error phase, no crash', () async {
      // Arrange
      wifi.listError = const DummyTransportException('offline');
      final c = makeContainer();

      // Act
      await c.read(syncControllerProvider.notifier).list();

      // Assert
      expect(c.read(syncControllerProvider).phase, SyncPhase.error);
      expect(c.read(syncControllerProvider).listError, contains('offline'));
    });
  });

  group('SyncController.syncAllNew —', () {
    test(
        'downloads every NEW file sequentially (newest-first), skipping '
        'in-library', () async {
      // Arrange
      wifi.files = const [
        (name: 'b.idl0', size: 200, sessionId: 'sid-B'),
        (name: 'c.idl0', size: 300, sessionId: 'sid-C'),
        (name: 'a.idl0', size: 100, sessionId: 'sid-A'), // in library, skipped
      ];
      final fakeRuns = _FakeRuns();
      final c = ProviderContainer(
        overrides: [
          wifiServiceProvider.overrideWithValue(wifi),
          runsProvider.overrideWith(() => fakeRuns),
        ],
      );
      c.read(sessionProvider.notifier).loadSessions([sessionMeta('sid-A')]);
      addTearDown(c.dispose);

      // Act — the connect-and-forget path.
      await c.read(syncControllerProvider.notifier).list();
      await c.read(syncControllerProvider.notifier).syncAllNew();

      // Assert — newest-first order (c before b); a is in library, skipped.
      expect(wifi.downloadLog, equals(['c.idl0', 'b.idl0']));
      expect(fakeRuns.registered, equals(['c.idl0', 'b.idl0']));
      expect(c.read(syncControllerProvider).phase, SyncPhase.done);
    });

    test('a failing download marks that entry error and continues', () async {
      // Arrange
      wifi.files = const [
        (name: 'b.idl0', size: 200, sessionId: 'sid-B'),
        (name: 'c.idl0', size: 300, sessionId: 'sid-C'),
      ];
      wifi.failDownloads = {'b.idl0'};
      final c = ProviderContainer(
        overrides: [
          wifiServiceProvider.overrideWithValue(wifi),
          runsProvider.overrideWith(() => _FakeRuns()),
        ],
      );
      addTearDown(c.dispose);

      // Act
      await c.read(syncControllerProvider.notifier).list();
      await c.read(syncControllerProvider.notifier).syncAllNew();

      // Assert — b errored, c still downloaded
      final entries = c.read(syncControllerProvider).entries;
      SyncEntry byName(String n) => entries.firstWhere((e) => e.file.name == n);
      expect(byName('b.idl0').status, SyncEntryStatus.error);
      expect(byName('b.idl0').errorMessage, isNotNull);
      expect(byName('c.idl0').status, SyncEntryStatus.done);
      expect(wifi.downloadLog, equals(['c.idl0', 'b.idl0']));
    });
  });

  group('SyncController.sync (manual selection) —', () {
    test('downloads only the files the user checked', () async {
      // Arrange
      wifi.files = const [
        (name: 'b.idl0', size: 200, sessionId: 'sid-B'),
        (name: 'c.idl0', size: 300, sessionId: 'sid-C'),
      ];
      final c = ProviderContainer(
        overrides: [
          wifiServiceProvider.overrideWithValue(wifi),
          runsProvider.overrideWith(() => _FakeRuns()),
        ],
      );
      addTearDown(c.dispose);

      // Act — check only b, then download the selection.
      await c.read(syncControllerProvider.notifier).list();
      c.read(syncControllerProvider.notifier).toggle('b.idl0');
      await c.read(syncControllerProvider.notifier).sync();

      // Assert — only b.idl0 downloaded
      expect(wifi.downloadLog, equals(['b.idl0']));
    });
  });

  group('SyncController.list — WiFi link gate —', () {
    test('list waits while the bind is converging, proceeds once bound',
        () async {
      // Arrange — device in WiFi mode with the bind still in flight (the
      // auto-sync-on-open race observed in the field: the first /files
      // fired before the link was up and hit a dead route).
      final ble = MockBleService();
      wifi.bindGate = Completer<void>();
      wifi.files = const [(name: 'a.idl0', size: 1, sessionId: 's1')];
      final c = ProviderContainer(
        overrides: [
          bleServiceProvider.overrideWithValue(ble),
          wifiServiceProvider.overrideWithValue(wifi),
        ],
      );
      addTearDown(c.dispose);
      await c.read(deviceProvider.notifier).connect();
      c.read(wifiBindControllerProvider); // activate bind-follows-mode
      ble.statusController.add(DeviceStatus.fromString('WiFi: ON'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        c.read(wifiBindControllerProvider).phase,
        WifiBindPhase.binding,
      );

      // Act — list while the link is converging; /files must not fire yet.
      final listing = c.read(syncControllerProvider.notifier).list();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(wifi.listCalls, equals(0));
      expect(c.read(syncControllerProvider).phase, SyncPhase.listing);

      wifi.bindGate!.complete(); // link converges → bound
      await listing;

      // Assert — proceeded exactly once, after the link came up.
      expect(wifi.listCalls, equals(1));
      expect(c.read(syncControllerProvider).entries, hasLength(1));
      expect(c.read(syncControllerProvider).phase, SyncPhase.idle);
    });

    test('list proceeds immediately when the bind controller is inactive',
        () async {
      // Arrange — no device / bind controller idle (desktop, or a test
      // container): the gate must pass straight through.
      wifi.files = const [(name: 'a.idl0', size: 1, sessionId: 's1')];
      final c = makeContainer();

      // Act
      await c.read(syncControllerProvider.notifier).list();

      // Assert
      expect(wifi.listCalls, equals(1));
      expect(c.read(syncControllerProvider).entries, hasLength(1));
    });
  });

  group('SyncController.shouldAutoSync —', () {
    test('reflects the autoSyncOnOpen setting', () async {
      // Arrange
      SharedPreferences.setMockInitialValues({'auto_sync_on_open': false});
      final c = ProviderContainer(
        overrides: [wifiServiceProvider.overrideWithValue(wifi)],
      );
      addTearDown(c.dispose);
      c.read(settingsProvider); // trigger build + async _load()
      await Future<void>.delayed(Duration.zero); // let settings _load() settle

      // Assert
      expect(
        c.read(syncControllerProvider.notifier).shouldAutoSync,
        isFalse,
      );
    });
  });
}

/// Fake [RunsNotifier] that records register calls and returns a stub id
/// without touching disk or the SQLite index.
class _FakeRuns extends RunsNotifier {
  final List<String> registered = [];

  @override
  Future<String?> registerDownloadedByName(String name) async {
    registered.add(name);
    return 'sid';
  }
}
