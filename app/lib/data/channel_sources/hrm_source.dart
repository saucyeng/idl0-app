import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/tabs/device/source_dialogs/hrm_dialog.dart';
import '../channel_source.dart';

/// BLE Heart Rate Monitor source. Always present in the channels table
/// (like IMU/GPS), even when no strap is paired — the source dialog is
/// where the user pairs/unpairs.
///
/// Channels: HR_BPM (id 22, u8, 1 Hz, bpm) and HR_RR (id 23, u16,
/// event-driven, ms). IDs are fixed per §5.2; resolved entries only emit
/// when [enabled] is true (matching the firmware behaviour — Spec 2 §5.2).
class HrmSource extends ChannelSource {
  /// Creates an [HrmSource] viewing the `heart_rate_monitor` config block.
  ///
  /// [hrmConfig] is `config['heart_rate_monitor']` from the active profile
  /// — pass an empty map (or const {'enabled': false}) when the block is
  /// absent.
  HrmSource({required this.hrmConfig});

  /// View into `config['heart_rate_monitor']`.
  final Map<String, dynamic> hrmConfig;

  /// Fixed channel id for the HR_BPM channel (§5.2).
  static const int hrChannelId = 22;

  /// Fixed channel id for the HR_RR channel (§5.2).
  static const int rrChannelId = 23;

  @override
  String get sourceKey => 'hrm';

  @override
  String get sourceLabel {
    final name = (hrmConfig['device_name'] as String?)?.trim() ?? '';
    return name.isEmpty ? 'Heart Rate Monitor' : 'Heart Rate Monitor — $name';
  }

  @override
  int? get sampleRateHz =>
      null; // event-driven (BPM at notify rate, RR per-beat)

  @override
  bool get enabled => (hrmConfig['enabled'] as bool?) ?? false;

  @override
  List<ChannelRow> get channels => [
        ChannelRow(
          channelName: 'HR_BPM',
          units: 'bpm',
          scale: 1.0,
          offset: 0.0,
          enabled: enabled,
          buildDialog: (_, __) => const _HrmRowDialogStub(),
        ),
        ChannelRow(
          channelName: 'HR_RR',
          units: 'ms',
          scale: 1000.0 / 1024.0,
          offset: 0.0,
          enabled: enabled,
          buildDialog: (_, __) => const _HrmRowDialogStub(),
        ),
      ];

  @override
  List<RegistryEntry> resolveRegistryEntries() {
    if (!enabled) return const [];
    return const [
      RegistryEntry(
        channelId: hrChannelId,
        dataType: DataType.u8,
        sampleRateHz: 1,
        scale: 1.0,
        offset: 0.0,
        name: 'HR_BPM',
        units: 'bpm',
      ),
      RegistryEntry(
        channelId: rrChannelId,
        dataType: DataType.u16,
        sampleRateHz: 0,
        scale: 1000.0 / 1024.0,
        offset: 0.0,
        name: 'HR_RR',
        units: 'ms',
      ),
    ];
  }

  @override
  Widget buildSourceDialog(BuildContext context, WidgetRef ref) =>
      const HrmSettingsDialog();
}

class _HrmRowDialogStub extends StatelessWidget {
  const _HrmRowDialogStub();

  @override
  Widget build(BuildContext context) => const AlertDialog(
        title: Text('HR channel'),
        content: Text(
          'Heart-rate channels (HR_BPM and HR_RR) come from a paired '
          'Polar H10 / Wahoo Tickr / Garmin strap. Edit the pairing in the '
          'Heart Rate Monitor source dialog (gear icon).',
        ),
      );
}
