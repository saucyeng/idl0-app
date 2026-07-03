import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../data/math_channel.dart';
import '../../../providers/math_channel_provider.dart';
import '../../brand/brand.dart';
import '../../widgets/grouped_channel_list.dart';

// ---------------------------------------------------------------------------
// Function catalogue — §10 function table
// ---------------------------------------------------------------------------

/// One entry in the function insert panel.
class _FunctionEntry {
  final String name;

  /// Full call signature pasted on Insert, e.g. `integrate(ch)`.
  final String insertText;
  final String category;

  const _FunctionEntry(this.name, this.insertText, this.category);
}

const _kFunctions = [
  // Filters
  _FunctionEntry('butter', 'butter(order, cutoff, type, ch)', 'Filters'),
  _FunctionEntry('sosfilt', 'sosfilt(sos, ch)', 'Filters'),
  // Reconstruction
  _FunctionEntry('declip', 'declip(ch)', 'Reconstruction'),
  // Time-domain
  _FunctionEntry('integrate', 'integrate(ch)', 'Time-domain'),
  _FunctionEntry('differentiate', 'differentiate(ch)', 'Time-domain'),
  _FunctionEntry('rms', 'rms(ch, w)', 'Time-domain'),
  _FunctionEntry('mean', 'mean(ch, w)', 'Time-domain'),
  _FunctionEntry('std', 'std(ch, w)', 'Time-domain'),
  _FunctionEntry('median', 'median(ch, w)', 'Time-domain'),
  // Frequency
  _FunctionEntry('fft', 'fft(ch, window)', 'Frequency'),
  _FunctionEntry('spectrogram', 'spectrogram(ch)', 'Frequency'),
  _FunctionEntry('hilbert', 'hilbert(ch)', 'Frequency'),
  // Correlation
  _FunctionEntry('correlate', 'correlate(a, b)', 'Correlation'),
  _FunctionEntry('convolve', 'convolve(ch, kernel)', 'Correlation'),
  // Resampling
  _FunctionEntry('resample', 'resample(ch, hz)', 'Resampling'),
  // Math
  _FunctionEntry('abs', 'abs(ch)', 'Math'),
  _FunctionEntry('sqrt', 'sqrt(ch)', 'Math'),
  _FunctionEntry('pow', 'pow(ch, n)', 'Math'),
  _FunctionEntry('sign', 'sign(ch)', 'Math'),
  _FunctionEntry('min', 'min(a, b)', 'Math'),
  _FunctionEntry('max', 'max(a, b)', 'Math'),
  _FunctionEntry('clamp', 'clamp(ch, low, high)', 'Math'),
  _FunctionEntry('floor', 'floor(ch)', 'Math'),
  _FunctionEntry('ceil', 'ceil(ch)', 'Math'),
  _FunctionEntry('round', 'round(ch)', 'Math'),
  // Trig
  _FunctionEntry('sin', 'sin(ch)', 'Trig'),
  _FunctionEntry('cos', 'cos(ch)', 'Trig'),
  _FunctionEntry('tan', 'tan(ch)', 'Trig'),
  _FunctionEntry('asin', 'asin(ch)', 'Trig'),
  _FunctionEntry('acos', 'acos(ch)', 'Trig'),
  _FunctionEntry('atan', 'atan(ch)', 'Trig'),
  _FunctionEntry('atan2', 'atan2(y, x)', 'Trig'),
  _FunctionEntry('sinh', 'sinh(ch)', 'Trig'),
  _FunctionEntry('cosh', 'cosh(ch)', 'Trig'),
  _FunctionEntry('tanh', 'tanh(ch)', 'Trig'),
  _FunctionEntry('deg2rad', 'deg2rad(ch)', 'Trig'),
  _FunctionEntry('rad2deg', 'rad2deg(ch)', 'Trig'),
  // Logic
  _FunctionEntry('if', 'if(cond, t, f)', 'Logic'),
  _FunctionEntry('and', ' and ', 'Logic'),
  _FunctionEntry('or', ' or ', 'Logic'),
  _FunctionEntry('not', 'not ', 'Logic'),
  // Lap (read lap/sector gates from workspace)
  _FunctionEntry('current_lap', 'current_lap()', 'Lap'),
  _FunctionEntry('lap_start_time', 'lap_start_time(n)', 'Lap'),
  _FunctionEntry('lap_start_distance', 'lap_start_distance(n)', 'Lap'),
  _FunctionEntry('sector_number', 'sector_number()', 'Lap'),
  // Variance (ghost-lap comparison)
  _FunctionEntry('variance_time', 'variance_time(ch)', 'Variance'),
  _FunctionEntry('variance_dist', 'variance_dist(ch)', 'Variance'),
];

