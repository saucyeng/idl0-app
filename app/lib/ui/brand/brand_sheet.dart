import 'package:flutter/material.dart';

import 'brand_tokens.dart';

/// Standard modal bottom-sheet scaffold for the redesign.
///
/// A mono title row + close ×, a hairline rule, a scrollable [child] body, and
/// an optional pinned [footer] (usually a full-width filled CTA). The surface,
/// hairline border, and zero radius come from the app's `bottomSheetTheme`.
/// Reused by the device picker, session detail, filter, and sync flows — build
/// every such sheet on this so they read identically. Open it with
/// [showBrandSheet].
class BrandSheet extends StatelessWidget {
  /// Sheet title (rendered uppercase mono).
  final String title;

  /// Scrollable body content.
  final Widget child;

  /// Optional pinned footer (e.g. a filled "Show results" CTA).
  final Widget? footer;

  /// Creates a [BrandSheet].
  const BrandSheet({
    super.key,
    required this.title,
    required this.child,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title.toUpperCase(),
                    style: plexMono(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: brandFg,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
          ),
          const Divider(
            height: brandHairlineWidth,
            thickness: brandHairlineWidth,
            color: brandRule,
          ),
          Flexible(child: SingleChildScrollView(child: child)),
          if (footer != null) ...[
            const Divider(
              height: brandHairlineWidth,
              thickness: brandHairlineWidth,
              color: brandRule,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: footer,
            ),
          ],
        ],
      ),
    );
  }
}

/// Shows a [BrandSheet] as a modal bottom sheet and returns its result (the
/// value passed to `Navigator.pop`), or null if dismissed.
Future<T?> showBrandSheet<T>({
  required BuildContext context,
  required String title,
  required Widget body,
  Widget? footer,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    builder: (_) => BrandSheet(title: title, footer: footer, child: body),
  );
}
