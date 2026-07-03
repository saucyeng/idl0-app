import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/mode_controller.dart';

/// Subscribes to [ModeController.results] for its whole lifetime and renders
/// the §5.4 failure UX (refusal SnackBars, timeout banner). Wrap a
/// long-lived, always-mounted widget (the Device tab) with this so mode-
/// transition refusals surface even though the mode picker is gone (§23).
class ModeResultListener extends ConsumerStatefulWidget {
  /// Creates a [ModeResultListener] around [child].
  const ModeResultListener({super.key, required this.child});

  /// The subtree to render; unaffected by the listener.
  final Widget child;

  @override
  ConsumerState<ModeResultListener> createState() =>
      _ModeResultListenerState();
}

class _ModeResultListenerState extends ConsumerState<ModeResultListener> {
  StreamSubscription<TransitionResult>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = ref.read(modeControllerProvider.notifier).results.listen(_onResult);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onResult(TransitionResult r) {
    if (!mounted) return;
    switch (r) {
      case Ok():
      case AbortedByCancel():
      case AbortedByDisconnect():
        break;
      case RefusedByFirmware(:final reason):
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Device refused: $reason')),
        );
      case RefusedByPolicy(:final reason):
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(reason)),
        );
      case TimedOutAwaitingConfirm(:final expected):
        ScaffoldMessenger.of(context).showMaterialBanner(
          MaterialBanner(
            content:
                Text('Device did not confirm ${expected.name}. Reconnect?'),
            actions: [
              TextButton(
                onPressed: () => ScaffoldMessenger.of(context)
                    .hideCurrentMaterialBanner(),
                child: const Text('Reconnect'),
              ),
            ],
          ),
        );
      case TransitionFailed(:final reason):
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(reason)),
        );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
