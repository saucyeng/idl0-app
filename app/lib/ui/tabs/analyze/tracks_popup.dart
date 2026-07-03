import 'package:flutter/material.dart';

import '../../../data/track.dart';
import '../../brand/brand.dart';
import '../data/track_editor_modal.dart';

/// Popup shown by the Analyze tab GPS map's "Tracks…" button. Lists every
/// Track visited in the current session and offers a "Create new Track"
/// entry. See `docs/IDL0_SPEC.md §26`.
///
/// Result type: [TracksPopupResult]. `null` on Done/dismiss; a
/// [TracksPopupCreateNew] sentinel signals the caller to enter
/// segment-selection mode.
sealed class TracksPopupResult {
  const TracksPopupResult();
}

/// Sentinel returned when the user taps "Create new Track from segment…".
///
/// The caller should enter segment-selection mode so the user can drag the
/// [TrackSegmentSelector] handles to define the new track.
class TracksPopupCreateNew extends TracksPopupResult {
  /// Creates a [TracksPopupCreateNew] sentinel.
  const TracksPopupCreateNew();
}

/// Popup widget that lists visited Tracks for a session with an [Edit] button
/// per row and a "Create new Track from segment…" footer entry.
///
/// Open via [TracksPopup.show] rather than constructing directly.
class TracksPopup extends StatelessWidget {
  /// Creates a [TracksPopup].
  const TracksPopup({super.key, required this.tracksWithLapCounts});

  /// Visited Tracks in the current session paired with the lap count for
  /// this session.
  final List<({Track track, int lapCount})> tracksWithLapCounts;

  /// Convenience launcher. Returns [TracksPopupCreateNew] if the user clicked
  /// "Create new Track…", `null` on Done/dismiss.
  static Future<TracksPopupResult?> show(
    BuildContext context, {
    required List<({Track track, int lapCount})> tracksWithLapCounts,
  }) {
    return showDialog<TracksPopupResult>(
      context: context,
      builder: (_) => TracksPopup(tracksWithLapCounts: tracksWithLapCounts),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        'Tracks in this session',
        style: plexMono(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: brandFg,
        ),
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (tracksWithLapCounts.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No tracks detected in this session',
                  style: plexMono(fontSize: 12, color: brandFgDim),
                ),
              )
            else
              for (final entry in tracksWithLapCounts)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    entry.track.name,
                    style: plexMono(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: brandFg,
                    ),
                  ),
                  subtitle: Text(
                    '${entry.lapCount} laps',
                    style: plexMono(fontSize: 12, color: brandFgDim),
                  ),
                  trailing: QuietButton(
                    label: 'Edit',
                    onPressed: () async {
                      Navigator.of(context).pop();
                      await TrackEditorModal.show(context, entry.track);
                    },
                  ),
                ),
            const Divider(
              color: brandRule,
              thickness: brandHairlineWidth,
              height: 1,
            ),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.add, color: brandFg),
              title: Text(
                'Create new Track from segment…',
                style: plexMono(fontSize: 14, color: brandFg),
              ),
              onTap: () {
                Navigator.of(context).pop(const TracksPopupCreateNew());
              },
            ),
          ],
        ),
      ),
      actions: [
        QuietButton(
          label: 'Done',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
