import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/device_provider.dart';
import '../../../providers/firmware_update_provider.dart';
import '../../../providers/link_activity.dart';
import '../../../providers/mode.dart';
import '../../../providers/mode_controller.dart';
import '../../brand/brand.dart';
import '../../shell/adaptive_shell.dart';
import 'device_picker.dart';

/// The Device tab hero — the single prominent status + primary-action surface,
/// a state machine over the existing [deviceProvider] / [modeControllerProvider].
///
/// Three states, all driven by live device state (no new model):
/// * **No device** (`!isConnected`) → blue **Connect** CTA.
/// * **Ready** (connected, not recording) → green **Start recording** CTA.
/// * **Recording** (`isRecording`) → amber **Stop recording** CTA + live timer.
///
/// Recording start is immediate — sensor health (HR/GPS/SD/IMU/battery) never
/// gates it (§23.9). The connection readout (SD/GPS/IMU/HR) is folded in here
/// directly, colour-coded so a degraded sensor reads as a warning in place. A
/// live RX/TX pair blinks on link traffic ([linkActivityProvider]).
///
/// Dense by design — no instructional copy (first-run guidance is a separate
/// walkthrough). Start/Stop route through [ModeController.switchTo]; refusals
/// surface via the always-mounted `ModeResultListener` wrapping the Device tab.
/// Connect/Disconnect are handled here and never let a transport error escape
/// as an uncaught exception.
class DeviceHeroCard extends ConsumerStatefulWidget {
  /// Creates a [DeviceHeroCard].
  const DeviceHeroCard({super.key});

  @override
  ConsumerState<DeviceHeroCard> createState() => _DeviceHeroCardState();
}

