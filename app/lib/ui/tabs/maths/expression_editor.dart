import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/math_channel.dart';
import '../../../providers/math_channel_provider.dart';
import '../../brand/brand.dart';
import 'function_help_panel.dart';

/// Multiline expression editor with operator toolbar, debounced validation,
/// and context-sensitive function help. See §15.4.
///
/// [controller] is owned by the parent ([MathsTab]) so that [InsertPanels]
/// can share the same controller for cursor-position insertion.
///
/// Debounce timings:
/// - 300 ms after last keystroke → validate and persist expression.
/// - 500 ms after last keystroke → trigger preview refresh (no-op until
///   real channel data is wired in a later session).
class ExpressionEditor extends ConsumerStatefulWidget {
  /// The shared [TextEditingController] for the expression field.
  final TextEditingController controller;

  /// UUID of the channel whose expression is being edited.
  final String activeChannelId;

  /// Creates an [ExpressionEditor].
  const ExpressionEditor({
    super.key,
    required this.controller,
    required this.activeChannelId,
  });

  @override
  ConsumerState<ExpressionEditor> createState() => _ExpressionEditorState();
}

class _ExpressionEditorState extends ConsumerState<ExpressionEditor> {
  // 300 ms debounce — validation + expression persist.
  static const _kValidationMs = 300;
  // 500 ms debounce — preview refresh.
  static const _kPreviewMs = 500;

  Timer? _validationTimer;
  Timer? _previewTimer;

  /// Function name detected at cursor position, drives [FunctionHelpPanel].
  String? _helpFunctionName;

  /// True once the first validation cycle has completed for this channel.
  /// Prevents showing "Valid" before the user has typed anything.
  bool _hasValidated = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    // Run initial validation if the channel already has an expression.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.controller.text.isNotEmpty) {
        _runValidation();
      }
    });
  }

  @override
  void didUpdateWidget(ExpressionEditor old) {
    super.didUpdateWidget(old);
    if (old.activeChannelId != widget.activeChannelId) {
      // New channel selected — reset validation state and re-validate.
      _validationTimer?.cancel();
      _previewTimer?.cancel();
      setState(() {
        _hasValidated = false;
        _helpFunctionName = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.controller.text.isNotEmpty) {
          _runValidation();
        }
      });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _validationTimer?.cancel();
    _previewTimer?.cancel();
    super.dispose();
  }

  void _onTextChanged() {
    // Immediately update function help (no debounce — purely cosmetic).
    final text = widget.controller.text;
    final sel = widget.controller.selection;
    final offset = sel.isValid ? sel.baseOffset : text.length;
    final fn = MathChannelValidator.functionAtCursor(text, offset);
    if (fn != _helpFunctionName) {
      setState(() => _helpFunctionName = fn);
    }

    // Debounced validation + persist (300 ms).
    _validationTimer?.cancel();
    _validationTimer = Timer(
      const Duration(milliseconds: _kValidationMs),
      _runValidation,
    );

    // Debounced preview refresh (500 ms).
    _previewTimer?.cancel();
    _previewTimer = Timer(
      const Duration(milliseconds: _kPreviewMs),
      _runPreviewUpdate,
    );
  }

  void _runValidation() {
    if (!mounted) return;
    setState(() => _hasValidated = true);

    final expression = widget.controller.text;
    final availableChannels = ref.read(mathExpressionChannelNamesProvider);
    ref
        .read(mathChannelProvider.notifier)
        .validate(expression, availableChannels);

    // Persist the updated expression to the active channel.
    final channels = ref.read(mathChannelProvider).channels;
    final idx = channels.indexWhere((c) => c.id == widget.activeChannelId);
    if (idx >= 0) {
      ref.read(mathChannelProvider.notifier).updateChannel(
            channels[idx].copyWith(expression: expression),
          );
    }
  }

  void _runPreviewUpdate() {
    // ExpressionPreview renders a TimeSeriesChart backed by
    // mathChannelEvalProvider, which watches the channels' name+expression
    // fingerprint on mathChannelProvider. The 300 ms validation debounce
    // already persists the expression via updateChannel, invalidating the
    // eval provider automatically. Nothing to do here — the provider graph
    // handles invalidation.
  }

  void _insertOperator(String op) {
    final ctrl = widget.controller;
    final text = ctrl.text;
    final sel = ctrl.selection;
    final offset = sel.isValid ? sel.baseOffset : text.length;
    final newText = MathChannelValidator.insertAtOffset(text, offset, op);
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: offset + op.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final validationError = ref.watch(
      mathChannelProvider.select((s) => s.validationError),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Operator toolbar
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final op in const [
                '+',
                '-',
                '*',
                '/',
                '<',
                '>',
                '<=',
                '>=',
                '==',
                '!=',
                'and',
                'or',
                '(',
                ')',
                '[',
                ']',
              ])
                _OperatorButton(
                  label: op,
                  onPressed: () => _insertOperator(
                    (op == 'and' || op == 'or') ? ' $op ' : op,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        // Expression textarea
        TextField(
          controller: widget.controller,
          maxLines: 5,
          minLines: 3,
          decoration: const InputDecoration(
            hintText: 'Enter expression, e.g. integrate([IMU1_AccelZ])',
          ),
          style: plexMono(fontSize: 13, color: brandFg),
        ),
        const SizedBox(height: 4),
        // Validation status — only shown after first validation cycle.
        if (_hasValidated) _ValidationStatus(error: validationError),
        // Context-sensitive function help.
        if (_helpFunctionName != null) ...[
          const SizedBox(height: 4),
          FunctionHelpPanel(functionName: _helpFunctionName!),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Validation status row
// ---------------------------------------------------------------------------

/// Shows a green "Valid" tick or a red error message.
class _ValidationStatus extends StatelessWidget {
  final String? error;

  const _ValidationStatus({required this.error});

  @override
  Widget build(BuildContext context) {
    if (error == null) {
      return Row(
        children: [
          const Icon(Icons.check_circle_outline, color: brandGood, size: 14),
          const SizedBox(width: 4),
          Text(
            'Valid',
            style: plexMono(color: brandGood, fontSize: 12),
          ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline, color: brandAccent, size: 14),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            error!,
            style: plexMono(color: brandAccent, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Operator toolbar button
// ---------------------------------------------------------------------------

/// A compact mono operator button for the expression toolbar. Inserts its
/// glyph at the cursor via [onPressed]. Uses the brand control fill + soft
/// radius so the operator strip reads as a row of tappable chips.
class _OperatorButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _OperatorButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Material(
        color: brandControlFill,
        borderRadius: BorderRadius.circular(brandControlRadiusSoft),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(brandControlRadiusSoft),
          child: Container(
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border.all(
                color: brandRule,
                width: brandHairlineWidth,
              ),
              borderRadius: BorderRadius.circular(brandControlRadiusSoft),
            ),
            child: Text(
              label,
              style: plexMono(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: brandFg,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
