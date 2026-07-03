import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../../../data/fit_export.dart';
import '../../../data/track.dart';
import '../../../providers/channel_provider.dart';
import '../../../providers/session_provider.dart';
import '../../../providers/session_workspace_provider.dart';
import '../../../providers/track_provider.dart';
import '../../../src/rust/session.dart' as rust;
import '../../brand/brand.dart';
import 'metadata_editor.dart' show resolveSessionVenue;
import 'session_detail_card.dart' show revealInFileManager;

/// Session-detail control that exports the session to a Garmin FIT file (for
/// Strava) with native lap splits, then saves it via a file picker. Lives in
/// the GPS-gated row beside "Create track"; the caller only renders this when
/// the session has GPS, so FIT export (which requires GPS) is always valid.
///
/// Sport is fixed to cycling in v1.
class FitExportControls extends ConsumerStatefulWidget {
  /// Creates [FitExportControls].
  const FitExportControls({super.key, required this.sessionId});

  /// Session UUID — resolves the handle and workspace.
  final String sessionId;

  @override
  ConsumerState<FitExportControls> createState() => _FitExportControlsState();
}

class _FitExportControlsState extends ConsumerState<FitExportControls> {
  bool _busy = false;

  /// Absolute path of the most recent successful export, or null. Drives the
  /// post-export icon affordance (drag + reveal); desktop-only.
  String? _savedPath;

  /// Whether the post-export affordance (drag/reveal) can be shown: a file
  /// exists and we're on a desktop OS (drag-out + file-manager reveal).
  bool get _showAffordance =>
      _savedPath != null &&
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  Widget build(BuildContext context) {
    final saved = _savedPath;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        QuietButton(
          label: 'Export .fit',
          icon: Icons.ios_share,
          onPressed: _busy ? null : _export,
        ),
        if (saved != null && _showAffordance) ...[
          const SizedBox(width: 8),
          // Drag the saved .fit straight into Strava's web upload. Flow A saved
          // a real file first, so the drag carries the on-disk file (the most
          // browser-reliable form) — no virtual file needed.
          DragItemWidget(
            allowedOperations: () => [DropOperation.copy],
            dragItemProvider: (request) async {
              final item = DragItem();
              item.add(Formats.fileUri(Uri.file(saved)));
              return item;
            },
            child: const DraggableWidget(
              child: Tooltip(
                message: 'Drag to Strava',
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.drag_indicator, size: 20, color: brandFgDim),
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.folder_open, size: 18),
            color: brandFgDim,
            tooltip: 'Show in Explorer',
            visualDensity: VisualDensity.compact,
            onPressed: () => revealInFileManager(saved),
          ),
        ],
      ],
    );
  }

  /// Builds the FIT bytes and writes them to a user-chosen path.
  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final meta = ref
          .read(sessionProvider)
          .sessions
          .firstWhere((s) => s.sessionId == widget.sessionId);
      final handle =
          await ref.read(sessionHandleProvider(widget.sessionId).future);
      final ws =
          await ref.read(sessionWorkspaceProvider(widget.sessionId).future);
      final laps = collectFitLaps(ws);

      final bytes = await rust.exportFitToVec(
        handle: handle,
        sport: rust.FitSport.cycling,
        laps: laps,
      );

      // Resolve the venue the same way the detail card does (own venue, else a
      // matched Track's), so the filename matches what the user sees.
      final tracks = ref.read(trackProvider).valueOrNull ?? const <Track>[];
      final venue = resolveSessionVenue(meta, ws, tracks);

      final outPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Export session to FIT',
        fileName: fitExportFileName(meta, venue),
        type: FileType.custom,
        allowedExtensions: const ['fit'],
      );
      if (outPath == null) return; // user cancelled
      final pathWithExt =
          outPath.toLowerCase().endsWith('.fit') ? outPath : '$outPath.fit';

      await File(pathWithExt).writeAsBytes(bytes, flush: true);

      if (!mounted) return;
      setState(() => _savedPath = pathWithExt);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Saved .fit')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('FIT export failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

}
