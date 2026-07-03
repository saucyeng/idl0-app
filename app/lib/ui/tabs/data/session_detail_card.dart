import 'dart:io' show File, Platform, Process;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../data/session_model.dart';
import '../../../data/track.dart';
import '../../../providers/detail_selection_provider.dart';
import '../../../providers/drive_sync_provider.dart';
import '../../../providers/runs_provider.dart';
import '../../../providers/session_gps_preview_provider.dart';
import '../../../providers/session_provider.dart';
import '../../../providers/session_workspace_provider.dart';
import '../../../providers/track_provider.dart';
import '../../brand/brand.dart';
import 'fit_export_controls.dart';
import 'metadata_editor.dart';
import 'session_map_preview.dart';
import 'track_editor_modal.dart';

/// Side-panel detail card for a single session. See `docs/IDL0_SPEC.md §24`.
///
/// Sourced by [sessionId] from [sessionProvider]. Hosts a [MetadataForm] for
/// editing, a collapsible file-info panel, and a low-prominence delete button
/// that opens a scoped delete confirmation dialog with three options:
/// Cancel / Remove from app / Delete everywhere.
///
/// "Delete everywhere" is disabled when [DriveSyncState.isSignedIn] is false.
///
/// The header venue falls back to a matched Track's venue when the session
/// carries no explicit `venueName` (mirroring the Sessions-tree heading and the
/// venue-filter facet) — so a track-matched session reads under its venue
/// instead of "(no venue)".
class SessionDetailCard extends ConsumerStatefulWidget {
  /// Creates a [SessionDetailCard].
  const SessionDetailCard({super.key, required this.sessionId});

  /// Session UUID — looked up in [sessionProvider].
  final String sessionId;

  @override
  ConsumerState<SessionDetailCard> createState() => _SessionDetailCardState();
}

class _SessionDetailCardState extends ConsumerState<SessionDetailCard> {
  final _formKey = GlobalKey<MetadataFormState>();
  bool _fileInfoExpanded = false;

