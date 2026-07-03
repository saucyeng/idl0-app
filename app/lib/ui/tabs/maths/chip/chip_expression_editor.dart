import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/math_channel.dart';
import '../../../../providers/math_channel_provider.dart';
import '../../../brand/brand.dart';
import '../../../widgets/grouped_channel_list.dart';
import 'definition_popover.dart';
import 'expression_node.dart';
import 'math_function_catalog.dart';
import 'unit_inference.dart';

/// PROTOTYPE chip-driven math expression editor.
///
/// Builds an expression as a tree of colour-coded chips: drag functions,
/// channels, operators, and values from the palette into argument slots.
/// Functions render with labelled empty slots; the output unit is inferred and
/// shown live (`integrate([accel])` → `m/s`). Hover or tap any chip for an
/// IDE-style definition card. Serialises to the exact text the Rust engine
/// consumes, so it round-trips with the raw-text editor.
///
/// See `math_function_catalog.dart` for the function set and unit rules, and
/// `unit_inference.dart` for the (prototype, Dart-side) dimensional analysis.
class ChipExpressionEditor extends ConsumerStatefulWidget {
  /// UUID of the channel being edited (for the rebuild key in the parent).
  final String activeChannelId;

  /// The channel's current expression text, parsed into chips on entry.
  final String initialExpression;

  /// Channel names available for reference in this session.
  final List<String> availableChannels;

  /// Called with the serialised expression whenever the tree is complete.
  final ValueChanged<String> onExpressionChanged;

  /// Creates a [ChipExpressionEditor].
  const ChipExpressionEditor({
    super.key,
    required this.activeChannelId,
    required this.initialExpression,
    required this.availableChannels,
    required this.onExpressionChanged,
  });

  @override
  ConsumerState<ChipExpressionEditor> createState() =>
      _ChipExpressionEditorState();
}

class _ChipExpressionEditorState extends ConsumerState<ChipExpressionEditor> {
  ExprNode? _root;

  /// True when [initialExpression] was non-empty but couldn't be parsed into
  /// chips — we show a hint to edit it in Text mode instead.
  bool _unparseable = false;

  int _palTab = 0;

  @override
  void initState() {
    super.initState();
    _seedFromText(widget.initialExpression);
  }

