import 'package:flutter/material.dart';

/// How to resolve importing a Track whose `trackId` already exists in the
/// library.
enum TrackImportResolution {
  /// Replace the existing Track's fields, keeping its `trackId`.
  updateInPlace,

  /// Add the imported Track under a fresh `trackId` (coexists with the existing
  /// one).
  newCopy,
}

/// Asks how to resolve a `trackId` collision on `.idl0t` import. Returns the
/// chosen [TrackImportResolution], or `null` if the user cancels.
class TrackImportConflictDialog extends StatelessWidget {
  /// Creates a [TrackImportConflictDialog] naming the [existingName] in the
  /// library that collides with the import.
  const TrackImportConflictDialog({super.key, required this.existingName});

  /// Display name of the library Track whose id collides with the import.
  final String existingName;

  /// Shows the dialog and resolves to the user's choice (or `null` on cancel).
  static Future<TrackImportResolution?> show(
    BuildContext context,
    String existingName,
  ) =>
      showDialog<TrackImportResolution>(
        context: context,
        builder: (_) => TrackImportConflictDialog(existingName: existingName),
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Track already exists'),
        content: Text(
          'A track with this ID already exists ("$existingName"). '
          'Update it in place, or import as a new copy?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, TrackImportResolution.newCopy),
            child: const Text('New copy'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, TrackImportResolution.updateInPlace),
            child: const Text('Update in place'),
          ),
        ],
      );
}
