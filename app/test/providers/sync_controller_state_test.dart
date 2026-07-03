import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/sync_controller.dart';

SyncEntry _entry(String name, SyncEntryStatus status,
        {bool selected = false,}) =>
    SyncEntry(
      file: (name: name, size: 1000, sessionId: name),
      status: status,
      selected: selected,
    );

void main() {
  test('SyncState getters — counts new/queued/done/batchTotal correctly', () {
    // Arrange
    final state = SyncState(
      phase: SyncPhase.syncing,
      entries: [
        _entry('a', SyncEntryStatus.done),
        _entry('b', SyncEntryStatus.downloading, selected: true),
        _entry('c', SyncEntryStatus.newPending, selected: true),
        _entry('d', SyncEntryStatus.newPending, selected: false),
        _entry('e', SyncEntryStatus.inLibrary),
      ],
    );

    // Assert
    expect(state.newCount, equals(2)); // c, d are NEW regardless of selection
    expect(state.queuedCount, equals(1)); // c selected+pending; d unselected
    expect(state.downloadingCount, equals(1)); // b
    expect(state.doneCount, equals(1)); // a
    expect(state.batchTotal, equals(3)); // done + downloading + queued
  });

  test('SyncEntry — receivedBytes derives from progress and size', () {
    // Arrange
    const entry = SyncEntry(
      file: (name: 'x', size: 2000, sessionId: 'x'),
      status: SyncEntryStatus.downloading,
      progress: 0.5,
    );

    // Act / Assert
    expect(entry.receivedBytes, equals(1000));
    // A downloading entry is not "new" — only pending/unknown are.
    expect(entry.isNew, isFalse);
  });

  test('SyncEntry — isNew is true for newPending and unknownIdentity', () {
    // Arrange / Act / Assert
    expect(
      _entry('p', SyncEntryStatus.newPending).isNew,
      isTrue,
    );
    expect(
      _entry('u', SyncEntryStatus.unknownIdentity).isNew,
      isTrue,
    );
    expect(
      _entry('l', SyncEntryStatus.inLibrary).isNew,
      isFalse,
    );
  });
}
