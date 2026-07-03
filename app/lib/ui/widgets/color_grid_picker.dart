import 'package:flutter/material.dart';

import '../brand/brand.dart';

/// Office-style palette: one row per hue (light → dark shades across the row),
/// plus a trailing greyscale row. Fixed const palette built from Material
/// `ColorSwatch` families — no dependency. Each entry is an ARGB-opaque
/// [Color]. Laid out as hue-rows × shade-columns.
const List<List<Color>> _kPalette = [
  // red
  [
    Color(0xFFEF9A9A),
    Color(0xFFE57373),
    Color(0xFFF44336),
    Color(0xFFD32F2F),
    Color(0xFFB71C1C),
  ],
  // orange
  [
    Color(0xFFFFCC80),
    Color(0xFFFFB74D),
    Color(0xFFFF9800),
    Color(0xFFF57C00),
    Color(0xFFE65100),
  ],
  // amber
  [
    Color(0xFFFFE082),
    Color(0xFFFFD54F),
    Color(0xFFFFC107),
    Color(0xFFFFA000),
    Color(0xFFFF6F00),
  ],
  // yellow
  [
    Color(0xFFFFF59D),
    Color(0xFFFFEE58),
    Color(0xFFFFEB3B),
    Color(0xFFFBC02D),
    Color(0xFFF57F17),
  ],
  // green
  [
    Color(0xFFA5D6A7),
    Color(0xFF81C784),
    Color(0xFF4CAF50),
    Color(0xFF388E3C),
    Color(0xFF1B5E20),
  ],
  // teal
  [
    Color(0xFF80CBC4),
    Color(0xFF4DB6AC),
    Color(0xFF009688),
    Color(0xFF00796B),
    Color(0xFF004D40),
  ],
  // cyan
  [
    Color(0xFF80DEEA),
    Color(0xFF4DD0E1),
    Color(0xFF00BCD4),
    Color(0xFF0097A7),
    Color(0xFF006064),
  ],
  // blue
  [
    Color(0xFF90CAF9),
    Color(0xFF64B5F6),
    Color(0xFF2196F3),
    Color(0xFF1976D2),
    Color(0xFF0D47A1),
  ],
  // indigo
  [
    Color(0xFF9FA8DA),
    Color(0xFF7986CB),
    Color(0xFF3F51B5),
    Color(0xFF303F9F),
    Color(0xFF1A237E),
  ],
  // purple
  [
    Color(0xFFCE93D8),
    Color(0xFFBA68C8),
    Color(0xFF9C27B0),
    Color(0xFF7B1FA2),
    Color(0xFF4A148C),
  ],
  // pink
  [
    Color(0xFFF48FB1),
    Color(0xFFF06292),
    Color(0xFFE91E63),
    Color(0xFFC2185B),
    Color(0xFF880E4F),
  ],
  // brown
  [
    Color(0xFFBCAAA4),
    Color(0xFFA1887F),
    Color(0xFF795548),
    Color(0xFF5D4037),
    Color(0xFF3E2723),
  ],
  // greyscale
  [
    Color(0xFFFFFFFF),
    Color(0xFFBDBDBD),
    Color(0xFF9E9E9E),
    Color(0xFF616161),
    Color(0xFF000000),
  ],
];

/// A grid of selectable colour swatches. Calls [onPick] with the chosen colour.
/// The swatch matching [selected] (compared by ARGB int) gets a ring.
class ColorGridPicker extends StatelessWidget {
  /// Currently selected colour, or null.
  final Color? selected;

  /// Invoked with the colour the user taps.
  final ValueChanged<Color> onPick;

  /// Creates a [ColorGridPicker].
  const ColorGridPicker({super.key, this.selected, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final selArgb = selected?.toARGB32();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in _kPalette)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in row)
                GestureDetector(
                  onTap: () => onPick(c),
                  child: Container(
                    width: 28,
                    height: 28,
                    margin: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: c,
                      borderRadius: BorderRadius.circular(brandControlRadius),
                      border: Border.all(
                        color: c.toARGB32() == selArgb ? brandFg : brandRule,
                        width: c.toARGB32() == selArgb ? 3 : brandHairlineWidth,
                      ),
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// Opens [ColorGridPicker] in a dialog and returns the picked colour, or null
/// if dismissed. [current] highlights the active swatch.
Future<Color?> showColorGridPicker(BuildContext context, {Color? current}) {
  return showDialog<Color>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(
        'PICK COLOUR',
        style: plexMono(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: brandFg,
          letterSpacing: brandLabelTracking,
        ),
      ),
      content: ColorGridPicker(
        selected: current,
        onPick: (c) => Navigator.of(ctx).pop(c),
      ),
      actions: [
        QuietButton(
          label: 'Cancel',
          onPressed: () => Navigator.of(ctx).pop(),
        ),
      ],
    ),
  );
}
