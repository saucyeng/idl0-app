import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'device_provider.dart';
import 'link_activity.dart';
import 'mode.dart';
import 'mode_step.dart';

/// Phase of an in-flight mode transition, used by the UI to render the
/// correct progress / spinner state. See spec §3.5.
enum TransitionPhase {
  /// No transition in progress.
  idle,

  /// Command sent; awaiting ATT result code from the firmware.
  sendingAck,

  /// ACK received; awaiting status confirmation that the mode has flipped.
  awaitingConfirm,
}

/// Snapshot of the controller's current transition state. The full
/// transition advances through a `List<Step>`; [stepIndex] is the
/// 0-based index of the step in flight.
class ModeTransition {
  /// Target [Mode] of the in-flight transition, or `null` when idle.
  final Mode? target;

  /// Current phase of the in-flight step.
  final TransitionPhase phase;

  /// 0-based index into the active step list.
  final int stepIndex;

  /// Creates a [ModeTransition]. Defaults are the idle/no-target state.
  const ModeTransition({
    this.target,
    this.phase = TransitionPhase.idle,
    this.stepIndex = 0,
  });

  /// Returns a copy of this transition with the given fields replaced.
  ModeTransition copyWith({
    Mode? target,
    TransitionPhase? phase,
    int? stepIndex,
  }) {
    return ModeTransition(
      target: target ?? this.target,
      phase: phase ?? this.phase,
      stepIndex: stepIndex ?? this.stepIndex,
    );
  }
}

/// Outcome of [ModeController.switchTo]. Sealed so the picker UI (T11/T12)
/// can render distinct UX per failure mode. See spec §5.4.
sealed class TransitionResult {
  /// Creates a [TransitionResult].
  const TransitionResult();
}

/// Transition completed successfully.
class Ok extends TransitionResult {
  /// Creates an [Ok] result.
  const Ok();
}

/// Firmware refused a command with a non-zero ATT result code.
class RefusedByFirmware extends TransitionResult {
  /// ATT result code byte from the firmware (e.g. `0x03`).
  final int attCode;

  /// User-facing reason mapped from the code via `defaultAckReason`.
  final String reason;

  /// Creates a [RefusedByFirmware] result.
  const RefusedByFirmware({required this.attCode, required this.reason});
}

/// App-side policy refused the transition before any command was sent
/// (e.g. `recording → wifi` is not allowed; user must stop recording first).
class RefusedByPolicy extends TransitionResult {
  /// Human-readable reason for the refusal.
  final String reason;

  /// Creates a [RefusedByPolicy] result carrying [reason].
  const RefusedByPolicy(this.reason);
}

/// A command step's status confirmation did not arrive in time.
class TimedOutAwaitingConfirm extends TransitionResult {
  /// Target [Mode] that was expected but never observed.
  final Mode expected;

  /// Creates a [TimedOutAwaitingConfirm] result.
  const TimedOutAwaitingConfirm({required this.expected});
}

/// BLE link dropped mid-transition.
class AbortedByDisconnect extends TransitionResult {
  /// Creates an [AbortedByDisconnect] result.
  const AbortedByDisconnect();
}

/// [ModeController.cancelTransition] was called.
class AbortedByCancel extends TransitionResult {
  /// Creates an [AbortedByCancel] result.
  const AbortedByCancel();
}

/// Non-firmware transport error aborted a step (e.g. WiFi bind failed
/// on Android). Distinct from [RefusedByFirmware] (ATT result code)
/// and [AbortedByDisconnect] (BLE link drop).
class TransitionFailed extends TransitionResult {
  /// User-facing explanation of what failed.
  final String reason;

  /// Creates a [TransitionFailed] result carrying [reason].
  const TransitionFailed(this.reason);
}

/// The §4 transition table: `(from, to) → ordered list of Steps`. Missing
/// entries fall through to either the explicit `recording → wifi` refusal
/// or the generic `RefusedByPolicy` branch in [ModeController.switchTo].
// Sensor health (HR strap, GPS, SD, IMU, battery) never gates recording — it
// surfaces as a non-blocking warning on the Device hero instead, the same as
// low battery / low storage. So Start records immediately; there is no HR gate.
const Map<(Mode, Mode), List<Step>> _kTransitions = {
  (Mode.idle, Mode.wifi): [WifiOn()],
  (Mode.idle, Mode.recording): [StartLogging()],
  (Mode.wifi, Mode.idle): [WifiOff()],
  (Mode.wifi, Mode.recording): [WifiOff(), StartLogging()],
  (Mode.recording, Mode.idle): [StopLogging()],
};

/// Walks the §4 transition table for a requested target [Mode], dispatching
/// each [Step] in order and mapping the first non-[StepOk] result to a
/// typed [TransitionResult] for the picker UI.
class ModeController extends Notifier<ModeTransition> {
  StepContext? _activeCtx;
  final _resultsCtrl = StreamController<TransitionResult>.broadcast();

