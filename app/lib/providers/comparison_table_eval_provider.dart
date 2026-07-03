import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:idl0/data/table_model.dart' as dm;
import 'package:idl0/providers/channel_provider.dart'
    show sessionHandleProvider;
import 'package:idl0/providers/comparison_provider.dart';
import 'package:idl0/src/rust/lib.dart' show SessionHandle;
import 'package:idl0/src/rust/session.dart' show evaluateTableMulti;
import 'package:idl0/src/rust/table.dart' as rust;

/// Evaluates the live N-lap comparison table: one row per [ComparisonLap]
/// (Main first), each row bound to its lap's session handle and recording-time
/// window, with `baselineRow = 0` so `main({col[]})` references the Main lap.
/// Columns come from the block; rows are derived from [comparisonLapsProvider].
///
/// The family key is the column list held on the comparison block; it is stable
/// across rebuilds (changes only on a column edit), so the provider re-evaluates
/// when the selection or the columns change. The heavy work (per-cell evaluation
/// across sessions) stays in `idl-rs`; only the small `CellResult` grid crosses
/// FFI.
final comparisonTableEvalProvider = FutureProvider.autoDispose
    .family<List<List<rust.CellResult>>, List<dm.TableColumn>>(
        (ref, columns) async {
  final set = ref.watch(comparisonLapsProvider);
  if (set.laps.isEmpty) return const [];

  // Distinct sessions → handle pool; each row → its handle index + window.
  final sessionIds = <String>[];
  final handles = <SessionHandle>[];
  final rowHandleIdx = <int>[];
  final windows = <(double, double)>[];
  final hasWindow = <bool>[];
  final rows = <rust.Row>[];

  for (final cl in set.laps) {
    final sid = cl.key.sessionId;
    var idx = sessionIds.indexOf(sid);
    if (idx < 0) {
      idx = sessionIds.length;
      sessionIds.add(sid);
      handles.add(await ref.watch(sessionHandleProvider(sid).future));
    }
    rowHandleIdx.add(idx);
    windows.add((cl.lap.startTimeSecs, cl.lap.endTimeSecs));
    hasWindow.add(true);
    rows.add(
      rust.Row(
        id: '${cl.key.sessionId}#${cl.key.lapNumber}',
        context: rust.RowContext(sessionId: sid, lapIndex: cl.lap.lapNumber - 1),
      ),
    );
  }

  final table = rust.TableModel(
    columns: [
      for (final c in columns)
        rust.Column(id: c.id, name: c.name, template: c.template),
    ],
    rows: rows,
    cells: [
      for (final _ in rows) [for (final _ in columns) const rust.Cell()],
    ],
  );

  return evaluateTableMulti(
    handles: handles,
    rowHandleIdx: rowHandleIdx,
    table: table,
    rowWindows: windows,
    rowHasWindow: hasWindow,
    baselineRow: 0,
  );
});
