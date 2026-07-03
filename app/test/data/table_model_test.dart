import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/table_model.dart';

void main() {
  test('TableModel — JSON round-trips columns/rows/cells', () {
    // Arrange
    const t = TableModel(
      columns: [TableColumn(id: 'c0', name: 'fmax', template: 'max([Fork])')],
      rows: [TableRow(id: 'r0', context: RowContext(sessionId: 's', lapIndex: 2))],
      cells: [
        [TableCell(formula: '{fmax} - min({fmax[]})')],
      ],
    );

    // Act
    final restored = TableModel.fromJson(t.toJson());

    // Assert
    expect(restored.columns.single.template, 'max([Fork])');
    expect(restored.rows.single.context!.lapIndex, 2);
    expect(restored.cells[0][0].formula, '{fmax} - min({fmax[]})');
  });

  test('TableModel.empty — has no columns, rows, or cells', () {
    // Arrange / Act
    final t = TableModel.empty();

    // Assert
    expect(t.columns, isEmpty);
    expect(t.rows, isEmpty);
    expect(t.cells, isEmpty);
  });

  test('TableCell — literal and name round-trip, omitted keys absent', () {
    // Arrange
    const cell = TableCell(literal: 3.0, name: 'lap');

    // Act
    final json = cell.toJson();
    final restored = TableCell.fromJson(json);

    // Assert
    expect(json.containsKey('formula'), isFalse);
    expect(restored.literal, 3.0);
    expect(restored.name, 'lap');
  });
}
