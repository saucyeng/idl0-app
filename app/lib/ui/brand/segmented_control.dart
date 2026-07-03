import 'package:flutter/material.dart';

import 'brand_tokens.dart';

/// One option in a [BrandSegmented].
class BrandSegment<T> {
  /// The value selected when this segment is tapped.
  final T value;

  /// Uppercase mono label.
  final String label;

  /// Optional leading icon.
  final IconData? icon;

  /// Creates a [BrandSegment].
  const BrandSegment({required this.value, required this.label, this.icon});
}

/// Mono segmented control — a hairline-bordered row of mutually-exclusive
/// options. The selected segment gets a [brandSurface2] fill + [brandFg] text;
/// the rest sit at [brandFgDim]. 7 px outer corners, hairline dividers between
/// segments. Set [tight] for the compact density used inside toolbars.
class BrandSegmented<T> extends StatelessWidget {
  /// The options, left to right.
  final List<BrandSegment<T>> segments;

  /// The currently selected value (matched by `==` against segment values).
  final T selected;

  /// Called with the tapped segment's value.
  final ValueChanged<T> onChanged;

  /// Compact density (smaller height/padding/type) for toolbar use.
  final bool tight;

  /// Creates a [BrandSegmented].
  const BrandSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.tight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: tight ? 28 : 34,
      decoration: BoxDecoration(
        color: brandControlFill,
        border: Border.all(color: brandRule, width: brandHairlineWidth),
        borderRadius: BorderRadius.circular(brandControlRadiusSoft),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < segments.length; i++) ...[
            if (i > 0)
              const VerticalDivider(
                width: brandHairlineWidth,
                thickness: brandHairlineWidth,
                color: brandRule,
              ),
            _Segment<T>(
              segment: segments[i],
              isSelected: segments[i].value == selected,
              tight: tight,
              onTap: () => onChanged(segments[i].value),
            ),
          ],
        ],
      ),
    );
  }
}

class _Segment<T> extends StatelessWidget {
  const _Segment({
    required this.segment,
    required this.isSelected,
    required this.tight,
    required this.onTap,
  });

  final BrandSegment<T> segment;
  final bool isSelected;
  final bool tight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = isSelected ? brandFg : brandFgDim;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: isSelected ? brandControlActive : Colors.transparent,
        padding: EdgeInsets.symmetric(horizontal: tight ? 10 : 14),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (segment.icon != null) ...[
              Icon(segment.icon, size: tight ? 14 : 16, color: fg),
              const SizedBox(width: 6),
            ],
            Text(
              segment.label.toUpperCase(),
              style: plexMono(
                fontSize: tight ? 11 : 12,
                fontWeight: FontWeight.w500,
                color: fg,
                letterSpacing: brandLabelTracking,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
