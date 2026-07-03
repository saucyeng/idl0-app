import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/session_model.dart';
import '../../../data/track.dart';
import '../../../providers/data_filters_provider.dart';
import '../../../providers/data_results_provider.dart';
import '../../../providers/track_provider.dart';
import '../../brand/brand.dart';

/// The vertical rail of facet groups shown to the left of the result panel
/// on wide layouts and in the bottom-sheet on narrow layouts. See
/// `docs/IDL0_SPEC.md §15.3` for the facet inventory.
///
/// Reads [dataFiltersProvider] for the active state, [trackProvider] for
/// Track names, [filteredSessionRowsProvider] for source data, and
/// [facetCountsProvider] for the per-option `(N)` badges.
class FilterRail extends ConsumerWidget {
  /// Creates a [FilterRail].
  const FilterRail({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(dataFiltersProvider);
    final tracksAsync = ref.watch(trackProvider);
    final countsAsync = ref.watch(facetCountsProvider);
    final domainAsync = ref.watch(lapTimeDomainProvider);

    return Material(
      color: brandSurface,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _DateSection(filters: filters),
          const Divider(height: 1, thickness: brandHairlineWidth, color: brandRule),
          _TrackFacet(
            filters: filters,
            tracks: tracksAsync.value ?? const [],
            counts: countsAsync.value?.tracks ?? const {},
          ),
          const Divider(height: 1, thickness: brandHairlineWidth, color: brandRule),
          _StringFacet(
            label: 'Venue',
            counts: countsAsync.value?.venues ?? const {},
            selected: filters.venues,
            onToggle: (v) =>
                ref.read(dataFiltersProvider.notifier).toggleVenue(v),
          ),
          const Divider(height: 1, thickness: brandHairlineWidth, color: brandRule),
          _StringFacet(
            label: 'Bike',
            counts: countsAsync.value?.bikes ?? const {},
            selected: filters.bikes,
            onToggle: (v) =>
                ref.read(dataFiltersProvider.notifier).toggleBike(v),
          ),
          const Divider(height: 1, thickness: brandHairlineWidth, color: brandRule),
          _StringFacet(
            label: 'Rider',
            counts: countsAsync.value?.riders ?? const {},
            selected: filters.riders,
            onToggle: (v) =>
                ref.read(dataFiltersProvider.notifier).toggleRider(v),
          ),
          const Divider(height: 1, thickness: brandHairlineWidth, color: brandRule),
          _StringFacet(
            label: 'Tag',
            counts: countsAsync.value?.tags ?? const {},
            selected: filters.tags,
            onToggle: (v) =>
                ref.read(dataFiltersProvider.notifier).toggleTag(v),
          ),
          const Divider(height: 1, thickness: brandHairlineWidth, color: brandRule),
          _LapTimeSection(filters: filters, domain: domainAsync.value),
          const Divider(height: 1, thickness: brandHairlineWidth, color: brandRule),
          _SourceFacet(
            filters: filters,
            counts: countsAsync.value?.sources ?? const {},
          ),
          const Divider(height: 1, thickness: brandHairlineWidth, color: brandRule),
          _BoolFacets(filters: filters),
          const SizedBox(height: 12),
          if (filters.hasAnyActiveFilter)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: QuietButton(
                label: 'Clear all',
                icon: Icons.clear_all,
                onPressed: () =>
                    ref.read(dataFiltersProvider.notifier).clearAll(),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Date section
// ---------------------------------------------------------------------------

class _DateSection extends ConsumerWidget {
  const _DateSection({required this.filters});

  final DataFilters filters;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(dataFiltersProvider.notifier);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final week = today.subtract(const Duration(days: 6));
    final month = today.subtract(const Duration(days: 29));

    final selectedPreset = _matchPreset(filters.dateRange, now);

    return _SectionFrame(
      title: 'Date',
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          _ChipButton(
            label: 'Today',
            selected: selectedPreset == _DatePreset.today,
            onTap: () => notifier.setDateRange(
              selectedPreset == _DatePreset.today
                  ? null
                  : DateTimeRange(start: today, end: today),
            ),
          ),
          _ChipButton(
            label: 'Week',
            selected: selectedPreset == _DatePreset.week,
            onTap: () => notifier.setDateRange(
              selectedPreset == _DatePreset.week
                  ? null
                  : DateTimeRange(start: week, end: today),
            ),
          ),
          _ChipButton(
            label: 'Month',
            selected: selectedPreset == _DatePreset.month,
            onTap: () => notifier.setDateRange(
              selectedPreset == _DatePreset.month
                  ? null
                  : DateTimeRange(start: month, end: today),
            ),
          ),
          _ChipButton(
            label: 'Custom',
            selected: selectedPreset == _DatePreset.custom,
            onTap: () async {
              final picked = await showDateRangePicker(
                context: context,
                firstDate: DateTime(2020),
                lastDate: DateTime(now.year + 1),
                initialDateRange: filters.dateRange,
              );
              if (picked != null) notifier.setDateRange(picked);
            },
          ),
        ],
      ),
    );
  }
}

enum _DatePreset { today, week, month, custom }

_DatePreset? _matchPreset(DateTimeRange? range, DateTime now) {
  if (range == null) return null;
  final today = DateTime(now.year, now.month, now.day);
  final week = today.subtract(const Duration(days: 6));
  final month = today.subtract(const Duration(days: 29));
  bool same(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
  if (same(range.end, today)) {
    if (same(range.start, today)) return _DatePreset.today;
    if (same(range.start, week)) return _DatePreset.week;
    if (same(range.start, month)) return _DatePreset.month;
  }
  return _DatePreset.custom;
}

// ---------------------------------------------------------------------------
// Track facet
// ---------------------------------------------------------------------------

class _TrackFacet extends ConsumerWidget {
  const _TrackFacet({
    required this.filters,
    required this.tracks,
    required this.counts,
  });

  final DataFilters filters;
  final List<Track> tracks;
  final Map<String, int> counts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(dataFiltersProvider.notifier);
    final entries = [
      for (final t in tracks)
        _FacetEntry(
          value: t.trackId,
          label: t.name.isEmpty ? '(unnamed track)' : t.name,
          count: counts[t.trackId] ?? 0,
        ),
    ]..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));

    return _MultiSelectFacet(
      title: 'Track',
      entries: entries,
      selected: filters.trackIds,
      onToggle: notifier.toggleTrack,
    );
  }
}