class _DeviceHeroCardState extends ConsumerState<DeviceHeroCard> {
  Timer? _recTicker;
  Duration _recElapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    // Seed the timer if the hero first builds while already recording (the
    // ref.listen below only fires on a change).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(deviceProvider).isRecording) _startRecTicker();
    });
  }

  @override
  void dispose() {
    _recTicker?.cancel();
    super.dispose();
  }

  void _startRecTicker() {
    _recTicker?.cancel();
    setState(() => _recElapsed = Duration.zero);
    _recTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recElapsed += const Duration(seconds: 1));
    });
  }

  void _stopRecTicker() {
    _recTicker?.cancel();
    _recTicker = null;
    if (mounted) setState(() => _recElapsed = Duration.zero);
  }

  // Start/Stop go through the mode controller so refusals surface via the
  // ModePicker's results listener (§5.4) — no HR gate, so this is immediate.
  void _start() =>
      ref.read(modeControllerProvider.notifier).switchTo(Mode.recording);
  void _stop() => ref.read(modeControllerProvider.notifier).switchTo(Mode.idle);

  @override
  Widget build(BuildContext context) {
    final device = ref.watch(deviceProvider);
    final transitionBusy =
        ref.watch(modeControllerProvider.select((t) => t.phase)) !=
            TransitionPhase.idle;

    // Keep the recording timer in lock-step with the live recording flag.
    ref.listen(deviceProvider.select((s) => s.isRecording), (_, recording) {
      if (recording) {
        if (_recTicker == null) _startRecTicker();
      } else {
        if (_recTicker != null) _stopRecTicker();
      }
    });

    final Widget body;
    if (!device.isConnected) {
      body = _noDevice();
    } else if (device.isRecording) {
      body = _recording(device, transitionBusy);
    } else {
      body = _ready(device, transitionBusy);
    }

    // A firmware update, when available, surfaces as a compact banner above
    // the hero content (§27.7); tapping it routes to Settings → Firmware.
    // Gated on a live link: an "update available" banner only means anything
    // for a connected device, and this closes the one-frame window between a
    // disconnect and the update provider re-deriving to idle. See §27.7.
    final update = ref.watch(firmwareUpdateProvider);
    final Widget child = device.isConnected && update is FirmwareUpdateAvailable
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _FirmwareUpdateBanner(version: update.release.version.toString()),
              const SizedBox(height: 12),
              body,
            ],
          )
        : body;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: brandSurface,
        border: Border.all(color: brandRule, width: brandHairlineWidth),
        borderRadius:
            const BorderRadius.all(Radius.circular(brandControlRadius)),
      ),
      child: child,
    );
  }

  // --- State A: no device -------------------------------------------------

  Widget _noDevice() {
    return StatusDropdownTrigger(
      prominent: true,
      leadingIcon: Icons.bluetooth,
      label: 'Select a device',
      onTap: () => showDevicePicker(context),
    );
  }

  // --- State B: ready -----------------------------------------------------

  Widget _ready(DeviceState device, bool busy) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: StatusDropdownTrigger(
                dotColor: brandGood,
                label: 'Connected · ${device.deviceName}',
                onTap: () => showDevicePicker(context),
              ),
            ),
            const _RxTxChips(),
            const SizedBox(width: 8),
            if (device.batteryPercent != null)
              _BatteryReadout(percent: device.batteryPercent!),
          ],
        ),
        const SizedBox(height: 10),
        _PeripheralReadout(device: device),
        const SizedBox(height: 14),
        QuietButton(
          label: 'Start recording',
          filled: true,
          large: true,
          emphasis: ButtonEmphasis.go,
          icon: Icons.fiber_manual_record,
          onPressed: busy ? null : _start,
        ),
      ],
    );
  }

  // --- State D: recording -------------------------------------------------

  Widget _recording(DeviceState device, bool busy) {
    final secs = _recElapsed.inSeconds;
    final mm = (secs ~/ 60).toString().padLeft(2, '0');
    final ss = (secs % 60).toString().padLeft(2, '0');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const PulsingDot(color: brandHivis),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'RECORDING · $mm:$ss',
                style: plexMono(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: brandHivis,
                  letterSpacing: brandLabelTracking,
                ),
              ),
            ),
            const _RxTxChips(),
            const SizedBox(width: 8),
            if (device.batteryPercent != null)
              _BatteryReadout(percent: device.batteryPercent!),
          ],
        ),
        const SizedBox(height: 10),
        _PeripheralReadout(device: device),
        const SizedBox(height: 14),
        QuietButton(
          label: 'Stop recording',
          filled: true,
          large: true,
          emphasis: ButtonEmphasis.live,
          icon: Icons.stop,
          onPressed: busy ? null : _stop,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Firmware update banner — compact "update available" affordance that routes
// to Settings → Firmware (§27.7).
// ---------------------------------------------------------------------------

class _FirmwareUpdateBanner extends ConsumerWidget {
  /// Target version string, e.g. `1.5.0`.
  final String version;
  const _FirmwareUpdateBanner({required this.version});

  /// Settings tab index in the AdaptiveScaffold shell (§27.6).
  static const _settingsTabIndex = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      onTap: () =>
          ref.read(shellIndexProvider.notifier).state = _settingsTabIndex,
      child: NoteBlock(
        borderColor: brandHivis,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.system_update_alt, size: 16, color: brandHivis),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Firmware update available — v$version',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const Icon(Icons.chevron_right, size: 16, color: brandFgDim),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Peripheral readout — the (folded-in) Connection detail, colour-coded so a
// degraded sensor reads as an in-place warning.
// ---------------------------------------------------------------------------

class _PeripheralReadout extends StatelessWidget {
  const _PeripheralReadout({required this.device});

  final DeviceState device;

  // TODO(idl0): surface richer per-peripheral status once the firmware §7.3
  // status string carries it — GPS fix-type (2D/3D) + satellite count, SD free
  // space, BLE signal RSSI. Each entry already renders as a (label, value,
  // colour) triple, so a longer value (e.g. "3D · 9 sat") slots in with no
  // layout change; add the fields to DeviceState then map them here.

  @override
  Widget build(BuildContext context) {
    final (sdV, sdC) = _sd();
    final (gpsV, gpsC) = _gps();
    final (imuV, imuC) = _imu();
    final (hrV, hrC) = _hr();
    return Wrap(
      spacing: 16,
      runSpacing: 6,
      children: [
        StatusIcon(icon: Icons.sd_card, label: 'SD', value: sdV, color: sdC),
        StatusIcon(
          icon: Icons.satellite_alt,
          label: 'GPS',
          value: gpsV,
          color: gpsC,
        ),
        StatusIcon(icon: Icons.sensors, label: 'IMU', value: imuV, color: imuC),
        StatusIcon(icon: Icons.favorite, label: 'HR', value: hrV, color: hrC),
        if (device.hrBatteryPercent != null)
          StatusIcon(
            icon: Icons.bluetooth,
            label: 'HRM',
            value: '${device.hrBatteryPercent}%',
            color: _pct(device.hrBatteryPercent!),
          ),
        // Neutral presentation — a firmware version is not a health state,
        // so no green/red semantics; brandFg is the same "plain value"
        // colour StatusIcon uses for unmatched-but-present states above.
        if (device.firmwareVersion != null)
          StatusIcon(
            icon: Icons.memory,
            label: 'FW',
            value: 'v${device.firmwareVersion}',
            color: brandFg,
          ),
      ],
    );
  }

  (String, Color) _sd() => switch (device.sdState) {
        null => ('—', brandFgDim),
        'OK' => ('OK', brandGood),
        'FULL' => ('FULL', brandAccent),
        'ERROR' => ('ERROR', brandAccent),
        'ABSENT' => ('NONE', brandAccent),
        final s => (s, brandFg),
      };

  (String, Color) _gps() => switch (device.gpsState) {
        null => ('—', brandFgDim),
        'FIX' => ('FIX', brandGood),
        'NOFIX' => ('NO FIX', brandHivis),
        'ABSENT' => ('NONE', brandAccent),
        final s => (s, brandFg),
      };

  (String, Color) _imu() => switch (device.imuState) {
        null => ('—', brandFgDim),
        'OK' => ('OK', brandGood),
        'PARTIAL' => ('PARTIAL', brandHivis),
        'ERROR' => ('ERROR', brandAccent),
        'ABSENT' => ('NONE', brandAccent),
        final s => (s, brandFg),
      };

  (String, Color) _hr() {
    final raw = device.hr;
    if (raw == null || raw.isEmpty) return ('—', brandFgDim);
    final upper = raw.toUpperCase();
    if (upper.startsWith('CONNECTED')) {
      final bpm = upper.substring('CONNECTED'.length).trim();
      return (bpm.isEmpty ? 'LIVE' : '$bpm BPM', brandGood);
    }
    if (upper.startsWith('NO_CONTACT')) return ('NO CONTACT', brandHivis);
    if (upper == 'SEARCHING') return ('SEARCHING', brandFgDim);
    if (upper == 'SUSPENDED') return ('SUSPENDED', brandHivis);
    if (upper == 'ABSENT') return ('OFF', brandFgDim);
    return (upper, brandFg);
  }

  Color _pct(int pct) {
    if (pct < 20) return brandAccent;
    if (pct < 40) return brandHivis;
    return brandGood;
  }
}

// ---------------------------------------------------------------------------
// RX / TX activity chips
// ---------------------------------------------------------------------------

class _RxTxChips extends StatelessWidget {
  const _RxTxChips();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ActivityChip(label: 'RX', isRx: true),
        SizedBox(width: 4),
        _ActivityChip(label: 'TX', isRx: false),
      ],
    );
  }
}

