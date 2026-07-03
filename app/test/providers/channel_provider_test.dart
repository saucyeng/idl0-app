import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/providers/channel_provider.dart';
import 'package:idl0/providers/selection_provider.dart';
import 'package:idl0/providers/session_provider.dart';
import 'package:idl0/src/rust/session.dart' as rust;

SessionMetadata _meta(String id) => SessionMetadata(
      sessionId: id,
      filePath: '/sessions/$id.idl0',
      workspacePath: '/sessions/$id.idl0w',
      createdTimestampMs: DateTime(2026, 4, 20).millisecondsSinceEpoch,
      fileSizeBytes: 0,
      rider: '',
      bike: '',
      bikeComment: '',
      venueName: '',
      eventName: '',
      eventSession: '',
      shortComment: '',
      longComment: '',
      deviceId: '',
    );

rust.ChannelMeta _ch(String id, {double rate = 800}) => rust.ChannelMeta(
      channelId: id,
      sampleRateHz: rate,
      length: 0,
      isEventDriven: rate == 0,
      synthesized: false,
    );

void main() {
  group('availableChannelNamesProvider', () {
    test("single session selected — returns that session's channel names",
        () async {
      // Arrange — channel names come from metadata only, not the sample copy.
      final container = ProviderContainer(
        overrides: [
          sessionChannelMetaProvider('uuid-1').overrideWith(
            (ref) async => [_ch('IMU0_AccelX'), _ch('IMU0_AccelY')],
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(availableChannelNamesProvider, (_, __) {});
      container.read(sessionProvider.notifier).addSession(_meta('uuid-1'));
      container.read(selectionProvider.notifier).toggleSession('uuid-1');

      // Act
      await container.read(sessionChannelMetaProvider('uuid-1').future);
      final names = container.read(availableChannelNamesProvider);

      // Assert
      expect(names, equals(['IMU0_AccelX', 'IMU0_AccelY']));
    });

    test('two sessions selected — returns sorted union of both channel sets',
        () async {
      // Arrange
      final container = ProviderContainer(
        overrides: [
          sessionChannelMetaProvider('uuid-1').overrideWith(
            (ref) async => [_ch('IMU0_AccelX'), _ch('WheelFront', rate: 50)],
          ),
          sessionChannelMetaProvider('uuid-2').overrideWith(
            (ref) async => [_ch('IMU0_AccelX'), _ch('GPS_Speed', rate: 10)],
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(availableChannelNamesProvider, (_, __) {});
      container.read(sessionProvider.notifier).addSession(_meta('uuid-1'));
      container.read(sessionProvider.notifier).addSession(_meta('uuid-2'));
      container.read(selectionProvider.notifier).toggleSession('uuid-1');
      container.read(selectionProvider.notifier).toggleSession('uuid-2');

      // Act
      await container.read(sessionChannelMetaProvider('uuid-1').future);
      await container.read(sessionChannelMetaProvider('uuid-2').future);
      final names = container.read(availableChannelNamesProvider);

      // Assert — deduplicated and sorted
      expect(names, equals(['GPS_Speed', 'IMU0_AccelX', 'WheelFront']));
    });

    test('no sessions selected — returns empty list', () {
      // Arrange
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Act
      final names = container.read(availableChannelNamesProvider);

      // Assert
      expect(names, isEmpty);
    });

    test("one session file errors — other session's channels still returned",
        () async {
      // Arrange
      final container = ProviderContainer(
        overrides: [
          sessionChannelMetaProvider('uuid-bad').overrideWith(
            (ref) async =>
                throw Exception('File not found: /sessions/uuid-bad.idl0'),
          ),
          sessionChannelMetaProvider('uuid-good').overrideWith(
            (ref) async => [_ch('IMU0_GyroZ')],
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(availableChannelNamesProvider, (_, __) {});
      container.read(sessionProvider.notifier).addSession(_meta('uuid-bad'));
      container.read(sessionProvider.notifier).addSession(_meta('uuid-good'));
      container.read(selectionProvider.notifier).toggleSession('uuid-bad');
      container.read(selectionProvider.notifier).toggleSession('uuid-good');

      // Act — await both; bad one completes as AsyncError
      await container
          .read(sessionChannelMetaProvider('uuid-bad').future)
          .catchError((_) => <rust.ChannelMeta>[]);
      await container.read(sessionChannelMetaProvider('uuid-good').future);
      final names = container.read(availableChannelNamesProvider);

      // Assert — errored session skipped, good session channels present
      expect(names, equals(['IMU0_GyroZ']));
    });
  });
}
