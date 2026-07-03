import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/app_settings.dart';
import 'package:idl0/providers/mode.dart';
import 'package:idl0/providers/runs_provider.dart';
import 'package:idl0/providers/settings_provider.dart';
import 'package:idl0/ui/tabs/data/sync_screen.dart';

import '../../helpers/fake_wifi_service.dart';

/// Settings notifier that loads no prefs and keeps auto-sync OFF, so the
/// screen does not kick off a download during the test.
class _NoAutoSyncSettings extends SettingsNotifier {
  @override
  AppSettings build() => AppSettings.defaults().copyWith(autoSyncOnOpen: false);
}

/// Fake [RunsNotifier] that records register calls without disk/DB I/O.
class _FakeRuns extends RunsNotifier {
  @override
  Future<String?> registerDownloadedByName(String name) async => 'sid';
}

void main() {
  testWidgets('SyncScreen — renders a NEW row from the device list',
      (tester) async {
    // Arrange
    final wifi = FakeWifiService()
      ..files = const [
        (name: 'b.idl0', size: 200, sessionId: 'sid-B'),
      ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          wifiServiceProvider.overrideWithValue(wifi),
          modeProvider.overrideWithValue(Mode.wifi),
          settingsProvider.overrideWith(_NoAutoSyncSettings.new),
        ],
        child: const MaterialApp(home: SyncScreen()),
      ),
    );

    // Act — let the post-frame list() complete.
    await tester.pumpAndSettle();

    // Assert
    expect(find.text('b.idl0'), findsOneWidget);
    expect(find.text('NEW'), findsOneWidget);
  });

  testWidgets('SyncScreen — shows WiFi gate when not in WiFi mode',
      (tester) async {
    // Arrange
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          wifiServiceProvider.overrideWithValue(FakeWifiService()),
          modeProvider.overrideWithValue(Mode.idle),
          settingsProvider.overrideWith(_NoAutoSyncSettings.new),
        ],
        child: const MaterialApp(home: SyncScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Assert — the gate, not a file list
    expect(find.text('Switch to WiFi mode'), findsOneWidget);
  });

  testWidgets(
      'SyncScreen — picker: Download is disabled until a file is '
      'checked, then downloads the selection', (tester) async {
    // Arrange — auto-sync off (default), so the screen is a picker.
    final wifi = FakeWifiService()
      ..files = const [
        (name: 'b.idl0', size: 200, sessionId: 'sid-B'),
      ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          wifiServiceProvider.overrideWithValue(wifi),
          modeProvider.overrideWithValue(Mode.wifi),
          settingsProvider.overrideWith(_NoAutoSyncSettings.new),
          runsProvider.overrideWith(_FakeRuns.new),
        ],
        child: const MaterialApp(home: SyncScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Assert — nothing checked, so Download is disabled.
    final disabled = find.widgetWithText(FilledButton, 'Download');
    expect(disabled, findsOneWidget);
    expect(tester.widget<FilledButton>(disabled).onPressed, isNull);

    // Act — check the file, then download the selection.
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    final active = find.widgetWithText(FilledButton, 'Download (1)');
    expect(active, findsOneWidget);
    await tester.tap(active);
    // Bounded pumps, not pumpAndSettle: an in-flight download shows an
    // indeterminate spinner that never "settles".
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Assert
    expect(wifi.downloadLog, contains('b.idl0'));
  });
}
