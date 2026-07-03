import 'package:flutter/material.dart';

import 'brand_tokens.dart';

/// A single icon button for use inside a [ToolGroup].
class IconBtn extends StatelessWidget {
  /// The glyph.
  final IconData icon;

  /// Tap callback; `null` disables (dims to [brandRule]).
  final VoidCallback? onPressed;

  /// Long-press / hover tooltip (e.g. "Duplicate").
  final String? tooltip;

  /// Optional icon tint override — e.g. [brandAccent] for a destructive tool.
  /// Defaults to [brandFg].
  final Color? tint;

  /// Creates an [IconBtn].
  const IconBtn({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final color = !enabled ? brandRule : (tint ?? brandFg);
    final button = InkWell(
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, size: 18, color: color),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// A hairline-bordered, segmented row of [IconBtn]s — the standard container
/// for the New / Duplicate / Import / Export toolbars (and any similar cluster).
/// 7 px outer corners, hairline dividers between buttons. Reuse it everywhere
/// those actions appear so they read consistently.
class ToolGroup extends StatelessWidget {
  /// The icon buttons, left to right.
  final List<IconBtn> children;

  /// Creates a [ToolGroup].
  const ToolGroup({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: brandControlFill,
        border: Border.all(color: brandRule, width: brandHairlineWidth),
        borderRadius: BorderRadius.circular(brandControlRadiusSoft),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                const VerticalDivider(
                  width: brandHairlineWidth,
                  thickness: brandHairlineWidth,
                  color: brandRule,
                ),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}
