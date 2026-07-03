import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/channel_source.dart';
import '../../../data/channel_sources/analog_channel_source.dart';
import '../../../data/channel_sources/digital_source.dart';
import '../../../data/channel_sources/gps_source.dart';
import '../../../data/channel_sources/hrm_source.dart';
import '../../../data/channel_sources/imu_source.dart';
import '../../../data/channel_sources/wheel_source.dart';
import '../../../providers/profile_provider.dart';
import '../../brand/brand.dart';
import 'add_channel_picker.dart';

/// Channel-table body of the Device tab.
///
/// One expandable parent row per [ChannelSource] (IMU0/1/2, GPS, Wheel
/// Speed slots, plus any user-added analog / digital / HRM sources).
/// Per-source dialogs and per-row dialogs are provided by each
/// [ChannelSource] implementation.
class ChannelsTable extends ConsumerStatefulWidget {
  /// Creates a [ChannelsTable].
  const ChannelsTable({super.key});

  @override
  ConsumerState<ChannelsTable> createState() => _ChannelsTableState();
}

class _ChannelsTableState extends ConsumerState<ChannelsTable> {
  /// `sourceKey`s currently expanded.
  final Set<String> _expanded = {};

  @override
  Widget build(BuildContext context) {
    final libAsync = ref.watch(profileProvider);
    return libAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (lib) {
        final active = lib.activeProfile;
        if (active == null) {
          return const Center(child: Text('No active profile'));
        }
        final sources = _buildSources(active.config);
        // On a wide surface (tablet / desktop) the row grid affords a name
        // column; on a phone it does not, so reflow into compact two-liners.
        return LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < _compactBreakpoint;
            return ListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                // The Unit/Scale/Offset columns only carry values on expanded
                // channel rows, so their headers show only when a source is
                // open (wide layout only — compact drops the detail columns).
                _HeaderRow(
                  anyExpanded:
                      sources.any((s) => _expanded.contains(s.sourceKey)),
                  compact: compact,
                ),
                for (final src in sources)
                  _SourceRow(
                    source: src,
                    expanded: _expanded.contains(src.sourceKey),
                    compact: compact,
                    onToggleExpand: () => setState(() {
                      if (_expanded.contains(src.sourceKey)) {
                        _expanded.remove(src.sourceKey);
                      } else {
                        _expanded.add(src.sourceKey);
                      }
                    }),
                  ),
                const Divider(),
                ListTile(
                  leading:
                      const Icon(Icons.add_circle_outline, color: brandGood),
                  title: Text(
                    '+ Add channel…',
                    style: plexMono(fontSize: 13, color: brandFg),
                  ),
                  onTap: () => showAddChannelPicker(context, ref),
                ),
              ],
            );
          },
        );
      },
    );
  }

  List<ChannelSource> _buildSources(Map<String, dynamic> config) {
    final imuCfg = (config['imu'] as Map<String, dynamic>?) ?? const {};
    final gpsCfg = (config['gps'] as Map<String, dynamic>?) ?? const {};
    final wheelCfg =
        (config['wheel_speed'] as Map<String, dynamic>?) ?? const {};
    final analogCfg = (config['analog'] as Map<String, dynamic>?) ?? const {};
    final digitalCfg = (config['digital'] as Map<String, dynamic>?) ?? const {};
    final hrmCfg =
        (config['heart_rate_monitor'] as Map<String, dynamic>?) ?? const {};

    // Hardware-pinned sources — always shown in the table even when
    // disabled. IMUs (0-17) + GPS (24-31) + HRM (22-23). Wheels are
    // not in this list — they're user-added via + Add channel… on the
    // (rare) bikes that have a Hall sensor wired up.
    final out = <ChannelSource>[
      ImuSource(index: 0, imuConfig: imuCfg, channelIdBase: 0),
      ImuSource(index: 1, imuConfig: imuCfg, channelIdBase: 6),
      ImuSource(index: 2, imuConfig: imuCfg, channelIdBase: 12),
      GpsSource(gpsConfig: gpsCfg, channelIdBase: 24),
      HrmSource(hrmConfig: hrmCfg),
    ];

    // Wheel slots: only surface in the table when enabled. The picker's
    // 'wheel_front' / 'wheel_rear' entries flip enabled=true on add.
    for (final slot in const ['front', 'rear']) {
      final slotCfg = (wheelCfg[slot] as Map<String, dynamic>?) ?? const {};
      if ((slotCfg['enabled'] as bool?) == true) {
        out.add(
          WheelSource(
            slot: slot,
            wheelConfig: wheelCfg,
            channelIdBase: slot == 'front' ? 32 : 33,
          ),
        );
      }
    }

    // User-added sources land after the hardware-pinned ones, with stable
    // sequential channel_ids starting at 40.
    var nextId = 40;
    for (final raw in (analogCfg['channels'] as List? ?? const [])) {
      if (raw is! Map<String, dynamic>) continue;
      out.add(
        AnalogChannelSource(
          key: raw['key'] as String,
          analogConfig: analogCfg,
          channelIdBase: nextId++,
        ),
      );
    }
    for (final raw in (digitalCfg['channels'] as List? ?? const [])) {
      if (raw is! Map<String, dynamic>) continue;
      out.add(
        DigitalSource(
          key: raw['key'] as String,
          digitalConfig: digitalCfg,
          channelIdBase: nextId++,
        ),
      );
    }
    return out;
  }
}

