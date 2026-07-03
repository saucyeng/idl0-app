import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:idl0/providers/workspace_provider.dart';
import 'package:idl0/ui/widgets/chart_action.dart';

/// Private [Intent] subclass used by [Shortcuts] + [Actions] to route
/// keyboard activators from [kDefaultChartBindings] to [dispatchChartAction].
class _ChartActionIntent extends Intent {
  /// The chart action to dispatch when this intent fires.
  final ChartAction action;

  const _ChartActionIntent(this.action);
}

/// Wraps a chart canvas with the v1 right-click / long-press context menu and
/// keyboard shortcuts sourced from [kDefaultChartBindings]. (Mouse-wheel
/// zoom/pan lives in the chart itself — [TimeSeriesChart] — so a single notch
/// produces a single action.)
///
/// Builds a cascading [MenuAnchor]: Cursor / Zoom / Pan collapse into hover-out
/// [SubmenuButton]s, with Reset View, Copy Cursor Values and Properties... at
/// the top level, dispatched through [dispatchChartAction]. v2 placeholders
/// (Maximise, Active Channel, Display, Data Offset, Export Data..., Print...,
/// Cut/Copy/Paste/Delete) are tucked under a disabled "More" submenu so users
/// learn the menu shape once.
///
/// Focus is grabbed on mouse-enter and pointer-down so shortcuts only fire
/// when the user is actively on the chart, preserving arrow-key page scroll
/// elsewhere in the worksheet.
class ChartContextMenu extends ConsumerStatefulWidget {
  /// Stable UUID of the worksheet — used by the dispatcher to route
  /// cursor and X-range writes to the right [cursorProvider] /
  /// `worksheetRanges`.
  final String worksheetId;

  /// Index of this chart's slot in the active worksheet — used by the
  /// dispatcher for vertical zoom and Properties.
  final int slotIndex;

  /// Full data extent of the worksheet's longest channel, in seconds.
  /// Used to clamp pan/zoom at boundaries.
  final (double, double) fullDataRange;

  /// Currently rendered Y range of the wrapped chart. Required for
  /// vertical zoom on slots in [YScaleMode.auto] — the chart is the only
  /// authority for the auto-fit values. Pass null for charts whose Y
  /// axis is fixed (lap progression).
  final (double, double)? currentYRange;

  /// Converts a pointer's local-x in this widget's coordinate system to
  /// data-space seconds. The chart supplies this so the wrapper can set
  /// cursor A/B at the exact press location.
  final double Function(double localDx) pixelToTimeSecs;

  /// Converts a pointer's local-y to data-space Y value, used by Zoom
  /// Window (Task 11). Optional in this task.
  final double Function(double localDy)? pixelToYValue;

  /// Optional: opens the chart properties dialog. Null hides the
  /// "Properties..." menu item (lap-table / lap-progression slots).
  final VoidCallback? onOpenProperties;

  /// Optional: copies cursor values to the clipboard. Null hides the
  /// "Copy Cursor Values" menu item.
  final VoidCallback? onCopyCursorValues;

  /// Optional: removes this chart slot from the worksheet (after a
  /// confirmation dialog). Null hides the "Remove chart" menu item —
  /// used for pinned Session-Sheet slots which cannot be deleted.
  final VoidCallback? onRemoveChart;

  /// Whether this chart's X axis is the worksheet-shared time axis (the
  /// `worksheetRanges` provider). When true (default), the menu shows
  /// horizontal/vertical Zoom and Pan items, and a primary (left) tap
  /// inside the chart pins cursor A at the tap location via
  /// [pixelToTimeSecs]. When false, those items are hidden and the tap
  /// is a no-op (other than focus + position tracking) because the
  /// dispatcher's writes to `worksheetRanges` / `cursorProvider` have
  /// no visible effect on the chart (e.g. lap-progression's X is lap
  /// number, FFT's X is Hz). The Cursor / Reset View / Properties
  /// items still render in the right-click menu.
  final bool xAxisIsWorksheetTime;

  /// Optional Y-scale override. When supplied, vertical zoom/pan, the
  /// zoom-window rectangle, and Reset View read [manualYRange] as the basis
  /// and write through this callback instead of the worksheet slot — used by
  /// the math-editor preview, which is not a worksheet slot. When null, the
  /// wrapper reads and writes the worksheet slot at [slotIndex] (the default
  /// for every chart in the Analyze worksheet).
  final ApplyYScale? onApplyYScale;

  /// The wrapped chart's current manual Y override (yMin, yMax), or null when
  /// it is in auto Y mode. Only consulted when [onApplyYScale] is supplied
  /// (preview mode); in slot mode the manual range is read from the slot.
  final (double, double)? manualYRange;

