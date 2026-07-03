import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/lap_context.dart';
import '../data/math_channel.dart';
import '../data/math_eval_failure_mapper.dart';
import '../data/session_model.dart';
import '../data/workbook.dart';
import '../src/rust/lib.dart' as rust;
import '../src/rust/math.dart' as rust;
import '../src/rust/session.dart' as rust;
import '../ui/tabs/analyze/chart_tile_cache.dart';
import 'channel_provider.dart';
import 'lap_provider.dart';
import 'session_workspace_provider.dart';
import 'suspension_estimator_provider.dart';
import 'workbook_provider.dart';
import 'workspace_provider.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

// Sentinel for nullable copyWith parameters — distinguishes "not provided"
// from explicit null.
class _Unset {
  const _Unset();
}

const _unset = _Unset();

/// Immutable state for [mathChannelProvider].
class MathChannelState {
  /// All math channels — tutorial templates seeded on first launch plus any
  /// user-created channels, all backed by the same SQLite store. Mutations
  /// flow through [MathChannelNotifier.addChannel] /
  /// [MathChannelNotifier.updateChannel] / [MathChannelNotifier.deleteChannel].
  final List<MathChannel> channels;

  /// UUID of the channel currently open in the expression editor.
  ///
  /// Null when no channel is selected.
  final String? activeChannelId;

  /// Validation error for the currently edited expression.
  ///
  /// Null when the expression is valid or validation has not yet run.
  final String? validationError;

  /// User-added named constants available in expressions.
  final List<MathConstant> constants;

  /// Per-name recompute generation for math channels. Bumped on edit / rename /
  /// delete over the dependent closure; consumed by the Analyze lap-pair path as
  /// a family-key trigger so a slice of an edited channel re-cuts from fresh
  /// data. A recompute trigger only — never part of any storage key, so no stale
  /// entry is orphaned. A name absent from the map is generation 0.
  final Map<String, int> generations;

  /// Creates a [MathChannelState].
  const MathChannelState({
    this.channels = const [],
    this.activeChannelId,
    this.validationError,
    this.constants = const [],
    this.generations = const {},
  });

  /// Returns a copy with the given fields replaced.
  ///
  /// Pass `activeChannelId: null` or `validationError: null` to explicitly
  /// clear those nullable fields.
  MathChannelState copyWith({
    List<MathChannel>? channels,
    Object? activeChannelId = _unset,
    Object? validationError = _unset,
    List<MathConstant>? constants,
    Map<String, int>? generations,
  }) =>
      MathChannelState(
        channels: channels ?? this.channels,
        activeChannelId: identical(activeChannelId, _unset)
            ? this.activeChannelId
            : activeChannelId as String?,
        validationError: identical(validationError, _unset)
            ? this.validationError
            : validationError as String?,
        constants: constants ?? this.constants,
        generations: generations ?? this.generations,
      );
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

/// Editor controller over the **active workbook's** math channels and
/// constants. The workbook (`.idl0wb`) is the single source of truth — there is
/// no separate store. CRUD mutates the active [Workbook] through
/// [workbookProvider]; [build] re-derives state whenever the workbook list or
/// the active-workbook index changes. See §15.4, §25.
class MathChannelNotifier extends Notifier<MathChannelState> {
  /// Transient editor selection, preserved across workbook-driven rebuilds.
  String? _activeChannelId;

  /// Transient validation error for the expression being edited.
  String? _validationError;

  /// Source of truth for [MathChannelState.generations], preserved across
  /// workbook-driven rebuilds (like [_activeChannelId]).
  final Map<String, int> _generations = {};

