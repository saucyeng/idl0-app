import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/math_channel.dart';
import '../../../data/math_quantity.dart';
import '../../../providers/math_channel_provider.dart';
import '../../../providers/settings_provider.dart';
import '../../brand/brand.dart';
import '../../widgets/color_grid_picker.dart';

/// Top bar of the expression editor showing editable channel metadata.
///
/// Fields: Name, Quantity (dropdown), Units (dropdown), Rate (Hz),
/// Decimal places, Color.
///
/// Selecting a quantity automatically sets Units to the quantity's primary
/// unit. Switching to a different quantity resets Units to the new primary.
/// Every change is immediately persisted via [MathChannelNotifier.updateChannel].
/// See §15.4.
class ChannelMetadataBar extends ConsumerStatefulWidget {
  /// The channel whose metadata is being displayed and edited.
  final MathChannel channel;

  /// Creates a [ChannelMetadataBar].
  const ChannelMetadataBar({super.key, required this.channel});

  @override
  ConsumerState<ChannelMetadataBar> createState() => _ChannelMetadataBarState();
}

class _ChannelMetadataBarState extends ConsumerState<ChannelMetadataBar> {
  late TextEditingController _nameCtrl;

  /// Currently selected quantity, derived from [MathChannel.quantity].
  /// Null when the stored quantity name is empty or not in [kMathQuantities].
  MathQuantity? _selectedQuantity;

  /// Currently selected unit string, guaranteed to be in
  /// [_selectedQuantity.units] when [_selectedQuantity] is non-null.
  String _selectedUnit = '';

