import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/exceptions.dart';
import 'mode.dart';
import 'runs_provider.dart' show wifiServiceProvider;

/// Phase of the Android process→AP network bind, which follows [Mode] state.
enum WifiBindPhase {
  /// Not in WiFi mode — the process is unbound (or being released).
  idle,

  /// In WiFi mode; a [WifiService.bind] call is in flight.
  binding,

  /// In WiFi mode and the process is bound to the device AP.
  bound,

  /// In WiFi mode but the bind failed; [WifiBindState.error] carries why.
  failed,
}

/// Immutable snapshot of the bind follower's state.
class WifiBindState {
  /// Current [WifiBindPhase].
  final WifiBindPhase phase;

  /// User-facing reason the last bind failed, or null. Only set when
  /// [phase] is [WifiBindPhase.failed].
  final String? error;

  /// Creates a [WifiBindState].
  const WifiBindState(this.phase, {this.error});
}

/// Keeps the Android WiFi network bind in lock-step with [modeProvider]: bound
/// whenever the device is in [Mode.wifi], released otherwise — regardless of
/// *how* the app reached that mode (an explicit `switchTo`, or relaunching
/// while the firmware AP is already up).
///
/// This is the single owner of the process bind. The bind is a **consequence
/// of WiFi-mode state**, not of the transition action, so the gap where a
/// fresh start already in WiFi mode never ran `WifiOn` (and so never bound) is
/// closed. [WifiService.bind] is idempotent + self-healing, so re-asserting on
/// every entry is cheap (fast-success when already bound; re-request when
/// Android dropped the no-internet network).
///
/// The Device tab activates this controller via `ref.watch`. It is
/// non-autoDispose, so once instantiated it lives for the app session and keeps
/// following mode even while the user is on the Data tab syncing.
class WifiBindController extends Notifier<WifiBindState> {
  @override
  WifiBindState build() {
    // fireImmediately handles "already in wifi mode at creation"; the ongoing
    // listen handles the (more common) transition into wifi a moment later,
    // once BLE has connected and the firmware status arrives.
    ref.listen<Mode>(
      modeProvider,
      (_, next) => _sync(next),
      fireImmediately: true,
    );
    return const WifiBindState(WifiBindPhase.idle);
  }

  Future<void> _sync(Mode mode) async {
    final wifi = ref.read(wifiServiceProvider);
    if (mode == Mode.wifi) {
      state = const WifiBindState(WifiBindPhase.binding);
      try {
        await wifi.bind();
        // Guard against a mode flip during the await writing stale state.
        if (ref.read(modeProvider) == Mode.wifi) {
          state = const WifiBindState(WifiBindPhase.bound);
        }
      } on TransportException catch (e) {
        if (ref.read(modeProvider) == Mode.wifi) {
          state = WifiBindState(WifiBindPhase.failed, error: e.message);
        }
      }
    } else if (mode == Mode.idle || mode == Mode.recording) {
      // Mode.unknown is a transient status frame — leave the bind alone rather
      // than churning release/bind on it.
      await wifi.release();
      if (ref.read(modeProvider) != Mode.wifi) {
        state = const WifiBindState(WifiBindPhase.idle);
      }
    }
  }
}

/// Provider for the [WifiBindController]. Activated (kept alive) by the Device
/// tab; thereafter the bind follows [Mode] for the whole app session.
final wifiBindControllerProvider =
    NotifierProvider<WifiBindController, WifiBindState>(WifiBindController.new);
