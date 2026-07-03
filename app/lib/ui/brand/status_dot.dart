import 'package:flutter/material.dart';

import 'brand_tokens.dart';

/// 10 px coloured dot + uppercase tracked label: `● LABEL`.
///
/// Colour is owned by the call site so the same widget can render any
/// semantic state (green = healthy, yellow = live, red = alert, dim =
/// idle). Replaces the older [StatusBadge] which baked the colour into a
/// three-state enum.
///
/// When [color] is [brandFgDim] the label also renders dim, so an idle
/// status doesn't visually compete with active ones.
class StatusDot extends StatelessWidget {
  /// Label text — rendered uppercase, tracked.
  final String label;

  /// Dot colour. Pass a semantic brand token: [brandGood] / [brandHivis]
  /// / [brandAccent] / [brandFgDim].
  final Color color;

  /// Creates a [StatusDot].
  const StatusDot({
    super.key,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final isDim = color == brandFgDim;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label.toUpperCase(),
            style: plexMono(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: isDim ? brandFgDim : brandFg,
              letterSpacing: brandLabelTracking,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
