import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/table_model.dart';
import 'package:idl0/data/worksheet.dart';
import 'package:idl0/data/worksheet_block.dart';

void main() {
  test('WorksheetBlock chart content — JSON round-trips', () {
    // Arrange
    final block = WorksheetBlock.chart(ChartSlot(chartType: ChartType.fft));

    // Act
    final restored = WorksheetBlock.fromJson(block.toJson());

    // Assert
    expect(restored.placement, BlockPlacement.inFlow);
    expect(restored.content, isA<ChartContent>());
    expect((restored.content as ChartContent).slot.chartType, ChartType.fft);
  });

  test('WorksheetBlock table content — JSON round-trips', () {
    // Arrange
    final block = WorksheetBlock.table(TableModel.empty());

    // Act
    final restored = WorksheetBlock.fromJson(block.toJson());

    // Assert
    expect(restored.content, isA<TableContent>());
    expect((restored.content as TableContent).table.columns, isEmpty);
  });

  test('WorksheetBlock — block id is preserved through JSON', () {
    // Arrange
    final block = WorksheetBlock.chart(ChartSlot());

    // Act
    final restored = WorksheetBlock.fromJson(block.toJson());

    // Assert
    expect(restored.id, block.id);
  });

  test('TableContent — rowSource round-trips and defaults to authored', () {
    // Arrange
    final live = TableContent(
      TableModel.empty(),
      rowSource: TableRowSource.lapSelection,
    );

    // Act
    final json = live.toJson();
    final back = WorksheetBlock.fromJson({
      'id': 'b1',
      'placement': 'inFlow',
      'content': json,
    }).content as TableContent;
    final authored = WorksheetBlock.fromJson({
      'id': 'b2',
      'placement': 'inFlow',
      'content': {'kind': 'table', 'table': TableModel.empty().toJson()},
    }).content as TableContent;

    // Assert
    expect(json['rowSource'], 'lapSelection');
    expect(back.rowSource, TableRowSource.lapSelection);
    expect(authored.rowSource, TableRowSource.authored);
  });
}