  /// The chart canvas to wrap.
  final Widget child;

  /// Creates a [ChartContextMenu].
  const ChartContextMenu({
    super.key,
    required this.worksheetId,
    required this.slotIndex,
    required this.fullDataRange,
    required this.pixelToTimeSecs,
    required this.child,
    this.currentYRange,
    this.pixelToYValue,
    this.onOpenProperties,
    this.onCopyCursorValues,
    this.onRemoveChart,
    this.onApplyYScale,
    this.manualYRange,
    this.xAxisIsWorksheetTime = true,
  });

  @override
  ConsumerState<ChartContextMenu> createState() => _ChartContextMenuState();
}

class _ChartContextMenuState extends ConsumerState<ChartContextMenu> {
  /// Focus node with [FocusNode.skipTraversal] so Tab navigation ignores
  /// chart slots, but explicit `requestFocus()` still works.
  final FocusNode _focusNode = FocusNode(skipTraversal: true);

  /// Drives the cascading [MenuAnchor] — opened programmatically at the
  /// right-click / long-press position so Cursor / Zoom / Pan collapse into
  /// hover-out submenus instead of one long flat list.
  final MenuController _menuController = MenuController();

  /// Last known pointer position in local chart coordinates. Used by the
  /// keyboard shortcut handler so cursor-placement actions have a location.
  Offset? _lastPointerLocal;

  /// Local position where the current drag gesture began, in widget
  /// coordinates. Non-null while a secondary-button or long-press drag
  /// is in progress.
  Offset? _dragStartLocal;

  /// Current pointer position during an active drag, in widget coordinates.
  /// Updated on every pointer-move event; drives the zoom-rect painter.
  Offset? _dragCurrentLocal;

  /// True once the pointer has moved more than 8 px from [_dragStartLocal],
  /// distinguishing a deliberate Zoom Window drag from an incidental wiggle
  /// before right-click or long-press ends.
  bool _isDragging = false;

  /// True when the current drag was initiated by a secondary-button
  /// [PointerDownEvent] via [_onPointerDown]. Used by [_onPointerUp] to
  /// avoid clearing long-press drag state (which is set by
  /// [LongPressGestureRecognizer] and finalised by [onLongPressEnd]).
  bool _secondaryDragActive = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// Builds the [Shortcuts] map from [kDefaultChartBindings] so there is a
  /// single source of truth — no duplicated literal activators here.
  Map<ShortcutActivator, Intent> _buildShortcutMap() {
    final result = <ShortcutActivator, Intent>{};
    kDefaultChartBindings.forEach((action, activators) {
      for (final activator in activators) {
        result[activator] = _ChartActionIntent(action);
      }
    });
    return result;
  }

  /// The wrapped chart's current manual Y override (yMin, yMax), or null in
  /// auto mode. From [widget.manualYRange] in preview mode, else the worksheet
  /// slot at [widget.slotIndex].
  (double, double)? _manualYRange() => widget.onApplyYScale != null
      ? widget.manualYRange
      : slotManualYRange(ref.read, widget.slotIndex);

  /// The Y-scale writer: the [widget.onApplyYScale] override in preview mode,
  /// otherwise the shared slot writer for [widget.slotIndex].
  ApplyYScale _applyYScale() =>
      widget.onApplyYScale ?? slotYScaleWriter(ref.read, widget.slotIndex);

  /// Dispatches [action] using the best-available pointer location.
  ///
  /// [local] is the local-coordinate offset to use for cursor-placement
  /// actions; when null (keyboard-only invocation) [cursorTimeSecs] is
  /// also null and cursor-placement actions are no-ops.
  void _runAction(ChartAction action, Offset? local) {
    final t = local != null ? widget.pixelToTimeSecs(local.dx) : null;
    dispatchChartAction(
      action,
      ChartActionContext(
        worksheetId: widget.worksheetId,
        read: ref.read,
        cursorTimeSecs: t,
        fullDataRange: widget.fullDataRange,
        currentYRange: widget.currentYRange,
        manualYRange: _manualYRange(),
        onApplyYScale: _applyYScale(),
        onOpenProperties: widget.onOpenProperties,
        onCopyCursorValues: widget.onCopyCursorValues,
      ),
    );
  }

  /// Opens the cascading context menu at [localPos] (chart-local coordinates,
  /// which the wrapping [MenuAnchor] uses as the anchor offset). Records the
  /// position so cursor-placement items land where the menu was opened.
  void _openMenu(Offset localPos) {
    _lastPointerLocal = localPos;
    _focusNode.requestFocus();
    _menuController.open(position: localPos);
  }

