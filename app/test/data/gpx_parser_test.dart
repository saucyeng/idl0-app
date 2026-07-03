import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/exceptions.dart';
import 'package:idl0/data/gpx_parser.dart';
import 'package:idl0/data/session_model.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a minimal valid GPX 1.1 document with the given track points.
///
/// Each entry in [points] is `(lat, lon, ele?, time?)`. Pass `null` for ele
/// or time to omit the corresponding child element.
String _buildGpx(
  List<({double lat, double lon, double? ele, String? time})> points, {
  String? extraNamespaces,
  String Function(int index)? extensionsXmlForPoint,
}) {
  final ns = extraNamespaces ?? '';
  final buf = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<gpx version="1.1" creator="test"$ns '
        'xmlns="http://www.topografix.com/GPX/1/1">')
    ..writeln('  <trk><name>Test</name><trkseg>');
  for (var i = 0; i < points.length; i++) {
    final p = points[i];
    buf.writeln('    <trkpt lat="${p.lat}" lon="${p.lon}">');
    if (p.ele != null) buf.writeln('      <ele>${p.ele}</ele>');
    if (p.time != null) buf.writeln('      <time>${p.time}</time>');
    if (extensionsXmlForPoint != null) {
      buf.writeln(extensionsXmlForPoint(i));
    }
    buf.writeln('    </trkpt>');
  }
  buf
    ..writeln('  </trkseg></trk>')
    ..writeln('</gpx>');
  return buf.toString();
}

ChannelData _channel(Session s, String id) =>
    s.channels.firstWhere((c) => c.channelId == id);

