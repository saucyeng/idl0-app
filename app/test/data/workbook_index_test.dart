import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/workbook.dart';
import 'package:idl0/data/workbook_index.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('WorkbookIndex —', () {
    late WorkbookIndex index;

    setUp(() async {
      index = await WorkbookIndex.open(inMemoryDatabasePath);
    });

    tearDown(() async {
      await index.close();
    });

    test('upsert + getById — returns same workbook', () async {
      // Arrange
      final wb = Workbook.create(name: 'A');

      // Act
      await index.upsert(wb);
      final fetched = await index.getById(wb.workbookId);

      // Assert
      expect(fetched, isNotNull);
      expect(fetched!.workbookId, wb.workbookId);
      expect(fetched.name, 'A');
    });

    test('getAll — orders by updated_at_ms descending', () async {
      // Arrange
      final older = Workbook.create(name: 'old', now: DateTime.utc(2026, 1, 1));
      final newer = Workbook.create(name: 'new', now: DateTime.utc(2026, 6, 1));

      // Act
      await index.upsert(older);
      await index.upsert(newer);
      final all = await index.getAll();

      // Assert
      expect(all.map((w) => w.name).toList(), ['new', 'old']);
    });

    test('delete — removes the row', () async {
      // Arrange
      final wb = Workbook.create(name: 'x');
      await index.upsert(wb);

      // Act
      await index.delete(wb.workbookId);

      // Assert
      expect(await index.getById(wb.workbookId), isNull);
    });

    test('upsert — replaces existing row on same id', () async {
      // Arrange
      final wb = Workbook.create(name: 'first');
      await index.upsert(wb);
      final renamed = wb.copyWith(name: 'second', now: DateTime.utc(2027));

      // Act
      await index.upsert(renamed);
      final all = await index.getAll();

      // Assert
      expect(all.length, 1);
      expect(all.first.name, 'second');
    });

    test('getById — returns null when not present', () async {
      // Arrange — empty index

      // Act
      final fetched = await index.getById('does-not-exist');

      // Assert
      expect(fetched, isNull);
    });
  });
}
