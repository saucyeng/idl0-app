import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/bike_profile.dart';
import '../../../providers/profile_provider.dart';

/// "New profile" dialog — name + duplicate-active toggle.
class NewProfileDialog extends ConsumerStatefulWidget {
  /// Creates a [NewProfileDialog].
  const NewProfileDialog({super.key});

  @override
  ConsumerState<NewProfileDialog> createState() => _NewProfileDialogState();
}

class _NewProfileDialogState extends ConsumerState<NewProfileDialog> {
  final _controller = TextEditingController();
  bool _duplicateActive = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New profile'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Profile name'),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            value: _duplicateActive,
            onChanged: (v) => setState(() => _duplicateActive = v ?? false),
            title: const Text('Duplicate the active profile'),
            contentPadding: EdgeInsets.zero,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _create,
          child: const Text('Create'),
        ),
      ],
    );
  }

  Future<void> _create() async {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    final lib = await ref.read(profileProvider.future);
    final newId = await ref.read(profileProvider.notifier).create(
          name,
          duplicateOfId: _duplicateActive ? lib.activeProfileId : null,
        );
    await ref.read(profileProvider.notifier).setActive(newId);
    if (mounted) Navigator.pop(context);
  }
}

/// "Rename profile" dialog.
class _RenameProfileDialog extends ConsumerStatefulWidget {
  const _RenameProfileDialog({required this.profile});
  final BikeProfile profile;

  @override
  ConsumerState<_RenameProfileDialog> createState() =>
      _RenameProfileDialogState();
}

class _RenameProfileDialogState extends ConsumerState<_RenameProfileDialog> {
  late final _controller =
      TextEditingController(text: widget.profile.profileName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename profile'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Profile name'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            final name = _controller.text.trim();
            if (name.isEmpty) return;
            await ref
                .read(profileProvider.notifier)
                .rename(widget.profile.profileId, name);
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Shows the bottom-sheet of profile actions (Rename / Duplicate / Delete /
/// Import / Export) attached to [active].
Future<void> showProfileActionsSheet(
  BuildContext context,
  WidgetRef ref,
  BikeProfile? active,
) async {
  if (active == null) return;
  await showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('Rename'),
            onTap: () {
              Navigator.pop(ctx);
              showDialog<void>(
                context: context,
                builder: (_) => _RenameProfileDialog(profile: active),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('Duplicate'),
            onTap: () async {
              Navigator.pop(ctx);
              final newId = await ref.read(profileProvider.notifier).create(
                    '${active.profileName} (copy)',
                    duplicateOfId: active.profileId,
                  );
              await ref.read(profileProvider.notifier).setActive(newId);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete'),
            onTap: () async {
              Navigator.pop(ctx);
              final ok = await showDialog<bool>(
                    context: context,
                    builder: (dialogCtx) => AlertDialog(
                      title: const Text('Delete profile?'),
                      content: Text('"${active.profileName}" will be removed.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogCtx, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(dialogCtx, true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  ) ??
                  false;
              if (!ok) return;
              try {
                await ref
                    .read(profileProvider.notifier)
                    .delete(active.profileId);
              } on StateError {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Cannot delete the last profile'),
                    ),
                  );
                }
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('Import from file'),
            onTap: () async {
              Navigator.pop(ctx);
              final r = await FilePicker.platform.pickFiles(
                allowedExtensions: ['idl0p', 'json'],
                type: FileType.custom,
              );
              final path = r?.files.single.path;
              if (path == null) return;
              await ref.read(profileProvider.notifier).importFromFile(path);
            },
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('Export to file'),
            onTap: () async {
              Navigator.pop(ctx);
              final dir = await FilePicker.platform.getDirectoryPath();
              if (dir == null) return;
              await ref.read(profileProvider.notifier).exportToFile(
                    active.profileId,
                    '$dir/${active.profileName}.idl0p',
                  );
            },
          ),
        ],
      ),
    ),
  );
}
