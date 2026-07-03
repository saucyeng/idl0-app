import 'package:idl0/data/table_model.dart';
import 'package:idl0/data/worksheet.dart' show ChartSlot;
import 'package:uuid/uuid.dart';

/// How a block sits in the worksheet. v1 renders only [inFlow] (stacked in
/// document order); [sideBySide] and [overlay] are stored for the Plan-2
/// flexible-layout subsystem but not yet honoured. See design §7.
enum BlockPlacement {
  /// Stacked in the worksheet's vertical flow (the only v1 layout).
  inFlow,

  /// Placed beside its predecessor (Plan 2).
  sideBySide,

  /// Drawn as a translucent overlay on [overlayTargetId] (Plan 2).
  overlay,
}

/// Where a table block's rows come from. [authored] rows are persisted in the
/// model (and read by the headless CLI); [lapSelection] rows are derived live
/// from the shared lap selection (the N-lap comparison table) and not persisted
/// — only the columns, alignment, and Main pin persist. See the N-lap variance
/// design §5, §8.
enum TableRowSource {
  /// Rows are persisted in the [TableModel] (the default; the CLI path).
  authored,

  /// Rows are derived live from the shared lap selection (N-lap comparison).
  lapSelection,
}

/// The payload of a worksheet block — a chart or a table.
sealed class BlockContent {
  /// Serializes the content (with a `kind` discriminator) to JSON.
  Map<String, dynamic> toJson();
}

/// A chart block payload wrapping a [ChartSlot].
class ChartContent extends BlockContent {
  /// Creates a [ChartContent].
  ChartContent(this.slot);

  /// The chart slot rendered by this block.
  final ChartSlot slot;

  @override
  Map<String, dynamic> toJson() => {'kind': 'chart', 'slot': slot.toJson()};
}

/// A table block payload wrapping a [TableModel].
class TableContent extends BlockContent {
  /// Creates a [TableContent]. [rowSource] defaults to [TableRowSource.authored].
  TableContent(this.table, {this.rowSource = TableRowSource.authored});

  /// The table model rendered/edited by this block. For
  /// [TableRowSource.lapSelection] only its columns are meaningful — rows are
  /// derived at render time from the shared lap selection.
  final TableModel table;

  /// Where this table's rows come from.
  final TableRowSource rowSource;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'table',
        'table': table.toJson(),
        if (rowSource != TableRowSource.authored) 'rowSource': rowSource.name,
      };
}

/// A first-class worksheet block: a chart or a table, with a placement. Blocks
/// replace the old flat chart list so tables and charts share one ordered,
/// placeable container (design §6, §7).
class WorksheetBlock {
  /// Creates a [WorksheetBlock], generating a stable UUID when [id] is omitted.
  WorksheetBlock({
    String? id,
    required this.content,
    this.placement = BlockPlacement.inFlow,
    this.overlayTargetId,
    this.overlayOpacity = 1.0,
  }) : id = id ?? const Uuid().v4();

  /// Stable identity, used to address the block in mutations and as a list key.
  final String id;

  /// The chart or table payload.
  final BlockContent content;

  /// How the block is laid out (only [BlockPlacement.inFlow] honoured in v1).
  final BlockPlacement placement;

  /// Target block id for [BlockPlacement.overlay] (Plan 2). Null otherwise.
  final String? overlayTargetId;

  /// Overlay opacity for [BlockPlacement.overlay] (Plan 2). Default 1.0.
  final double overlayOpacity;

  /// Creates a chart block wrapping [slot].
  factory WorksheetBlock.chart(ChartSlot slot, {String? id}) =>
      WorksheetBlock(id: id, content: ChartContent(slot));

  /// Creates a table block wrapping [table].
  factory WorksheetBlock.table(TableModel table, {String? id}) =>
      WorksheetBlock(id: id, content: TableContent(table));

  /// Returns a copy with the given fields replaced. [id] is preserved.
  WorksheetBlock copyWith({
    BlockContent? content,
    BlockPlacement? placement,
    String? overlayTargetId,
    double? overlayOpacity,
  }) =>
      WorksheetBlock(
        id: id,
        content: content ?? this.content,
        placement: placement ?? this.placement,
        overlayTargetId: overlayTargetId ?? this.overlayTargetId,
        overlayOpacity: overlayOpacity ?? this.overlayOpacity,
      );

  /// Serializes to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
        'id': id,
        'placement': placement.name,
        if (overlayTargetId != null) 'overlayTargetId': overlayTargetId,
        if (overlayOpacity != 1.0) 'overlayOpacity': overlayOpacity,
        'content': content.toJson(),
      };

  /// Deserializes from a JSON map produced by [toJson]. An unknown content kind
  /// falls back to a chart block so older/newer files load without crashing.
  factory WorksheetBlock.fromJson(Map<String, dynamic> json) {
    final c = json['content'] as Map<String, dynamic>;
    final content = switch (c['kind']) {
      'table' => TableContent(
          TableModel.fromJson(c['table'] as Map<String, dynamic>),
          rowSource: TableRowSource.values.firstWhere(
            (s) => s.name == c['rowSource'],
            orElse: () => TableRowSource.authored,
          ),
        ),
      _ => ChartContent(ChartSlot.fromJson(c['slot'] as Map<String, dynamic>)),
    };
    return WorksheetBlock(
      id: json['id'] as String?,
      content: content,
      placement: BlockPlacement.values.firstWhere(
        (p) => p.name == json['placement'],
        orElse: () => BlockPlacement.inFlow,
      ),
      overlayTargetId: json['overlayTargetId'] as String?,
      overlayOpacity: (json['overlayOpacity'] as num?)?.toDouble() ?? 1.0,
    );
  }
}