  @override
  Widget build(BuildContext context) {
    final meta = ref
        .watch(sessionProvider)
        .sessions
        .where((s) => s.sessionId == widget.sessionId)
        .firstOrNull;
    if (meta == null) return const SizedBox.shrink();

    final wsAsync = ref.watch(sessionWorkspaceProvider(widget.sessionId));
    final tracks = ref.watch(trackProvider).valueOrNull ?? const <Track>[];
    final displayVenue = resolveSessionVenue(meta, wsAsync.valueOrNull, tracks);
    // Show the "Create track" entry only once we know the session has GPS.
    final hasGps = ref
            .watch(sessionGpsPreviewProvider(widget.sessionId))
            .valueOrNull
            ?.isNotEmpty ??
        false;

    return Material(
      color: brandSurface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Header row ──────────────────────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _title(meta, displayVenue),
                      style: plexMono(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: brandFg,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: brandFgDim,
                    tooltip: 'Close',
                    onPressed: () =>
                        ref.read(detailSelectionProvider.notifier).clear(),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // ── GPS map preview + create-track entry ─────────────────────
              SessionMapPreview(sessionId: widget.sessionId),
              if (hasGps) ...[
                const SizedBox(height: 8),
                // Wrap (not Row) so Create track + the FIT export controls flow
                // onto a second line in the narrow detail panel instead of
                // overflowing.
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    QuietButton(
                      label: 'Create track',
                      icon: Icons.add_road,
                      onPressed: () => TrackEditorModal.createFromSessionAndShow(
                        context,
                        ref,
                        widget.sessionId,
                      ),
                    ),
                    FitExportControls(sessionId: widget.sessionId),
                  ],
                ),
              ],
              const SizedBox(height: 12),

              // ── MetadataForm (async-loaded workspace) ────────────────────
              wsAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: brandFgDim,
                      ),
                    ),
                  ),
                ),
                error: (e, _) => Text(
                  'Failed to load workspace: $e',
                  style: plexMono(fontSize: 12.5, color: brandAccent),
                ),
                data: (ws) => MetadataForm(
                  key: _formKey,
                  meta: meta,
                  workspace: ws,
                  saver: ref.read(workspaceSaverFactoryProvider)(
                    meta.workspacePath,
                  ),
                  onSaved: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Saved')),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),

              // ── Collapsible file-info panel ──────────────────────────────
              _FileInfoPanel(
                meta: meta,
                expanded: _fileInfoExpanded,
                onToggle: () =>
                    setState(() => _fileInfoExpanded = !_fileInfoExpanded),
              ),
              const SizedBox(height: 16),

              // ── Action row: Save + Delete ────────────────────────────────
              Row(
                children: [
                  QuietButton(
                    label: 'Save',
                    filled: true,
                    onPressed: () => _formKey.currentState?.save(),
                  ),
                  const Spacer(),
                  QuietButton(
                    label: 'Delete…',
                    emphasis: ButtonEmphasis.alert,
                    icon: Icons.delete_outline,
                    onPressed: () => _confirmDelete(meta, displayVenue),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Formats the card header: `<venue> · <date> · <time>`.
  String _title(SessionMetadata meta, String displayVenue) {
    final dt =
        DateTime.fromMillisecondsSinceEpoch(meta.createdTimestampMs).toLocal();
    final fmt = DateFormat('yyyy-MM-dd · HH:mm');
    final venue = displayVenue.isEmpty ? '(no venue)' : displayVenue;
    return '$venue · ${fmt.format(dt)}';
  }

  /// Opens the scoped delete confirmation dialog and, on confirmation,
  /// delegates to [RunsNotifier.deleteSession] then clears the detail panel.
  Future<void> _confirmDelete(SessionMetadata meta, String displayVenue) async {
    final isSignedIn = ref.read(driveSyncProvider).isSignedIn;
    final scope = await showDialog<DeleteScope>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this session?'),
        content: Text(_title(meta, displayVenue)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(DeleteScope.appOnly),
            child: const Text('Remove from app'),
          ),
          Tooltip(
            message: isSignedIn
                ? ''
                : 'Sign in to Drive in Settings to delete the remote copy',
            child: FilledButton.tonal(
              onPressed: isSignedIn
                  ? () => Navigator.of(ctx).pop(DeleteScope.everywhere)
                  : null,
              child: const Text('Delete everywhere'),
            ),
          ),
        ],
      ),
    );
    if (scope == null) return;
    try {
      await ref
          .read(runsProvider.notifier)
          .deleteSession(meta.sessionId, scope: scope);
      if (!mounted) return;
      ref.read(detailSelectionProvider.notifier).clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }
}

/// Collapsible file-info panel showing path, size, source, creation
/// timestamp, and device ID for the given [SessionMetadata].
class _FileInfoPanel extends StatelessWidget {
  const _FileInfoPanel({
    required this.meta,
    required this.expanded,
    required this.onToggle,
  });

  final SessionMetadata meta;

  /// Whether the panel body is currently visible.
  final bool expanded;

  /// Called when the user taps the expand/collapse affordance.
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(
                  expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 16,
                  color: brandFgDim,
                ),
                const SizedBox(width: 4),
                Text(
                  'FILE INFO',
                  style: plexMono(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: brandFgDim,
                    letterSpacing: brandLabelTracking,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (expanded) ...[
          _pathRow(context),
          _row(
            'Size',
            // fileSizeBytes converted to MB for display.
            '${(meta.fileSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB',
          ),
          _row('Source', meta.sourceType.name),
          _row(
            'Created',
            DateTime.fromMillisecondsSinceEpoch(meta.createdTimestampMs)
                .toLocal()
                .toString(),
          ),
          _row('Device', meta.deviceId),
        ],
      ],
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 70,
              child: Text(
                label,
                style: plexMono(fontSize: 11.5, color: brandFgDim),
              ),
            ),
            Expanded(
              child: SelectableText(
                value,
                style: plexMono(fontSize: 11.5, color: brandFg),
              ),
            ),
          ],
        ),
      );

  /// The Path row — the file path rendered as selectable (highlight/copy) text
  /// with two quick actions: copy-to-clipboard (all platforms) and reveal in
  /// the host file manager (desktop only, gated by [_canRevealInFileManager]).
  Widget _pathRow(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 70,
              child: Text(
                'Path',
                style: plexMono(fontSize: 11.5, color: brandFgDim),
              ),
            ),
            Expanded(
              child: SelectableText(
                meta.filePath,
                style: plexMono(fontSize: 11.5, color: brandFg),
              ),
            ),
            _RowAction(
              icon: Icons.content_copy,
              tooltip: 'Copy path',
              onTap: () => _copyPath(context),
            ),
            if (_canRevealInFileManager)
              _RowAction(
                icon: Icons.folder_open_outlined,
                tooltip: _revealTooltip,
                onTap: () => _reveal(context),
              ),
          ],
        ),
      );

  /// Whether this platform can reveal a file in a desktop file manager.
  bool get _canRevealInFileManager =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// Platform-appropriate tooltip for the reveal-in-file-manager action.
  String get _revealTooltip {
    if (Platform.isWindows) return 'Show in Explorer';
    if (Platform.isMacOS) return 'Reveal in Finder';
    return 'Open containing folder';
  }

  /// Copies the session file's absolute path to the clipboard.
  Future<void> _copyPath(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: meta.filePath));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Path copied to clipboard')),
    );
  }

  /// Reveals the session file in the host file manager, surfacing a snackbar on
  /// failure (e.g. the file manager binary is unavailable).
  Future<void> _reveal(BuildContext context) async {
    try {
      await revealInFileManager(meta.filePath);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open file manager: $e')),
      );
    }
  }
}

