import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/exceptions.dart';
import 'device_provider.dart';
import 'mode.dart';

/// Typed reader and listener closures abstracting over the two sources
/// of a Riverpod handle: production code passes `Ref.read` / `Ref.listen`,
/// tests pass `ProviderContainer.read` / `ProviderContainer.listen`. Both
/// shapes are duck-compatible at runtime but share no static interface;
/// the closure pair gives us static typing without sacrificing either
/// call site.
typedef StepReader = T Function<T>(ProviderListenable<T> provider);

/// Listener closure matching `Ref.listen` / `ProviderContainer.listen`. See
/// [StepReader] for the rationale behind the closure-passing pattern.
typedef StepListener = ProviderSubscription<T> Function<T>(
  ProviderListenable<T> provider,
  void Function(T? previous, T next) listener,
);

/// Carries the dependencies a [Step] needs plus a cooperative cancel signal.
/// Created per `switchTo()` call by [ModeController] (T10). Single-use
/// across one transition's step list — calling [cancel] aborts the
/// in-flight step and short-circuits all subsequent steps in that
/// transition.
class StepContext {
  /// Reads a Riverpod provider's current value.
  final StepReader read;

  /// Subscribes to a Riverpod provider; the returned subscription must be
  /// closed when the step completes (callers should use `try / finally`).
  final StepListener listen;

  /// How long to wait for status confirmation after an ACK before
  /// emitting [StepTimedOut]. Default 2 s; the firmware's 1 Hz status
  /// publisher (T1) makes <=1 s the typical observed latency.
  final Duration confirmTimeout;

  /// Resolved when the caller wants the in-flight step to abort with
  /// [StepCancelled] at its next await point.
  final Completer<void> _cancel = Completer<void>();

  /// Creates a [StepContext] from explicit reader / listener closures.
  /// Prefer [StepContext.fromRef] (production) or
  /// [StepContext.fromContainer] (tests).
  StepContext({
    required this.read,
    required this.listen,
    this.confirmTimeout = const Duration(seconds: 2),
  });

  /// Production constructor: build a [StepContext] from a [Ref] (the
  /// handle Notifiers receive).
  factory StepContext.fromRef(
    Ref ref, {
    Duration confirmTimeout = const Duration(seconds: 2),
  }) {
    return StepContext(
      read: <T>(provider) => ref.read(provider),
      listen: <T>(provider, listener) => ref.listen<T>(provider, listener),
      confirmTimeout: confirmTimeout,
    );
  }

  /// Test constructor: build a [StepContext] from a [ProviderContainer].
  factory StepContext.fromContainer(
    ProviderContainer container, {
    Duration confirmTimeout = const Duration(seconds: 2),
  }) {
    return StepContext(
      read: <T>(provider) => container.read(provider),
      listen: <T>(provider, listener) =>
          container.listen<T>(provider, listener),
      confirmTimeout: confirmTimeout,
    );
  }

  /// Signals cancellation to the in-flight step.
  void cancel() {
    if (!_cancel.isCompleted) _cancel.complete();
  }

  /// True once [cancel] has been called.
  bool get isCancelled => _cancel.isCompleted;

  /// Future that completes when [cancel] is called.
  Future<void> get onCancel => _cancel.future;
}

/// Outcome of a single [Step]. Sealed so the controller can exhaustively map
/// each case to a `TransitionResult` / user-facing failure UX (§5.4).
sealed class StepResult {
  const StepResult();
}

/// Step completed successfully — command accepted and confirmation observed.
class StepOk extends StepResult {
  /// Creates a [StepOk] result.
  const StepOk();
}

/// Firmware returned a non-zero ATT result code (§3.3).
class StepRefused extends StepResult {
  /// ATT result code byte (e.g. `0x03` for `WRITE_NOT_PERMITTED`).
  final int attCode;

  /// User-facing reason string from [defaultAckReason].
  final String reason;

  /// Creates a [StepRefused] result carrying the ATT [attCode] and the
  /// user-facing [reason] mapped from it.
  const StepRefused({required this.attCode, required this.reason});
}

/// Confirmation (mode-change or HR-ready) did not arrive within the budget.
class StepTimedOut extends StepResult {
  /// How long the step actually waited before giving up.
  final Duration waited;

  /// Creates a [StepTimedOut] result recording the elapsed [waited] duration.
  const StepTimedOut({required this.waited});
}

/// BLE link dropped while the step was awaiting confirmation.
class StepDisconnected extends StepResult {
  /// Creates a [StepDisconnected] result.
  const StepDisconnected();
}

/// [StepContext.cancel] was called while the step was awaiting confirmation.
class StepCancelled extends StepResult {
  /// Creates a [StepCancelled] result.
  const StepCancelled();
}

