import 'package:idl0/data/table_model.dart';
import 'package:uuid/uuid.dart';

/// Builds a per-lap summary [TableModel]: rows = laps (1..[lapCount]), columns =
/// a Lap label + a `max(...)` metric per channel + a delta-to-best column for
/// the first metric. Cell values come from column templates; each row carries a
/// lap [RowContext] so `[Channel]` references resolve to that lap's window.
///
/// The delta column uses the `{name[]}` whole-column aggregate
/// (`{m} - min({m[]})`) so it reads "how far off the best lap this lap is".
TableModel buildPerLapTable({
  required String sessionId,
  required int lapCount,
  required List<String> metricChannels,
}) {
  const uuid = Uuid();
  final columns = <TableColumn>[
    TableColumn(id: uuid.v4(), name: 'lap'), // label column, literals per row
    for (final ch in metricChannels)
      TableColumn(
        id: uuid.v4(),
        name: '${ch.toLowerCase()}_max',
        template: 'max([$ch])',
      ),
  ];
  // Delta-to-best on the first metric.
  if (metricChannels.isNotEmpty) {
    final m = '${metricChannels.first.toLowerCase()}_max';
    columns.add(
      TableColumn(
        id: uuid.v4(),
        name: '${m}_delta',
        template: '{$m} - min({$m[]})',
      ),
    );
  }
  final rows = <TableRow>[
    for (var i = 0; i < lapCount; i++)
      TableRow(id: uuid.v4(), context: RowContext(sessionId: sessionId, lapIndex: i)),
  ];
  final cells = <List<TableCell>>[
    for (var i = 0; i < lapCount; i++)
      [
        TableCell(literal: (i + 1).toDouble()), // Lap number label
        for (var c = 1; c < columns.length; c++) const TableCell(), // template-driven
      ],
  ];
  return TableModel(columns: columns, rows: rows, cells: cells);
}
