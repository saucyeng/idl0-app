import 'package:flutter/material.dart';

import 'brand.dart';

/// Compact, color-coded peripheral readout: an [icon] tinted by [color], a
/// dim [label], and an optional [value] (a short numeric/text such as `OK`,
/// `82%`, or later `12.4 GB`). Used in the Device card's status strip.
///
/// The [value] slot is optional so the firmware §7.3 numeric follow-on
/// (GB free, battery voltage, GPS sat count) can fill it in with no UI change.
class StatusIcon extends StatelessWidget {
  /// Creates a [StatusIcon].
  const StatusIcon({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    this.value,
  });

  /// Glyph for the peripheral (e.g. `Icons.sd_card`).
  final IconData icon;

  /// Short uppercase label (e.g. `SD`, `GPS`).
  final String label;

  /// Status color from the brand palette — green ok / amber degraded /
  /// red fault / dim absent.
  final Color color;

  /// Optional short value (`OK`, `82%`, `142`). When null, only the icon +
  /// label render.
  final String? value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 5),
        Text(
          value == null ? label : '$label $value',
          style: plexMono(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: value == null ? brandFgDim : color,
          ),
        ),
      ],
    );
  }
}
