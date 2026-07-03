import 'package:flutter/material.dart';

import 'brand_tokens.dart';

/// NATOPS-style spec row.
///
///     KEY .................................... VALUE
///
/// Leader dots fill the gap between the uppercase tracked key and the
/// right-aligned value. Dots are drawn deterministically via [CustomPaint]
/// so they always align regardless of font rendering.
class SpecRow extends StatelessWidget {
  /// Left-side key — rendered uppercase, dim, tracked.
  final String label;

  /// Right-side value — rendered as-is, in [brandFg].
  final String value;

  /// Override the value text style. Use to highlight a value with hivis,
  /// accent, or a different weight.
  final TextStyle? valueStyle;

  /// Vertical padding inside the row.
  final double verticalPadding;

  /// Creates a [SpecRow].
  const SpecRow({
    super.key,
    required this.label,
    required this.value,
    this.valueStyle,
    this.verticalPadding = 6,
  });

  @override
  Widget build(BuildContext context) {
    final labelStyle = plexMono(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: brandFgDim,
      letterSpacing: brandLabelTracking,
    );
    final defaultValueStyle = plexMono(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      color: brandFg,
    );
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: verticalPadding),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(label.toUpperCase(), style: labelStyle),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: SizedBox(
                height: 12,
                child: CustomPaint(
                  painter: _LeaderDotsPainter(),
                  size: Size.infinite,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(value, style: valueStyle ?? defaultValueStyle),
        ],
      ),
    );
  }
}

class _LeaderDotsPainter extends CustomPainter {
  static const double _dotSpacing = 4.0;
  static const double _dotRadius = 0.75;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0) return;
    final paint = Paint()..color = brandRule;
    final cy = size.height - 3; // align with descender baseline
    final count = (size.width / _dotSpacing).floor();
    final offset =
        (size.width - (count - 1) * _dotSpacing) / 2; // center the run
    for (int i = 0; i < count; i++) {
      canvas.drawCircle(
        Offset(offset + i * _dotSpacing, cy),
        _dotRadius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LeaderDotsPainter oldDelegate) => false;
}
