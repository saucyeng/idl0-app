import 'package:flutter/material.dart';

import 'brand_tokens.dart';

/// Quiet section header — uppercase tracked label + hairline rule extending
/// to the right edge.
///
///     CONNECTION ─────────────────────────────────────────
///
/// The default header used across every tab. Label + rule, nothing else.
///
/// Optional [trailing] widget is laid out flush-right, between the rule
/// and the right edge. Use it for a single [StatusDot] or small action
/// tied to the section, never decorative content.
class MinimalSectionHead extends StatelessWidget {
  /// Uppercase tracked label.
  final String label;

  /// Optional trailing widget rendered flush-right between the rule and
  /// the right edge (e.g. a [StatusBadge] or small action).
  final Widget? trailing;

  /// Creates a [MinimalSectionHead].
  const MinimalSectionHead({
    super.key,
    required this.label,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            label.toUpperCase(),
            style: plexMono(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: brandFgDim,
              letterSpacing: brandKickerTracking,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: _HairlineRule(),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _HairlineRule extends StatelessWidget {
  const _HairlineRule();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: brandHairlineWidth,
      color: brandRule,
    );
  }
}
