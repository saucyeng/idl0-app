import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/device_provider.dart';
import '../../brand/brand.dart';

/// Pre-flight checklist items the user must confirm before calibration begins.
///
/// All three must be checked before "Calibrate IMUs" is enabled. See §11.
const _kChecklistItems = [
  'Bike upright on level ground',
  'Bike stationary',
  'Rider off the bike',
];

/// Calibration flow for the Device tab.
///
/// Presents a pre-flight checklist, a 5-second animated progress bar, and
/// posts CMD_CALIBRATE_IMU (0x05) via [DeviceNotifier.calibrate]. See §11
/// and §7.2.
class CalibrationPanel extends ConsumerStatefulWidget {
  /// Creates a [CalibrationPanel].
  const CalibrationPanel({super.key});

  @override
  ConsumerState<CalibrationPanel> createState() => _CalibrationPanelState();
}

class _CalibrationPanelState extends ConsumerState<CalibrationPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progressController;
  final List<bool> _checked = List.filled(_kChecklistItems.length, false);
  bool _isCalibrating = false;
  bool _calibrationComplete = false;

  @override
  void initState() {
    super.initState();
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() => _calibrationComplete = true);
        }
      });
  }

  @override
  void dispose() {
    _progressController.dispose();
    super.dispose();
  }

  bool get _checklistComplete => _checked.every((v) => v);

  Future<void> _startCalibration() async {
    setState(() {
      _isCalibrating = true;
      _calibrationComplete = false;
    });
    _progressController.forward(from: 0.0);

    try {
      await ref.read(deviceProvider.notifier).calibrate();
    } finally {
      if (mounted) setState(() => _isCalibrating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = ref.watch(deviceProvider.select((s) => s.isConnected));
    final canCalibrate = isConnected && _checklistComplete && !_isCalibrating;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NoteBlock(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'PRE-FLIGHT CHECKLIST',
                  style: plexMono(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: brandFgDim,
                    letterSpacing: brandKickerTracking,
                  ),
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < _kChecklistItems.length; i++)
                  CheckboxListTile(
                    title: Text(_kChecklistItems[i].toUpperCase()),
                    value: _checked[i],
                    onChanged: _isCalibrating
                        ? null
                        : (v) => setState(() => _checked[i] = v!),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_isCalibrating) ...[
            const StatusDot(
              label: 'calibrating — hold still',
              color: brandHivis,
            ),
            const SizedBox(height: 8),
            AnimatedBuilder(
              animation: _progressController,
              builder: (context, _) => LinearProgressIndicator(
                value: _progressController.value,
                minHeight: 2,
              ),
            ),
          ] else if (_calibrationComplete) ...[
            const StatusDot(
              label: 'calibration complete',
              color: brandGood,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: QuietButton(
                label: 'Recalibrate',
                onPressed: canCalibrate ? _startCalibration : null,
              ),
            ),
          ] else ...[
            Align(
              alignment: Alignment.centerLeft,
              child: QuietButton(
                label: 'Calibrate IMUs',
                emphasis:
                    canCalibrate ? ButtonEmphasis.go : ButtonEmphasis.normal,
                onPressed: canCalibrate ? _startCalibration : null,
              ),
            ),
          ],
          if (!isConnected)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'CONNECT A DEVICE TO ENABLE CALIBRATION',
                style: plexMono(
                  fontSize: 11,
                  color: brandFgDim,
                  letterSpacing: brandLabelTracking,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