  // ── Stable collaborators, captured in [build] ───────────────────────────────
  // Every CRUD method here writes through [workbookProvider], which [build]
  // watches — so the write re-dirties this notifier. Any `ref` call *after*
  // that write (before the deferred rebuild runs) trips Riverpod's
  // `_didChangeDependency` assertion. We therefore capture the (stable)
  // collaborators once per build, the only window where `ref` is guaranteed
  // usable, and read them — never `ref` — from the mutation methods. See the
  // regression covered by math_channel_provider_test.dart.
  late ChartTileCache _tileCache;
  late WorkbookNotifier _workbookNotifier;
  late WorkspaceNotifier _workspaceNotifier;

  @override
  MathChannelState build() {
    _tileCache = ref.read(chartTileCacheProvider);
    _workbookNotifier = ref.read(workbookProvider.notifier);
    _workspaceNotifier = ref.read(workspaceProvider.notifier);

    final wbs = ref.watch(workbookProvider).valueOrNull;
    final activeIdx =
        ref.watch(workspaceProvider.select((s) => s.activeWorkbookIndex));

    if (wbs == null ||
        wbs.isEmpty ||
        activeIdx < 0 ||
        activeIdx >= wbs.length) {
      return MathChannelState(
        activeChannelId: _activeChannelId,
        validationError: _validationError,
        generations: Map.unmodifiable(_generations),
      );
    }

    final wb = wbs[activeIdx];
    // Drop the selection if its channel is gone (e.g. workbook switch/delete).
    if (_activeChannelId != null &&
        !wb.mathChannels.any((c) => c.id == _activeChannelId)) {
      _activeChannelId = null;
    }
    return MathChannelState(
      channels: wb.mathChannels,
      constants: wb.constants,
      activeChannelId: _activeChannelId,
      validationError: _validationError,
      generations: Map.unmodifiable(_generations),
    );
  }

  /// Completes immediately — kept for API compatibility with callers/tests that
  /// awaited the old async load. State now derives synchronously from the
  /// active workbook.
  Future<void> get loadComplete async {}

  /// The active [Workbook], or null while the library is still loading/empty.
  ///
  /// Reads the captured collaborators rather than `ref` so it stays valid even
  /// when called right after a workbook write has re-dirtied this notifier
  /// (e.g. back-to-back edits before the rebuild flushes).
  Workbook? get _activeWorkbook {
    final wbs = _workbookNotifier.currentWorkbooks;
    if (wbs.isEmpty) return null;
    final idx = _workspaceNotifier.activeWorkbookIndex;
    if (idx < 0 || idx >= wbs.length) return null;
    return wbs[idx];
  }

  /// Applies [transform] to the active workbook and persists it via
  /// [workbookProvider]. No-op when no active workbook exists yet (the eager
  /// default seed populates it shortly). The resulting workbook emission
  /// re-runs [build], so state reflects the change without a local mutation.
  Future<void> _mutateWorkbook(Workbook Function(Workbook) transform) async {
    final wb = _activeWorkbook;
    if (wb == null) return;
    await _workbookNotifier.updateWorkbook(transform(wb));
  }

  // ---- Channel CRUD --------------------------------------------------------

  /// Appends [channel] to the active workbook's math channels.
  Future<void> addChannel(MathChannel channel) => _mutateWorkbook(
        (wb) => wb.copyWith(mathChannels: [...wb.mathChannels, channel]),
      );

  /// Replaces the channel with the same [MathChannel.id]. No-op if absent.
  ///
  /// For property edits (expression, units, colour, decimals) where the stable
  /// id is unchanged. Renames go through [renameChannel].
  Future<void> updateChannel(MathChannel channel) async {
    await _mutateWorkbook((wb) {
      final i = wb.mathChannels.indexWhere((c) => c.id == channel.id);
      if (i < 0) return wb;
      final list = [...wb.mathChannels]..[i] = channel;
      return wb.copyWith(mathChannels: list);
    });
    // Cached tiles for this channel are now stale (expression/metadata changed)
    // — drop them, and every channel that depends on it, across every session
    // so the next paint decimates fresh. Tiles are keyed by the channel *name*
    // (the engine stores math results under the name; see
    // [mathChannelEvalProvider]), so invalidation must use the name — not the
    // UUID, which never matched and left stale coarse tiles surviving an edit.
    _invalidateTilesForName(channel.name);
  }

