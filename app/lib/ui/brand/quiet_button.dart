import 'package:flutter/material.dart';

import 'brand_tokens.dart';

/// Semantic emphasis for [QuietButton].
///
/// For outline buttons (the default) this drives the **border** colour so the
/// button telegraphs its kind of action at a glance. For [QuietButton.filled]
/// buttons it drives the **fill** colour (with contrasting ink), giving the
/// redesign's primary-action hierarchy.
enum ButtonEmphasis {
  /// Neutral action — outline border / filled in [brandFg]. Default.
  ///
  /// Filled + normal is the **primary** action of a screen: a filled
  /// warm-white button with dark ink. High contrast, one per screen.
  normal,

  /// [brandAccent] (red) — required-fix / **destructive** action.
  ///
  /// Outline: red border. Filled: red fill with warm-white ink (e.g. a
  /// destructive confirm). Red is no longer the primary-action colour.
  alert,

  /// [brandGood] (green) — start a healthy live operation (Start recording,
  /// Connect, Confirm). Filled green = the "go" CTA.
  go,

  /// [brandHivis] (amber) — currently armed / live; tapping stops something
  /// already in motion. Filled amber = the "live" CTA (Stop recording).
  live,

  /// [brandInfo] (blue) — the connectivity / transport command category:
  /// Bluetooth (BLE) scan/connect/pair, WiFi transfer, and informational
  /// connect actions. Filled blue = the "connect" CTA.
  info,
}

/// The quiet field manual action button — uppercase tracked mono label.
///
/// Two visual families share one widget, both at the 7 px soft control radius:
/// * **Outline** (default): transparent fill, hairline border coloured by
///   [emphasis]. The everyday action affordance (Edit, Cancel, Disconnect).
/// * **Filled** ([filled] = true): a solid [emphasis]-coloured fill with
///   contrasting ink — the redesign's primary hierarchy (primary = warm-white,
///   connect = blue, go = green, live = amber, destructive = red).
///
/// [large] makes a full-width, taller CTA (13 px label, 2.0 tracking) for the
/// single pronounced action per screen. [icon] adds a leading glyph.
///
/// Disabled state dims label + border/fill.
class QuietButton extends StatelessWidget {
  /// Label text — rendered uppercase, tracked.
  final String label;

  /// Tap callback. `null` disables the button.
  final VoidCallback? onPressed;

  /// Semantic emphasis — drives border colour (outline) or fill colour (filled).
  final ButtonEmphasis emphasis;

  /// When true, renders a solid [emphasis]-coloured fill with contrasting ink
  /// (the redesign primary hierarchy). When false (the default), renders the
  /// outline button. Both families use the 7 px soft control radius.
  final bool filled;

  /// When true, renders a full-width, taller CTA (13 px label, 2.0 tracking,
  /// ~16 px vertical padding) for the one pronounced action per screen.
  final bool large;

  /// Optional leading icon glyph (e.g. record / push / stop).
  final IconData? icon;

  /// Creates a [QuietButton].
  const QuietButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.emphasis = ButtonEmphasis.normal,
    this.filled = false,
    this.large = false,
    this.icon,
  });

  /// Outline border colour by [emphasis] (used only when not [filled]).
  Color _borderColor(bool enabled) {
    if (!enabled) return brandRule;
    return switch (emphasis) {
      ButtonEmphasis.alert => brandAccent,
      ButtonEmphasis.go => brandGood,
      ButtonEmphasis.live => brandHivis,
      ButtonEmphasis.info => brandInfo,
      ButtonEmphasis.normal => brandFg,
    };
  }

  /// Fill colour by [emphasis] (used only when [filled]).
  Color _fillColor(bool enabled) {
    if (!enabled) return brandSurface2;
    return switch (emphasis) {
      ButtonEmphasis.alert => brandAccent,
      ButtonEmphasis.go => brandGood,
      ButtonEmphasis.live => brandHivis,
      ButtonEmphasis.info => brandInfo,
      ButtonEmphasis.normal => brandFg,
    };
  }

  /// Ink (label + icon) colour.
  Color _inkColor(bool enabled) {
    if (!enabled) return brandFgDim;
    if (!filled) return brandFg;
    // Dark ink on the light fills (warm-white / green / amber); warm-white ink
    // on the darker saturated fills (red destructive, blue connect).
    return switch (emphasis) {
      ButtonEmphasis.alert || ButtonEmphasis.info => brandFg,
      _ => brandBg,
    };
  }

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final ink = _inkColor(enabled);
    // Every interactive control uses the softened 7px radius; the fill vs
    // outline distinction (not the corner) separates the two families.
    const radius = brandControlRadiusSoft;

    final labelWidget = Text(
      label.toUpperCase(),
      style: plexMono(
        fontSize: large ? 15 : 12,
        fontWeight: filled || large ? FontWeight.w600 : FontWeight.w500,
        color: ink,
        letterSpacing: large ? brandKickerTracking : brandLabelTracking,
      ),
    );

    final Widget child = icon == null
        ? labelWidget
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: large ? 22 : 16, color: ink),
              const SizedBox(width: 8),
              labelWidget,
            ],
          );

    final button = OutlinedButton(
      onPressed: onPressed,
      style: ButtonStyle(
        shape: WidgetStateProperty.all(
          const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(radius)),
          ),
        ),
        padding: WidgetStateProperty.all(
          large
              ? const EdgeInsets.symmetric(horizontal: 24, vertical: 20)
              : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
        side: WidgetStateProperty.all(
          filled
              ? BorderSide.none
              : BorderSide(
                  color: _borderColor(enabled),
                  width: brandHairlineWidth,
                ),
        ),
        foregroundColor: WidgetStateProperty.all(ink),
        backgroundColor: WidgetStateProperty.all(
          filled ? _fillColor(enabled) : Colors.transparent,
        ),
      ),
      child: child,
    );

    // The one pronounced CTA stretches to fill its (bounded) parent width.
    return large ? SizedBox(width: double.infinity, child: button) : button;
  }
}
