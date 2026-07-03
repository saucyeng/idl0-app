import 'package:flutter/material.dart';

import '../brand/brand.dart';

/// A compact tri-state-aware checkbox that visually mutes itself when the
/// row's selection mode is the inactive one in the global selection's
/// XOR (`session` vs `lap`) model.
///
/// Mirrors the checkbox treatment used in the Data tab's Sessions tree so
/// the Analyze tab's lap-table checkboxes feel like the same control. When
/// muted, the box still responds to taps — tapping flips selection mode and
/// toggles the new entry, matching the Data tab's "click anywhere to switch
/// mode" affordance.
///
/// `ModeAwareCheckbox` is purely presentational — the caller is responsible
/// for invoking the right `selectionProvider` mutation in [onToggle]. The
/// widget renders nothing extra (no labels, no padding); embed it inside a
/// row/cell as appropriate.
class ModeAwareCheckbox extends StatelessWidget {
  /// Creates a [ModeAwareCheckbox].
  const ModeAwareCheckbox({
    super.key,
    required this.checked,
    required this.muted,
    required this.onToggle,
    this.tooltip,
    this.size = 18,
  });

  /// Whether this entry is currently selected (in *its* mode — the visual
  /// always reflects the underlying truth, even when [muted]).
  final bool checked;

  /// `true` when the global selection mode does NOT match this checkbox's
  /// row kind. Renders at reduced opacity so the user can see at a glance
  /// which mode is active.
  final bool muted;

  /// Called when the user taps the box. The caller must perform the right
  /// `toggleSession` / `toggleLap` write — this widget intentionally does
  /// not know about [selectionProvider].
  final VoidCallback onToggle;

  /// Optional tooltip text — useful for "Tap to switch to lap mode" hints.
  final String? tooltip;

  /// Diameter of the checkbox tap target. Defaults to 18 dp to match the
  /// compact iconography used in `lap_table.dart`.
  final double size;

  @override
  Widget build(BuildContext context) {
    // Brand mapping: a selected box reads as the saturated go-green, an
    // unselected-but-active box is the dim label foreground, and a muted box
    // (the inactive axis of the session/lap XOR) recedes to the faintest
    // foreground so the active mode is obvious at a glance.
    final Color fg = muted
        ? brandFgFaint
        : (checked ? brandGood : brandFgDim);
    final box = SizedBox(
      width: size + 6,
      height: size + 6,
      child: Center(
        child: Icon(
          checked
              ? Icons.check_box
              : Icons.check_box_outline_blank,
          size: size,
          color: fg,
        ),
      ),
    );
    final tappable = InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.zero,
      child: box,
    );
    if (tooltip == null) return tappable;
    return Tooltip(message: tooltip!, child: tappable);
  }
}