  /// Renames the channel with [id] to [newName] and rewrites every *other*
  /// channel's expression that references the old name (`[oldName]` →
  /// `[newName]`), so dependent expressions don't break — IDE-style "rename
  /// symbol". Charts reference channels by stable [MathChannel.id], so chart
  /// membership is unaffected. No-op when [id] is unknown, [newName] is empty,
  /// or the name is unchanged.
  ///
  /// The old name is read from the workbook (not the caller), so this is
  /// idempotent and race-free: committing the same rename twice is a no-op.
  Future<void> renameChannel(String id, String newName) async {
    String? renamedFrom;
    await _mutateWorkbook((wb) {
      final i = wb.mathChannels.indexWhere((c) => c.id == id);
      if (i < 0) return wb;
      final oldName = wb.mathChannels[i].name;
      if (newName.isEmpty || newName == oldName) return wb;
      renamedFrom = oldName;
      final oldRef = '[$oldName]';
      final newRef = '[$newName]';
      final list = [
        for (final c in wb.mathChannels)
          if (c.id == id)
            c.copyWith(name: newName)
          else if (c.expression.contains(oldRef))
            c.copyWith(expression: c.expression.replaceAll(oldRef, newRef))
          else
            c,
      ];
      return wb.copyWith(mathChannels: list);
    });
    // The channel is now stored under [newName]; its old-name tiles are
    // orphaned (the chart self-sources by the current name) — drop them.
    // Dependents keep valid tiles: a rename changes the reference token, not
    // the values, so their stored eval is numerically unchanged. No-op when
    // the rename itself was a no-op (empty/unchanged name).
    if (renamedFrom != null) {
      // The channel is now stored under [newName]; its old-name tiles are
      // orphaned (the chart self-sources by the current name) — drop them.
      // A rename changes the reference token, not the values, so dependents'
      // stored eval is numerically unchanged and their tiles stay valid; and
      // the renamed channel's own lap slice re-cuts automatically because its
      // family-key channelId changes (oldName → newName). No generation bump.
      _tileCache.invalidateChannelAcrossSessions(renamedFrom!);
    }
  }

  /// Duplicates the channel with [id]: a deep copy with a fresh UUID and a
  /// unique name (`"<name> copy"`, then `"<name> copy 2"`, … on collision).
  /// Appends the copy to the active workbook, makes it active, and returns its
  /// new id. Returns null (no-op) when [id] is not found.
  Future<String?> duplicateChannel(String id) async {
    final wb = _activeWorkbook;
    if (wb == null) return null;
    final idx = wb.mathChannels.indexWhere((c) => c.id == id);
    if (idx < 0) return null;
    final src = wb.mathChannels[idx];

    final existing = wb.mathChannels.map((c) => c.name).toSet();
    var name = '${src.name} copy';
    var n = 2;
    while (existing.contains(name)) {
      name = '${src.name} copy $n';
      n++;
    }

    final copy = src.copyWith(id: const Uuid().v4(), name: name);
    await addChannel(copy);
    setActiveChannel(copy.id);
    return copy.id;
  }

  /// Removes the channel with [id] from the active workbook. Clears the active
  /// selection if it matches.
  Future<void> deleteChannel(String id) async {
    if (_activeChannelId == id) _activeChannelId = null;
    // Capture the name before the mutation removes the channel — tiles are
    // keyed by name, and the dependent closure (computed post-mutation, where
    // dependents still carry the now-dangling `[name]` reference) needs it.
    final deletedName = _nameForId(id);
    await _mutateWorkbook(
      (wb) => wb.copyWith(
        mathChannels: wb.mathChannels.where((c) => c.id != id).toList(),
      ),
    );
    // Deleting an upstream channel makes its dependents' stored eval change
    // (their `[name]` reference is now broken), so drop the deleted channel's
    // tiles and every dependent's tiles, all keyed by name.
    if (deletedName != null) _invalidateTilesForName(deletedName);
  }