// Shared column geometry. Every row — the header, each source (parent), and
// each channel (child) — lays its right-hand cells on this one grid so values
// align into scannable columns. NAME is the only flexible cell, so it absorbs
// the chevron (parent) vs indent (child) difference while RATE / UNIT / SCALE /
// OFFSET / ON stay vertically aligned regardless of nesting; the trailing
// gutter is reserved on every row so the per-source gear never pushes the
// source columns out of line with the header (the old ListTile `trailing` did
// exactly that). UNIT / SCALE / OFFSET only carry values on channel rows.
const double _cLead = 32; // chevron (source) / indent gutter (channel)
const double _cRate =
    56; // sample rate, right-aligned (fits the RATE HZ kicker)
const double _cGap = 14; // gap before the unit/scale/offset block
const double _cUnit = 46; // unit symbol (g / dps / kN)
const double _cScale = 78; // scale factor (e.g. 4.88e-4)
const double _cOffset = 56; // offset (e.g. 0 / -1.5)
const double _cColGap = 12; // breathing room between unit / scale / offset
const double _cOn = 36; // enabled checkbox
const double _cTrail = 44; // per-source settings gear (reserved elsewhere)

/// Below this available width the fixed RATE/UNIT/SCALE/OFFSET columns
/// (~400 px together) leave the flexible NAME cell too little room and the
/// channel name clips. Narrower than this we reflow each row into a compact
/// two-liner (name on its own line, calibration detail on a dim second line);
/// wider, we keep the scannable single-row column grid. Sized so the wide grid
/// still affords a comfortable name column at the threshold (phones land in
/// compact, tablets/desktop in the grid).
const double _compactBreakpoint = 560;

/// Rate label for the compact layout's metadata line. `null` Hz = event-driven.
String _rateLabel(int? hz) => hz != null ? '$hz Hz' : 'event';

/// Compact one-line calibration summary for a channel's second metadata line.
///
/// Reads as the calibration formula `physical = stored × scale + offset`:
/// rate, then the unit (only when the channel has one), then `×scale`, then a
/// signed offset (only when non-zero, so the common zero-offset IMU case stays
/// clean). Keeps the scale/offset detail the wide grid shows in its own columns
/// without the width those columns need.
String _channelMeta(ChannelRow row, int? hz) {
  final parts = <String>[_rateLabel(hz)];
  if (row.units.isNotEmpty) parts.add(row.units);
  parts.add('×${row.scale.toStringAsExponential(2)}');
  if (row.offset != 0) {
    parts.add(row.offset > 0 ? '+${row.offset}' : '${row.offset}');
  }
  return parts.join('  ·  ');
}

/// Enabled indicator for the **On** column — a saturated [brandGood] filled
/// box when on, a dim hollow box when off, and a dash when the source has no
/// channels to enable. Read-only: tap the row to edit (and toggle) the source
/// or channel in its dialog.
Widget _onIndicator({required bool on, bool applicable = true}) {
  if (!applicable) {
    return const Icon(Icons.remove, size: 16, color: brandFgFaint);
  }
  return Icon(
    on ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
    size: 19,
    color: on ? brandGood : brandFgDim,
  );
}

