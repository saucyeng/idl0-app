import 'package:flutter/material.dart';

import 'brand_tokens.dart';

/// A tappable "current X ▾" trigger — an optional status dot or leading icon, a
/// mono label, and a trailing chevron. The affordance for opening the device
/// picker (and any similar dropdown).
///
/// Two densities:
/// * inline (default) — sits inside a status row (e.g. "● Connected · {name} ▾").
/// * [prominent] — a full-width bordered control (e.g. the no-device
///   "Select a device ▾").
class StatusDropdownTrigger extends StatelessWidget {
  /// The label (rendered uppercase, tracked, ellipsised).
  final String label;

  /// Tap callback — opens the picker. `null` disables.
  final VoidCallback? onTap;

  /// Optional status dot colour shown before the label.
  final Color? dotColor;

  /// Optional leading icon (used instead of [dotColor], e.g. bluetooth).
  final IconData? leadingIcon;

  /// Full-width bordered treatment for use as a primary control.
  final bool prominent;

  /// Creates a [StatusDropdownTrigger].
  const StatusDropdownTrigger({
    super.key,
    required this.label,
    required this.onTap,
    this.dotColor,
    this.leadingIcon,
    this.prominent = false,
  });

  @override
  Widget build(BuildContext context) {
    final row = Row(
      mainAxisSize: prominent ? MainAxisSize.max : MainAxisSize.min,
      children: [
        if (dotColor != null) ...[
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
        ] else if (leadingIcon != null) ...[
          Icon(leadingIcon, size: 18, color: brandFg),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            label.toUpperCase(),
            overflow: TextOverflow.ellipsis,
            style: plexMono(
              fontSize: prominent ? 13 : 12,
              fontWeight: FontWeight.w500,
              color: brandFg,
              letterSpacing: brandLabelTracking,
            ),
          ),
        ),
        const SizedBox(width: 6),
        const Icon(Icons.expand_more, size: 18, color: brandFgDim),
      ],
    );

    if (!prominent) {
      return InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: row,
        ),
      );
    }

    final radius = BorderRadius.circular(brandControlRadiusSoft);
    return Material(
      color: brandControlFill,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: brandRule, width: brandHairlineWidth),
        borderRadius: radius,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: row,
        ),
      ),
    );
  }
}