  /// Sets the active channel for editing. Pass null to deselect. This is
  /// transient UI state, not persisted to the workbook.
  void setActiveChannel(String? id) {
    _activeChannelId = id;
    state = state.copyWith(activeChannelId: id);
  }

  // ---- Tile invalidation ---------------------------------------------------

  /// The name of the math channel with [id] in the active workbook, or null if
  /// absent. Reads the captured notifier (never `ref`) so it stays valid right
  /// after a workbook write.
  String? _nameForId(String id) {
    final channels = _activeWorkbook?.mathChannels;
    if (channels == null) return null;
    final i = channels.indexWhere((c) => c.id == id);
    return i < 0 ? null : channels[i].name;
  }

  /// Drops cached chart tiles for the channel named [name] and every channel
  /// that transitively depends on it (see [mathTileInvalidationNames]), across
  /// all sessions. Reads the post-mutation workbook through the captured
  /// notifier (never `ref`) so it is safe to call right after a workbook write.
  void _invalidateTilesForName(String name) {
    final channels = _activeWorkbook?.mathChannels ?? const <MathChannel>[];
    final closure = mathTileInvalidationNames(channels, name);
    for (final n in closure) {
      _tileCache.invalidateChannelAcrossSessions(n);
    }
    _bumpGenerations(closure);
  }

  /// Bumps the recompute generation for [names] and emits new state, so the
  /// Analyze lap-pair path (which keys lap slices on a source's generation)
  /// re-cuts them from fresh data. Generation is a recompute trigger only —
  /// never part of a storage key — so nothing is orphaned by a bump.
  void _bumpGenerations(Iterable<String> names) {
    for (final n in names) {
      _generations[n] = (_generations[n] ?? 0) + 1;
    }
    state = state.copyWith(generations: Map.unmodifiable(_generations));
  }

  // ---- Validation ----------------------------------------------------------

  /// Validates [expression] against [availableChannels] and updates
  /// [MathChannelState.validationError].
  ///
  /// [availableChannels] should include session channel names and other math
  /// channel names. Pass an empty list to skip channel-reference validation.
  void validate(String expression, List<String> availableChannels) {
    _validationError =
        MathChannelValidator.validate(expression, availableChannels);
    state = state.copyWith(validationError: _validationError);
  }

  // ---- Constants CRUD ------------------------------------------------------

  /// Appends [constant] to the active workbook's constants.
  Future<void> addConstant(MathConstant constant) => _mutateWorkbook(
        (wb) => wb.copyWith(constants: [...wb.constants, constant]),
      );

