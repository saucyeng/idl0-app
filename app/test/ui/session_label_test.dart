import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/session_model.dart';
import 'package:idl0/ui/tabs/analyze/session_label.dart';

SessionMetadata _meta({required String id, required int createdMs}) =>
    SessionMetadata(
      sessionId: id,
      filePath: '',
      workspacePath: '',
      createdTimestampMs: createdMs,
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

void main() {
  test('formatSessionLabel — known epoch — YYYY-MM-DD HH:MM in UTC', () {
    // Arrange — derive the epoch from a UTC wall-clock so the expectation is
    // self-evident.
    final createdMs = DateTime.utc(2026, 6, 24, 14, 5).millisecondsSinceEpoch;
    final m = _meta(id: 'abc', createdMs: createdMs);

    // Act
    final label = formatSessionLabel(m);

    // Assert
    expect(label, equals('2026-06-24 14:05'));
  });

  test('sessionDisplayLabel — id present — formatted date', () {
    // Arrange
    final createdMs = DateTime.utc(2026, 6, 24, 14, 5).millisecondsSinceEpoch;
    final sessions = [_meta(id: 'sess-1', createdMs: createdMs)];

    // Act
    final label = sessionDisplayLabel(sessions, 'sess-1');

    // Assert
    expect(label, equals('2026-06-24 14:05'));
  });

  test('sessionDisplayLabel — id absent — 8-char uuid prefix fallback', () {
    // Arrange
    final sessions = <SessionMetadata>[];

    // Act
    final label = sessionDisplayLabel(sessions, 'df0a57622722fe2e');

    // Assert
    expect(label, equals('df0a5762'));
  });
}
