import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/math_channel.dart';
import '../../../providers/math_channel_provider.dart';
import '../../brand/brand.dart';
import 'channel_metadata_bar.dart';
import 'chip/chip_expression_editor.dart';
import 'expression_editor.dart';
import 'expression_preview.dart';
import 'insert_panels.dart';

/// Tab 3 — Math channel expression editor.
///
/// Left/top: scrollable channel list with + and template buttons.
/// Right/bottom: metadata bar, expression editor, preview, and insert panels
/// for the active channel.
///
/// On wide screens (>700 dp) the two panes sit side by side in a [Row].
/// On narrow screens they stack vertically in a scrollable [Column].
/// See §15.4.
class MathsTab extends ConsumerStatefulWidget {
  /// Creates a [MathsTab].
  const MathsTab({super.key});

  @override
  ConsumerState<MathsTab> createState() => _MathsTabState();
}

class _MathsTabState extends ConsumerState<MathsTab> {
  final TextEditingController _expressionCtrl = TextEditingController();

  /// ID of the channel whose expression is currently in [_expressionCtrl].
  String? _syncedChannelId;

  /// Editor mode: true = chip-driven "Build" editor, false = raw-text editor.
  /// Both share [_expressionCtrl] so switching is lossless.
  bool _chipMode = true;

  @override
  void dispose() {
    _expressionCtrl.dispose();
    super.dispose();
  }

  /// Validates [expr] and persists it to the channel with [id]. Mirrors the
  /// debounced persist path in [ExpressionEditor] so the chip editor writes
  /// through the same provider.
  void _persistExpression(String id, String expr) {
    final available = ref.read(mathExpressionChannelNamesProvider);
    ref.read(mathChannelProvider.notifier).validate(expr, available);
    final channels = ref.read(mathChannelProvider).channels;
    final idx = channels.indexWhere((c) => c.id == id);
    if (idx >= 0) {
      ref.read(mathChannelProvider.notifier).updateChannel(
            channels[idx].copyWith(expression: expr),
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final mathState = ref.watch(mathChannelProvider);

    // Sync expression controller when the active channel changes.
    ref.listen<String?>(
      mathChannelProvider.select((s) => s.activeChannelId),
      (prev, next) {
        if (next == _syncedChannelId) return;
        _syncedChannelId = next;
        if (next == null) {
          _expressionCtrl.text = '';
          return;
        }
        final channels = ref.read(mathChannelProvider).channels;
        final idx = channels.indexWhere((c) => c.id == next);
        if (idx >= 0) _expressionCtrl.text = channels[idx].expression;
      },
    );

    final activeChannel = mathState.activeChannelId != null
        ? mathState.channels.cast<MathChannel?>().firstWhere(
              (c) => c?.id == mathState.activeChannelId,
              orElse: () => null,
            )
        : null;

    final isWide = MediaQuery.sizeOf(context).width > 700;

    final channelList = _ChannelList(
      activeChannelId: mathState.activeChannelId,
    );

    Widget editorArea;
    if (activeChannel == null) {
      editorArea = Center(
        child: Text(
          'SELECT A CHANNEL OR TAP + TO CREATE ONE',
          style: plexMono(
            fontSize: 11,
            color: brandFgDim,
            letterSpacing: brandLabelTracking,
          ),
        ),
      );
    } else {
      final available = ref.watch(mathExpressionChannelNamesProvider);
      editorArea = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChannelMetadataBar(channel: activeChannel),
          const SizedBox(height: 12),
          // Editor mode — chip-driven "Build" vs raw expression "Text".
          Align(
            alignment: Alignment.centerLeft,
            child: BrandSegmented<bool>(
              selected: _chipMode,
              onChanged: (v) => setState(() => _chipMode = v),
              segments: const [
                BrandSegment(value: true, label: 'Build'),
                BrandSegment(value: false, label: 'Text'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_chipMode)
            ChipExpressionEditor(
              key: ValueKey('chip-${activeChannel.id}'),
              activeChannelId: activeChannel.id,
              initialExpression: _expressionCtrl.text,
              availableChannels: available,
              onExpressionChanged: (expr) {
                _expressionCtrl.text = expr;
                _persistExpression(activeChannel.id, expr);
              },
            )
          else ...[
            ExpressionEditor(
              controller: _expressionCtrl,
              activeChannelId: activeChannel.id,
            ),
            const SizedBox(height: 12),
            InsertPanels(
              controller: _expressionCtrl,
              availableChannels: available,
            ),
          ],
          const SizedBox(height: 12),
          const ExpressionPreview(),
        ],
      );
    }

    if (isWide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 240,
            child: SingleChildScrollView(child: channelList),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: editorArea,
            ),
          ),
        ],
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          channelList,
          const Divider(),
          editorArea,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Channel list
// ---------------------------------------------------------------------------

class _ChannelList extends ConsumerWidget {
  final String? activeChannelId;

  const _ChannelList({this.activeChannelId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channels = ref.watch(mathChannelProvider).channels;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Header — quiet section head + a brand '+' new-channel action.
        MinimalSectionHead(
          label: 'Math Channels',
          trailing: IconBtn(
            icon: Icons.add,
            tooltip: 'New channel',
            onPressed: () => _addBlankChannel(ref),
          ),
        ),
        const Divider(height: 1),
        // Channel rows
        if (channels.isEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'NO CHANNELS YET',
              style: plexMono(
                fontSize: 11,
                color: brandFgDim,
                letterSpacing: brandLabelTracking,
              ),
            ),
          ),
        for (final ch in channels)
          ListTile(
            dense: true,
            selected: ch.id == activeChannelId,
            selectedTileColor: brandSurface2,
            leading:
                Icon(Icons.show_chart, size: 18, color: Color(ch.colorValue)),
            title: Text(
              ch.name.toUpperCase(),
              style: plexMono(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: brandFg,
                letterSpacing: 0.6,
              ),
            ),
            subtitle: Text(
              ch.units,
              style: plexMono(fontSize: 11, color: brandFgDim),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconBtn(
                  icon: Icons.copy_outlined,
                  tooltip: 'Duplicate',
                  onPressed: () => ref
                      .read(mathChannelProvider.notifier)
                      .duplicateChannel(ch.id),
                ),
                IconBtn(
                  icon: Icons.delete_outline,
                  tooltip: 'Delete',
                  tint: brandAccent,
                  onPressed: () => ref
                      .read(mathChannelProvider.notifier)
                      .deleteChannel(ch.id),
                ),
              ],
            ),
            onTap: () =>
                ref.read(mathChannelProvider.notifier).setActiveChannel(ch.id),
          ),
        const Divider(height: 1),
        // Templates
        _TemplateSection(),
      ],
    );
  }