// ---------------------------------------------------------------------------
// InsertPanels
// ---------------------------------------------------------------------------

/// Three insert panels — Channels, Functions, Constants — that paste text at
/// the cursor position in [controller].
///
/// On wide screens (width > 700 dp) the three panels are shown as columns.
/// On narrow screens they collapse to a [TabBar] + [TabBarView]. See §15.4.
class InsertPanels extends ConsumerStatefulWidget {
  /// The expression [TextEditingController] to insert text into.
  final TextEditingController controller;

  /// Names of channels available in the current context (session channels +
  /// other math channel names). Used to populate the Channels panel.
  final List<String> availableChannels;

  /// Creates [InsertPanels].
  const InsertPanels({
    super.key,
    required this.controller,
    required this.availableChannels,
  });

  @override
  ConsumerState<InsertPanels> createState() => _InsertPanelsState();
}

class _InsertPanelsState extends ConsumerState<InsertPanels> {
  /// Index of the active panel in the narrow-screen segmented switcher
  /// (0 = Channels, 1 = Functions, 2 = Constants). Ignored on wide screens.
  int _selectedTab = 0;

  void _insertAtCursor(String text) {
    final ctrl = widget.controller;
    final sel = ctrl.selection;
    final current = ctrl.text;
    final offset = sel.isValid ? sel.baseOffset : current.length;
    final newText = MathChannelValidator.insertAtOffset(current, offset, text);
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: offset + text.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width > 700;

    final channelsPanel = _ChannelsPanel(
      availableChannels: widget.availableChannels,
      onInsert: _insertAtCursor,
    );
    final functionsPanel = _FunctionsPanel(onInsert: _insertAtCursor);
    final constantsPanel = _ConstantsPanel(onInsert: _insertAtCursor);

    if (isWide) {
      return SizedBox(
        height: 200,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _PanelCard(title: 'CHANNELS', child: channelsPanel),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _PanelCard(title: 'FUNCTIONS', child: functionsPanel),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _PanelCard(title: 'CONSTANTS', child: constantsPanel),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        BrandSegmented<int>(
          selected: _selectedTab,
          onChanged: (v) => setState(() => _selectedTab = v),
          segments: const [
            BrandSegment(value: 0, label: 'Channels'),
            BrandSegment(value: 1, label: 'Functions'),
            BrandSegment(value: 2, label: 'Constants'),
          ],
        ),
        const SizedBox(height: 8),
        // IndexedStack keeps all three panels alive (search query, scroll
        // position) when switching segments — swipe-between-tabs is dropped.
        SizedBox(
          height: 180,
          child: _PanelCard(
            title: const ['CHANNELS', 'FUNCTIONS', 'CONSTANTS'][_selectedTab],
            child: IndexedStack(
              index: _selectedTab,
              sizing: StackFit.expand,
              children: [channelsPanel, functionsPanel, constantsPanel],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Panel card wrapper
// ---------------------------------------------------------------------------

class _PanelCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _PanelCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border.fromBorderSide(
          BorderSide(color: brandRule, width: brandHairlineWidth),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 6),
            child: Row(
              children: [
                Container(width: 3, height: 10, color: brandAccent),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: plexMono(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: brandFgDim,
                    letterSpacing: brandKickerTracking,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Channels panel
// ---------------------------------------------------------------------------

class _ChannelsPanel extends StatefulWidget {
  final List<String> availableChannels;
  final ValueChanged<String> onInsert;

  const _ChannelsPanel({
    required this.availableChannels,
    required this.onInsert,
  });

  @override
  State<_ChannelsPanel> createState() => _ChannelsPanelState();
}

class _ChannelsPanelState extends State<_ChannelsPanel> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() => _query = _searchCtrl.text));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(4),
          child: TextField(
            controller: _searchCtrl,
            decoration: const InputDecoration(
              hintText: 'Search channels…',
              prefixIcon: Icon(Icons.search, size: 16, color: brandFgDim),
            ),
            style: plexMono(fontSize: 12, color: brandFg),
          ),
        ),
        Expanded(
          child: GroupedChannelList(
            names: widget.availableChannels,
            query: _query,
            rowBuilder: (name) => _InsertRow(
              label: name,
              onInsert: () => widget.onInsert('[$name]'),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Functions panel
// ---------------------------------------------------------------------------

class _FunctionsPanel extends StatelessWidget {
  final ValueChanged<String> onInsert;

  const _FunctionsPanel({required this.onInsert});

  @override
  Widget build(BuildContext context) {
    String? currentCategory;
    final items = <Widget>[];

    for (final fn in _kFunctions) {
      if (fn.category != currentCategory) {
        currentCategory = fn.category;
        items.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 0, 2),
            child: Text(
              fn.category.toUpperCase(),
              style: plexMono(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: brandFgDim,
                letterSpacing: brandLabelTracking,
              ),
            ),
          ),
        );
      }
      items.add(
        _InsertRow(
          label: fn.insertText,
          onInsert: () => onInsert(fn.insertText),
        ),
      );
    }

    return ListView(children: items);
  }
}

// ---------------------------------------------------------------------------
// Constants panel
// ---------------------------------------------------------------------------

class _ConstantsPanel extends ConsumerWidget {
  final ValueChanged<String> onInsert;

  const _ConstantsPanel({required this.onInsert});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final constants = ref.watch(mathChannelProvider).constants;

    return Column(
      children: [
        Expanded(
          child: constants.isEmpty
              ? Center(
                  child: Text(
                    'No constants yet',
                    style: plexMono(color: brandFgDim, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  itemCount: constants.length,
                  itemExtent: 32,
                  itemBuilder: (_, i) {
                    final c = constants[i];
                    return _InsertRow(
                      label: '${c.name} = ${c.value}',
                      onInsert: () => onInsert(c.value.toString()),
                      trailing: IconBtn(
                        icon: Icons.delete_outline,
                        tooltip: 'Delete constant',
                        tint: brandAccent,
                        onPressed: () => ref
                            .read(mathChannelProvider.notifier)
                            .removeConstant(c.id),
                      ),
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(6),
          child: QuietButton(
            label: 'Add constant',
            icon: Icons.add,
            filled: true,
            onPressed: () => _showAddDialog(context, ref),
          ),
        ),
      ],
    );
  }

  void _showAddDialog(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _AddConstantDialog(
        onAdd: (name, value) {
          ref.read(mathChannelProvider.notifier).addConstant(
                MathConstant(
                  id: const Uuid().v4(),
                  name: name,
                  value: value,
                ),
              );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared row widget
// ---------------------------------------------------------------------------

class _InsertRow extends StatelessWidget {
  final String label;
  final VoidCallback onInsert;
  final Widget? trailing;

  const _InsertRow({
    required this.label,
    required this.onInsert,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              label,
              style: plexMono(fontSize: 12, color: brandFg),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (trailing != null) trailing!,
        TextButton(
          onPressed: onInsert,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: const Size(40, 28),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            'INSERT',
            style: plexMono(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: brandFg,
              letterSpacing: brandLabelTracking,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Add constant dialog
// ---------------------------------------------------------------------------

class _AddConstantDialog extends StatefulWidget {
  final void Function(String name, double value) onAdd;

  const _AddConstantDialog({required this.onAdd});

  @override
  State<_AddConstantDialog> createState() => _AddConstantDialogState();
}

class _AddConstantDialogState extends State<_AddConstantDialog> {
  final _nameCtrl = TextEditingController();
  final _valueCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _valueCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        'ADD CONSTANT',
        style: plexMono(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: brandFg,
          letterSpacing: brandLabelTracking,
        ),
      ),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Name'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _valueCtrl,
              decoration: const InputDecoration(labelText: 'Value'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              validator: (v) =>
                  double.tryParse(v ?? '') == null ? 'Must be a number' : null,
            ),
          ],
        ),
      ),
      actions: [
        QuietButton(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        QuietButton(
          label: 'Add',
          filled: true,
          onPressed: () {
            if (_formKey.currentState?.validate() ?? false) {
              widget.onAdd(
                _nameCtrl.text.trim(),
                double.parse(_valueCtrl.text),
              );
              Navigator.of(context).pop();
            }
          },
        ),
      ],
    );
  }
}
