/// Overlay layout model — Dart mirror of the engine's `overlay::model`
/// (SPEC §33.1). Stored on the workbook (`.idl0wb` v2, `overlay_layouts`);
/// the engine consumes this JSON directly (`idl-rs overlay --workbook`), so
/// the wire shape is engine-defined: snake_case keys, `rect` as an
/// `[x, y, w, h]` array of canvas fractions, lowercase style strings.
library;

/// A named overlay layout (workbook asset, canvas-agnostic).
class OverlayLayout {
  /// Stable UUID for this layout within the workbook.
  final String id;

  /// User-facing display name, e.g. `MTB default`.
  final String name;

  /// Design-space size as `"WxH"` pixels (stroke/font scaling only).
  final String canvas;

  /// Positioned elements, drawn in list order.
  final List<OverlayElement> elements;

  /// Creates an [OverlayLayout].
  const OverlayLayout({
    required this.id,
    required this.name,
    required this.canvas,
    required this.elements,
  });

  /// Serializes to the engine-defined JSON shape (SPEC §33.1).
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'canvas': canvas,
        'elements': elements.map((e) => e.toJson()).toList(),
      };

  /// Deserializes from the engine-defined JSON shape.
  ///
  /// Throws [FormatException] on an unknown element `type`.
  factory OverlayLayout.fromJson(Map<String, dynamic> json) => OverlayLayout(
        id: json['id'] as String,
        name: json['name'] as String,
        canvas: json['canvas'] as String,
        elements: (json['elements'] as List<dynamic>? ?? [])
            .map((e) => OverlayElement.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

List<double> _rect(Map<String, dynamic> json) =>
    (json['rect'] as List<dynamic>).map((v) => (v as num).toDouble()).toList();

/// One positioned overlay element. [rect] is normalized `[x, y, w, h]`.
sealed class OverlayElement {
  /// Normalized `[x, y, w, h]` canvas fractions.
  final List<double> rect;

  /// Creates an [OverlayElement] at [rect].
  const OverlayElement({required this.rect});

  /// Serializes to the engine-defined JSON shape, `type`-discriminated.
  Map<String, dynamic> toJson();

  /// Deserializes any element kind by its `type` discriminator.
  ///
  /// Throws [FormatException] on an unknown `type`.
  factory OverlayElement.fromJson(Map<String, dynamic> json) =>
      switch (json['type'] as String?) {
        'gauge' => GaugeElement(
            rect: _rect(json),
            channel: json['channel'] as String,
            style: json['style'] as String,
            label: json['label'] as String? ?? '',
            min: (json['min'] as num).toDouble(),
            max: (json['max'] as num).toDouble(),
          ),
        'attitude' => AttitudeElement(
            rect: _rect(json),
            channel: json['channel'] as String,
            style: json['style'] as String,
            rangeDeg: (json['range_deg'] as num).toDouble(),
          ),
        'trace_strip' => TraceStripElement(
            rect: _rect(json),
            channels: (json['channels'] as List<dynamic>)
                .map((c) => c as String)
                .toList(),
            windowS: (json['window_s'] as num).toDouble(),
          ),
        'track_map' => TrackMapElement(rect: _rect(json)),
        'lap_panel' => LapPanelElement(rect: _rect(json)),
        final other =>
          throw FormatException('unknown overlay element type: $other'),
      };
}

/// Single-value readout; [style] ∈ `numeric | bar | dial`; [min]/[max]
/// bound bar/dial travel in channel units.
class GaugeElement extends OverlayElement {
  /// Channel id sampled for the readout.
  final String channel;

  /// Rendering style: `numeric | bar | dial`.
  final String style;

  /// Unit caption drawn beside the value, e.g. `km/h`.
  final String label;

  /// Lower bound of bar/dial travel, in channel units.
  final double min;

  /// Upper bound of bar/dial travel, in channel units.
  final double max;

  /// Creates a [GaugeElement].
  const GaugeElement({
    required super.rect,
    required this.channel,
    required this.style,
    required this.label,
    required this.min,
    required this.max,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'gauge',
        'rect': rect,
        'channel': channel,
        'style': style,
        'label': label,
        'min': min,
        'max': max,
      };
}

/// Signed zero-centered indicator; [style] ∈ `roll | steer`; [rangeDeg] is
/// full-scale deflection in degrees.
class AttitudeElement extends OverlayElement {
  /// Channel id sampled for the deflection angle, in degrees.
  final String channel;

  /// Rendering style: `roll | steer`.
  final String style;

  /// Full-scale deflection in degrees (symmetric about zero).
  final double rangeDeg;

  /// Creates an [AttitudeElement].
  const AttitudeElement({
    required super.rect,
    required this.channel,
    required this.style,
    required this.rangeDeg,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'attitude',
        'rect': rect,
        'channel': channel,
        'style': style,
        'range_deg': rangeDeg,
      };
}

/// Scrolling time-series strip: trailing [windowS] seconds, "now" at the
/// right edge.
class TraceStripElement extends OverlayElement {
  /// Channel ids traced, drawn in list order.
  final List<String> channels;

  /// Trailing window length in seconds.
  final double windowS;

  /// Creates a [TraceStripElement].
  const TraceStripElement({
    required super.rect,
    required this.channels,
    required this.windowS,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'trace_strip',
        'rect': rect,
        'channels': channels,
        'window_s': windowS,
      };
}

/// Session GPS outline with current-position dot.
class TrackMapElement extends OverlayElement {
  /// Creates a [TrackMapElement].
  const TrackMapElement({required super.rect});

  @override
  Map<String, dynamic> toJson() => {'type': 'track_map', 'rect': rect};
}

/// Current/last/best lap readout.
class LapPanelElement extends OverlayElement {
  /// Creates a [LapPanelElement].
  const LapPanelElement({required super.rect});

  @override
  Map<String, dynamic> toJson() => {'type': 'lap_panel', 'rect': rect};
}
