import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/table_model.dart';
import 'package:idl0/data/worksheet.dart';
import 'package:idl0/data/worksheet_block.dart';

void main() {
  group('ChartSlot scatter', () {
    test('toJson/fromJson — scatter slot — round-trips every scatter field', () {
      // Arrange
      final slot = ChartSlot(
        chartType: ChartType.scatter,
        scatterXChannelId: 'IMU0_AccelY',
        scatterYChannelId: 'IMU0_AccelX',
        scatterMode: ScatterMode.density,
        scatterColorChannelId: 'GPS_Speed',
        scatterColorMin: -1.0,
        scatterColorMax: 1.0,
        scatterEqualAspect: false,
        scatterReferenceCircles: false,
        scatterBinCount: 32,
      );

      // Act
      final restored = ChartSlot.fromJson(slot.toJson());

      // Assert
      expect(restored.chartType, ChartType.scatter);
      expect(restored.scatterXChannelId, 'IMU0_AccelY');
      expect(restored.scatterYChannelId, 'IMU0_AccelX');
      expect(restored.scatterMode, ScatterMode.density);
      expect(restored.scatterColorChannelId, 'GPS_Speed');
      expect(restored.scatterColorMin, -1.0);
      expect(restored.scatterColorMax, 1.0);
      expect(restored.scatterEqualAspect, false);
      expect(restored.scatterReferenceCircles, false);
      expect(restored.scatterBinCount, 32);
    });

    test('fromJson — absent scatter fields — applies documented defaults', () {
      // Arrange — a bare scatter slot with no scatter keys.
      final json = {'chartType': 'scatter'};

      // Act
      final slot = ChartSlot.fromJson(json);

      // Assert
      expect(slot.scatterXChannelId, isNull);
      expect(slot.scatterYChannelId, isNull);
      expect(slot.scatterMode, ScatterMode.points);
      expect(slot.scatterEqualAspect, true);
      expect(slot.scatterReferenceCircles, true);
      expect(slot.scatterBinCount, 64);
    });

    test('fromJson — unknown scatterMode — falls back to points', () {
      // Arrange
      final json = {'chartType': 'scatter', 'scatterMode': 'bogus'};

      // Act
      final slot = ChartSlot.fromJson(json);

      // Assert
      expect(slot.scatterMode, ScatterMode.points);
    });
  });

  test('Worksheet.fromJson — legacy charts array migrates to chart blocks', () {
    // Arrange — a pre-blocks worksheet with a charts array (no blocks key).
    final json = {
      'id': 'w1',
      'name': 'Sheet 1',
      'xAxisMode': 'time',
      'charts': [
        {'chartType': 'timeSeries', 'channelIds': <String>[]},
        {'chartType': 'fft', 'channelIds': <String>[]},
      ],
    };

    // Act
    final ws = Worksheet.fromJson(json);

    // Assert
    expect(ws.blocks.length, 2);
    expect(ws.blocks.every((b) => b.content is ChartContent), isTrue);
    expect((ws.blocks[1].content as ChartContent).slot.chartType, ChartType.fft);
  });

  test('Worksheet — round-trips a table block', () {
    // Arrange
    final ws = Worksheet(name: 'S', blocks: [WorksheetBlock.table(TableModel.empty())]);

    // Act
    final restored = Worksheet.fromJson(ws.toJson());

    // Assert
    expect(restored.blocks.single.content, isA<TableContent>());
  });

  test('withChartSlots — preserves table blocks after the charts', () {
    // Arrange — a worksheet with one chart then one table.
    final ws = Worksheet(
      name: 'S',
      blocks: [
        WorksheetBlock.chart(ChartSlot()),
        WorksheetBlock.table(TableModel.empty()),
      ],
    );

    // Act — replace the chart list with two charts.
    final updated = ws.withChartSlots([ChartSlot(), ChartSlot()]);

    // Assert — two chart blocks first, the table block preserved after them.
    expect(updated.blocks.length, 3);
    expect(updated.blocks[0].content, isA<ChartContent>());
    expect(updated.blocks[1].content, isA<ChartContent>());
    expect(updated.blocks[2].content, isA<TableContent>());
    expect(updated.tableBlocks.single.id, ws.tableBlocks.single.id);
  });

  test('charts getter — returns only chart slots, in order', () {
    // Arrange
    final ws = Worksheet(
      name: 'S',
      blocks: [
        WorksheetBlock.chart(ChartSlot(chartType: ChartType.timeSeries)),
        WorksheetBlock.table(TableModel.empty()),
        WorksheetBlock.chart(ChartSlot(chartType: ChartType.fft)),
      ],
    );

    // Act / Assert
    expect(
      ws.charts.map((c) => c.chartType),
      [ChartType.timeSeries, ChartType.fft],
    );
  });

  test('ChartSlot — variance fields round-trip', () {
    // Arrange
    final slot = ChartSlot(chartType: ChartType.varianceTrace).copyWith(
      varianceChannelIds: ['Fork'],
      varianceMode: VarianceMode.time,
    );

    // Act
    final back = ChartSlot.fromJson(slot.toJson());

    // Assert
    expect(back.chartType, ChartType.varianceTrace);
    expect(back.varianceChannelIds, ['Fork']);
    expect(back.varianceMode, VarianceMode.time);
  });

  test('ChartSlot — variance fields default for non-variance slots', () {
    // Arrange — a timeSeries slot omits the variance keys; defaults apply.
    final back = ChartSlot.fromJson(ChartSlot().toJson());

    // Assert
    expect(back.varianceChannelIds, isEmpty);
    expect(back.varianceMode, VarianceMode.distance);
  });
}
