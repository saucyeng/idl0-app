import 'package:flutter/material.dart';

import '../../../brand/brand.dart';

/// Shared chrome for the Device-tab source / channel settings dialogs so every
/// config dialog reads identically.
///
/// The dialog **bodies** (text fields, switches, dropdowns, sliders) inherit
/// the app's brand theme directly — only the title, sub-section headings, and
/// the action row need a hand to match the redesign idiom used elsewhere
/// (uppercase mono kickers + the [QuietButton] action hierarchy). Pair the
/// per-row enable toggles with `activeColor: brandGood` at the call site so an
/// enabled control reads the same saturated green as the channel table's On
/// column.

/// Uppercase mono kicker title for a settings dialog, matching the
/// [BrandSheet] title idiom.
Widget sourceDialogTitle(String label) {
  return Text(
    label.toUpperCase(),
    style: plexMono(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: brandFg,
      letterSpacing: 1.0,
    ),
  );
}

/// Left-aligned mono kicker for a sub-section heading inside a dialog body
/// (e.g. "Axes", "NMEA sentences").
Widget sourceDialogSectionLabel(String label) {
  return Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Text(
        label.toUpperCase(),
        style: plexMono(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: brandFgDim,
          letterSpacing: brandKickerTracking,
        ),
      ),
    ),
  );
}

/// Standard action row for a settings dialog: an optional destructive action
/// (Delete / Forget, red outline) then Cancel (outline) + a filled primary CTA
/// (Save), all in the [QuietButton] hierarchy. `AlertDialog` right-aligns them.
List<Widget> sourceDialogActions({
  required VoidCallback onCancel,
  required VoidCallback onPrimary,
  String primaryLabel = 'Save',
  String? destructiveLabel,
  VoidCallback? onDestructive,
}) {
  return [
    if (destructiveLabel != null && onDestructive != null)
      QuietButton(
        label: destructiveLabel,
        emphasis: ButtonEmphasis.alert,
        onPressed: onDestructive,
      ),
    QuietButton(label: 'Cancel', onPressed: onCancel),
    QuietButton(label: primaryLabel, filled: true, onPressed: onPrimary),
  ];
}
