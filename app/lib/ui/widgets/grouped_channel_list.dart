import 'package:flutter/material.dart';

import '../../data/channel_groups.dart';
import '../brand/brand.dart';

/// A channel list that renders [names] as collapsible groups (GPS, IMU0, …)
/// with ungrouped names flat beneath them. When [query] is non-empty the
/// grouping is bypassed and a flat, case-insensitively filtered list is shown.
///
/// Row rendering is delegated to [rowBuilder] so the same widget serves the
/// Maths insert panel (insert rows) and the Analyze picker (checkbox rows).
/// Groups are collapsed by default. Presentation-only.
class GroupedChannelList extends StatelessWidget {
  /// All candidate channel names, already sorted by the caller.
  final List<String> names;

  /// Builds the row widget for one channel name.
  final Widget Function(String name) rowBuilder;

  /// Active search query. Empty → grouped view; non-empty → flat filtered list.
  final String query;

  /// Creates a [GroupedChannelList].
  const GroupedChannelList({
    super.key,
    required this.names,
    required this.rowBuilder,
    this.query = '',
  });

  @override
  Widget build(BuildContext context) {
    final q = query.trim().toLowerCase();
    if (q.isNotEmpty) {
      final filtered = names.where((n) => n.toLowerCase().contains(q)).toList();
      if (filtered.isEmpty) {
        return Center(
          child: Text(
            'No channels',
            style: plexMono(color: brandFgDim, fontSize: 12),
          ),
        );
      }
      return ListView(
        shrinkWrap: true,
        children: [for (final n in filtered) rowBuilder(n)],
      );
    }

    final grouped = groupChannelNames(names);
    return ListView(
      shrinkWrap: true,
      children: [
        for (final g in grouped.groups)
          ExpansionTile(
            dense: true,
            tilePadding: const EdgeInsets.symmetric(horizontal: 8),
            title: Text(
              '${g.label}  (${g.channels.length})',
              style: plexMono(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: brandFg,
              ),
            ),
            children: [for (final n in g.channels) rowBuilder(n)],
          ),
        for (final n in grouped.ungrouped) rowBuilder(n),
      ],
    );
  }
}