bool _hasChannel(Session s, String id) =>
    s.channels.any((c) => c.channelId == id);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('GpxParser.parse —', () {
    test('minimal valid GPX with 3 trkpts — lat/lon/time channels populated',
        () {
      // Arrange
      final xml = _buildGpx([
        (
          lat: 47.6062,
          lon: -122.3321,
          ele: 100.0,
          time: '2026-04-20T10:00:00Z',
        ),
        (
          lat: 47.6063,
          lon: -122.3322,
          ele: 101.0,
          time: '2026-04-20T10:00:01Z',
        ),
        (
          lat: 47.6064,
          lon: -122.3323,
          ele: 102.0,
          time: '2026-04-20T10:00:02Z',
        ),
      ]);

      // Act
      final result = GpxParser.parse(xml);
      final session = result.session;

      // Assert — lat/lon scaled by 1e7 to match firmware i32 encoding so
      // that GpsMapChart and LapDetector can consume both .idl0 and .gpx
      // sessions without a per-source branch.
      expect(session.deviceId, equals('gpx-import'));
      expect(session.sessionId, isNotEmpty);
      expect(
        _channel(session, 'GPS_Latitude').samples,
        equals([476062000.0, 476063000.0, 476064000.0]),
      );
      expect(
        _channel(session, 'GPS_Longitude').samples,
        equals([-1223321000.0, -1223322000.0, -1223323000.0]),
      );
      expect(
        _channel(session, 'GPS_Altitude').samples,
        equals([100.0, 101.0, 102.0]),
      );
      final epoch = _channel(session, 'GPS_EpochMs').samples;
      expect(epoch.length, equals(3));
      expect(
        epoch.first.toInt(),
        equals(DateTime.utc(2026, 4, 20, 10, 0, 0).millisecondsSinceEpoch),
      );
      expect(session.timestampUtcMs, equals(epoch.first.toInt()));
    });

    test('sampleRateHz inferred from timestamps within 5% of 1 Hz', () {
      // Arrange — five points 1 second apart
      final xml = _buildGpx([
        for (var i = 0; i < 5; i++)
          (
            lat: 47.0 + i * 0.0001,
            lon: -122.0,
            ele: 100.0,
            time: DateTime.utc(2026, 4, 20, 10, 0, i).toIso8601String(),
          ),
      ]);

      // Act
      final session = GpxParser.parse(xml).session;

      // Assert — inferred rate within ±5% of 1.0 Hz
      final rate = _channel(session, 'GPS_Latitude').sampleRateHz;
      expect((rate - 1.0).abs() / 1.0, lessThan(0.05));
    });

    test('extracts HR / Cadence / Power channels from extensions', () {
      // Arrange — Garmin TrackPointExtension + Strava power
      final xml = _buildGpx(
        [
          (
            lat: 47.0,
            lon: -122.0,
            ele: 100.0,
            time: '2026-04-20T10:00:00Z',
          ),
          (
            lat: 47.0001,
            lon: -122.0001,
            ele: 101.0,
            time: '2026-04-20T10:00:01Z',
          ),
        ],
        extraNamespaces:
            ' xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1"',
        extensionsXmlForPoint: (i) {
          final hr = 140 + i;
          final cad = 80 + i;
          final pw = 200 + i * 10;
          return '''
            <extensions>
              <gpxtpx:TrackPointExtension>
                <gpxtpx:hr>$hr</gpxtpx:hr>
                <gpxtpx:cad>$cad</gpxtpx:cad>
              </gpxtpx:TrackPointExtension>
              <power>$pw</power>
            </extensions>
          ''';
        },
      );

      // Act
      final session = GpxParser.parse(xml).session;

      // Assert
      expect(_channel(session, 'HR_BPM').samples, equals([140.0, 141.0]));
      expect(_channel(session, 'Cadence_RPM').samples, equals([80.0, 81.0]));
      expect(_channel(session, 'Power_W').samples, equals([200.0, 210.0]));
    });

    test('omits HR/Cadence/Power channels when extensions absent', () {
      // Arrange
      final xml = _buildGpx([
        (
          lat: 47.0,
          lon: -122.0,
          ele: 100.0,
          time: '2026-04-20T10:00:00Z',
        ),
        (
          lat: 47.0001,
          lon: -122.0001,
          ele: 101.0,
          time: '2026-04-20T10:00:01Z',
        ),
      ]);

      // Act
      final session = GpxParser.parse(xml).session;

      // Assert
      expect(_hasChannel(session, 'HR_BPM'), isFalse);
      expect(_hasChannel(session, 'Cadence_RPM'), isFalse);
      expect(_hasChannel(session, 'Power_W'), isFalse);
    });

    test('throws GpxParseException on empty <trk>', () {
      // Arrange
      const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><name>Empty</name><trkseg></trkseg></trk>
</gpx>
''';

      // Act / Assert
      expect(
        () => GpxParser.parse(xml),
        throwsA(isA<GpxParseException>()),
      );
    });

    test('throws GpxParseException on missing <trkpt> attributes', () {
      // Arrange — second point is missing the lon attribute
      const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><trkseg>
    <trkpt lat="47.0" lon="-122.0"><ele>100</ele></trkpt>
    <trkpt lat="47.0001"><ele>101</ele></trkpt>
  </trkseg></trk>
</gpx>
''';

      // Act / Assert
      expect(
        () => GpxParser.parse(xml),
        throwsA(isA<GpxParseException>()),
      );
    });

    test('throws GpxParseException on empty input', () {
      // Arrange / Act / Assert
      expect(
        () => GpxParser.parse('   '),
        throwsA(isA<GpxParseException>()),
      );
    });

    test('throws GpxParseException on malformed XML', () {
      // Arrange — unclosed element
      const xml = '<gpx><trk><trkseg><trkpt lat="1" lon="2">';

      // Act / Assert
      expect(
        () => GpxParser.parse(xml),
        throwsA(isA<GpxParseException>()),
      );
    });

    test('missing <time> elements — falls back to 1 Hz with warning', () {
      // Arrange — no time on any point
      final xml = _buildGpx([
        (lat: 47.0, lon: -122.0, ele: 100.0, time: null),
        (lat: 47.0001, lon: -122.0001, ele: 101.0, time: null),
        (lat: 47.0002, lon: -122.0002, ele: 102.0, time: null),
      ]);

      // Act
      final result = GpxParser.parse(xml);
      final session = result.session;

      // Assert
      expect(result.warning, isNotNull);
      expect(_channel(session, 'GPS_Latitude').sampleRateHz, equals(1.0));
      // Synthesized timestamps: 0 ms, 1000 ms, 2000 ms
      expect(
        _channel(session, 'GPS_EpochMs').samples,
        equals([0.0, 1000.0, 2000.0]),
      );
    });
  });
}