  /// Applies the zoom-window rectangle defined by local-coordinate corners
  /// [a] and [b] to the worksheet X range and (when [widget.pixelToYValue]
  /// is non-null) to the slot's manual Y range.
  ///
  /// X range is written via [WorkspaceNotifier.setXAxisRange]; the call is a
  /// no-op if the mapped X span is effectively zero (< 1e-9 s).
  /// Y range is written through [_applyYScale] (slot or preview-local) with
  /// [YScaleMode.manual]; the lower pixel-Y (higher data-Y) becomes [yMax]
  /// because screen-Y increases downward.
  void _applyZoomWindow(Offset a, Offset b) {
    final xa = widget.pixelToTimeSecs(a.dx);
    final xb = widget.pixelToTimeSecs(b.dx);
    final (xStart, xEnd) = xa < xb ? (xa, xb) : (xb, xa);
    if ((xEnd - xStart).abs() < 1e-9) return;
    ref.read(workspaceProvider.notifier).setXAxisRange(
          widget.worksheetId,
          xStart,
          xEnd,
        );
    final pyToY = widget.pixelToYValue;
    if (pyToY != null) {
      final ya = pyToY(a.dy);
      final yb = pyToY(b.dy);
      final (yMin, yMax) = ya < yb ? (ya, yb) : (yb, ya);
      _applyYScale()(mode: YScaleMode.manual, yMin: yMin, yMax: yMax);
    }
  }

  /// Handles raw pointer-down events for secondary-button drag tracking.
  ///
  /// Called before the gesture arena so secondary-button presses are captured
  /// unconditionally — [TapGestureRecognizer] would otherwise win the arena
  /// and suppress the move/up stream needed for Zoom Window.
  void _onPointerDown(PointerDownEvent e) {
    if (e.buttons != kSecondaryButton) return;
    _focusNode.requestFocus();
    setState(() {
      _dragStartLocal = e.localPosition;
      _dragCurrentLocal = e.localPosition;
      _isDragging = false;
      _secondaryDragActive = true;
    });
  }

  /// Tracks pointer movement for the active secondary-button drag.
  void _onPointerMove(PointerMoveEvent e) {
    if (!_secondaryDragActive) return;
    if (_dragStartLocal == null) return;
    setState(() {
      _dragCurrentLocal = e.localPosition;
      final delta = e.localPosition - _dragStartLocal!;
      if (delta.distance > 8 && !_isDragging) {
        _isDragging = true;
      }
    });
  }

