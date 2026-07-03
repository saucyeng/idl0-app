import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/workbook_provider.dart';
import '../../brand/brand.dart';

/// Per-workbook sync settings dialog. Spec §8.4.
class WorkbookSyncSettingsDialog extends ConsumerStatefulWidget {
  /// Creates a [WorkbookSyncSettingsDialog].
  const WorkbookSyncSettingsDialog({
    super.key,
    required this.workbookId,
    required this.workbookName,
  });

  /// UUID of the workbook whose sync settings are being edited.
  final String workbookId;

  /// Display name — shown in the title.
  final String workbookName;

  @override
  ConsumerState<WorkbookSyncSettingsDialog> createState() =>
      _WorkbookSyncSettingsDialogState();
}

class _WorkbookSyncSettingsDialogState
    extends ConsumerState<WorkbookSyncSettingsDialog> {
  late final TextEditingController _debounceCtrl;

  @override
  void initState() {
    super.initState();
    final config = ref.read(workbookSyncConfigProvider(widget.workbookId));
    _debounceCtrl =
        TextEditingController(text: (config.debounceMs ~/ 1000).toString());
  }

  @override
  void dispose() {
    _debounceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(workbookSyncConfigProvider(widget.workbookId));
    final notifier =
        ref.read(workbookSyncConfigProvider(widget.workbookId).notifier);

    return AlertDialog(
      title: Text(
        'Sync settings — ${widget.workbookName}',
        style: plexMono(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: brandFg,
        ),
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Sync this workbook to Drive',
                    style: plexMono(fontSize: 14, color: brandFg),
                  ),
                ),
                Switch(
                  value: config.enabled,
                  onChanged: notifier.setEnabled,
                  activeThumbColor: brandGood,
                  activeTrackColor: brandGood,
                  inactiveThumbColor: brandControlFill,
                  inactiveTrackColor: brandRule,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Drive upload delay (seconds)',
                    style: plexMono(fontSize: 14, color: brandFg),
                  ),
                ),
                SizedBox(
                  width: 72,
                  child: TextField(
                    controller: _debounceCtrl,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.end,
                    style: plexMono(fontSize: 14, color: brandFg),
                    cursorColor: brandFg,
                    decoration: const InputDecoration(isDense: true),
                    onSubmitted: (v) {
                      final s = int.tryParse(v);
                      if (s == null) return;
                      final clamped = s.clamp(1, 600);
                      notifier.setDebounceMs(clamped * 1000);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: QuietButton(
                label: 'Force sync now',
                icon: Icons.cloud_upload,
                onPressed: () async {
                  await ref
                      .read(workbookProvider.notifier)
                      .flushPendingUploads();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Force sync triggered')),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        QuietButton(
          label: 'Done',
          filled: true,
          onPressed: () {
            // Commit the debounce edit if the user pressed Done without
            // first hitting Enter on the field.
            final s = int.tryParse(_debounceCtrl.text);
            if (s != null) {
              final clamped = s.clamp(1, 600);
              notifier.setDebounceMs(clamped * 1000);
            }
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }
}