  void _seedFromText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      _root = null;
      _unparseable = false;
      return;
    }
    final parsed = parseExpression(trimmed);
    _root = parsed;
    _unparseable = parsed == null;
  }

  // ---- unit resolution ---------------------------------------------------

  /// Resolves a channel's unit: math channels by name first, then the built-in
  /// session channels, else null (unknown).
  String? _channelUnit(String name) {
    final channels = ref.read(mathChannelProvider).channels;
    for (final c in channels) {
      if (c.name == name) return c.units;
    }
    return baseChannelUnit(name);
  }

  InferredUnit? _unitOf(ExprNode node) => inferUnit(node, _channelUnit);

  // ---- mutation ----------------------------------------------------------

  void _treeChanged() {
    setState(() {});
    final root = _root;
    if (root == null) {
      widget.onExpressionChanged('');
      return;
    }
    if (root.isComplete) {
      widget.onExpressionChanged(root.toExpression());
    }
  }

  ExprNode _nodeFromItem(_PaletteItem item) {
    switch (item) {
      case _ChannelItem(:final name):
        return ChannelNode(name);
      case _FunctionItem(:final spec):
        return FunctionNode(spec.name, spec.args.length);
      case _OperatorItem(:final op):
        return op == 'not' ? UnaryNode('not') : BinaryNode(op);
      case _NumberItem(:final value):
        return NumberNode(value);
      case _StringItem(:final value):
        return StringNode(value);
    }
  }

  /// Returns an assign-closure for the first empty slot in [node] (depth-first),
  /// or null if the subtree is fully filled. Powers tap-to-fill.
  void Function(ExprNode?)? _firstEmpty(ExprNode node) {
    switch (node) {
      case final FunctionNode fn:
        for (var i = 0; i < fn.args.length; i++) {
          final a = fn.args[i];
          if (a == null) return (n) => fn.args[i] = n;
          final inner = _firstEmpty(a);
          if (inner != null) return inner;
        }
        return null;
      case final BinaryNode b:
        if (b.left == null) return (n) => b.left = n;
        final il = _firstEmpty(b.left!);
        if (il != null) return il;
        if (b.right == null) return (n) => b.right = n;
        return _firstEmpty(b.right!);
      case final UnaryNode u:
        if (u.operand == null) return (n) => u.operand = n;
        return _firstEmpty(u.operand!);
      default:
        return null;
    }
  }

  /// Tapping a palette item drops it into the first open spot.
  void _tapInsert(_PaletteItem item) {
    final node = _nodeFromItem(item);
    if (_root == null) {
      _root = node;
      _unparseable = false;
      _treeChanged();
      return;
    }
    final assign = _firstEmpty(_root!);
    if (assign != null) {
      assign(node);
      _treeChanged();
    }
  }

  // ---- build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final root = _root;
    final inferred = root != null ? _unitOf(root) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _outputHeader(inferred, root),
        const SizedBox(height: 6),
        _canvas(root),
        const SizedBox(height: 6),
        _statusLine(root),
        const SizedBox(height: 12),
        _palette(),
      ],
    );
  }

  Widget _outputHeader(InferredUnit? inferred, ExprNode? root) {
    final unit = inferred?.unit;
    final warn = inferred?.warning;
    final String unitLabel;
    Color unitColor;
    if (root == null) {
      unitLabel = '—';
      unitColor = brandFgDim;
    } else if (warn != null) {
      unitLabel = '⚠ units';
      unitColor = brandAccent;
    } else if (unit == null) {
      unitLabel = '?';
      unitColor = brandFgDim;
    } else if (unit.isEmpty) {
      unitLabel = 'unitless';
      unitColor = brandFgDim;
    } else {
      unitLabel = unit;
      unitColor = brandGood;
    }

    return Row(
      children: [
        Text(
          'OUTPUT UNIT',
          style: plexMono(
            fontSize: 10,
            color: brandFgDim,
            letterSpacing: brandLabelTracking,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: unitColor.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(brandControlRadiusSoft),
            border: Border.all(color: unitColor.withValues(alpha: 0.8)),
          ),
          child: Text(
            '→ $unitLabel',
            style: plexMono(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: unitColor,
            ),
          ),
        ),
        const Spacer(),
        if (root != null)
          IconBtn(
            icon: Icons.clear_all,
            tooltip: 'Clear all',
            onPressed: () {
              setState(() {
                _root = null;
                _unparseable = false;
              });
              _treeChanged();
            },
          ),
      ],
    );
  }

  Widget _canvas(ExprNode? root) {
    Widget body;
    if (_unparseable) {
      body = Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'This expression is too complex to show as chips. Switch to Text '
          'mode to edit it, or Clear all to rebuild.',
          style: plexSans(fontSize: 12, color: brandFgDim),
        ),
      );
    } else if (root == null) {
      body = _slot(
        null,
        label: 'drop a channel or function',
        assign: (n) {
          setState(() => _root = n);
          _treeChanged();
        },
      );
    } else {
      body = _nodeView(root, (n) {
        setState(() => _root = n);
        _treeChanged();
      });
    }

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: brandSurface2,
        borderRadius: BorderRadius.circular(brandControlRadius),
        border: Border.all(color: brandRule, width: brandHairlineWidth),
      ),
      child: Align(alignment: Alignment.centerLeft, child: body),
    );
  }

  Widget _statusLine(ExprNode? root) {
    if (root == null) {
      return Text(
        'Tap or drag a chip to start.',
        style: plexMono(fontSize: 11, color: brandFgFaint),
      );
    }
    final expr = root.toExpression();
    if (!root.isComplete) {
      return Row(
        children: [
          const Icon(Icons.more_horiz, size: 14, color: brandFgDim),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              'Fill the empty slots to finish.',
              style: plexMono(fontSize: 11, color: brandFgDim),
            ),
          ),
        ],
      );
    }
    final error = MathChannelValidator.validate(expr, widget.availableChannels);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          error == null ? Icons.check_circle_outline : Icons.error_outline,
          size: 14,
          color: error == null ? brandGood : brandAccent,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            error ?? expr,
            style: plexMono(
              fontSize: 11,
              color: error == null ? brandFgDim : brandAccent,
            ),
          ),
        ),
      ],
    );
  }

  // ---- node rendering ----------------------------------------------------

  Widget _slot(
    ExprNode? node, {
    required String label,
    required void Function(ExprNode?) assign,
    ArgKind kind = ArgKind.channel,
    List<String>? choices,
  }) {
    if (node != null) return _nodeView(node, assign, choices: choices);
    return _EmptySlot(
      label: label,
      kind: kind,
      onAccept: (item) {
        assign(_nodeFromItem(item));
      },
      onPick: () => _pickForSlot(kind, choices, assign),
    );
  }

  Widget _nodeView(
    ExprNode node,
    void Function(ExprNode?) assign, {
    List<String>? choices,
  }) {
    switch (node) {
      case ChannelNode(:final name):
        final unit = _channelUnit(name);
        return DefinitionPopover(
          title: '[$name]',
          summary: unit != null && unit.isNotEmpty
              ? 'Channel · unit $unit'
              : 'Channel reference',
          child: _Pill(
            label: '[$name]',
            color: chipChannelColor,
            onClear: () => assign(null),
          ),
        );
      case NumberNode():
        return _Pill(
          label: formatNumber(node.value),
          color: chipNumberColor,
          onTap: () => _editNumber(node),
          onClear: () => assign(null),
        );
      case StringNode():
        return _Pill(
          label: '"${node.value}"',
          color: chipStringColor,
          onTap: () => _editString(node, choices),
          onClear: () => assign(null),
        );
      case FunctionNode():
        return _functionView(node, assign);
      case BinaryNode():
        return _binaryView(node, assign);
      case UnaryNode():
        return _unaryView(node, assign);
    }
  }

  Widget _functionView(FunctionNode fn, void Function(ExprNode?) assign) {
    final spec = fn.spec;
    final color = spec != null ? colorForCategory(spec.category) : brandFgDim;
    final inferred = _unitOf(fn);
    final unitExtra = (inferred?.unit != null && inferred!.unit!.isNotEmpty)
        ? '→ ${inferred.unit}'
        : null;

    final children = <Widget>[
      DefinitionPopover(
        title: spec?.signature ?? '${fn.name}(…)',
        summary: spec?.summary ?? 'Unknown function.',
        docs: spec?.docs,
        extra: unitExtra,
        child: _Pill(
          label: fn.name,
          color: color,
          onClear: () => assign(null),
        ),
      ),
      _punct('('),
    ];
    for (var i = 0; i < fn.args.length; i++) {
      if (i > 0) children.add(_punct(', '));
      final argSpec =
          spec != null && i < spec.args.length ? spec.args[i] : null;
      final idx = i;
      children.add(
        _slot(
          fn.args[i],
          label: argSpec?.label ?? 'arg',
          kind: argSpec?.kind ?? ArgKind.channel,
          choices: argSpec?.choices,
          assign: (n) {
            fn.args[idx] = n;
            _treeChanged();
          },
        ),
      );
    }
    children.add(_punct(')'));

    return Container(
      padding: const EdgeInsets.fromLTRB(4, 3, 4, 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(brandControlRadiusSoft),
        border: Border(
          left: BorderSide(color: color.withValues(alpha: 0.7), width: 2),
        ),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 2,
        runSpacing: 3,
        children: children,
      ),
    );
  }

  Widget _binaryView(BinaryNode bin, void Function(ExprNode?) assign) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: BoxDecoration(
        color: brandControlFill.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(brandControlRadiusSoft),
        border: Border.all(color: brandRule),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 2,
        runSpacing: 3,
        children: [
          _punct('('),
          _slot(
            bin.left,
            label: 'a',
            assign: (n) {
              bin.left = n;
              _treeChanged();
            },
          ),
          _opChip(bin.op, () => assign(null)),
          _slot(
            bin.right,
            label: 'b',
            assign: (n) {
              bin.right = n;
              _treeChanged();
            },
          ),
          _punct(')'),
        ],
      ),
    );
  }

  Widget _unaryView(UnaryNode un, void Function(ExprNode?) assign) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 2,
      children: [
        _opChip(un.op, () => assign(null)),
        _slot(
          un.operand,
          label: 'x',
          assign: (n) {
            un.operand = n;
            _treeChanged();
          },
        ),
      ],
    );
  }

  Widget _opChip(String op, VoidCallback onClear) {
    final spec = kMathOperators.cast<OperatorSpec?>().firstWhere(
          (o) => o?.op == op,
          orElse: () => null,
        );
    return DefinitionPopover(
      title: op,
      summary: spec?.summary ?? 'Operator',
      child: _Pill(label: op, color: chipOperatorColor, onClear: onClear),
    );
  }

  Widget _punct(String s) => Text(
        s,
        style: plexMono(
          fontSize: 15,
          color: brandFgDim,
          fontWeight: FontWeight.w600,
        ),
      );

  // ---- editing dialogs ---------------------------------------------------

  Future<void> _editNumber(NumberNode node) async {
    final ctrl = TextEditingController(text: formatNumber(node.value));
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'VALUE',
          style: plexMono(
            fontSize: 14,
            color: brandFg,
            letterSpacing: brandLabelTracking,
          ),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          style: plexMono(fontSize: 14, color: brandFg),
          onSubmitted: (v) => Navigator.of(ctx).pop(double.tryParse(v)),
        ),
        actions: [
          QuietButton(
            label: 'Cancel',
            onPressed: () => Navigator.of(ctx).pop(),
          ),
          QuietButton(
            label: 'Set',
            filled: true,
            onPressed: () => Navigator.of(ctx).pop(double.tryParse(ctrl.text)),
          ),
        ],
      ),
    );
    if (result != null) {
      node.value = result;
      _treeChanged();
    }
  }

  Future<void> _editString(StringNode node, List<String>? choices) async {
    if (choices == null || choices.isEmpty) return;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(
          'CHOOSE',
          style: plexMono(
            fontSize: 14,
            color: brandFg,
            letterSpacing: brandLabelTracking,
          ),
        ),
        children: [
          for (final c in choices)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(c),
              child: Text(c, style: plexMono(fontSize: 13, color: brandFg)),
            ),
        ],
      ),
    );
    if (result != null) {
      node.value = result;
      _treeChanged();
    }
  }

  /// Empty-slot tap: edit inline for number/string slots, else open the picker.
  Future<void> _pickForSlot(
    ArgKind kind,
    List<String>? choices,
    void Function(ExprNode?) assign,
  ) async {
    if (kind == ArgKind.number) {
      final node = NumberNode(0);
      assign(node);
      await _editNumber(node);
      return;
    }
    if (kind == ArgKind.string) {
      final c = (choices != null && choices.isNotEmpty) ? choices.first : '';
      final node = StringNode(c);
      assign(node);
      await _editString(node, choices);
      return;
    }
    final item = await _showInsertPicker();
    if (item != null) assign(_nodeFromItem(item));
  }

  Future<_PaletteItem?> _showInsertPicker() {
    return showDialog<_PaletteItem>(
      context: context,
      builder: (ctx) =>
          _InsertPickerDialog(availableChannels: widget.availableChannels),
    );
  }

  // ---- palette -----------------------------------------------------------

  Widget _palette() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        BrandSegmented<int>(
          selected: _palTab,
          onChanged: (v) => setState(() => _palTab = v),
          segments: const [
            BrandSegment(value: 0, label: 'Channels'),
            BrandSegment(value: 1, label: 'Functions'),
            BrandSegment(value: 2, label: 'Operators'),
            BrandSegment(value: 3, label: 'Values'),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 196,
          child: Container(
            decoration: const BoxDecoration(
              border: Border.fromBorderSide(
                BorderSide(color: brandRule, width: brandHairlineWidth),
              ),
            ),
            child: IndexedStack(
              index: _palTab,
              sizing: StackFit.expand,
              children: [
                _channelsPalette(),
                _functionsPalette(),
                _operatorsPalette(),
                _valuesPalette(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _channelsPalette() => _ChannelsPalette(
        availableChannels: widget.availableChannels,
        onTap: (name) => _tapInsert(_ChannelItem(name)),
      );

  Widget _functionsPalette() {
    final byCategory = <FnCategory, List<MathFunctionSpec>>{};
    for (final f in kMathFunctions) {
      byCategory.putIfAbsent(f.category, () => []).add(f);
    }
    const labels = {
      FnCategory.signal: 'SIGNAL',
      FnCategory.timeDomain: 'TIME-DOMAIN',
      FnCategory.math: 'MATH & TRIG',
      FnCategory.logic: 'LOGIC · LAP · VARIANCE',
    };
    final items = <Widget>[];
    for (final cat in FnCategory.values) {
      final fns = byCategory[cat];
      if (fns == null) continue;
      items.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Text(
            labels[cat]!,
            style: plexMono(
              fontSize: 10,
              color: colorForCategory(cat),
              letterSpacing: brandLabelTracking,
            ),
          ),
        ),
      );
      items.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final f in fns)
                DefinitionPopover(
                  title: f.signature,
                  summary: f.summary,
                  docs: f.docs,
                  child: _paletteDraggable(
                    _Pill(label: f.name, color: colorForCategory(f.category)),
                    _FunctionItem(f),
                    () => _tapInsert(_FunctionItem(f)),
                  ),
                ),
            ],
          ),
        ),
      );
      items.add(const SizedBox(height: 4));
    }
    return ListView(padding: const EdgeInsets.only(bottom: 8), children: items);
  }

  Widget _operatorsPalette() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final o in kMathOperators)
            DefinitionPopover(
              title: o.op,
              summary: o.summary,
              child: _paletteDraggable(
                _Pill(label: o.op, color: chipOperatorColor),
                _OperatorItem(o.op),
                () => _tapInsert(_OperatorItem(o.op)),
              ),
            ),
          DefinitionPopover(
            title: 'not',
            summary: 'Logical NOT of a truthy channel.',
            child: _paletteDraggable(
              const _Pill(label: 'not', color: chipOperatorColor),
              const _OperatorItem('not'),
              () => _tapInsert(const _OperatorItem('not')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _valuesPalette() {
    final constants = ref.watch(mathChannelProvider).constants;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'NUMBER',
            style: plexMono(
              fontSize: 10,
              color: chipNumberColor,
              letterSpacing: brandLabelTracking,
            ),
          ),
          const SizedBox(height: 6),
          _paletteDraggable(
            const _Pill(label: '123', color: chipNumberColor),
            const _NumberItem(0),
            () => _tapInsert(const _NumberItem(0)),
          ),
          if (constants.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'CONSTANTS',
              style: plexMono(
                fontSize: 10,
                color: chipNumberColor,
                letterSpacing: brandLabelTracking,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final c in constants)
                  DefinitionPopover(
                    title: c.name,
                    summary: 'Constant = ${formatNumber(c.value)}',
                    child: _paletteDraggable(
                      _Pill(label: c.name, color: chipNumberColor),
                      _NumberItem(c.value),
                      () => _tapInsert(_NumberItem(c.value)),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Wraps [pill] as a [Draggable] payload plus tap-to-insert.
  Widget _paletteDraggable(Widget pill, _PaletteItem item, VoidCallback onTap) {
    return Draggable<_PaletteItem>(
      data: item,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: Transform.translate(
          offset: const Offset(-20, -16),
          child: pill,
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: pill),
      child: GestureDetector(onTap: onTap, child: pill),
    );
  }
}

// ---------------------------------------------------------------------------
// Palette item payloads
// ---------------------------------------------------------------------------

sealed class _PaletteItem {
  const _PaletteItem();
}

class _ChannelItem extends _PaletteItem {
  final String name;
  const _ChannelItem(this.name);
}

class _FunctionItem extends _PaletteItem {
  final MathFunctionSpec spec;
  const _FunctionItem(this.spec);
}

class _OperatorItem extends _PaletteItem {
  final String op;
  const _OperatorItem(this.op);
}

class _NumberItem extends _PaletteItem {
  final double value;
  const _NumberItem(this.value);
}

class _StringItem extends _PaletteItem {
  final String value;
  const _StringItem(this.value);
}

// ---------------------------------------------------------------------------
// Pill — the chip visual
// ---------------------------------------------------------------------------

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final VoidCallback? onClear;

  const _Pill({
    required this.label,
    required this.color,
    this.onTap,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(brandControlRadiusSoft);
    return Material(
      color: color.withValues(alpha: 0.18),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: color.withValues(alpha: 0.9)),
        borderRadius: radius,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: plexMono(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: brandFg,
                ),
              ),
              if (onClear != null) ...[
                const SizedBox(width: 5),
                GestureDetector(
                  onTap: onClear,
                  child: Icon(
                    Icons.close,
                    size: 13,
                    color: color.withValues(alpha: 0.95),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty slot — a drop target
// ---------------------------------------------------------------------------

class _EmptySlot extends StatelessWidget {
  final String label;
  final ArgKind kind;
  final void Function(_PaletteItem) onAccept;
  final VoidCallback onPick;

  const _EmptySlot({
    required this.label,
    required this.kind,
    required this.onAccept,
    required this.onPick,
  });

  Color get _hint {
    switch (kind) {
      case ArgKind.number:
        return chipNumberColor;
      case ArgKind.string:
        return chipStringColor;
      case ArgKind.channel:
        return chipChannelColor;
    }
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<_PaletteItem>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => onAccept(d.data),
      builder: (ctx, cand, rej) {
        final active = cand.isNotEmpty;
        final c = _hint;
        return GestureDetector(
          onTap: onPick,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: active ? c.withValues(alpha: 0.22) : brandControlFill,
              borderRadius: BorderRadius.circular(brandControlRadiusSoft),
              border: Border.all(
                color: active ? c : c.withValues(alpha: 0.4),
                width: active ? 1.5 : brandHairlineWidth,
              ),
            ),
            child: Text(
              label,
              style: plexMono(
                fontSize: 11,
                color: active ? brandFg : brandFgDim,
              ).copyWith(fontStyle: FontStyle.italic),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Channels palette — searchable, draggable channel chips
// ---------------------------------------------------------------------------

class _ChannelsPalette extends StatefulWidget {
  final List<String> availableChannels;
  final ValueChanged<String> onTap;

  const _ChannelsPalette({
    required this.availableChannels,
    required this.onTap,
  });

  @override
  State<_ChannelsPalette> createState() => _ChannelsPaletteState();
}

class _ChannelsPaletteState extends State<_ChannelsPalette> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() => _query = _searchCtrl.text));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.availableChannels.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'No channels — load a session to reference its channels.',
            textAlign: TextAlign.center,
            style: plexMono(fontSize: 11, color: brandFgDim),
          ),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(4),
          child: TextField(
            controller: _searchCtrl,
            decoration: const InputDecoration(
              hintText: 'Search channels…',
              prefixIcon: Icon(Icons.search, size: 16, color: brandFgDim),
            ),
            style: plexMono(fontSize: 12, color: brandFg),
          ),
        ),
        Expanded(
          child: GroupedChannelList(
            names: widget.availableChannels,
            query: _query,
            rowBuilder: (name) => Draggable<_PaletteItem>(
              data: _ChannelItem(name),
              dragAnchorStrategy: pointerDragAnchorStrategy,
              feedback: Material(
                color: Colors.transparent,
                child: Transform.translate(
                  offset: const Offset(-20, -16),
                  child: _Pill(label: '[$name]', color: chipChannelColor),
                ),
              ),
              child: GestureDetector(
                onTap: () => widget.onTap(name),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.drag_indicator,
                        size: 14,
                        color: chipChannelColor.withValues(alpha: 0.7),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          name,
                          style: plexMono(fontSize: 12, color: brandFg),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Insert picker dialog — used when tapping an empty channel slot
// ---------------------------------------------------------------------------

class _InsertPickerDialog extends StatefulWidget {
  final List<String> availableChannels;

  const _InsertPickerDialog({required this.availableChannels});

  @override
  State<_InsertPickerDialog> createState() => _InsertPickerDialogState();
}

class _InsertPickerDialogState extends State<_InsertPickerDialog> {
  int _tab = 0;
  String _query = '';
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() => _query = _searchCtrl.text));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        'INSERT',
        style: plexMono(
          fontSize: 14,
          color: brandFg,
          letterSpacing: brandLabelTracking,
        ),
      ),
      content: SizedBox(
        width: 340,
        height: 380,
        child: Column(
          children: [
            BrandSegmented<int>(
              selected: _tab,
              onChanged: (v) => setState(() => _tab = v),
              segments: const [
                BrandSegment(value: 0, label: 'Channels'),
                BrandSegment(value: 1, label: 'Functions'),
              ],
            ),
            const SizedBox(height: 8),
            if (_tab == 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: TextField(
                  controller: _searchCtrl,
                  decoration: const InputDecoration(
                    hintText: 'Search channels…',
                    prefixIcon: Icon(Icons.search, size: 16, color: brandFgDim),
                  ),
                  style: plexMono(fontSize: 12, color: brandFg),
                ),
              ),
            Expanded(
              child: _tab == 0
                  ? (widget.availableChannels.isEmpty
                      ? Center(
                          child: Text(
                            'No channels available',
                            style: plexMono(fontSize: 12, color: brandFgDim),
                          ),
                        )
                      : GroupedChannelList(
                          names: widget.availableChannels,
                          query: _query,
                          rowBuilder: (name) => ListTile(
                            dense: true,
                            title: Text(
                              name,
                              style: plexMono(fontSize: 12, color: brandFg),
                            ),
                            onTap: () =>
                                Navigator.of(context).pop(_ChannelItem(name)),
                          ),
                        ))
                  : ListView(
                      children: [
                        for (final f in kMathFunctions)
                          ListTile(
                            dense: true,
                            title: Text(
                              f.signature,
                              style: plexMono(fontSize: 12, color: brandFg),
                            ),
                            subtitle: Text(
                              f.summary,
                              style: plexSans(fontSize: 11, color: brandFgDim),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () =>
                                Navigator.of(context).pop(_FunctionItem(f)),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        QuietButton(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
