import 'package:flutter/material.dart';

import 'brand_tokens.dart';

/// A single-line dense table row.
///
/// TODO(idl0): this is a deliberate *starting point*. Its final shape (checkbox
/// gutter, expand chevrons, the 3 indent tiers, recessed lap sub-rows, tristate
/// parent state) is driven by the real Date›Session›Laps tree — evolve it then
/// (redesign Phase 11), not in isolation.
///
/// The caller sizes each cell (`Expanded` / `SizedBox`) in [children]; this
/// widget only supplies the row chrome — 6 px vertical padding (a dense rhythm
/// that fits ~8 rows where the old tall tiles fit ~4), the tap target, and the
/// selected treatment: a [brandSurface2] fill plus a 3 px [brandGood] inset bar
/// on the left. The bar's width is always reserved so selection never shifts
/// layout.
class DenseRow extends StatelessWidget {
  /// The row cells, laid out left to right.
  final List<Widget> children;

  /// Highlights the row (fill + green inset bar).
  final bool selected;

  /// Row tap (open detail). The caller wires selection separately (e.g. a
  /// checkbox cell), per the selection model.
  final VoidCallback? onTap;

  /// Creates a [DenseRow].
  const DenseRow({
    super.key,
    required this.children,
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? brandControlActive : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: selected ? brandGood : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(13, 6, 16, 6),
          child: Row(children: children),
        ),
      ),
    );
  }
}

/// A table header row of mono kicker cells, hairline-ruled beneath. Pair with
/// [DenseRow]s that use the same cell widths. Use [headerCell] to style a label.
class TableHeader extends StatelessWidget {
  /// The header cells, laid out left to right (use [headerCell] for labels).
  final List<Widget> children;

  /// Creates a [TableHeader].
  const TableHeader({super.key, required this.children});

  /// A styled uppercase kicker label for a header cell, optionally
  /// right-aligned for numeric columns.
  static Widget headerCell(String label, {bool right = false}) {
    return Text(
      label.toUpperCase(),
      textAlign: right ? TextAlign.right : TextAlign.left,
      style: plexMono(
        fontSize: 10,
        fontWeight: FontWeight.w500,
        color: brandFgDim,
        letterSpacing: brandKickerTracking,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: brandRule, width: brandHairlineWidth),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(children: children),
    );
  }
}
