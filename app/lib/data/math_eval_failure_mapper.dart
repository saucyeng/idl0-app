import '../src/rust/math.dart' as rust;
import 'exceptions.dart';

/// Maps the generated [rust.MathEvalFailure] onto the app's typed
/// [MathChannelException] hierarchy (§16) so surfaced messages match the
/// pre-cut-over Dart evaluator.
MathChannelException mapMathEvalFailure(rust.MathEvalFailure e) {
  return switch (e.kind) {
    rust.MathEvalFailureKind.parse => ExpressionSyntaxException(e.message),
    rust.MathEvalFailureKind.unknownChannel =>
      UnknownChannelException(e.message),
    rust.MathEvalFailureKind.divisionByZero =>
      DivisionByZeroException(e.message),
    rust.MathEvalFailureKind.unknownFunction ||
    rust.MathEvalFailureKind.argCount ||
    rust.MathEvalFailureKind.type ||
    rust.MathEvalFailureKind.noLapContext ||
    rust.MathEvalFailureKind.notImplemented ||
    rust.MathEvalFailureKind.runtime =>
      MathChannelEvaluationException(e.message),
  };
}