  /// Finalises the secondary-button gesture on pointer-up.
  ///
  /// Only acts when [_secondaryDragActive] is true, which is only set by
  /// [_onPointerDown] for [kSecondaryButton] events. This prevents
  /// accidentally clearing long-press drag state (set by
  /// [LongPressGestureRecognizer]) before [onLongPressEnd] fires.
  ///
  /// If the pointer moved more than 8 px ([_isDragging] == true), applies
  /// the zoom window. Otherwise the menu is opened by [TapGestureRecognizer]'s
  /// [onSecondaryTapUp] callback.
  void _onPointerUp(PointerUpEvent e) {
    if (!_secondaryDragActive) return;
    if (_dragStartLocal == null) return;
    if (_isDragging) {
      _applyZoomWindow(_dragStartLocal!, _dragCurrentLocal!);
      // Zoom was applied — clear _secondaryDragActive so onSecondaryTapUp
      // skips opening the context menu.
      setState(() {
        _dragStartLocal = null;
        _dragCurrentLocal = null;
        _isDragging = false;
        _secondaryDragActive = false;
      });
    } else {
      // Small drag / plain click — leave _secondaryDragActive = true so
      // onSecondaryTapUp (which fires next) knows to open the context menu,
      // then clear the remaining drag state.
      setState(() {
        _dragStartLocal = null;
        _dragCurrentLocal = null;
        _isDragging = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => MenuAnchor(
        controller: _menuController,
        menuChildren: _buildMenuChildren(),
        builder: (context, _, __) => Shortcuts(
          shortcuts: _buildShortcutMap(),
          child: Actions(
            actions: <Type, Action<Intent>>{
              _ChartActionIntent: CallbackAction<_ChartActionIntent>(
                onInvoke: (intent) {
                  _runAction(intent.action, _lastPointerLocal);
                  return null;
                },
              ),
            },
            child: MouseRegion(
              onEnter: (_) => _focusNode.requestFocus(),
              child: Focus(
                focusNode: _focusNode,
                child: Listener(
                  onPointerDown: _onPointerDown,
                  onPointerMove: _onPointerMove,
                  onPointerUp: _onPointerUp,
                  child: RawGestureDetector(
                    behavior: HitTestBehavior.opaque,
                    gestures: <Type, GestureRecognizerFactory>{
                      LongPressGestureRecognizer:
                          GestureRecognizerFactoryWithHandlers<
                              LongPressGestureRecognizer>(
                        () => LongPressGestureRecognizer(),
                        (instance) => instance
                          ..onLongPressStart = (d) {
                            _focusNode.requestFocus();
                            _lastPointerLocal = d.localPosition;
                            setState(() {
                              _dragStartLocal = d.localPosition;
                              _dragCurrentLocal = d.localPosition;
                              _isDragging = false;
                            });
                          }
                          ..onLongPressMoveUpdate = (d) {
                            setState(() {
                              _dragCurrentLocal = d.localPosition;
                              final delta = d.localPosition - _dragStartLocal!;
                              if (delta.distance > 8 && !_isDragging) {
                                _isDragging = true;
                              }
                            });
                          }
                          ..onLongPressEnd = (d) {
                            if (_isDragging) {
                              _applyZoomWindow(
                                _dragStartLocal!,
                                _dragCurrentLocal!,
                              );
                            } else {
                              _openMenu(_dragStartLocal!);
                            }
                            setState(() {
                              _dragStartLocal = null;
                              _dragCurrentLocal = null;
                              _isDragging = false;
                              _secondaryDragActive = false;
                            });
                          },
                      ),
                      TapGestureRecognizer:
                          GestureRecognizerFactoryWithHandlers<
                              TapGestureRecognizer>(
                        () => TapGestureRecognizer(),
                        (instance) => instance
                          ..onTapDown = (d) {
                            _lastPointerLocal = d.localPosition;
                            _focusNode.requestFocus();
                            // Primary-tap pins cursor A at the tap location
                            // for charts whose X axis is worksheet time.
                            // Lap-progression / FFT skip this — their X axis
                            // is not in cursor units. The inner widget's own
                            // GestureDetector loses the gesture-arena race
                            // against this recognizer, so the wrapper is the
                            // only place tap-to-pin can fire reliably.
                            if (widget.xAxisIsWorksheetTime) {
                              _runAction(
                                ChartAction.setCursorAHere,
                                d.localPosition,
                              );
                            }
                          }
                          ..onSecondaryTapDown = (d) {
                            // Drag state is already set by _onPointerDown via
                            // Listener — just ensure focus is active.
                            _focusNode.requestFocus();
                          }
                          ..onSecondaryTapUp = (d) {
                            // _secondaryDragActive is true when _onPointerUp
                            // decided this was a plain click (no drag). It is
                            // false when _onPointerUp already applied a zoom
                            // window, in which case we skip the menu.
                            if (_secondaryDragActive) {
                              _openMenu(d.localPosition);
                              setState(() {
                                _secondaryDragActive = false;
                              });
                            }
                          },
                      ),
                    },
                    child: Stack(
                      children: [
                        widget.child,
                        if (_isDragging &&
                            _dragStartLocal != null &&
                            _dragCurrentLocal != null)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: _ZoomRectPainter(
                                  start: _dragStartLocal!,
                                  end: _dragCurrentLocal!,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  /// Builds the cascading menu: Cursor / Zoom / Pan collapse into hover-out
  /// [SubmenuButton]s, with the always-relevant Reset / Copy / Properties /
  /// Remove as top-level [MenuItemButton]s and the disabled v2 placeholders
  /// tucked under a "More" submenu. Zoom and Pan only appear when this chart's
  /// X axis is worksheet time (see [ChartContextMenu.xAxisIsWorksheetTime]).
  List<Widget> _buildMenuChildren() {
    return [
      SubmenuButton(
        menuChildren: [
          _leaf('Place active here', ChartAction.setCursorAHere),
          _leaf('Drop datum here', ChartAction.setCursorBHere),
          _leaf(
            'Swap active and datum',
            ChartAction.swapCursors,
            shortcut: 'X',
          ),
          _leaf('Clear active', ChartAction.clearCursorA),
          _leaf('Clear datum', ChartAction.clearCursorB),
          _leaf('Clear both', ChartAction.clearBothCursors),
        ],
        child: const Text('Cursor'),
      ),
      if (widget.xAxisIsWorksheetTime) ...[
        SubmenuButton(
          menuChildren: [
            _leaf('Zoom Window', ChartAction.zoomWindow),
            _leaf('Zoom to Cursors', ChartAction.zoomToCursors, shortcut: 'Z'),
            _leaf('Horizontal Zoom In', ChartAction.hZoomIn, shortcut: 'Alt+→'),
            _leaf(
              'Horizontal Zoom Out',
              ChartAction.hZoomOut,
              shortcut: 'Alt+←',
            ),
            _leaf(
              'Horizontal Zoom Full Out',
              ChartAction.hZoomFullOut,
              shortcut: 'F2',
            ),
            _leaf('Vertical Zoom In', ChartAction.vZoomIn, shortcut: 'Alt+↑'),
            _leaf('Vertical Zoom Out', ChartAction.vZoomOut, shortcut: 'Alt+↓'),
            _leaf(
              'Vertical Zoom Full Out',
              ChartAction.vZoomFullOut,
              shortcut: 'Alt+F2',
            ),
          ],
          child: const Text('Zoom'),
        ),
        SubmenuButton(
          menuChildren: [
            _leaf('Pan Left', ChartAction.panLeft, shortcut: 'Shift+←'),
            _leaf('Pan Right', ChartAction.panRight, shortcut: 'Shift+→'),
            _leaf('Pan Up', ChartAction.panUp, shortcut: 'Shift+↑'),
            _leaf('Pan Down', ChartAction.panDown, shortcut: 'Shift+↓'),
          ],
          child: const Text('Pan'),
        ),
      ],
      _leaf('Reset View', ChartAction.resetView),
      if (widget.onCopyCursorValues != null)
        _leaf(
          'Copy Cursor Values',
          ChartAction.copyCursorValues,
          shortcut: 'Ctrl+Shift+C',
        ),
      if (widget.onOpenProperties != null)
        _leaf('Properties...', ChartAction.openProperties, shortcut: 'F5'),
      if (widget.onRemoveChart != null)
        MenuItemButton(
          onPressed: () => widget.onRemoveChart?.call(),
          child: const Text('Remove chart'),
        ),
      const SubmenuButton(
        menuChildren: [
          _DisabledLeaf('Maximise', 'F6'),
          _DisabledLeaf('Active Channel', null),
          _DisabledLeaf('Display', null),
          _DisabledLeaf('Data Offset', null),
          _DisabledLeaf('Export Data...', null),
          _DisabledLeaf('Print...', null),
          _DisabledLeaf('Cut / Copy / Paste / Delete', null),
        ],
        child: Text('More'),
      ),
    ];
  }

  /// A leaf menu item that dispatches [action] at the menu-open location and
  /// shows an optional [shortcut] hint on the trailing edge.
  Widget _leaf(String label, ChartAction action, {String? shortcut}) =>
      MenuItemButton(
        onPressed: () => _runAction(action, _lastPointerLocal),
        trailingIcon: shortcut == null ? null : _ShortcutHint(shortcut),
        child: Text(label),
      );
}

/// Trailing keyboard-shortcut hint shown on a [MenuItemButton].
class _ShortcutHint extends StatelessWidget {
  final String label;

  const _ShortcutHint(this.label);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 24),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      );
}

/// A greyed-out v2 placeholder menu item (no action) with an optional
/// shortcut hint. Rendered disabled so users learn the menu shape once.
class _DisabledLeaf extends StatelessWidget {
  final String label;
  final String? shortcut;

  const _DisabledLeaf(this.label, this.shortcut);

  @override
  Widget build(BuildContext context) => MenuItemButton(
        onPressed: null,
        trailingIcon: shortcut == null ? null : _ShortcutHint(shortcut!),
        child: Text(label),
      );
}

/// Paints the translucent zoom-window selection rectangle during a
/// right-click-drag or long-press-drag gesture.
///
/// [start] and [end] are both in the widget's local coordinate system.
/// The fill uses [color] at 15 % opacity; the stroke is solid at 1.5 px.
/// Pointer events are suppressed by the [IgnorePointer] wrapper in the
/// build tree — this painter is purely decorative.
class _ZoomRectPainter extends CustomPainter {
  /// Corner where the drag began, in local widget coordinates.
  final Offset start;

  /// Current pointer position, in local widget coordinates.
  final Offset end;

  /// Theme primary colour used for both fill (15 % alpha) and stroke.
  final Color color;

  /// Creates a [_ZoomRectPainter].
  _ZoomRectPainter({
    required this.start,
    required this.end,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromPoints(start, end);
    final fill = Paint()
      ..color = color.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(rect, fill);
    canvas.drawRect(rect, stroke);
  }

  @override
  bool shouldRepaint(covariant _ZoomRectPainter oldDelegate) =>
      oldDelegate.start != start || oldDelegate.end != end;
}