  void _addBlankChannel(WidgetRef ref) {
    final ch = MathChannel(
      id: const Uuid().v4(),
      name: 'New channel',
      quantity: '',
      units: '',
      sampleRateHz: 0.0,
      decimalPlaces: 3,
      color: '#FF2196F3',
      expression: '',
    );
    ref.read(mathChannelProvider.notifier).addChannel(ch);
    ref.read(mathChannelProvider.notifier).setActiveChannel(ch.id);
  }
}

// ---------------------------------------------------------------------------
// Templates section
// ---------------------------------------------------------------------------

class _TemplateSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templates = MathChannelLibrary.shipped.templates;

    return ExpansionTile(
      dense: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
      title: Text(
        'TEMPLATES',
        style: plexMono(
          fontSize: 11,
          color: brandFgDim,
          letterSpacing: brandLabelTracking,
        ),
      ),
      children: [
        for (final tpl in templates)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            leading: Icon(
              Icons.add_circle_outline,
              size: 16,
              color: Color(tpl.colorValue),
            ),
            title: Text(
              tpl.name.toUpperCase(),
              style: plexMono(fontSize: 12, color: brandFg),
            ),
            onTap: () => _addFromTemplate(ref, tpl),
          ),
      ],
    );
  }

  void _addFromTemplate(WidgetRef ref, MathChannel template) {
    final ch = template.copyWith(id: const Uuid().v4());
    ref.read(mathChannelProvider.notifier).addChannel(ch);
    ref.read(mathChannelProvider.notifier).setActiveChannel(ch.id);
  }
}