  /// Removes the constant with [id] from the active workbook.
  Future<void> removeConstant(String id) => _mutateWorkbook(
        (wb) => wb.copyWith(
          constants: wb.constants.where((c) => c.id != id).toList(),
        ),
      );
}

// ---------------------------------------------------------------------------
// Tile-invalidation closure
// ---------------------------------------------------------------------------

/// The math-channel names whose cached chart tiles go stale when the channel
/// named [changedName] changes (expression edit, rename, or delete): the
/// channel itself plus every channel that references it *transitively* via
/// `[name]` syntax.
///
/// Chart tiles are keyed by the channel's **stored name** — the engine stores a
/// math result under [MathChannel.name] (`storeAs`) and the chart decimates it
/// by that name (see [mathChannelEvalProvider] and chart_workspace.dart). So
/// when an upstream channel changes, a downstream dependent's tiles are stale
/// even though the dependent's own expression text is untouched; both must be
/// dropped. Returns names (the tile key) — never UUIDs.
///
/// References are delimited (`[Name]`), so a shorter name is never matched as a
/// substring of a longer one (`[Fork]` does not match `[Fork vel]`). This
/// mirrors the rename rewrite in [MathChannelNotifier.renameChannel].
@visibleForTesting
Set<String> mathTileInvalidationNames(
  List<MathChannel> channels,
  String changedName,
) {
  final affected = <String>{changedName};
  final pending = <String>[changedName];
  while (pending.isNotEmpty) {
    final ref = '[${pending.removeLast()}]';
    for (final c in channels) {
      if (affected.contains(c.name)) continue;
      if (c.expression.contains(ref)) {
        affected.add(c.name);
        pending.add(c.name);
      }
    }
  }
  return affected;
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// Provides [MathChannelState] and the [MathChannelNotifier]. See §17.
final mathChannelProvider =
    NotifierProvider<MathChannelNotifier, MathChannelState>(
  MathChannelNotifier.new,
);

/// Sorted, deduplicated channel names referenceable from a math expression:
/// the union of the selected sessions' channel names
/// ([availableChannelNamesProvider]) and the names of every math channel in
/// the library.
///
/// Single source of truth for the Maths-tab editor's channel scope. Both the
/// Channels insert panel (so a math channel can be inserted as `[Name]`) and
/// expression validation (`validate()`) read this, keeping the picker, the
/// validator, and the evaluator consistent — the evaluator already resolves
/// `[MathChannelName]` cross-references via `_resolveDependencies`. See §25.
final mathExpressionChannelNamesProvider = Provider<List<String>>((ref) {
  final sessionNames = ref.watch(availableChannelNamesProvider);
  final mathNames = ref.watch(mathChannelProvider).channels.map((c) => c.name);
  return ({...sessionNames, ...mathNames}.toList())..sort();
});

/// Evaluates a math channel expression for one session, lazily on demand.
///
/// Key is a Dart record `(channelId, sessionId)` — records implement `==` and
/// `hashCode` structurally so each unique pair gets its own cached result.
///
/// Automatically invalidates when [mathChannelProvider] state changes (e.g.
/// the expression is saved after the 300 ms debounce in [ExpressionEditor]),
/// because the provider uses `ref.watch` on [mathChannelProvider].
///
/// Throws [StateError] if [channelId] is not in [mathChannelProvider].
/// Surfaces [MathChannelEvaluationException] as [AsyncError] on eval failure.
///
/// Evaluation runs in the Rust `idl_rs::math` engine via [rust.evalMath]
/// (Phase 3a). Cross-channel dependencies are resolved Rust-side too (Phase 3b)
/// via [rust.resolveMathDependencies], which evaluates each referenced math
/// channel deps-first and writes it into the retained handle's math store, so
/// the outer evaluation reads it without marshalling samples. Lap-aware /
/// variance functions consume a [rust.MathLapCtxArg] built from the resolved
/// [LapContext]; the overlay session crosses as a second handle.
final mathChannelEvalProvider = FutureProvider.autoDispose.family<
    ({int length, double sampleRateHz, String storedAs}),
    ({String channelId, String sessionId})>((ref, arg) async {
  // Invalidate only when a channel's name or expression actually changes.
  // Watching the whole MathChannelState re-evaluated every math channel on
  // editor churn (active-channel switches, per-keystroke validation).
  ref.watch(
    mathChannelProvider.select(
      (s) => s.channels
          .map((c) => '${c.name}\u0000${c.expression}')
          .join('\u0001'),
    ),
  );
  final channels = ref.read(mathChannelProvider).channels;
  final channel = channels.firstWhere(
    (c) => c.id == arg.channelId,
    orElse: () => throw StateError(
      'Math channel ${arg.channelId} not found in mathChannelProvider',
    ),
  );

  // Suspension-estimator virtual sensors are not expressions — they are produced
  // by the offline geometry-constrained estimator, which runs once per session
  // (suspensionEstimatorProvider, off the UI isolate) and stores all four outputs
  // into the handle's math store. Route them there instead of the expression
  // evaluator, so they auto-evaluate and surface the normal math-channel loading
  // spinner. The stored id == this channel's name (the chart decimates by name).
  if (kSuspensionEstimatorChannels.contains(channel.name)) {
    final meta =
        await ref.watch(suspensionEstimatorProvider(arg.sessionId).future);
    return (
      length: meta.length,
      sampleRateHz: meta.sampleRateHz,
      storedAs: channel.name,
    );
  }

  final handle = await ref.watch(sessionHandleProvider(arg.sessionId).future);

  // Resolve LapContext only when the expression uses a lap-aware function.
  // Avoids loading workspace / laps / overlay-session data otherwise. See §5.
  // Lap/sector recording seconds are carried on the laps themselves
  // (engine-computed), so no channel samples are needed here.
  final lapContext = _kLapAwarePattern.hasMatch(channel.expression)
      ? await _resolveLapContext(ref, targetSessionId: arg.sessionId)
      : null;

  final defs = [
    for (final c in channels)
      rust.MathChannelDefArg(name: c.name, expression: c.expression),
  ];

  // Overlay handle (for variance): the reference session, retained. Resolve
  // referenced math channels into the overlay handle's store FIRST so the top
  // expression's variance_* can read them Rust-side.
  rust.SessionHandle? overlayHandle;
  if (lapContext?.overlayLapKey != null && lapContext!.overlayLaps != null) {
    final oh = await ref.watch(
      sessionHandleProvider(lapContext.overlayLapKey!.sessionId).future,
    );
    overlayHandle = oh;
    // The overlay session's laps act as "main" for the overlay sub-evaluation
    // (current_lap / lap_start_time look up against them); no nested overlay.
    final overlayLapCtx = LapContext(mainLaps: lapContext.overlayLaps!);
    final overlayArg = _buildLapCtxArg(overlayLapCtx, null);
    await rust.resolveMathDependencies(
      handle: oh,
      targetName: channel.name,
      targetExpression: channel.expression,
      defs: defs,
      lapCtx: overlayArg,
    );
    // This path writes Math dependency entries into the overlay handle's store,
    // so reclaim it here too (a deleted/renamed channel's entries would
    // otherwise linger in an overlay session that is never itself rendered).
    await rust.retainDerived(
      handle: oh,
      liveSources: [for (final c in channels) c.name],
    );
  }

  final lapArg = _buildLapCtxArg(lapContext, overlayHandle);

  // Resolve referenced math channels into the main handle's store (Rust-side).
  await rust.resolveMathDependencies(
    handle: handle,
    targetName: channel.name,
    targetExpression: channel.expression,
    defs: defs,
    lapCtx: lapArg,
  );

  try {
    // The engine evaluates AND stores the result under this channel's name,
    // so the chart can decimate it by id like any base channel (§15.3) —
    // `resolve_math_dependencies` only writes *referenced* deps, never the
    // displayed channel itself. Only metadata crosses FFI; the samples stay
    // in the handle's math store.
    final out = await rust.evalMathIntoStore(
      handle: handle,
      expression: channel.expression,
      storeAs: channel.name,
      lapCtx: lapArg,
    );
    // Reclaim derived entries no longer backed by a live channel (a deleted /
    // renamed math channel's output + slices). Declarative: keep what's real.
    // Base-channel slices and current-math slices survive (spec §4).
    await rust.retainDerived(
      handle: handle,
      liveSources: [for (final c in channels) c.name],
    );
    return (
      length: out.length,
      sampleRateHz: out.sampleRateHz,
      storedAs: channel.name,
    );
  } on rust.MathEvalFailure catch (e) {
    throw mapMathEvalFailure(e);
  }
});

final RegExp _kLapAwarePattern = RegExp(
  r'\b(variance_time|variance_dist|current_lap|lap_start_time|lap_start_distance|sector_number)\s*\(',
);

/// Builds the bridge lap-context argument from a resolved [LapContext].
///
/// Lap/sector windows are read directly from the laps' engine-computed
/// recording seconds ([Lap.startTimeSecs] / [Sector.startTimeSecs]); the overlay
/// session crosses as a second handle ([overlayHandle]) carrying its lap window
/// in raw epoch ms (for the Rust variance geometry) plus its recording-second
/// start. Returns an empty context when [ctx] is null.
rust.MathLapCtxArg _buildLapCtxArg(
  LapContext? ctx,
  rust.SessionHandle? overlayHandle,
) {
  if (ctx == null) {
    return rust.MathLapCtxArg(
      mainLapStarts: Float64List(0),
      mainLapEnds: Float64List(0),
      mainSectorStarts: Float64List(0),
      mainSectorEnds: Float64List(0),
      mainLapNumber: null,
      overlay: null,
    );
  }

  final lapStarts = <double>[for (final l in ctx.mainLaps) l.startTimeSecs];
  final lapEnds = <double>[for (final l in ctx.mainLaps) l.endTimeSecs];
  final sectorStarts = <double>[
    for (final l in ctx.mainLaps)
      for (final s in l.sectors) s.startTimeSecs,
  ];
  final sectorEnds = <double>[
    for (final l in ctx.mainLaps)
      for (final s in l.sectors) s.endTimeSecs,
  ];

  rust.MathOverlayArg? overlay;
  if (overlayHandle != null &&
      ctx.overlayLapKey != null &&
      ctx.overlayLaps != null) {
    Lap? lap;
    for (final l in ctx.overlayLaps!) {
      if (l.lapNumber == ctx.overlayLapKey!.lapNumber) {
        lap = l;
        break;
      }
    }
    if (lap != null) {
      overlay = rust.MathOverlayArg(
        handle: overlayHandle,
        lapStartMs: lap.startTimestampMs.toDouble(),
        lapEndMs: lap.endTimestampMs.toDouble(),
        lapStartUniformSec: lap.startTimeSecs,
      );
    }
  }

  return rust.MathLapCtxArg(
    mainLapStarts: Float64List.fromList(lapStarts),
    mainLapEnds: Float64List.fromList(lapEnds),
    mainSectorStarts: Float64List.fromList(sectorStarts),
    mainSectorEnds: Float64List.fromList(sectorEnds),
    mainLapNumber: ctx.mainLapNumber,
    overlay: overlay,
  );
}

/// Resolves a [LapContext] for lap-aware math functions. Reads main/overlay
/// designation from the per-session workspace and loads main laps (and, when
/// the overlay points at a different session, that session's laps). Lap/sector
/// recording seconds already live on the [Lap]s, so no channel samples or
/// session-start lookup are needed here.
///
/// Returns a context with [LapContext.mainLapNumber] null when no main is
/// designated; variance helpers in the evaluator surface a clear error in that
/// case. Doesn't itself throw on missing data — fail gracefully so non-variance
/// functions (e.g. `current_lap` outside any variance call) still work.
Future<LapContext> _resolveLapContext(
  Ref ref, {
  required String targetSessionId,
}) async {
  final mainLaps =
      ref.watch(sessionLapsProvider(targetSessionId)).valueOrNull ??
          const <Lap>[];

  final workspace =
      await ref.watch(sessionWorkspaceProvider(targetSessionId).future);
  final overlayLapKey = workspace.overlayLapKey;

  List<Lap>? overlayLaps;
  if (overlayLapKey != null) {
    overlayLaps = overlayLapKey.sessionId == targetSessionId
        ? mainLaps
        : ref.watch(sessionLapsProvider(overlayLapKey.sessionId)).valueOrNull;
  }

  return LapContext(
    mainLaps: mainLaps,
    mainLapNumber: workspace.mainLapNumber,
    overlayLapKey: overlayLapKey,
    overlayLaps: overlayLaps,
  );
}
