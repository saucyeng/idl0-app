import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/providers/selection_provider.dart';
import 'package:idl0/providers/session_provider.dart';

SessionMetadata _meta(String id, {String deviceId = ''}) => SessionMetadata(
      sessionId: id,
      filePath: '/sessions/$id.idl0',
      workspacePath: '/sessions/$id.idl0w',
      createdTimestampMs: 0,
      fileSizeBytes: 0,
      rider: '',
      bike: '',
      bikeComment: '',
      venueName: '',
      eventName: '',
      eventSession: '',
      shortComment: '',
      longComment: '',
      deviceId: deviceId,
    );

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  test('sessionProvider — initial state — sessions list is empty', () {
    // Arrange / Act — read initial state

    // Assert
    expect(container.read(sessionProvider).sessions, isEmpty);
  });

  test('sessionProvider — addSession — appends to the list', () {
    // Arrange
    final meta = _meta('uuid-1');

    // Act
    container.read(sessionProvider.notifier).addSession(meta);

    // Assert
    expect(container.read(sessionProvider).sessions, hasLength(1));
    expect(
      container.read(sessionProvider).sessions.first.sessionId,
      equals('uuid-1'),
    );
  });

  test('addSession — same sessionId added twice — replaces in place, no dup',
      () {
    // Arrange — register a session, then "re-download" the same session
    // (carrying a venue edit from a previous metadata save, say) to
    // simulate the retried-download path on hardware.
    final original = _meta('uuid-1', deviceId: 'aabbccddeeff');
    final reimported = original.copyWith(venueName: 'Updated Venue');
    container.read(sessionProvider.notifier).addSession(original);

    // Act
    container.read(sessionProvider.notifier).addSession(reimported);

    // Assert — exactly one entry, the latest one wins. (Mirrors the
    // ConflictAlgorithm.replace semantics used by SessionIndex.upsert so
    // both layers agree on duplicate handling, and downstream widget
    // builders never see two SessionMetadata with the same sessionId —
    // duplicate keys in the widget tree threw a rendering-library
    // exception on hardware.)
    final sessions = container.read(sessionProvider).sessions;
    expect(sessions, hasLength(1));
    expect(sessions.single.venueName, equals('Updated Venue'));
  });

  test(
      'addSession — same sessionId, different deviceId — still upserts; '
      'colliding deviceIds are not appended (would break widget keys)', () {
    // Arrange — astronomically rare cross-device UUID collision. Two
    // physically different devices happen to produce the same 128-bit
    // session UUID. Without dedup, the in-memory list has two entries
    // with the same sessionId and the widget tree throws on duplicate
    // keys. With this contract, the latest import wins — see TASKS.md
    // for the composite-sessionId migration that would let us keep both.
    final first = _meta('uuid-1', deviceId: 'aabbccddeeff');
    final second = _meta('uuid-1', deviceId: '112233445566');
    container.read(sessionProvider.notifier).addSession(first);

    // Act
    container.read(sessionProvider.notifier).addSession(second);

    // Assert
    final sessions = container.read(sessionProvider).sessions;
    expect(sessions, hasLength(1));
    expect(sessions.single.deviceId, equals('112233445566'));
  });

  test('sessionProvider — removeSession — drops from list and from selection',
      () {
    // Arrange
    container.read(sessionProvider.notifier).addSession(_meta('uuid-1'));
    container.read(selectionProvider.notifier).toggleSession('uuid-1');

    // Act
    container.read(sessionProvider.notifier).removeSession('uuid-1');

    // Assert
    expect(container.read(sessionProvider).sessions, isEmpty);
    expect(container.read(selectionProvider).sessionIds, isEmpty);
  });

  test('sessionProvider — loadSessions — replaces the list verbatim', () {
    // Arrange
    container.read(sessionProvider.notifier).addSession(_meta('stale'));

    // Act
    container
        .read(sessionProvider.notifier)
        .loadSessions([_meta('uuid-2'), _meta('uuid-3')]);

    // Assert
    final ids = container
        .read(sessionProvider)
        .sessions
        .map((s) => s.sessionId)
        .toList();
    expect(ids, equals(['uuid-2', 'uuid-3']));
  });

  test('updateSession — replaces in-memory entry by sessionId', () {
    // Arrange
    final original = _meta('x');
    container.read(sessionProvider.notifier).addSession(original);

    // Act
    container.read(sessionProvider.notifier).updateSession(
          original.copyWith(venueName: 'New'),
        );

    // Assert
    final updated = container.read(sessionProvider).sessions.single;
    expect(updated.venueName, 'New');
  });

  test('updateSession — no-op when sessionId not in list', () {
    // Arrange
    final stranger = _meta('absent');

    // Act
    container.read(sessionProvider.notifier).updateSession(stranger);

    // Assert
    expect(container.read(sessionProvider).sessions, isEmpty);
  });
}
