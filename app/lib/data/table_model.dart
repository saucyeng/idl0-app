/// Serializable table model mirroring `idl_rs::table::TableModel`. The widget
/// edits this; evaluation is engine-side (see `table_eval_provider.dart`).
///
/// The JSON keys match the engine's camelCase serde keys so the model is the
/// single portable artifact persisted inside the `.idl0wb` (design §9a). The
/// field names also match the FRB-generated `rust.TableModel` so mapping to the
/// engine type is field-for-field.
library;

/// A table column. [name] (when set) is the `{name}` / `{name[]}` reference
/// target; [template] is a formula applied to every cell in the column that has
/// no own formula (evaluated in each row's context).
class TableColumn {
  /// Stable identity for the column.
  final String id;

  /// Reference name, the target of `{name}` (same-row) and `{name[]}` (column).
  final String? name;

  /// Formula applied down the column where a cell has no own formula.
  final String? template;

  /// Creates a [TableColumn].
  const TableColumn({required this.id, this.name, this.template});

  /// Serializes to a JSON-compatible map (camelCase, engine-compatible).
  Map<String, dynamic> toJson() => {
        'id': id,
        if (name != null) 'name': name,
        if (template != null) 'template': template,
      };

  /// Deserializes from a JSON map produced by [toJson].
  factory TableColumn.fromJson(Map<String, dynamic> j) => TableColumn(
        id: j['id'] as String,
        name: j['name'] as String?,
        template: j['template'] as String?,
      );
}

/// Binds a row to a lap of a session so the row's `[Channel]` references
/// resolve to that lap's window.
class RowContext {
  /// Session UUID the lap belongs to.
  final String sessionId;

  /// Zero-based lap index within the session.
  final int lapIndex;

  /// Creates a [RowContext].
  const RowContext({required this.sessionId, required this.lapIndex});

  /// Serializes to a JSON-compatible map.
  Map<String, dynamic> toJson() =>
      {'sessionId': sessionId, 'lapIndex': lapIndex};

  /// Deserializes from a JSON map produced by [toJson].
  factory RowContext.fromJson(Map<String, dynamic> j) => RowContext(
        sessionId: j['sessionId'] as String,
        lapIndex: (j['lapIndex'] as num).toInt(),
      );
}

/// A table row. [context] optionally binds a lap window for `[Channel]` refs.
class TableRow {
  /// Stable identity for the row.
  final String id;

  /// Lap binding for this row, or null for an unbound row.
  final RowContext? context;

  /// Creates a [TableRow].
  const TableRow({required this.id, this.context});

  /// Serializes to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
        'id': id,
        if (context != null) 'context': context!.toJson(),
      };

  /// Deserializes from a JSON map produced by [toJson].
  factory TableRow.fromJson(Map<String, dynamic> j) => TableRow(
        id: j['id'] as String,
        context: j['context'] == null
            ? null
            : RowContext.fromJson(j['context'] as Map<String, dynamic>),
      );
}

/// One table cell. A [literal] short-circuits evaluation; otherwise the
/// effective formula is [formula] or the column's template. [name] lets a
/// single cell be a `{name}` target.
class TableCell {
  /// Cell formula (omit the leading `=`); null falls back to the column template.
  final String? formula;

  /// Literal numeric value; when set, the cell is not evaluated.
  final double? literal;

  /// Optional `{name}` reference target for this single cell.
  final String? name;

  /// Creates a [TableCell].
  const TableCell({this.formula, this.literal, this.name});

  /// Serializes to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
        if (formula != null) 'formula': formula,
        if (literal != null) 'literal': literal,
        if (name != null) 'name': name,
      };

  /// Deserializes from a JSON map produced by [toJson].
  factory TableCell.fromJson(Map<String, dynamic> j) => TableCell(
        formula: j['formula'] as String?,
        literal: (j['literal'] as num?)?.toDouble(),
        name: j['name'] as String?,
      );
}

/// A grid of cells whose formulas reference other cells and row-windowed
/// channels. Mirrors `idl_rs::table::TableModel`; evaluated engine-side.
class TableModel {
  /// Columns in display order.
  final List<TableColumn> columns;

  /// Rows in display order.
  final List<TableRow> rows;

  /// `cells[r][c]` is the cell at row `r`, column `c`.
  final List<List<TableCell>> cells;

  /// Creates a [TableModel].
  const TableModel({
    required this.columns,
    required this.rows,
    required this.cells,
  });

  /// An empty table (no columns, rows, or cells).
  factory TableModel.empty() => const TableModel(
        columns: [],
        rows: [],
        cells: [],
      );

  /// Serializes to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
        'columns': columns.map((c) => c.toJson()).toList(),
        'rows': rows.map((r) => r.toJson()).toList(),
        'cells':
            cells.map((row) => row.map((c) => c.toJson()).toList()).toList(),
      };

  /// Deserializes from a JSON map produced by [toJson].
  factory TableModel.fromJson(Map<String, dynamic> j) => TableModel(
        columns: (j['columns'] as List)
            .map((c) => TableColumn.fromJson(c as Map<String, dynamic>))
            .toList(),
        rows: (j['rows'] as List)
            .map((r) => TableRow.fromJson(r as Map<String, dynamic>))
            .toList(),
        cells: (j['cells'] as List)
            .map(
              (row) => (row as List)
                  .map((c) => TableCell.fromJson(c as Map<String, dynamic>))
                  .toList(),
            )
            .toList(),
      );
}
