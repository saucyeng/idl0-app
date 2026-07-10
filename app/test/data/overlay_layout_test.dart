import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/overlay_layout.dart';

/// Engine parity fixture — mirrors LAYOUT_JSON in idl-rs
/// core/src/overlay/model.rs. Keep in lockstep.
const _layoutJson = '''
{
  "id": "11111111-2222-3333-4444-555555555555",
  "name": "MTB default",
  "canvas": "1920x1080",
  "elements": [
    { "type": "gauge", "rect": [0.02, 0.80, 0.14, 0.16], "channel": "GPS_SpeedKmh",
      "style": "numeric", "label": "km/h", "min": 0, "max": 80 },
    { "type": "attitude", "rect": [0.18, 0.80, 0.10, 0.16], "channel": "Roll_deg",
      "style": "roll", "range_deg": 60 },
    { "type": "trace_strip", "rect": [0.30, 0.82, 0.40, 0.15],
      "channels": ["TravelFront_mm", "TravelRear_mm"], "window_s": 8.0 },
    { "type": "track_map", "rect": [0.84, 0.04, 0.14, 0.25] },
    { "type": "lap_panel", "rect": [0.02, 0.04, 0.16, 0.14] }
  ]
}
''';

void main() {
  group('OverlayLayout —', () {
    test('fromJson — engine parity fixture — parses all five element kinds',
        () {
      // Arrange
      final json = jsonDecode(_layoutJson) as Map<String, dynamic>;

      // Act
      final layout = OverlayLayout.fromJson(json);

      // Assert
      expect(layout.name, 'MTB default');
      expect(layout.elements, hasLength(5));
      final gauge = layout.elements[0] as GaugeElement;
      expect(gauge.channel, 'GPS_SpeedKmh');
      expect(gauge.style, 'numeric');
      expect(gauge.rect, [0.02, 0.80, 0.14, 0.16]);
      final attitude = layout.elements[1] as AttitudeElement;
      expect(attitude.rangeDeg, 60);
      final trace = layout.elements[2] as TraceStripElement;
      expect(trace.channels, ['TravelFront_mm', 'TravelRear_mm']);
      expect(trace.windowS, 8.0);
      expect(layout.elements[3], isA<TrackMapElement>());
      expect(layout.elements[4], isA<LapPanelElement>());
    });

    test('toJson — round-trip — re-parses identically', () {
      // Arrange
      final layout =
          OverlayLayout.fromJson(jsonDecode(_layoutJson) as Map<String, dynamic>);

      // Act
      final back = OverlayLayout.fromJson(layout.toJson());

      // Assert
      expect(back.toJson(), layout.toJson());
      expect((back.elements[0] as GaugeElement).max, 80);
    });

    test('fromJson — unknown element type — throws FormatException', () {
      // Arrange
      final json = jsonDecode(_layoutJson) as Map<String, dynamic>;
      (json['elements'] as List)[0] = {
        'type': 'hologram',
        'rect': [0, 0, 1, 1],
      };

      // Act + Assert
      expect(() => OverlayLayout.fromJson(json), throwsFormatException);
    });
  });
}