  late TextEditingController _rateCtrl;
  late TextEditingController _decimalsCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.channel.name);
    _rateCtrl = TextEditingController(
      text: widget.channel.sampleRateHz == 0.0
          ? ''
          : widget.channel.sampleRateHz.toString(),
    );
    _decimalsCtrl =
        TextEditingController(text: widget.channel.decimalPlaces.toString());
    _syncQuantityState(widget.channel);
  }

  @override
  void didUpdateWidget(ChannelMetadataBar old) {
    super.didUpdateWidget(old);
    if (old.channel.id != widget.channel.id) {
      _nameCtrl.text = widget.channel.name;
      _rateCtrl.text = widget.channel.sampleRateHz == 0.0
          ? ''
          : widget.channel.sampleRateHz.toString();
      _decimalsCtrl.text = widget.channel.decimalPlaces.toString();
      _syncQuantityState(widget.channel);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _rateCtrl.dispose();
    _decimalsCtrl.dispose();
    super.dispose();
  }

  /// Derives [_selectedQuantity] and [_selectedUnit] from [channel].
  ///
  /// If the stored units value is not in the new quantity's list, falls back
  /// to the primary unit (index 0).
  void _syncQuantityState(MathChannel channel) {
    final q = MathQuantity.byName(channel.quantity);
    String unit = channel.units;
    if (q != null && !q.units.contains(unit)) {
      unit = q.units.first;
    }
    _selectedQuantity = q;
    _selectedUnit = unit;
  }

  void _persist(MathChannel updated) {
    ref.read(mathChannelProvider.notifier).updateChannel(updated);
  }

  /// Commits a rename of the active channel on Enter / focus loss: trims,
  /// no-ops when unchanged or empty, and propagates the new name into every
  /// dependent expression via [MathChannelNotifier.renameChannel].
  void _commitRename(String value) {
    final name = value.trim();
    if (name.isEmpty || name == widget.channel.name) return;
    ref
        .read(mathChannelProvider.notifier)
        .renameChannel(widget.channel.id, name);
  }

  void _onQuantityChanged(MathQuantity? q) {
    String newUnit = '';
    if (q != null) {
      final system = ref.read(settingsProvider.select((s) => s.unitSystem));
      newUnit = defaultUnit(q, system);
    }
    setState(() {
      _selectedQuantity = q;
      _selectedUnit = newUnit;
    });
    _persist(
      widget.channel.copyWith(
        quantity: q?.name ?? '',
        units: newUnit,
      ),
    );
  }

  void _onUnitChanged(String? unit) {
    if (unit == null) return;
    setState(() => _selectedUnit = unit);
    _persist(widget.channel.copyWith(units: unit));
  }

  @override
  Widget build(BuildContext context) {
    // Units dropdown items for the currently selected quantity.
    final unitItems = _selectedQuantity?.units
        .map(
          (u) => DropdownMenuItem<String>(
            value: u,
            child: Text(
              u.isEmpty ? '—' : u,
              style: plexMono(fontSize: 13, color: brandFg),
            ),
          ),
        )
        .toList();

    // Ensure _selectedUnit is in the items list before passing as value.
    final unitValue = unitItems != null &&
            unitItems.any((item) => item.value == _selectedUnit)
        ? _selectedUnit
        : unitItems?.first.value;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _MetaField(
          label: 'Name',
          controller: _nameCtrl,
          width: 160,
          // Rename commits on Enter or focus loss — not per keystroke — so the
          // rename and the rewrite of dependent `[OldName]` references happen
          // atomically and race-free. See §25.
          onSubmitted: _commitRename,
          onBlur: _commitRename,
        ),
        // Quantity dropdown
        _DropdownField<MathQuantity?>(
          label: 'Quantity',
          width: 160,
          value: _selectedQuantity,
          hint: Text(
            'Quantity',
            style: plexMono(fontSize: 13, color: brandFgDim),
          ),
          items: kMathQuantities
              .map(
                (q) => DropdownMenuItem<MathQuantity?>(
                  value: q,
                  child: Text(
                    q.name,
                    style: plexMono(fontSize: 13, color: brandFg),
                  ),
                ),
              )
              .toList(),
          onChanged: _onQuantityChanged,
        ),
        // Units dropdown — disabled when no quantity is selected
        _DropdownField<String>(
          label: 'Units',
          width: 100,
          value: unitValue,
          items: unitItems,
          onChanged: unitItems != null ? _onUnitChanged : null,
          disabledHint:
              Text('—', style: plexMono(fontSize: 13, color: brandFgDim)),
        ),
        _MetaField(
          label: 'Rate (Hz)',
          controller: _rateCtrl,
          width: 88,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          onSubmitted: (v) {
            final hz = double.tryParse(v) ?? 0.0;
            _persist(widget.channel.copyWith(sampleRateHz: hz));
          },
        ),
        _MetaField(
          label: 'Decimals',
          controller: _decimalsCtrl,
          width: 80,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onSubmitted: (v) {
            final d = int.tryParse(v) ?? 3;
            _persist(widget.channel.copyWith(decimalPlaces: d.clamp(0, 9)));
          },
        ),
        _ColorChip(
          color: Color(widget.channel.colorValue),
          onChanged: (c) => _persist(
            widget.channel
                .copyWith(color: MathChannel.hexFromArgb(c.toARGB32())),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Labeled dropdown field styled to match [_MetaField].
///
/// Uses [InputDecorator] + [DropdownButton] rather than
/// [DropdownButtonFormField] to avoid the deprecated `value` parameter.
class _DropdownField<T> extends StatelessWidget {
  final String label;
  final double width;
  final T? value;
  final Widget? hint;
  final List<DropdownMenuItem<T>>? items;
  final ValueChanged<T?>? onChanged;
  final Widget? disabledHint;

  const _DropdownField({
    required this.label,
    required this.width,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
    this.disabledHint,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null && items != null;
    return SizedBox(
      width: width,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          enabled: enabled,
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            hint: hint,
            items: items,
            onChanged: onChanged,
            isDense: true,
            isExpanded: true,
            disabledHint: disabledHint,
            iconEnabledColor: brandFgDim,
            style: plexMono(fontSize: 13, color: brandFg),
          ),
        ),
      ),
    );
  }
}

class _MetaField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final double width;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String> onSubmitted;

  /// Fired when the field loses focus, with the current text. Used by the Name
  /// field to commit a rename on blur (onSubmitted only fires on Enter).
  final ValueChanged<String>? onBlur;

  const _MetaField({
    required this.label,
    required this.controller,
    required this.width,
    required this.onSubmitted,
    this.keyboardType,
    this.inputFormatters,
    this.onBlur,
  });

  @override
  Widget build(BuildContext context) {
    Widget field = TextField(
      controller: controller,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      style: plexMono(fontSize: 13, color: brandFg),
      onSubmitted: onSubmitted,
      onEditingComplete: () => onSubmitted(controller.text),
    );
    if (onBlur != null) {
      field = Focus(
        onFocusChange: (hasFocus) {
          if (!hasFocus) onBlur!(controller.text);
        },
        child: field,
      );
    }
    return SizedBox(width: width, child: field);
  }
}

/// Tappable color chip. Opens a preset color picker dialog.
class _ColorChip extends StatelessWidget {
  final Color color;
  final ValueChanged<Color> onChanged;

  const _ColorChip({required this.color, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Color', style: plexMono(fontSize: 11, color: brandFgDim)),
        const SizedBox(height: 2),
        GestureDetector(
          onTap: () => _showPicker(context),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: brandRule,
                width: brandHairlineWidth,
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showPicker(BuildContext context) async {
    final picked = await showColorGridPicker(context, current: color);
    if (picked != null) onChanged(picked);
  }
}