/// A small RX or TX chip that flashes green for ~250 ms each time its
/// [linkActivityProvider] counter ticks, then settles back to dim — a live
/// "data is flowing" tell.
class _ActivityChip extends ConsumerStatefulWidget {
  const _ActivityChip({required this.label, required this.isRx});

  final String label;
  final bool isRx;

  @override
  ConsumerState<_ActivityChip> createState() => _ActivityChipState();
}

class _ActivityChipState extends ConsumerState<_ActivityChip> {
  bool _hot = false;
  Timer? _cool;

  @override
  void dispose() {
    _cool?.cancel();
    super.dispose();
  }

  void _flash() {
    setState(() => _hot = true);
    _cool?.cancel();
    _cool = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _hot = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(
      linkActivityProvider.select((a) => widget.isRx ? a.rx : a.tx),
      (_, __) => _flash(),
    );
    final dotColor = _hot ? brandGood : brandFgFaint;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: brandControlFill,
        border: Border.all(color: brandRule, width: brandHairlineWidth),
        borderRadius:
            const BorderRadius.all(Radius.circular(brandControlRadiusSoft)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            widget.label,
            style: plexMono(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: _hot ? brandFg : brandFgDim,
              letterSpacing: brandLabelTracking,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Battery readout
// ---------------------------------------------------------------------------

class _BatteryReadout extends StatelessWidget {
  const _BatteryReadout({required this.percent});

  final int percent;

  @override
  Widget build(BuildContext context) {
    final Color color;
    if (percent < 20) {
      color = brandAccent;
    } else if (percent < 40) {
      color = brandHivis;
    } else {
      color = brandGood;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          percent >= 80
              ? Icons.battery_full
              : percent >= 40
                  ? Icons.battery_4_bar
                  : Icons.battery_2_bar,
          size: 14,
          color: color,
        ),
        const SizedBox(width: 3),
        Text('$percent%', style: plexMono(fontSize: 12, color: color)),
      ],
    );
  }
}
