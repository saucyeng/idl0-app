import 'package:flutter/material.dart';

import '../../brand/brand.dart';
import 'channels_table.dart';
import 'profile_bar.dart';

/// Card 2 of the Device tab — config authoring. Wraps the profile picker
/// ([ProfileBar]) and the [ChannelsTable] in one bordered card. The active
/// profile's config is what Push Config sends to the device. See SPEC §23.
class ConfigCard extends StatelessWidget {
  /// Creates a [ConfigCard].
  const ConfigCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: brandSurface,
        border: Border.all(color: brandRule, width: brandHairlineWidth),
        borderRadius:
            const BorderRadius.all(Radius.circular(brandControlRadius)),
      ),
      // Transparent Material below the card's coloured Container: the profile
      // bar's ListTile paints its ink/splash on the nearest Material ancestor,
      // which would otherwise be hidden behind this Container's background.
      child: Material(
        type: MaterialType.transparency,
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MinimalSectionHead(label: 'config'),
            SizedBox(height: 8),
            ProfileBar(),
            SizedBox(height: 12),
            ChannelsTable(),
          ],
        ),
      ),
    );
  }
}
