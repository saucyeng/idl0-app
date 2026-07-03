import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/device_provider.dart';
import '../../../providers/mode.dart';
import '../../../providers/mode_controller.dart';
import '../../../providers/sync_controller.dart';
import '../../brand/brand.dart';
import '../data/sync_screen.dart';

/// Card 1 entry to device file sync (§23/§24). Tapping auto-enters WiFi mode
/// (the file APIs need the AP up), opens the [SyncScreen], and drops back to
/// idle when the user returns. The `(N new)` badge reflects how many device
/// sessions aren't yet in the library, once a listing has run.
class DeviceFilesEntry extends ConsumerWidget {
  /// Creates a [DeviceFilesEntry].
  const DeviceFilesEntry({super.key});

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    // Auto-enter WiFi (no-op if already there). Refusals surface via the
    // ModeResultListener wrapping the Device tab.
    final result =
        await ref.read(modeControllerProvider.notifier).switchTo(Mode.wifi);
    if (result is! Ok) return;
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SyncScreen()),
    );
    // Returned from the files screen — drop WiFi back to idle.
    await ref.read(modeControllerProvider.notifier).switchTo(Mode.idle);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(deviceProvider.select((s) => s.isConnected));
    final newCount = ref.watch(syncControllerProvider.select((s) => s.newCount));
    return ListTile(
      enabled: connected,
      leading: const Icon(Icons.folder_open, color: brandFg),
      title: const Text('Files'),
      trailing: newCount > 0
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: brandGood,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$newCount new',
                style: plexMono(fontSize: 11, color: brandBg),
              ),
            )
          : const Icon(Icons.chevron_right, color: brandFgDim),
      onTap: connected ? () => _open(context, ref) : null,
    );
  }
}