/// Reveals [filePath] in the host operating system's file manager, selecting
/// the file itself where the platform supports it.
///
/// * **Windows** — `explorer /select,<path>` highlights the file in its folder.
///   (Explorer exits non-zero even on success, so its exit code is ignored.)
/// * **macOS** — `open -R <path>` reveals the file in Finder.
/// * **Linux** — no portable "select this file" verb exists, so the file's
///   containing directory is opened with `xdg-open`.
///
/// Desktop-only. Throws [UnsupportedError] on mobile/web so callers can gate
/// the affordance behind a platform check (see [_FileInfoPanel._pathRow]).
Future<void> revealInFileManager(String filePath) async {
  if (Platform.isWindows) {
    // explorer /select rejects forward slashes — normalise to backslashes.
    // The flag and path must be ONE argument (`/select,<path>`); split across
    // two tokens, explorer drops the selection and just opens the folder.
    final winPath = filePath.replaceAll('/', r'\');
    await Process.run('explorer', ['/select,$winPath']);
    return;
  }
  if (Platform.isMacOS) {
    await Process.run('open', ['-R', filePath]);
    return;
  }
  if (Platform.isLinux) {
    await Process.run('xdg-open', [File(filePath).parent.path]);
    return;
  }
  throw UnsupportedError('Reveal in file manager is not supported here');
}

/// A compact, low-prominence icon button for the file-info row quick actions
/// (copy path, reveal in file manager). Sized to sit inline with an 11.5 px
/// mono value row without inflating its height.
class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  /// Glyph shown in the button.
  final IconData icon;

  /// Hover/long-press tooltip describing the action.
  final String tooltip;

  /// Tap callback.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
        icon: Icon(icon, size: 15),
        tooltip: tooltip,
        color: brandFgDim,
        hoverColor: brandInfo.withValues(alpha: 0.12),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        constraints: const BoxConstraints(minWidth: 28, minHeight: 24),
        onPressed: onTap,
      );
}