  @override
  ModeTransition build() {
    ref.onDispose(_resultsCtrl.close);
    return const ModeTransition();
  }

  /// Broadcast (multi-listener) stream of every [TransitionResult] emitted
  /// by [switchTo]. The picker (T11/T12) subscribes to surface refusals
  /// and timeouts as toasts.
  Stream<TransitionResult> get results => _resultsCtrl.stream;

  /// Exposes the §4 table for the coverage meta-test. Returns the step list
  /// for `(from, to)`, or `null` if no transition is configured.
  static List<Step>? transitionFor(Mode from, Mode to) =>
      _kTransitions[(from, to)];

  /// Transitions the device to [target] by walking the §4 table.
  ///
  /// Returns an [Ok] on success, or a typed failure subclass on the first
  /// step that did not return [StepOk]. Calls with `target == current`
  /// short-circuit to [Ok] without sending any command. Missing table
  /// entries become [RefusedByPolicy]; the special `recording → wifi`
  /// case carries an explicit reason string.
  Future<TransitionResult> switchTo(Mode target) async {
    // Precondition: a live BLE link is required to drive any mode change.
    // Without this, WifiOn / StartLogging issue a Control write with no GATT
    // link and throw raw "device not connected" exceptions — exactly the spam
    // seen when switching mode just after a device reboot has dropped the link.
    if (!ref.read(deviceProvider).isConnected) {
      const r = RefusedByPolicy('Connect to the device first.');
      _resultsCtrl.add(r);
      return r;
    }

    final current = ref.read(modeProvider);
    if (current == target) {
      // Re-entering the same mode is a transition no-op. The WiFi bind is
      // maintained independently by `WifiBindController` (it follows mode
      // state), so a wifi → wifi "no-op" still keeps the process bound — the
      // transition doesn't own the bind anymore.
      const r = Ok();
      _resultsCtrl.add(r);
      return r;
    }
    if (current == Mode.recording && target == Mode.wifi) {
      const r = RefusedByPolicy('Stop recording first.');
      _resultsCtrl.add(r);
      return r;
    }
    final steps = _kTransitions[(current, target)];
    if (steps == null) {
      final r = RefusedByPolicy('Transition $current → $target not allowed.');
      _resultsCtrl.add(r);
      return r;
    }

    // Picker UI is expected to gate input while a transition runs (§5.4),
    // but guard defensively here so a concurrent dispatch (e.g. test, or a
    // future programmatic caller) cannot clobber the active StepContext.
    if (_activeCtx != null) {
      const r = RefusedByPolicy('Transition already in progress.');
      _resultsCtrl.add(r);
      return r;
    }

    // Blink the hero's TX chip — we're about to send the transition's commands.
    ref.read(linkActivityProvider.notifier).pulseTx();
    final ctx = StepContext.fromRef(ref);
    _activeCtx = ctx;
    state = ModeTransition(target: target, phase: TransitionPhase.sendingAck);

    try {
      for (var i = 0; i < steps.length; i++) {
        final step = steps[i];
        state = state.copyWith(
          stepIndex: i,
          phase: TransitionPhase.sendingAck,
        );
        final result = await step.run(ctx);
        final mapped = _mapStepResult(result, target);
        if (mapped is! Ok) {
          state = const ModeTransition();
          _activeCtx = null;
          _resultsCtrl.add(mapped);
          return mapped;
        }
      }

      state = const ModeTransition();
      _activeCtx = null;
      const r = Ok();
      _resultsCtrl.add(r);
      return r;
    } finally {
      _activeCtx = null;
    }
  }

  /// Aborts the in-flight transition (if any) at the active step's next
  /// await point. The step will return [StepCancelled], which the walker
  /// maps to [AbortedByCancel].
  void cancelTransition() {
    _activeCtx?.cancel();
  }

  /// Maps a [StepResult] to its corresponding [TransitionResult].
  TransitionResult _mapStepResult(StepResult r, Mode target) {
    return switch (r) {
      StepOk() => const Ok(),
      StepRefused(:final attCode, :final reason) =>
        RefusedByFirmware(attCode: attCode, reason: reason),
      StepTimedOut() => TimedOutAwaitingConfirm(expected: target),
      StepDisconnected() => const AbortedByDisconnect(),
      StepCancelled() => const AbortedByCancel(),
      StepFailed(:final reason) => TransitionFailed(reason),
    };
  }
}

/// Riverpod provider for the singleton [ModeController]. UI consumers
/// `watch` the [ModeTransition] state for phase/progress; they `read` the
/// notifier to call [ModeController.switchTo] or
/// [ModeController.cancelTransition].
final modeControllerProvider =
    NotifierProvider<ModeController, ModeTransition>(ModeController.new);
