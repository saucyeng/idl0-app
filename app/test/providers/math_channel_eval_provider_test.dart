import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/math_channel.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/providers/math_channel_provider.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

MathChannel _ch({
  required String id,
  required String expression,
}) =>
    MathChannel(
      id: id,
      name: 'Test Channel',
      quantity: 'Speed',
      units: 'm/s',
      sampleRateHz: 0.0,
      decimalPlaces: 2,
      color: '#FF2196F3',
      expression: expression,
    );

/// Creates a [ProviderContainer] for the (skipped) eval tests.
///
/// The whole group is skipped because `mathChannelEvalProvider` evaluates
/// through the `idl-rs` bridge, whose native library is not loaded under
/// `flutter test`. [sessionId] / [sessionChannels] are retained for the
/// skipped test bodies' call signatures.
Future<ProviderContainer> _makeContainer(
  String sessionId,
  List<ChannelData> sessionChannels,
) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await container.read(mathChannelProvider.notifier).loadComplete;
  return container;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group(
    'mathChannelEvalProvider —',
    () {
      // 1
      test('evaluates expression against session channel data', () async {
        // Arrange
        const sessionId = 'session-eval-1';
        final container = await _makeContainer(
          sessionId,
          [
            const ChannelData(
              channelId: 'Speed',
              sampleRateHz: 100.0,
              samples: [1.0, 2.0, 3.0],
            ),
          ],
        );
        final channel = _ch(id: 'ch-eval-1', expression: '[Speed] * 2');
        await container.read(mathChannelProvider.notifier).addChannel(channel);

        // Act
        final result = await container.read(
          mathChannelEvalProvider(
            (
              channelId: 'ch-eval-1',
              sessionId: sessionId,
            ),
          ).future,
        );

        // Assert — metadata-only result; samples stay in the handle's math
        // store under the channel name (decimated tiles read them by id).
        expect(result.length, equals(3));
        expect(result.sampleRateHz, equals(100.0));
        expect(result.storedAs, equals('Test Channel'));
      });

      // 2
      test('surfaces AsyncError when expression references unknown channel',
          () async {
        // Arrange
        const sessionId = 'session-eval-2';
        final container = await _makeContainer(sessionId, []);
        final channel = _ch(id: 'ch-eval-2', expression: '[NoSuchChannel]');
        await container.read(mathChannelProvider.notifier).addChannel(channel);

        // Act & Assert
        await expectLater(
          container.read(
            mathChannelEvalProvider(
              (
                channelId: 'ch-eval-2',
                sessionId: sessionId,
              ),
            ).future,
          ),
          throwsA(anything),
        );
      });

      // 3
      test('re-evaluates when expression is updated in mathChannelProvider',
          () async {
        // Arrange
        const sessionId = 'session-eval-3';
        final container = await _makeContainer(
          sessionId,
          [
            const ChannelData(
              channelId: 'Speed',
              sampleRateHz: 100.0,
              samples: [10.0, 20.0],
            ),
          ],
        );
        final channel = _ch(id: 'ch-eval-3', expression: '[Speed] * 1');
        await container.read(mathChannelProvider.notifier).addChannel(channel);

        final first = await container.read(
          mathChannelEvalProvider(
            (
              channelId: 'ch-eval-3',
              sessionId: sessionId,
            ),
          ).future,
        );
        expect(first.length, equals(2));

        // Act — update expression
        await container.read(mathChannelProvider.notifier).updateChannel(
              channel.copyWith(expression: '[Speed] * 3'),
            );

        // Assert — provider re-evaluates with new expression (the result is
        // metadata-only; value parity lives in the rust/core math suite).
        final second = await container.read(
          mathChannelEvalProvider(
            (
              channelId: 'ch-eval-3',
              sessionId: sessionId,
            ),
          ).future,
        );
        expect(second.length, equals(2));
      });
    },
    // mathChannelEvalProvider now evaluates entirely through the idl-rs
    // bridge (eval_math_into_store via sessionHandleProvider). The bridge
    // native library is not loaded under `flutter test` (see chart_workspace_
    // test), and there is no Dart-side injection seam after the Phase-3a
    // cut-over. Evaluation parity is covered by the rust/core math suite
    // (idl_rs::math unit tests + math::tests_parity, ported from the former
    // Dart evaluator suite).
    skip: 'Requires the idl-rs bridge native library (not loaded under '
        'flutter test); eval parity is covered by the rust/core math suite.',
  );
}
