import 'package:flutter/material.dart';

import 'brand_tokens.dart';
import 'minimal_section_head.dart';

/// Collapsible content section with a [MinimalSectionHead] title.
///
/// Owns its expanded state so the rotating chevron sits cleanly inside
/// the section head's `trailing` slot, flush-right against the hairline
/// rule (the default [ExpansionTile] chevron lands past the title and
/// outside the brand-mandated 16 px gutter).
///
/// Tap anywhere on the header to toggle. Animates with a 160 ms ease.
class CollapsibleSection extends StatefulWidget {
  /// Uppercase tracked label rendered in the section head.
  final String label;

  /// Content shown when expanded.
  final Widget child;

  /// Whether the section starts expanded. Defaults to `false` (collapsed)
  /// — explicitly opt in for high-traffic sections.
  final bool initiallyExpanded;

  /// Creates a [CollapsibleSection].
  const CollapsibleSection({
    super.key,
    required this.label,
    required this.child,
    this.initiallyExpanded = false,
  });

  @override
  State<CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<CollapsibleSection> {
  late bool _expanded = widget.initiallyExpanded;

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: _toggle,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          child: MinimalSectionHead(
            label: widget.label,
            trailing: AnimatedRotation(
              turns: _expanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 160),
              child: const Icon(
                Icons.expand_more,
                size: 16,
                color: brandFgDim,
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: widget.child,
                )
              : const SizedBox(width: double.infinity, height: 0),
        ),
      ],
    );
  }
}
