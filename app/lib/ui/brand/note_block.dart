import 'package:flutter/material.dart';

import 'brand_tokens.dart';

/// Bordered callout block with a thin left rule.
///
///     │
///     │  child content
///     │
///
/// 1 px left rule in [brandRule], 16 px default padding. Replaces the
/// older `TickBlock` which prepended a red accent tick — that decoration
/// is dropped in the quiet field manual treatment so the rule alone
/// signals "this is a callout."
///
/// Pass [borderColor] when the callout's content carries a semantic state
/// (e.g. [brandAccent] for a warning, [brandGood] for a healthy info
/// note); defaults to [brandRule].
class NoteBlock extends StatelessWidget {
  /// The content rendered inside the block.
  final Widget child;

  /// Inner padding around [child]. Defaults to 16 on all sides.
  final EdgeInsetsGeometry padding;

  /// Left rule colour. Defaults to [brandRule].
  final Color borderColor;

  /// Creates a [NoteBlock].
  const NoteBlock({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderColor = brandRule,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: borderColor, width: brandHairlineWidth),
        ),
      ),
      padding: padding,
      child: child,
    );
  }
}
