import 'package:flutter/material.dart' show Color, IconData, Icons;
import 'package:idl0/data/worksheet.dart' show ChartType;

/// Display metadata for one [ChartType].
///
/// Single source of truth for the glyph, human label, and one-line
/// description used by the Add-Chart picker (mobile) and the desktop
/// chart-type rail. Adding a new chart type is one entry in
/// [kChartTypeCatalog] plus (if user-addable) one entry in
/// [kAddableChartTypes], alongside its render widget and property section.
class ChartTypeInfo {
  /// Creates a [ChartTypeInfo].
  const ChartTypeInfo({
    required this.icon,
    required this.label,
    required this.blurb,
    required this.accent,
  });

  /// Material glyph shown in the picker row and the desktop rail. Chosen to
  /// read as a miniature of the chart it represents.
  final IconData icon;

  /// Human-facing chart-type name, e.g. `Time Series`.
  final String label;

  /// One-line description shown under the label in the picker and beside the
  /// desktop rail — the IDE-style "what is this" hint.
  final String blurb;

  /// Signature colour for this chart type — tints the picker/rail glyph and
  /// the desktop rail's selected fill + border, so each type reads by colour
  /// as well as glyph (the category-colour convention). Drawn from
  /// `brandChartPalette` hues so it sits in the field-manual palette.
  final Color accent;
}

/// Per-[ChartType] display metadata. Covers every chart type, including the
/// pinned Session-Sheet types (lap table / lap progression) so the rail and
/// any future "convert" affordance can label them even though they are not
/// user-addable.
const Map<ChartType, ChartTypeInfo> kChartTypeCatalog = {
  ChartType.timeSeries: ChartTypeInfo(
    icon: Icons.show_chart,
    label: 'Time Series',
    blurb: 'Channels plotted against time or distance.',
    accent: Color(0xFF5BA6F0), // azure
  ),
  ChartType.fft: ChartTypeInfo(
    icon: Icons.equalizer,
    label: 'FFT',
    blurb: 'Frequency spectrum of the assigned channels.',
    accent: Color(0xFFB98AE6), // violet
  ),
  ChartType.spectrogram: ChartTypeInfo(
    icon: Icons.gradient,
    label: 'Spectrogram',
    blurb: 'Frequency content of a channel over time, as a heatmap.',
    accent: Color(0xFFD96BC4), // magenta
  ),
  ChartType.histogram: ChartTypeInfo(
    icon: Icons.bar_chart,
    label: 'Histogram',
    blurb: 'Value distribution of a channel over the session.',
    accent: Color(0xFF3FC9C0), // teal
  ),
  ChartType.gpsMap: ChartTypeInfo(
    icon: Icons.map_outlined,
    label: 'GPS Map',
    blurb: 'Ride track drawn on a map.',
    accent: Color(0xFF35C46E), // green
  ),
  ChartType.lapTable: ChartTypeInfo(
    icon: Icons.table_rows_outlined,
    label: 'Lap Table',
    blurb: 'Per-session lap × sector times.',
    accent: Color(0xFFE8964B), // orange
  ),
  ChartType.lapProgression: ChartTypeInfo(
    icon: Icons.timeline,
    label: 'Lap Times',
    blurb: 'Lap time per lap, one line per session.',
    accent: Color(0xFFF5D547), // amber
  ),
  ChartType.varianceTrace: ChartTypeInfo(
    icon: Icons.compare_arrows,
    label: 'Lap Variance',
    blurb: 'Each selected lap vs the fastest, per sample.',
    accent: Color(0xFFEC6A5C), // coral
  ),
  ChartType.scatter: ChartTypeInfo(
    icon: Icons.scatter_plot,
    label: 'Scatter',
    blurb: 'One channel vs another — the G-G friction circle.',
    accent: Color(0xFF6E78E8), // indigo
  ),
};

/// Chart types the user can add from the Add-Chart picker / desktop rail, in
/// presentation order. Lap table and lap progression are pinned to Session
/// Sheets at construction and are therefore not addable here.
const List<ChartType> kAddableChartTypes = [
  ChartType.timeSeries,
  ChartType.fft,
  ChartType.spectrogram,
  ChartType.histogram,
  ChartType.gpsMap,
  ChartType.varianceTrace,
  ChartType.scatter,
];

/// Returns the [ChartTypeInfo] for [type], falling back to the time-series
/// entry for any type missing from the catalog (keeps callers null-safe).
ChartTypeInfo chartTypeInfo(ChartType type) =>
    kChartTypeCatalog[type] ?? kChartTypeCatalog[ChartType.timeSeries]!;