/// Uppercase mono kicker for a Channels-table header cell, clipped to one line
/// so a tracked label never wraps inside its fixed-width column.
Widget _headerCell(String label, {TextAlign align = TextAlign.left}) {
  return Text(
    label.toUpperCase(),
    textAlign: align,
    maxLines: 1,
    overflow: TextOverflow.clip,
    style: plexMono(
      fontSize: 10,
      fontWeight: FontWeight.w500,
      color: brandFgDim,
      letterSpacing: brandLabelTracking,
    ),
  );
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.anyExpanded, required this.compact});

  /// Whether any source is expanded — the Unit/Scale/Offset columns only carry
  /// values on expanded channel rows, so their headers are hidden when
  /// everything is closed. Ignored in [compact] (no detail columns).
  final bool anyExpanded;

  /// Compact (phone) layout — only SOURCE / ON head the two-liner rows.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      // Hairline beneath the kickers separates the header from the table body,
      // matching the TableHeader idiom used elsewhere in the redesign.
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: brandRule, width: brandHairlineWidth),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
      child: compact
          ? Row(
              children: [
                const SizedBox(width: _cLead),
                Expanded(child: _headerCell('Source')),
                SizedBox(
                  width: _cOn,
                  child: _headerCell('On', align: TextAlign.center),
                ),
                const SizedBox(width: _cTrail),
              ],
            )
          : Row(
              children: [
                const SizedBox(width: _cLead),
                Expanded(child: _headerCell('Source')),
                SizedBox(
                  width: _cRate,
                  child: _headerCell('Rate Hz', align: TextAlign.right),
                ),
                const SizedBox(width: _cGap),
                SizedBox(
                  width: _cUnit,
                  child: anyExpanded ? _headerCell('Unit') : null,
                ),
                const SizedBox(width: _cColGap),
                SizedBox(
                  width: _cScale,
                  child: anyExpanded ? _headerCell('Scale') : null,
                ),
                const SizedBox(width: _cColGap),
                SizedBox(
                  width: _cOffset,
                  child: anyExpanded ? _headerCell('Offset') : null,
                ),
                SizedBox(
                  width: _cOn,
                  child: _headerCell('On', align: TextAlign.center),
                ),
                const SizedBox(width: _cTrail),
              ],
            ),
    );
  }
}

class _SourceRow extends ConsumerWidget {
  const _SourceRow({
    required this.source,
    required this.expanded,
    required this.compact,
    required this.onToggleExpand,
  });

  final ChannelSource source;
  final bool expanded;

  /// Compact (phone) two-liner layout vs the wide single-row column grid.
  final bool compact;

