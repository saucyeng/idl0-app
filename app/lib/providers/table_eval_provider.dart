import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:idl0/data/table_model.dart' as dm;
import 'package:idl0/providers/channel_provider.dart' show sessionHandleProvider;
import 'package:idl0/providers/lap_provider.dart' show sessionLapsProvider;
import 'package:idl0/src/rust/session.dart' show evaluateTable;
import 'package:idl0/src/rust/table.dart' as rust;

/// Key for [tableEvalProvider]: the bound session and the table to evaluate.
/// The [table] instance is held in the worksheet block and only changes on
/// edit, so the family key is stable across rebuilds and re-evaluates exactly
/// when the model changes.
typedef TableEvalKey = ({String sessionId, dm.TableModel table});

/// Evaluates [TableEvalKey.table] against the bound session's handle, resolving
/// each row's lap window from the lap cache, and returns the engine
/// `CellResult`s as `result[r][c]`.
///
/// Each row's `[Channel]` references resolve to its lap window
/// `(startTimeSecs, endTimeSecs)`; a row without a resolvable lap falls back to
/// the full channel. The heavy work (slicing + per-cell evaluation) stays in
/// `idl-rs`; only the small per-cell results cross FFI.
final tableEvalProvider = FutureProvider.autoDispose
    .family<List<List<rust.CellResult>>, TableEvalKey>((ref, k) async {
  final handle = await ref.watch(sessionHandleProvider(k.sessionId).future);

  final windows = <(double, double)>[];
  final hasWindow = <bool>[];
  for (final row in k.table.rows) {
    final ctx = row.context;
    final w = ctx == null ? null : _lapWindowSecs(ref, ctx.sessionId, ctx.lapIndex);
    if (w == null) {
      windows.add((0, 0));
      hasWindow.add(false);
    } else {
      windows.add(w);
      hasWindow.add(true);
    }
  }

  return evaluateTable(
    handle: handle,
    table: _toRust(k.table),
    rowWindows: windows,
    rowHasWindow: hasWindow,
  );
});

/// Resolves lap [lapIndex] (0-based) of [sessionId] to its recording-time
/// window `(startSecs, endSecs)`, or null when laps aren't available yet or the
/// index is out of range. Watches [sessionLapsProvider] so the table
/// re-evaluates once detection completes.
(double, double)? _lapWindowSecs(Ref ref, String sessionId, int lapIndex) {
  final laps = ref.watch(sessionLapsProvider(sessionId)).valueOrNull;
  if (laps == null || lapIndex < 0 || lapIndex >= laps.length) return null;
  final lap = laps[lapIndex];
  return (lap.startTimeSecs, lap.endTimeSecs);
}

/// Maps the Dart table model to the FRB `rust.TableModel` field-for-field (the
/// mirror names match).
rust.TableModel _toRust(dm.TableModel t) => rust.TableModel(
      columns: [
        for (final c in t.columns)
          rust.Column(id: c.id, name: c.name, template: c.template),
      ],
      rows: [
        for (final r in t.rows)
          rust.Row(
            id: r.id,
            context: r.context == null
                ? null
                : rust.RowContext(
                    sessionId: r.context!.sessionId,
                    lapIndex: r.context!.lapIndex,
                  ),
          ),
      ],
      cells: [
        for (final row in t.cells)
          [
            for (final c in row)
              rust.Cell(formula: c.formula, literal: c.literal, name: c.name),
          ],
      ],
    );
