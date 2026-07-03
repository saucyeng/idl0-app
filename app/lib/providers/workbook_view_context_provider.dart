import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'workspace_provider.dart';

/// Runtime binding between the active workbook and the sessions it renders
/// against.
///
/// Workbooks themselves are session-agnostic. The view context names which
/// session is "primary" (the main subject of analysis) and optionally which
/// is "overlay" (a second session to compare against). Stored in memory
/// only; not part of the `.idl0wb` payload.
class WorkbookViewContext {
  /// Session whose data drives every chart in the active workbook. `null`
  /// when nothing is bound — charts render their empty-state placeholder.
  final String? primarySessionId;

  /// Optional comparison session. When non-null, charts that support
  /// compare-rendering draw a second trace from this session.
  final String? overlaySessionId;

  /// Creates a [WorkbookViewContext].
  const WorkbookViewContext({this.primarySessionId, this.overlaySessionId});
}

/// Notifier for [WorkbookViewContext]. Exposes intent-named methods rather
/// than a generic `update` so call sites read clearly at use.
class WorkbookViewContextNotifier extends Notifier<WorkbookViewContext> {
  @override
  WorkbookViewContext build() => const WorkbookViewContext();

  /// Binds [sessionId] as the primary session. Leaves overlay unchanged.
  ///
  /// On a bind transition (A → B): clears every worksheet's X-axis zoom range
  /// and cursor pair so state from the prior session does not bleed onto the
  /// new one. First-bind (null → B) leaves prior values untouched — there is
  /// no prior session to clean up from. Idempotent re-bind (A → A) is a no-op
  /// on view state.
  void setPrimary(String sessionId) {
    final previous = state.primarySessionId;
    state = WorkbookViewContext(
      primarySessionId: sessionId,
      overlaySessionId: state.overlaySessionId,
    );
    if (previous != null && previous != sessionId) {
      // Bind transition (A → B): clear cursor/zoom so they don't leak
      // between sessions. First-bind (null → B) leaves prior values untouched
      // since there are no values "from the prior session" to clear.
      ref.read(workspaceProvider.notifier).clearAllWorksheetViewState();
    }
  }

  /// Clears the primary binding. Leaves overlay unchanged. Charts will
  /// render their empty-state placeholder until a new primary is bound.
  void clearPrimary() {
    state = WorkbookViewContext(overlaySessionId: state.overlaySessionId);
  }

  /// Binds [sessionId] as the overlay (compare) session. Leaves primary
  /// unchanged.
  void setOverlay(String sessionId) {
    state = WorkbookViewContext(
      primarySessionId: state.primarySessionId,
      overlaySessionId: sessionId,
    );
  }

  /// Clears the overlay binding. Leaves primary unchanged.
  void clearOverlay() {
    state = WorkbookViewContext(primarySessionId: state.primarySessionId);
  }
}

/// Riverpod provider exposing the active [WorkbookViewContext].
final workbookViewContextProvider =
    NotifierProvider<WorkbookViewContextNotifier, WorkbookViewContext>(
  WorkbookViewContextNotifier.new,
);
