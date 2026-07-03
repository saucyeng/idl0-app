import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/table_model.dart' as dm;
import '../../../data/worksheet_block.dart';
import '../../../providers/table_eval_provider.dart';
import '../../../providers/workspace_provider.dart';
import '../../../src/rust/table.dart' as rust;
import '../../brand/brand.dart';
import '../../widgets/value_format.dart' show formatChannelValue;

/// Renders and edits a table block. The grid is evaluated engine-side
/// ([tableEvalProvider]); each cell shows its formatted value or an inline
/// error. Tapping a cell edits its formula/literal; tapping a column header
/// edits the column name/template. Edits write the new [dm.TableModel] back
/// into the block via [WorkspaceNotifier.updateBlock].
class TableWidget extends ConsumerWidget {
  /// Creates a [TableWidget].
  const TableWidget({
    super.key,
    required this.blockId,
    required this.table,
    required this.sessionId,
  });

  /// Id of the [WorksheetBlock] this table lives in (the edit write-back key).
  final String blockId;

  /// The table model rendered and edited.
  final dm.TableModel table;

  /// Bound primary session whose channels `[Channel]` references resolve
  /// against; empty when no session is loaded (the grid then shows literals
  /// only).
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = sessionId.isEmpty
        ? null
        : ref
            .watch(tableEvalProvider((sessionId: sessionId, table: table)))
            .valueOrNull;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: brandSurface,
        border: Border.all(color: brandRule),
        borderRadius:
            const BorderRadius.all(Radius.circular(brandControlRadiusSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, ref),
          if (table.columns.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Empty table.',
                style: plexMono(fontSize: 12, color: brandFgDim),
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: _grid(context, ref, results),
            ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, WidgetRef ref) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        child: Row(
          children: [
            const Icon(Icons.table_rows_outlined, size: 16, color: brandFgDim),
            const SizedBox(width: 8),
            Text('Table', style: plexMono(fontSize: 12, color: brandFgDim)),
            const Spacer(),
            IconButton(
              tooltip: 'Remove table',
              icon: const Icon(Icons.close, size: 16, color: brandFgDim),
              onPressed: () =>
                  ref.read(workspaceProvider.notifier).removeBlock(blockId),
            ),
          ],
        ),
      );

  Widget _grid(
    BuildContext context,
    WidgetRef ref,
    List<List<rust.CellResult>>? results,
  ) =>
      Table(
        defaultColumnWidth: const FixedColumnWidth(108),
        border: const TableBorder.symmetric(
          inside: BorderSide(color: brandRule),
        ),
        children: [
          TableRow(
            decoration: const BoxDecoration(color: brandSurface2),
            children: [
              for (var c = 0; c < table.columns.length; c++)
                _headerCell(context, ref, c),
            ],
          ),
          for (var r = 0; r < table.rows.length; r++)
            TableRow(
              children: [
                for (var c = 0; c < table.columns.length; c++)
                  _bodyCell(context, ref, r, c, results),
              ],
            ),
        ],
      );

  Widget _headerCell(BuildContext context, WidgetRef ref, int c) {
    final col = table.columns[c];
    return InkWell(
      onTap: () => _editColumn(context, ref, c),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text(
          col.name ?? col.id,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: plexMono(fontSize: 12, color: brandFg).copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _bodyCell(
    BuildContext context,
    WidgetRef ref,
    int r,
    int c,
    List<List<rust.CellResult>>? results,
  ) {
    final cell = table.cells[r][c];
    final result = (results != null && r < results.length && c < results[r].length)
        ? results[r][c]
        : null;

    String text;
    Color color = brandFg;
    if (result?.error != null) {
      text = result!.error!;
      color = brandAccent;
    } else if (result?.value != null) {
      text = formatChannelValue(result!.value!);
    } else if (cell.literal != null) {
      text = formatChannelValue(cell.literal!);
    } else if (sessionId.isEmpty) {
      text = '—';
      color = brandFgDim;
    } else {
      text = '…'; // evaluating
      color = brandFgDim;
    }

    return InkWell(
      onTap: () => _editCell(context, ref, r, c),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: plexMono(fontSize: 12, color: color),
        ),
      ),
    );
  }

  // ── Edits ────────────────────────────────────────────────────────────────

  Future<void> _editCell(
    BuildContext context,
    WidgetRef ref,
    int r,
    int c,
  ) async {
    final cell = table.cells[r][c];
    final initial = cell.literal != null
        ? formatChannelValue(cell.literal!)
        : (cell.formula != null ? '=${cell.formula}' : '');
    final controller = TextEditingController(text: initial);

    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Cell', style: plexMono(fontSize: 14, color: brandFg)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: plexMono(fontSize: 13, color: brandFg),
          decoration: const InputDecoration(
            helperText: 'Number, or =formula (e.g. =max([Fork])). '
                'Blank uses the column template.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true) return;

    final newCell = _parseCell(controller.text);
    _commit(ref, _withCell(table, r, c, newCell));
  }

  Future<void> _editColumn(
    BuildContext context,
    WidgetRef ref,
    int c,
  ) async {
    final col = table.columns[c];
    final nameCtl = TextEditingController(text: col.name ?? '');
    final tmplCtl = TextEditingController(text: col.template ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Column', style: plexMono(fontSize: 14, color: brandFg)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtl,
              style: plexMono(fontSize: 13, color: brandFg),
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: tmplCtl,
              style: plexMono(fontSize: 13, color: brandFg),
              decoration: const InputDecoration(
                labelText: 'Template',
                helperText: 'Applied to each cell without its own formula.',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true) return;

    final name = nameCtl.text.trim();
    final tmpl = tmplCtl.text.trim();
    final newCol = dm.TableColumn(
      id: col.id,
      name: name.isEmpty ? null : name,
      template: tmpl.isEmpty ? null : tmpl,
    );
    _commit(ref, _withColumn(table, c, newCol));
  }

  /// A literal number, a `=formula`, an unprefixed formula, or a blank cell.
  dm.TableCell _parseCell(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const dm.TableCell();
    if (text.startsWith('=')) {
      return dm.TableCell(formula: text.substring(1).trim());
    }
    final n = double.tryParse(text);
    return n != null ? dm.TableCell(literal: n) : dm.TableCell(formula: text);
  }

  void _commit(WidgetRef ref, dm.TableModel updated) {
    ref
        .read(workspaceProvider.notifier)
        .updateBlock(blockId, WorksheetBlock.table(updated, id: blockId));
  }

  dm.TableModel _withCell(dm.TableModel t, int r, int c, dm.TableCell cell) {
    final cells = [for (final row in t.cells) [...row]];
    cells[r][c] = cell;
    return dm.TableModel(columns: t.columns, rows: t.rows, cells: cells);
  }

  dm.TableModel _withColumn(dm.TableModel t, int c, dm.TableColumn col) {
    final cols = [...t.columns];
    cols[c] = col;
    return dm.TableModel(columns: cols, rows: t.rows, cells: t.cells);
  }
}
