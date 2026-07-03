import 'package:flutter/material.dart';

import 'brand_tokens.dart';

/// Small mono pill with 7 px corners.
///
/// Optional [onDeleted] adds a trailing × (used for removable active-filter and
/// compare chips); [selected] fills it with [brandSurface2] and brightens the
/// label. [onTap] makes the whole chip tappable (used for multi-select facet
/// chips).
class BrandChip extends StatelessWidget {
  /// Uppercase mono label.
  final String label;

  /// When non-null, shows a trailing × that calls this on tap.
  final VoidCallback? onDeleted;

  /// Whole-chip tap (e.g. toggle a facet).
  final VoidCallback? onTap;

  /// Filled/active treatment.
  final bool selected;

  /// Creates a [BrandChip].
  const BrandChip({
    super.key,
    required this.label,
    this.onDeleted,
    this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? brandFg : brandFgDim;
    final radius = BorderRadius.circular(brandControlRadiusSoft);
    return Material(
      color: selected ? brandControlActive : brandControlFill,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: brandRule, width: brandHairlineWidth),
        borderRadius: radius,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label.toUpperCase(),
                style: plexMono(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: fg,
                  letterSpacing: brandLabelTracking,
                ),
              ),
              if (onDeleted != null) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: onDeleted,
                  child: Icon(Icons.close, size: 13, color: fg),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