// ---------------------------------------------------------------------------
// Generic string facet (Bike / Rider / Tag) — value `''` is the "(none)"
// pseudo-entry, surfaced from the count map directly.
// ---------------------------------------------------------------------------

class _StringFacet extends StatelessWidget {
  const _StringFacet({
    required this.label,
    required this.counts,
    required this.selected,
    required this.onToggle,
  });

  final String label;
  final Map<String, int> counts;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final entries = counts.entries
        .map((e) => _FacetEntry(
              value: e.key,
              label: e.key.isEmpty ? '(none)' : e.key,
              count: e.value,
            ),)
        .toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));

    return _MultiSelectFacet(
      title: label,
      entries: entries,
      selected: selected,
      onToggle: onToggle,
    );
  }
}

class _SourceFacet extends ConsumerWidget {
  const _SourceFacet({required this.filters, required this.counts});

  final DataFilters filters;
  final Map<SessionSourceType, int> counts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(dataFiltersProvider.notifier);
    return _SectionFrame(
      title: 'Source',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final src in SessionSourceType.values)
            _brandCheckRow(
              checked: filters.sources.contains(src),
              label: '.${src.name}',
              count: counts[src] ?? 0,
              onTap: () => notifier.toggleSource(src),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lap-time RangeSlider with mm:ss text inputs
// ---------------------------------------------------------------------------

class _LapTimeSection extends ConsumerStatefulWidget {
  const _LapTimeSection({required this.filters, required this.domain});

  final DataFilters filters;
  final ({int minMs, int maxMs})? domain;

  @override
  ConsumerState<_LapTimeSection> createState() => _LapTimeSectionState();
}

class _LapTimeSectionState extends ConsumerState<_LapTimeSection> {
  late final TextEditingController _minCtrl;
  late final TextEditingController _maxCtrl;

  @override
  void initState() {
    super.initState();
    _minCtrl = TextEditingController(text: _formatRange(_currentMinMs));
    _maxCtrl = TextEditingController(text: _formatRange(_currentMaxMs));
  }

  @override
  void didUpdateWidget(_LapTimeSection old) {
    super.didUpdateWidget(old);
    if (!_focusedMin && _minCtrl.text != _formatRange(_currentMinMs)) {
      _minCtrl.text = _formatRange(_currentMinMs);
    }
    if (!_focusedMax && _maxCtrl.text != _formatRange(_currentMaxMs)) {
      _maxCtrl.text = _formatRange(_currentMaxMs);
    }
  }

  bool _focusedMin = false;
  bool _focusedMax = false;

  int get _domainMin => widget.domain?.minMs ?? 60 * 1000;
  int get _domainMax => widget.domain?.maxMs ?? 60 * 60 * 1000;
  int get _currentMinMs =>
      widget.filters.lapTimeMs?.start.toInt() ?? _domainMin;
  int get _currentMaxMs =>
      widget.filters.lapTimeMs?.end.toInt() ?? _domainMax;

  @override
  void dispose() {
    _minCtrl.dispose();
    _maxCtrl.dispose();
    super.dispose();
  }

  void _commitFromText() {
    final newMin = _parseRange(_minCtrl.text) ?? _currentMinMs;
    final newMax = _parseRange(_maxCtrl.text) ?? _currentMaxMs;
    final clampedMin = newMin.clamp(_domainMin, _domainMax);
    final clampedMax = newMax
        .clamp(_domainMin, _domainMax)
        .clamp(clampedMin, _domainMax);
    if (clampedMin == _domainMin && clampedMax == _domainMax) {
      ref.read(dataFiltersProvider.notifier).setLapTimeRange(null);
    } else {
      ref.read(dataFiltersProvider.notifier).setLapTimeRange(
            RangeValues(clampedMin.toDouble(), clampedMax.toDouble()),
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final values = RangeValues(
      _currentMinMs.toDouble().clamp(
            _domainMin.toDouble(),
            _domainMax.toDouble(),
          ),
      _currentMaxMs.toDouble().clamp(
            _domainMin.toDouble(),
            _domainMax.toDouble(),
          ),
    );
    return _SectionFrame(
      title: 'Lap time',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RangeSlider(
            values: values,
            min: _domainMin.toDouble(),
            max: _domainMax.toDouble(),
            divisions: ((_domainMax - _domainMin) ~/ 1000).clamp(10, 600),
            labels: RangeLabels(
              _formatRange(values.start.toInt()),
              _formatRange(values.end.toInt()),
            ),
            onChanged: (r) {
              if (r.start <= _domainMin && r.end >= _domainMax) {
                ref.read(dataFiltersProvider.notifier).setLapTimeRange(null);
              } else {
                ref.read(dataFiltersProvider.notifier).setLapTimeRange(r);
              }
            },
          ),
          Row(
            children: [
              Expanded(
                child: Focus(
                  onFocusChange: (f) {
                    _focusedMin = f;
                    if (!f) _commitFromText();
                  },
                  child: TextField(
                    controller: _minCtrl,
                    style: plexMono(fontSize: 12.5, color: brandFg),
                    cursorColor: brandFg,
                    decoration: _brandInput(label: 'Min (mm:ss)'),
                    onSubmitted: (_) => _commitFromText(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Focus(
                  onFocusChange: (f) {
                    _focusedMax = f;
                    if (!f) _commitFromText();
                  },
                  child: TextField(
                    controller: _maxCtrl,
                    style: plexMono(fontSize: 12.5, color: brandFg),
                    cursorColor: brandFg,
                    decoration: _brandInput(label: 'Max (mm:ss)'),
                    onSubmitted: (_) => _commitFromText(),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _formatRange(int ms) {
    final m = ms ~/ 60000;
    final s = (ms ~/ 1000) % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// Parses `mm:ss` → milliseconds. Returns null on bad input. Empty
  /// string is treated as "no bound" (caller substitutes the domain edge).
  static int? _parseRange(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    final parts = t.split(':');
    if (parts.length != 2) return null;
    final m = int.tryParse(parts[0]);
    final s = int.tryParse(parts[1]);
    if (m == null || s == null) return null;
    if (m < 0 || s < 0 || s >= 60) return null;
    return (m * 60 + s) * 1000;
  }
}

// ---------------------------------------------------------------------------
// Has-gates / Has-GPS booleans
// ---------------------------------------------------------------------------

class _BoolFacets extends ConsumerWidget {
  const _BoolFacets({required this.filters});

  final DataFilters filters;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(dataFiltersProvider.notifier);
    return _SectionFrame(
      title: 'Requirements',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _brandCheckRow(
            checked: filters.requireGates,
            label: 'Has gates',
            onTap: () => notifier.setRequireGates(!filters.requireGates),
          ),
          _brandCheckRow(
            checked: filters.requireGps,
            label: 'Has GPS',
            onTap: () => notifier.setRequireGps(!filters.requireGps),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared scaffolding
// ---------------------------------------------------------------------------

class _FacetEntry {
  const _FacetEntry({
    required this.value,
    required this.label,
    required this.count,
  });
  final String value;
  final String label;
  final int count;
}

/// A compact, tappable brand facet row: a small square check that fills
/// [brandGood] when [checked], a mono label, and an optional dim count badge.
/// Replaces the Material `CheckboxListTile` across the rail's facets.
Widget _brandCheckRow({
  required bool checked,
  required String label,
  required VoidCallback onTap,
  int? count,
}) {
  return InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 15,
            height: 15,
            decoration: BoxDecoration(
              color: checked ? brandGood : Colors.transparent,
              border: Border.all(
                color: checked ? brandGood : brandFgDim,
                width: 1.5,
              ),
              borderRadius: BorderRadius.circular(3),
            ),
            child:
                checked ? const Icon(Icons.check, size: 12, color: brandBg) : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: plexMono(fontSize: 12.5, color: brandFg),
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 8),
            Text('$count', style: plexMono(fontSize: 11.5, color: brandFgDim)),
          ],
        ],
      ),
    ),
  );
}

/// Brand-styled [InputDecoration] for the rail's search and lap-time fields.
InputDecoration _brandInput({String? hint, String? label, IconData? prefix}) {
  OutlineInputBorder border(Color c) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(brandControlRadiusSoft),
        borderSide: BorderSide(color: c, width: brandHairlineWidth),
      );
  return InputDecoration(
    hintText: hint,
    labelText: label,
    hintStyle: plexMono(fontSize: 12.5, color: brandFgFaint),
    labelStyle: plexMono(fontSize: 12, color: brandFgDim),
    isDense: true,
    filled: true,
    fillColor: brandControlFill,
    prefixIcon:
        prefix == null ? null : Icon(prefix, size: 16, color: brandFgDim),
    border: border(brandRule),
    enabledBorder: border(brandRule),
    focusedBorder: border(brandFgDim),
  );
}

class _MultiSelectFacet extends StatefulWidget {
  const _MultiSelectFacet({
    required this.title,
    required this.entries,
    required this.selected,
    required this.onToggle,
  });

  final String title;
  final List<_FacetEntry> entries;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  @override
  State<_MultiSelectFacet> createState() => _MultiSelectFacetState();
}

class _MultiSelectFacetState extends State<_MultiSelectFacet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final showSearch = widget.entries.length >= 8;
    final filtered = _query.isEmpty
        ? widget.entries
        : widget.entries
            .where((e) => e.label.toLowerCase().contains(_query.toLowerCase()))
            .toList();
    return _SectionFrame(
      title: widget.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showSearch)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                style: plexMono(fontSize: 12.5, color: brandFg),
                cursorColor: brandFg,
                decoration: _brandInput(hint: 'Search…', prefix: Icons.search),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          if (widget.entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                'No options',
                style: plexMono(fontSize: 12, color: brandFgFaint),
              ),
            )
          else
            ConstrainedBox(
              // Cap multi-select list height; ListView scrolls when long.
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: filtered.length,
                itemBuilder: (_, i) {
                  final entry = filtered[i];
                  return _brandCheckRow(
                    checked: widget.selected.contains(entry.value),
                    label: entry.label,
                    count: entry.count,
                    onTap: () => widget.onToggle(entry.value),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionFrame extends StatelessWidget {
  const _SectionFrame({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: plexMono(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: brandFgDim,
              letterSpacing: brandKickerTracking,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _ChipButton extends StatelessWidget {
  const _ChipButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return BrandChip(
      label: label,
      selected: selected,
      onTap: onTap,
    );
  }
}
