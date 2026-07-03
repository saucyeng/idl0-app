import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/data/track.dart';
import 'package:idl0/providers/drive_sync_provider.dart';
import 'package:idl0/providers/runs_provider.dart';
import 'package:idl0/providers/session_provider.dart';
import 'package:idl0/transport/drive_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_drive_workbook_ops.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Mock PathProvider that redirects documents/support paths into a temp dir
/// so tests don't touch the user's real app-data location.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.tmp);
  final Directory tmp;

  @override
  Future<String?> getApplicationDocumentsPath() async => tmp.path;

  @override
  Future<String?> getApplicationSupportPath() async => tmp.path;

  @override
  Future<String?> getExternalStoragePath() async => tmp.path;
}

/// Inert DriveService — registerDownloadedSession queues an upload that we
/// don't want to actually issue.
class _OfflineDriveService with FakeDriveWorkbookOps implements DriveService {
  @override
  bool get isSignedIn => false;

  @override
  String? get accountEmail => null;

  @override
  Future<void> signIn() async {}

  @override
  Future<void> signOut() async {}

  @override
  Future<void> uploadSessionFile(SessionMetadata s, String fileType) async {}

  @override
  Future<List<DriveTrackFile>> listTracks() async => const [];

  @override
  Future<Track> downloadTrack(String trackId) async =>
      throw UnimplementedError();

  @override
  Future<void> uploadTrack(Track track) async {}

  @override
  Future<void> deleteRemote(String sessionId) async {}
}

