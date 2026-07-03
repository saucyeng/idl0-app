import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/mode.dart';
import '../../brand/brand.dart';

/// Info-only mode readout for the Device card. Mode is now automatic (WiFi is
/// driven by file sync, recording by the primary button), so this is a status
/// line, not a control. See SPEC §23.
class ModeStatusLine extends ConsumerWidget {
  /// Creates a [ModeStatusLine].
  const ModeStatusLine({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(modeProvider);
    final (label, color) = switch (mode) {
      Mode.idle => ('Idle', brandFgDim),
      Mode.wifi => ('Syncing…', brandHivis),
      Mode.recording => ('Recording', brandHivis),
      Mode.unknown => ('Syncing…', brandFgDim),
    };
    return Row(
      children: [
        Text(
          'MODE',
          style: plexMono(
            fontSize: 11,
            color: brandFgDim,
            letterSpacing: brandLabelTracking,
          ),
        ),
        const SizedBox(width: 10),
        Text(label, style: plexMono(fontSize: 12, color: color)),
      ],
    );
  }
}
