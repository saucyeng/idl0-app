import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../brand/brand.dart';
import '../../../shell/adaptive_shell.dart' show shellIndexProvider;

/// IDE-style hover/tap definition card for a math chip (function or channel).
///
/// Shows [title] + [summary] on hover (desktop) or tap (touch); a tap pins the
/// card open, and "More ▾" expands [docs]. The card body is rendered into the
/// root [Overlay] via [OverlayPortal] so it can float above sibling chips.
///
/// Because the app's tabs are kept alive in an [IndexedStack] (see
/// [AdaptiveShell]), a pinned card would otherwise survive a tab switch and
/// float — undismissable — over whatever tab is shown next (its only dismiss
/// affordance, the chip, is now off-screen). To prevent that, the card watches
/// [shellIndexProvider] and force-dismisses itself whenever the active tab
/// changes.
class DefinitionPopover extends ConsumerStatefulWidget {
  /// The chip content the card describes (the function/channel chip itself).
  final Widget child;

  /// Bold heading — typically the function signature or channel name.
  final String title;

  /// One-line summary shown under the title.
  final String summary;

  /// Optional long-form documentation, revealed by the "More ▾" affordance.
  final String? docs;

  /// Optional accent line between title and summary (e.g. an inferred unit).
  final String? extra;

  /// Creates a [DefinitionPopover].
  const DefinitionPopover({
    super.key,
    required this.child,
    required this.title,
    required this.summary,
    this.docs,
    this.extra,
  });

  @override
  ConsumerState<DefinitionPopover> createState() => _DefinitionPopoverState();
}

class _DefinitionPopoverState extends ConsumerState<DefinitionPopover> {
  final _ctrl = OverlayPortalController();
  final _link = LayerLink();
  bool _expanded = false;
  bool _pinned = false;

  /// Grace period so the pointer can cross the gap from chip to card without
  /// the card dismissing first.
  Timer? _hideTimer;

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _show() {
    _hideTimer?.cancel();
    if (!_ctrl.isShowing) _ctrl.show();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 140), () {
      if (mounted) setState(_hide);
    });
  }

  void _hide() {
    if (_pinned) return;
    _expanded = false;
    if (_ctrl.isShowing) _ctrl.hide();
  }

  /// Force-dismiss regardless of pin state — used when the active tab changes,
  /// so a pinned card never orphans itself over another tab.
  void _dismiss() {
    _hideTimer?.cancel();
    if (!_pinned && !_ctrl.isShowing) return;
    _pinned = false;
    _expanded = false;
    if (_ctrl.isShowing) _ctrl.hide();
    if (mounted) setState(() {});
  }

  void _togglePin() {
    setState(() {
      _pinned = !_pinned;
      if (_pinned) {
        _show();
      } else {
        _expanded = false;
        _ctrl.hide();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Leaving the Maths tab (any shell-index change) dismisses a pinned card.
    ref.listen<int>(shellIndexProvider, (_, __) => _dismiss());

    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _ctrl,
        overlayChildBuilder: (ctx) {
          return Positioned(
            width: 280,
            child: CompositedTransformFollower(
              link: _link,
              targetAnchor: Alignment.bottomLeft,
              followerAnchor: Alignment.topLeft,
              offset: const Offset(0, 6),
              child: MouseRegion(
                onEnter: (_) => _show(),
                onExit: (_) => _scheduleHide(),
                child: _card(),
              ),
            ),
          );
        },
        child: MouseRegion(
          onEnter: (_) => _show(),
          onExit: (_) => _scheduleHide(),
          child: GestureDetector(
            onTap: _togglePin,
            behavior: HitTestBehavior.opaque,
            child: widget.child,
          ),
        ),
      ),
    );
  }

  Widget _card() {
    return Material(
      color: brandSurface,
      elevation: 6,
      borderRadius: BorderRadius.circular(brandControlRadiusSoft),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(brandControlRadiusSoft),
          border: Border.all(color: brandRule),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.title,
              style: plexMono(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: brandFg,
              ),
            ),
            if (widget.extra != null) ...[
              const SizedBox(height: 2),
              Text(
                widget.extra!,
                style: plexMono(fontSize: 11, color: brandGood),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              widget.summary,
              style: plexSans(fontSize: 12, color: brandFgDim),
            ),
            if (widget.docs != null) ...[
              const SizedBox(height: 8),
              if (_expanded)
                Text(
                  widget.docs!,
                  style: plexSans(fontSize: 12, color: brandFg, height: 1.45),
                )
              else
                GestureDetector(
                  onTap: () => setState(() {
                    _expanded = true;
                    _pinned = true;
                  }),
                  child: Text(
                    'More ▾',
                    style: plexMono(
                      fontSize: 11,
                      color: brandInfo,
                      letterSpacing: brandLabelTracking,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
