import 'package:flutter/material.dart';

import 'brand_tokens.dart';

/// A small filled dot that gently pulses opacity — the live "recording"
/// indicator.
///
/// [color] defaults to [brandHivis] (the live/recording amber). The pulse is a
/// ~0.9 s ease in/out fade between full and dim, evoking a dash light.
class PulsingDot extends StatefulWidget {
  /// Dot colour. Defaults to the live amber [brandHivis].
  final Color color;

  /// Diameter in logical pixels.
  final double size;

  /// Creates a [PulsingDot].
  const PulsingDot({super.key, this.color = brandHivis, this.size = 10});

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0.35).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}
