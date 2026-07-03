import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/data/track.dart';
import 'package:idl0/providers/auto_connect.dart';
import 'package:idl0/providers/drive_sync_provider.dart';
import 'package:idl0/providers/session_provider.dart';
import 'package:idl0/providers/track_provider.dart';
import 'package:idl0/transport/drive_service.dart';
import 'package:idl0/ui/shell/adaptive_shell.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_drive_workbook_ops.dart';

/// Inert [DriveService] so the Data tab's Track-sync chain does not hit the
/// network during `pumpAndSettle`. Marked signed-out so `_syncWithDrive`
/// returns immediately.
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
  Future<void> uploadSessionFile(SessionMetadata session, String fileType) =>
      throw UnimplementedError();
  @override
  Future<List<DriveTrackFile>> listTracks() async => const [];
  @override
  Future<Track> downloadTrack(String trackId) =>
      throw UnimplementedError();
  @override
  Future<void> uploadTrack(Track track) async {}
  @override
  Future<void> deleteRemote(String sessionId) async {}
}

/// AsyncNotifier with an empty initial Track list and a no-op sync.
class _EmptyTrackNotifier extends TrackNotifier {
  @override
  Future<List<Track>> build() async => const [];
}

/// Skips the startup auto-connect. The real controller kicks off a BLE
/// `connect()` whose `adapterState` wait schedules a multi-second timeout
/// Timer — which would still be pending at teardown and trip the "Timer is
/// still pending" invariant. The breakpoint tests don't touch BLE.
class _NoopAutoConnect extends AutoConnectController {
  @override
  void build() {}
}

List<Override> _shellOverrides() => [
      driveServiceProvider.overrideWithValue(_OfflineDriveService()),
      trackProvider.overrideWith(_EmptyTrackNotifier.new),
      autoConnectControllerProvider.overrideWith(_NoopAutoConnect.new),
      // No-op session loader so the test does not depend on a real
      // databases path.
      sessionIndexLoaderProvider.overrideWith((_) async {}),
    ];

/// Runs [body] with the transient `RenderFlex` overflow errors suppressed.
///
/// [AdaptiveScaffold] animates its body in from a narrow width, so the
/// not-yet-widened tab content momentarily overflows on the entrance frame
/// (often several widgets at once) before the body settles to full width —
/// confirmed not a real layout bug. Any non-overflow error still propagates.
///
/// [WidgetTester.pumpAndSettle] is intentionally avoided: the shell's
/// loading-state spinners (`CircularProgressIndicator`) animate forever, so it
/// never reaches a quiescent frame and times out. The breakpoint decision the
/// tests assert (bar vs rail) is made synchronously on the first build, so a
/// single suppressed pump is sufficient.
Future<void> _ignoringOverflow(Future<void> Function() body) async {
  final original = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains('overflowed')) return;
    original?.call(details);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = original;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets(
    'AdaptiveShell — width < 600px — shows NavigationBar, no NavigationRail',
    (tester) async {
      // Arrange — narrow screen triggers the small breakpoint (<600 dp).
      // AdaptiveShell passes useDrawer:false so NavigationBar appears on any
      // platform when the small breakpoint is active.
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Act
      await _ignoringOverflow(
        () => tester.pumpWidget(
          ProviderScope(
            overrides: _shellOverrides(),
            child: const MaterialApp(home: AdaptiveShell()),
          ),
        ),
      );

      // Assert
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    },
  );

  testWidgets(
    'AdaptiveShell — width >= 600px — shows NavigationRail, no NavigationBar',
    (tester) async {
      // Arrange — wide screen triggers medium/large breakpoint (>=600 dp).
      tester.view.physicalSize = const Size(900, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Act
      await _ignoringOverflow(
        () => tester.pumpWidget(
          ProviderScope(
            overrides: _shellOverrides(),
            child: const MaterialApp(home: AdaptiveShell()),
          ),
        ),
      );

      // Assert
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
    },
  );
}
