import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/profile_provider.dart';
import 'profile_dialogs.dart';

/// Top-of-Device-tab profile picker.
///
/// Dropdown of profiles, `+` to create, kebab for rename/duplicate/delete/
/// import/export. Below the controls, a one-line summary of the active
/// profile's bike + rider.
class ProfileBar extends ConsumerWidget {
  /// Creates a [ProfileBar].
  const ProfileBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final libAsync = ref.watch(profileProvider);
    return libAsync.when(
      loading: () => const SizedBox(
        height: 56,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => SizedBox(
        height: 56,
        child: Center(child: Text('Profiles error: $e')),
      ),
      data: (lib) {
        final active = lib.activeProfile;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Profile:'),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: active?.profileId,
                      items: [
                        for (final p in lib.profiles)
                          DropdownMenuItem(
                            value: p.profileId,
                            child: Text(
                              p.profileName.isEmpty
                                  ? '(unnamed)'
                                  : p.profileName,
                            ),
                          ),
                      ],
                      onChanged: (id) {
                        if (id != null) {
                          ref.read(profileProvider.notifier).setActive(id);
                        }
                      },
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'New profile',
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => const NewProfileDialog(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.more_vert),
                    tooltip: 'Profile actions',
                    onPressed: () =>
                        showProfileActionsSheet(context, ref, active),
                  ),
                ],
              ),
              if (active != null) _ActiveSummary(active.config),
            ],
          ),
        );
      },
    );
  }
}

class _ActiveSummary extends StatelessWidget {
  const _ActiveSummary(this.config);
  final Map<String, dynamic> config;

  @override
  Widget build(BuildContext context) {
    final bp = (config['bike_profile'] as Map<String, dynamic>?) ?? const {};
    final bike = (bp['name'] as String?)?.trim();
    final rider = (bp['default_rider'] as String?)?.trim();
    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 2),
      child: Text(
        'Bike: ${bike?.isNotEmpty == true ? bike : '(unset)'}'
        '  ·  '
        'Rider: ${rider?.isNotEmpty == true ? rider : '(unset)'}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}