/// Non-firmware transport error that aborted the step (e.g. WiFi
/// `bind`/`release` failed on Android). Distinct from [StepRefused],
/// which carries a firmware ATT result code, and from [StepDisconnected],
/// which is specifically the BLE link going down.
class StepFailed extends StepResult {
  /// User-facing explanation of what failed.
  final String reason;

  /// Creates a [StepFailed] result with the user-facing [reason].
  const StepFailed(this.reason);
}

/// A single (send command → await ACK → await confirmation) operation. The
/// [ModeController] walks a `List<Step>` for each `(from, to)` transition.
/// See spec §3.4 / §4.1.
sealed class Step {
  const Step();

  /// Runs the step against [ctx]. Must clean up all subscriptions and timers
  /// before returning so a completed step never leaks listeners.
  Future<StepResult> run(StepContext ctx);
}

/// Sends `CMD_WIFI_ON` and waits for the firmware to report [Mode.wifi].
///
/// This step brings the firmware SoftAP **up** only — it does NOT bind the
/// Android process to the AP. The bind follows WiFi-mode *state* and is owned
/// by `WifiBindController` (activated by the Device tab), so the process is
/// bound whenever the device is in [Mode.wifi] regardless of how it got there
/// (explicit switch, or relaunch with the AP already up). See
/// `providers/wifi_bind_controller.dart`.
class WifiOn extends Step {
  /// Creates a [WifiOn] step.
  const WifiOn();
  @override
  Future<StepResult> run(StepContext ctx) => _runCmd(
        ctx,
        send: () => ctx.read(bleServiceProvider).wifiOn(),
        targetMatch: (m) => m == Mode.wifi,
      );
}

/// Sends `CMD_WIFI_OFF` and waits for any mode other than [Mode.wifi].
///
/// Brings the firmware SoftAP **down** only — the Android bind is released by
/// `WifiBindController` when mode leaves [Mode.wifi] (it follows state, not
/// this action).
class WifiOff extends Step {
  /// Creates a [WifiOff] step.
  const WifiOff();
  @override
  Future<StepResult> run(StepContext ctx) => _runCmd(
        ctx,
        send: () => ctx.read(bleServiceProvider).wifiOff(),
        targetMatch: (m) => m != Mode.wifi,
      );
}

/// Sends `CMD_START_LOGGING` and waits for [Mode.recording].
class StartLogging extends Step {
  /// Creates a [StartLogging] step.
  const StartLogging();
  @override
  Future<StepResult> run(StepContext ctx) => _runCmd(
        ctx,
        send: () => ctx.read(bleServiceProvider).startRecording(),
        targetMatch: (m) => m == Mode.recording,
      );
}

/// Sends `CMD_STOP_LOGGING` and waits for any mode other than [Mode.recording].
class StopLogging extends Step {
  /// Creates a [StopLogging] step.
  const StopLogging();
  @override
  Future<StepResult> run(StepContext ctx) => _runCmd(
        ctx,
        send: () => ctx.read(bleServiceProvider).stopRecording(),
        targetMatch: (m) => m != Mode.recording,
      );
}

/// Shared (send → ACK → confirm) implementation used by [WifiOn], [WifiOff],
/// [StartLogging], [StopLogging]. Catches [CommandRefusedException] from the
/// send call (ATT non-zero) and maps it to [StepRefused]; rethrows everything
/// else so genuine bugs aren't swallowed.
Future<StepResult> _runCmd(
  StepContext ctx, {
  required Future<void> Function() send,
  required bool Function(Mode) targetMatch,
}) async {
  try {
    await send();
  } on CommandRefusedException catch (e) {
    return StepRefused(attCode: e.attCode, reason: e.reason);
  }

  if (ctx.isCancelled) return const StepCancelled();
  // Fast path: status frame already shows target mode (firmware republishes
  // on state transitions, so the confirming frame may have raced the ACK).
  if (targetMatch(ctx.read(modeProvider))) return const StepOk();
  if (!ctx.read(deviceProvider).isConnected) {
    return const StepDisconnected();
  }

  final completer = Completer<StepResult>();
  final modeSub = ctx.listen<Mode>(modeProvider, (_, next) {
    if (targetMatch(next) && !completer.isCompleted) {
      completer.complete(const StepOk());
    }
  });
  final connSub = ctx.listen<bool>(
    deviceProvider.select((s) => s.isConnected),
    (_, isConn) {
      if (!isConn && !completer.isCompleted) {
        completer.complete(const StepDisconnected());
      }
    },
  );
  ctx.onCancel.then((_) {
    if (!completer.isCompleted) completer.complete(const StepCancelled());
  });
  final timer = Timer(ctx.confirmTimeout, () {
    if (!completer.isCompleted) {
      completer.complete(StepTimedOut(waited: ctx.confirmTimeout));
    }
  });

  try {
    return await completer.future;
  } finally {
    modeSub.close();
    connSub.close();
    timer.cancel();
  }
}
