import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/wifi_bind_controller.dart';
import '../../brand/brand.dart';
import 'calibration_panel.dart';
import 'config_card.dart';
import 'device_files_entry.dart';
import 'device_hero_card.dart';
import 'mode_result_listener.dart';
import 'mode_status_line.dart';
import 'push_config_button.dart';

/// Device tab — two cards: the [DeviceHeroCard] (runtime status + actions)
/// and the [ConfigCard] (profile + channels), with calibration tucked below.
///
/// Pilot of the "quiet field manual" treatment: minimal section heads,
/// plain outlined buttons, and semantic colour coding (green = healthy,
/// yellow = live recording, red = required action / fault, dim = idle).
///
/// Mode is now automatic (WiFi driven by file sync, recording by the hero's
/// primary button), so it shows as an info-only [ModeStatusLine] rather than a
/// picker. Mode-transition refusals still surface via [ModeResultListener],
/// which wraps the tab so the §5.4 failure UX is never lost (§23).
class DeviceTab extends ConsumerWidget {
  /// Creates a [DeviceTab].
  const DeviceTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Activate the bind-follows-mode controller. It is non-autoDispose, so once
    // the Device tab instantiates it here it lives for the app session and
    // keeps the Android WiFi bind in lock-step with Mode — including the case
    // where the app relaunches with the firmware AP already up — even while the
    // user is on the Data tab syncing.
    ref.watch(wifiBindControllerProvider);
    return const ModeResultListener(
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DeviceHeroCard(),
            SizedBox(height: 8),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: ModeStatusLine(),
            ),
            SizedBox(height: 8),
            PushConfigButton(),
            SizedBox(height: 4),
            DeviceFilesEntry(),
            SizedBox(height: 12),
            ConfigCard(),
            SizedBox(height: 12),
            CollapsibleSection(
              label: 'calibration',
              child: CalibrationPanel(),
            ),
            SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