/// Minimum-viable v2 IDL0 file: 48-byte header + 4-byte 0xDEADBEEF end marker.
/// See `docs/IDL0_SPEC.md` §5. Empty registry, single IMU, no records.
Uint8List _minimalV2Idl0() {
  final hdr = ByteData(48);
  int pos = 0;
  // Magic "IDL0"
  hdr.setUint8(pos++, 0x49);
  hdr.setUint8(pos++, 0x44);
  hdr.setUint8(pos++, 0x4C);
  hdr.setUint8(pos++, 0x30);
  hdr.setUint8(pos++, 2); // schema_version = 2
  // UUID 16 bytes (all 0xAB)
  for (int i = 0; i < 16; i++) {
    hdr.setUint8(pos++, 0xAB);
  }
  // Device ID 6 bytes
  for (int i = 0; i < 6; i++) {
    hdr.setUint8(pos++, 0xCD);
  }
  // session_start_ms (little-endian int64)
  hdr.setInt64(pos, 1704110400000, Endian.little);
  pos += 8;
  // config_crc32 (u32 LE)
  hdr.setUint32(pos, 0xABCD1234, Endian.little);
  pos += 4;
  // imu_mask (u32 LE) = accel+gyro all axes
  hdr.setUint32(pos, 0x3F, Endian.little);
  pos += 4;
  // imu_count (u8)
  hdr.setUint8(pos++, 1);
  // imu_sample_rate_hz (u16 LE)
  hdr.setUint16(pos, 800, Endian.little);
  pos += 2;
  // gps_sample_rate_hz (u8)
  hdr.setUint8(pos++, 5);
  // registry_count (u8) = 0
  hdr.setUint8(pos++, 0);
  assert(pos == 48, 'header should be exactly 48 bytes, got $pos');

  // 0xDEADBEEF end marker.
  final tail = ByteData(4)..setUint32(0, 0xDEADBEEF, Endian.little);

  return Uint8List.fromList(
    hdr.buffer.asUint8List() + tail.buffer.asUint8List(),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('idl0_runs_dl_');
    PathProviderPlatform.instance = _FakePathProvider(tmp);
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('RunsNotifier.registerDownloadedSession —', () {
    test('file missing — returns null without crashing', () async {
      // Arrange — no file at the given path.
      final container = ProviderContainer(overrides: [
        driveServiceProvider.overrideWithValue(_OfflineDriveService()),
      ],);
      addTearDown(container.dispose);

      // Act
      final result = await container
          .read(runsProvider.notifier)
          .registerDownloadedSession('${tmp.path}/does_not_exist.idl0');

      // Assert
      expect(result, isNull);
      expect(container.read(sessionProvider).sessions, isEmpty);
    });

    test('happy path — parses, upserts index, addSession, bumps state counter',
        () async {
      // Arrange — drop a minimal valid v2 .idl0 file into the sessions dir
      // (mirrors what RealWifiService.downloadFile would produce).
      final sessionsDir = Directory(p.join(tmp.path, 'sessions'));
      await sessionsDir.create(recursive: true);
      final downloadedPath = p.join(sessionsDir.path, 'session_001.idl0');
      await File(downloadedPath).writeAsBytes(_minimalV2Idl0(), flush: true);

      final container = ProviderContainer(overrides: [
        driveServiceProvider.overrideWithValue(_OfflineDriveService()),
      ],);
      addTearDown(container.dispose);

      final counterBefore = container.read(runsProvider);
      expect(container.read(sessionProvider).sessions, isEmpty);

      // Act
      final sessionId = await container
          .read(runsProvider.notifier)
          .registerDownloadedSession(downloadedPath);

      // Assert — registration succeeded and session is visible
      expect(sessionId, isNotNull);
      final sessions = container.read(sessionProvider).sessions;
      expect(sessions.length, equals(1));
      expect(sessions.first.sessionId, equals(sessionId));
      expect(container.read(runsProvider), equals(counterBefore + 1));

      // The file has been renamed to <sessionId>.idl0 — the original named
      // file no longer exists, the canonical one does.
      expect(File(downloadedPath).existsSync(), isFalse);
      final canonicalPath = p.join(sessionsDir.path, '${sessionId!}.idl0');
      expect(File(canonicalPath).existsSync(), isTrue);
    },
        // registerDownloadedSession parses via the idl-rs bridge
        // (parseSessionFromPath), whose native library is not loaded under
        // `flutter test` (see math_channel_eval_provider_test). .idl0 parse
        // coverage lives in the rust/core suite; this exercises only the Dart
        // registration orchestration (rename → index upsert → addSession →
        // counter bump), which cannot run without a parsed handle.
        skip: 'Requires the idl-rs bridge native library (not loaded under '
            'flutter test).',);

    test(
        'already at canonical path — does not throw and registers successfully',
        () async {
      // Arrange — drop the file at its eventual canonical path. This exercises
      // the "skip rename" branch.
      final sessionsDir = Directory(p.join(tmp.path, 'sessions'));
      await sessionsDir.create(recursive: true);

      // Parse the bytes once to learn what sessionId will be assigned, then
      // write to that path so registerDownloadedSession finds it pre-canonical.
      final bytes = _minimalV2Idl0();
      // Easiest: write to a temp name, parse via the public API by calling
      // registerDownloadedSession once to discover the assigned id, then
      // re-stage and assert the second call is a no-op-style success.
      final stagedPath = p.join(sessionsDir.path, 'staging.idl0');
      await File(stagedPath).writeAsBytes(bytes, flush: true);

      final container = ProviderContainer(overrides: [
        driveServiceProvider.overrideWithValue(_OfflineDriveService()),
      ],);
      addTearDown(container.dispose);

      final firstId = await container
          .read(runsProvider.notifier)
          .registerDownloadedSession(stagedPath);
      expect(firstId, isNotNull);

      // Act — registering the same canonical file again should still succeed
      // (upsert path).
      final canonicalPath = p.join(sessionsDir.path, '${firstId!}.idl0');
      expect(File(canonicalPath).existsSync(), isTrue);

      final secondId = await container
          .read(runsProvider.notifier)
          .registerDownloadedSession(canonicalPath);

      // Assert
      expect(secondId, equals(firstId));
      expect(File(canonicalPath).existsSync(), isTrue);
    },
        // Same as the happy-path case: registration parses via the idl-rs
        // bridge, unavailable under `flutter test`.
        skip: 'Requires the idl-rs bridge native library (not loaded under '
            'flutter test).',);
  });
}