  final VoidCallback onToggleExpand;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabledCount = source.channels.where((c) => c.enabled).length;
    final total = source.channels.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        compact
            ? _compactSourceRow(context, ref, enabledCount, total)
            : _wideSourceRow(context, ref, enabledCount, total),
        if (expanded)
          for (final row in source.channels)
            compact
                ? _compactChannelRow(context, ref, row)
                : _wideChannelRow(context, ref, row),
      ],
    );
  }

  /// Per-source settings gear, constrained to the trailing gutter so it never
  /// pushes the row's other cells out of line.
  Widget _gear(BuildContext context, WidgetRef ref) {
    return IconButton(
      icon: const Icon(Icons.settings, color: brandFgDim),
      tooltip: '${source.sourceLabel} settings',
      padding: EdgeInsets.zero,
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: _cTrail, height: 36),
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => source.buildSourceDialog(context, ref),
      ),
    );
  }

  // --- Wide layout (tablet / desktop): one aligned column grid per row. ------

  Widget _wideSourceRow(
    BuildContext context,
    WidgetRef ref,
    int enabledCount,
    int total,
  ) {
    return InkWell(
      onTap: onToggleExpand,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Row(
          children: [
            SizedBox(
              width: _cLead,
              child: Icon(
                expanded ? Icons.expand_more : Icons.chevron_right,
                size: 20,
                color: brandFgDim,
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      source.sourceLabel,
                      overflow: TextOverflow.ellipsis,
                      style: plexMono(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: brandFg,
                      ),
                    ),
                  ),
                  if (total > 0) ...[
                    const SizedBox(width: 8),
                    Text(
                      '$enabledCount/$total',
                      style: plexMono(fontSize: 11, color: brandFgDim),
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(
              width: _cRate,
              child: Text(
                source.sampleRateHz?.toString() ?? 'event',
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: plexMono(fontSize: 13, color: brandFg),
              ),
            ),
            const SizedBox(width: _cGap),
            // Sources carry no per-channel unit / scale / offset — blank.
            const SizedBox(width: _cUnit),
            const SizedBox(width: _cColGap),
            const SizedBox(width: _cScale),
            const SizedBox(width: _cColGap),
            const SizedBox(width: _cOffset),
            SizedBox(
              width: _cOn,
              child: Center(
                child: _onIndicator(on: source.enabled, applicable: total > 0),
              ),
            ),
            SizedBox(width: _cTrail, child: _gear(context, ref)),
          ],
        ),
      ),
    );
  }

  Widget _wideChannelRow(BuildContext context, WidgetRef ref, ChannelRow row) {
    return InkWell(
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => row.buildDialog(context, ref),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        child: Row(
          children: [
            const SizedBox(width: _cLead),
            Expanded(
              // A small NAME-cell indent shows the channel sits under its
              // source without nudging the RATE/UNIT/ON columns, which are
              // fixed-width and align with the header.
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Text(
                  row.channelName,
                  overflow: TextOverflow.ellipsis,
                  style: plexMono(fontSize: 13, color: brandFg),
                ),
              ),
            ),
            SizedBox(
              width: _cRate,
              child: Text(
                source.sampleRateHz?.toString() ?? 'event',
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: plexMono(fontSize: 12, color: brandFgDim),
              ),
            ),
            const SizedBox(width: _cGap),
            SizedBox(
              width: _cUnit,
              child: Text(
                row.units,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: plexMono(fontSize: 12, color: brandFgDim),
              ),
            ),
            const SizedBox(width: _cColGap),
            // Scale and offset are tertiary calibration detail — faintest so
            // the name + unit carry the row at a glance.
            SizedBox(
              width: _cScale,
              child: Text(
                row.scale.toStringAsExponential(2),
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: plexMono(fontSize: 12, color: brandFgFaint),
              ),
            ),
            const SizedBox(width: _cColGap),
            SizedBox(
              width: _cOffset,
              child: Text(
                '${row.offset}',
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: plexMono(fontSize: 12, color: brandFgFaint),
              ),
            ),
            SizedBox(
              width: _cOn,
              child: Center(child: _onIndicator(on: row.enabled)),
            ),
            const SizedBox(width: _cTrail),
          ],
        ),
      ),
    );
  }

  // --- Compact layout (phone): name on its own line, detail on a 2nd line. ---

  Widget _compactSourceRow(
    BuildContext context,
    WidgetRef ref,
    int enabledCount,
    int total,
  ) {
    return InkWell(
      onTap: onToggleExpand,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Row(
          children: [
            SizedBox(
              width: _cLead,
              child: Icon(
                expanded ? Icons.expand_more : Icons.chevron_right,
                size: 20,
                color: brandFgDim,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          source.sourceLabel,
                          overflow: TextOverflow.ellipsis,
                          style: plexMono(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: brandFg,
                          ),
                        ),
                      ),
                      if (total > 0) ...[
                        const SizedBox(width: 8),
                        Text(
                          '$enabledCount/$total',
                          style: plexMono(fontSize: 11, color: brandFgDim),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _rateLabel(source.sampleRateHz),
                    style: plexMono(fontSize: 11, color: brandFgDim),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: _cOn,
              child: Center(
                child: _onIndicator(on: source.enabled, applicable: total > 0),
              ),
            ),
            SizedBox(width: _cTrail, child: _gear(context, ref)),
          ],
        ),
      ),
    );
  }

  Widget _compactChannelRow(
    BuildContext context,
    WidgetRef ref,
    ChannelRow row,
  ) {
    return InkWell(
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => row.buildDialog(context, ref),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        child: Row(
          children: [
            const SizedBox(width: _cLead),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.channelName,
                      overflow: TextOverflow.ellipsis,
                      style: plexMono(fontSize: 13, color: brandFg),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _channelMeta(row, source.sampleRateHz),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: plexMono(fontSize: 11, color: brandFgDim),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: _cOn,
              child: Center(child: _onIndicator(on: row.enabled)),
            ),
            const SizedBox(width: _cTrail),
          ],
        ),
      ),
    );
  }
}
