import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/exceptions.dart';
import 'package:idl0/data/overlay_layout.dart';
import 'package:idl0/data/workbook.dart';
import 'package:idl0/providers/workspace_provider.dart';

void main() {
  group('Workbook —', () {
    test('Workbook.create — assigns UUID and matched timestamps', () {
      final now = DateTime.utc(2026, 5, 26, 12, 0, 0);
      final wb = Workbook.create(name: 'Test', now: now);

      expect(wb.workbookId, isNotEmpty);
      expect(wb.name, 'Test');
      expect(wb.worksheets, isEmpty);
      expect(wb.mathChannels, isEmpty);
      expect(wb.createdAtMs, now.millisecondsSinceEpoch);
      expect(wb.updatedAtMs, now.millisecondsSinceEpoch);
      expect(wb.workbookVersion, 2);
    });

    test('toJson → fromJson — round-trips all fields', () {
      final wb = Workbook(
        workbookId: 'abc-123',
        name: 'Suspension',
        worksheets: [Worksheet(name: 'Sheet 1')],
        mathChannels: const [],
        createdAtMs: 1700000000000,
        updatedAtMs: 1700000500000,
        workbookVersion: 1,
      );

      final decoded = Workbook.fromJson(wb.toJson());

      expect(decoded.workbookId, wb.workbookId);
      expect(decoded.name, wb.name);
      expect(decoded.worksheets.length, 1);
      expect(decoded.worksheets.first.name, 'Sheet 1');
      expect(decoded.createdAtMs, wb.createdAtMs);
      expect(decoded.updatedAtMs, wb.updatedAtMs);
      expect(decoded.workbookVersion, 1);
    });

    test(
        'fromJson — too-new version throws UnsupportedWorkbookVersionException',
        () {
      final json = {
        'workbook_id': 'x',
        'name': 'x',
        'created_at_ms': 0,
        'updated_at_ms': 0,
        'workbook_version': 999,
      };

      expect(
        () => Workbook.fromJson(json),
        throwsA(isA<UnsupportedWorkbookVersionException>()),
      );
    });

    test('fromJson — missing required field throws WorkbookParseException', () {
      expect(
        () => Workbook.fromJson({
          'name': 'no id here',
          'created_at_ms': 0,
          'updated_at_ms': 0,
          'workbook_version': 1,
        }),
        throwsA(isA<WorkbookParseException>()),
      );
    });

    test('copyWith — bumps updatedAtMs when a content field changes', () {
      const wb = Workbook(
        workbookId: 'x',
        name: 'Old',
        worksheets: [],
        mathChannels: [],
        createdAtMs: 1000,
        updatedAtMs: 1000,
        workbookVersion: 1,
      );
      final later = DateTime.utc(2026, 5, 26, 12, 0, 1);

      final renamed = wb.copyWith(name: 'New', now: later);

      expect(renamed.name, 'New');
      expect(renamed.updatedAtMs, later.millisecondsSinceEpoch);
      expect(renamed.createdAtMs, 1000);
    });

    test('copyWith — no content change leaves updatedAtMs untouched', () {
      const wb = Workbook(
        workbookId: 'x',
        name: 'Same',
        worksheets: [],
        mathChannels: [],
        createdAtMs: 1000,
        updatedAtMs: 2000,
        workbookVersion: 1,
      );

      final still = wb.copyWith();

      expect(still.updatedAtMs, 2000);
    });

    group('Workbook v2 — overlay layouts —', () {
      test('fromJson — v1 json without overlay_layouts — defaults to empty',
          () {
        // Arrange
        final wb = Workbook.create(name: 'wb');
        final json = wb.toJson()
          ..['workbook_version'] = 1
          ..remove('overlay_layouts');

        // Act
        final back = Workbook.fromJson(json);

        // Assert
        expect(back.overlayLayouts, isEmpty);
      });

      test('toJson/fromJson — with a layout — round-trips and version is 2',
          () {
        // Arrange
        const layout = OverlayLayout(
          id: 'L1',
          name: 'A',
          canvas: '1920x1080',
          elements: [TrackMapElement(rect: [0.8, 0.0, 0.2, 0.3])],
        );
        final wb =
            Workbook.create(name: 'wb').copyWith(overlayLayouts: [layout]);

        // Act
        final back = Workbook.fromJson(wb.toJson());

        // Assert
        expect(back.workbookVersion, 2);
        expect(back.overlayLayouts.single.name, 'A');
        expect(
          back.overlayLayouts.single.elements.single,
          isA<TrackMapElement>(),
        );
      });
    });
  });
}
