import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/mode.dart';
import '../../../providers/mode_controller.dart';
import '../../../providers/sync_controller.dart';

/// Full-screen device-file Sync screen (§24). Pushed from the Data tab's
/// "Sync" button. Lists device files, shows NEW / IN LIBRARY status, and
/// runs the sequential download queue. Auto-starts when the
/// `autoSyncOnOpen` setting is on.
///
/// Owns the WiFi-mode gate: when the device is not in [Mode.wifi] it shows a
/// "Switch to WiFi mode" prompt (the file APIs require WiFi mode). It does
/// NOT bind/release the WiFi network itself — the [ModeController] owns that
/// lifecycle (see WifiService docs).
class SyncScreen extends ConsumerStatefulWidget {
  /// Creates a [SyncScreen].
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initSync());
  }

  Future<void> _initSync() async {
    if (ref.read(modeProvider) != Mode.wifi) return;
    final controller = ref.read(syncControllerProvider.notifier);
    if (ref.read(syncControllerProvider).entries.isEmpty) {
      await controller.list();
    }
    if (!mounted) return;
    // Connect-and-forget: only when the user opted in. Default is the picker.
    if (controller.shouldAutoSync &&
        ref.read(syncControllerProvider).newCount > 0) {
      await controller.syncAllNew();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(modeProvider);
    final state = ref.watch(syncControllerProvider);
    final controller = ref.read(syncControllerProvider.notifier);
    final syncing = state.phase == SyncPhase.syncing;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Device Files'),
        actions: [
          if (syncing)
            TextButton(
              onPressed: controller.stop,
              child: const Text('Stop'),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Reload',
              onPressed: controller.list,
            ),
        ],
      ),
      body: _body(mode, state, controller),
    );
  }

  Widget _body(Mode mode, SyncState state, SyncController controller) {
    if (mode != Mode.wifi) return const _WifiGate();
    if (state.phase == SyncPhase.listing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.phase == SyncPhase.error) {
      return _ListError(message: state.listError, onRetry: controller.list);
    }
    if (state.entries.isEmpty) {
      return const Center(child: Text('No files on device.'));
    }
    return Column(
      children: [
        _SyncBanner(state: state, onSync: controller.sync),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: state.entries.length,
            itemBuilder: (_, i) => _EntryTile(
              entry: state.entries[i],
              onToggle: () => controller.toggle(state.entries[i].file.name),
            ),
          ),
        ),
      ],
    );
  }
}

/// Top banner: "Sync N new" button (idle) or progress summary (syncing).
class _SyncBanner extends StatelessWidget {
  const _SyncBanner({required this.state, required this.onSync});

  final SyncState state;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    if (state.phase == SyncPhase.syncing) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text('Syncing — ${state.doneCount} of ${state.batchTotal} done'),
            const Spacer(),
            Text(
              '${state.queuedCount} queued',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }
    final newCount = state.newCount;
    if (newCount == 0) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('All device files are in your library.'),
      );
    }
    // Picker: download the checked files. Selection-driven, unchecked default.
    final selected = state.queuedCount;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$newCount new on device',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.download),
            label: Text(selected > 0 ? 'Download ($selected)' : 'Download'),
            onPressed: selected > 0 ? onSync : null,
          ),
        ],
      ),
    );
  }
}

/// One checklist row.
class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.onToggle});

  final SyncEntry entry;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final sizeMb = (entry.file.size / (1024 * 1024)).toStringAsFixed(1);
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      minVerticalPadding: 0,
      horizontalTitleGap: 8,
      leading: _leading(),
      title: Text(entry.file.name, style: const TextStyle(fontSize: 13)),
      subtitle: _subtitle(sizeMb),
      trailing: _badge(),
    );
  }

  Widget _leading() {
    switch (entry.status) {
      case SyncEntryStatus.downloading:
        return const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case SyncEntryStatus.done:
      case SyncEntryStatus.inLibrary:
        return const Icon(Icons.check, size: 20, color: Colors.green);
      case SyncEntryStatus.error:
        return const Icon(Icons.error_outline, size: 20, color: Colors.red);
      case SyncEntryStatus.newPending:
      case SyncEntryStatus.unknownIdentity:
        return Checkbox(value: entry.selected, onChanged: (_) => onToggle());
    }
  }

  Widget _subtitle(String sizeMb) {
    if (entry.status == SyncEntryStatus.downloading) {
      final mb = (entry.receivedBytes / (1024 * 1024)).toStringAsFixed(1);
      final pct = (entry.progress * 100).round();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$mb / $sizeMb MB · $pct%',
            style: const TextStyle(fontSize: 11),
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: entry.progress),
        ],
      );
    }
    if (entry.status == SyncEntryStatus.error) {
      return Text(
        entry.errorMessage ?? 'Failed',
        style: const TextStyle(fontSize: 11, color: Colors.red),
      );
    }
    return Text('$sizeMb MB', style: const TextStyle(fontSize: 12));
  }

  Widget? _badge() {
    final String text;
    final Color color;
    switch (entry.status) {
      case SyncEntryStatus.newPending:
        text = 'NEW';
        color = const Color(0xFF2E7D32);
      case SyncEntryStatus.unknownIdentity:
        text = 'NEW?';
        color = const Color(0xFFE65100);
      case SyncEntryStatus.inLibrary:
        text = 'IN LIBRARY';
        color = Colors.grey;
      case SyncEntryStatus.done:
        text = 'DONE';
        color = Colors.grey;
      case SyncEntryStatus.downloading:
      case SyncEntryStatus.error:
        return null;
    }
    return Text(
      text,
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        color: color,
      ),
    );
  }
}

/// WiFi-mode gate (moved from the old DownloadPanel).
class _WifiGate extends ConsumerWidget {
  const _WifiGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transition = ref.watch(modeControllerProvider);
    final switching = transition.phase != TransitionPhase.idle &&
        transition.target == Mode.wifi;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            const Text(
              'WiFi mode required to load files.',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: switching
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi),
              label: Text(
                switching ? 'Bringing up WiFi…' : 'Switch to WiFi mode',
              ),
              onPressed: switching
                  ? null
                  : () => ref
                      .read(modeControllerProvider.notifier)
                      .switchTo(Mode.wifi),
            ),
            if (!Platform.isAndroid) ...[
              const SizedBox(height: 16),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Join the device WiFi from system settings first. '
                  'This platform cannot auto-connect.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Listing-failure view with a retry button.
class _ListError extends StatelessWidget {
  const _ListError({required this.message, required this.onRetry});

  final String? message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(
              'Could not reach device.\n${message ?? ""}',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      );
}
