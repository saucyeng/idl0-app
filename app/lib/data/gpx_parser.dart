import 'dart:math' as math;

import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';

import 'exceptions.dart';
import 'session_model.dart';

/// Result returned by [GpxParser.parse].
///
/// Always carries a valid [session]. [warning] is non-null when the parse
/// succeeded but some quality concern should be surfaced — e.g. timestamps
/// were missing so the GPS sample rate was assumed to be 1 Hz.
class GpxParseResult {
  /// The parsed session, ready to be inserted into [SessionMetadata]/SQLite.
  final Session session;

  /// User-facing advisory message, or `null` when none.
  final String? warning;

  /// Trimmed contents of the file's top-level `<metadata><name>` element,
  /// or `null` when absent. Used as the default Track / Session name in
  /// the GPX import dialog when the user hasn't typed one.
  final String? metadataName;

  /// Creates a [GpxParseResult].
  const GpxParseResult({
    required this.session,
    this.warning,
    this.metadataName,
  });
}

/// Parses a Garmin/Strava `.gpx` track export into a [Session]. See §12.
///
/// Pure-Dart, side-effect-free — no I/O, no Flutter, no Rust calls. Reads
/// the entire XML document into memory; GPX files are small (a few MB at
/// the most for multi-hour rides), so streaming is not required.
///
/// Channel mapping:
/// - `<trkpt lat lon>` → `GPS_Latitude`, `GPS_Longitude` (decimal degrees
///   scaled by 1e7 to match firmware convention — see [_coordScale])
/// - `<trkpt><ele>` → `GPS_Altitude` (metres; 0 when absent)
/// - `<trkpt><time>` → `GPS_EpochMs` (UTC ms)
/// - `<gpxtpx:hr>` → `HR_BPM` (only when present)
/// - `<gpxtpx:cad>` → `Cadence_RPM` (only when present)
/// - `<power>` (Strava) → `Power_W` (only when present)
/// - `<speed>` (m/s, GPX/u-blox/gpxtpx) → `GPS_SpeedKmh` (×3.6); derived from
///   consecutive lat/lon/time deltas when absent
/// - `<course>` (degrees from north, GPX/gpxtpx) → `GPS_Heading`; derived
///   from consecutive lat/lon when absent
class GpxParser {
  static const _uuid = Uuid();

  /// Scale factor matching the firmware's i32 lat/lon encoding
  /// (51.5074° N → `515074000`). Channel consumers (GPS map, lap detector)
  /// already divide raw samples by this factor; storing GPX-derived
  /// coordinates at the same scale lets imported sessions render and time
  /// laps without per-source branching.
  static const double _coordScale = 1e7;

  /// Parses [xmlContent] and returns the resulting session.
  ///
  /// Throws [GpxParseException] when the XML is malformed, contains no
  /// `<trkpt>` elements, or has a `<trkpt>` missing required `lat`/`lon`
  /// attributes.
  static GpxParseResult parse(String xmlContent) {
    if (xmlContent.trim().isEmpty) {
      throw const GpxParseException('GPX file is empty.');
    }

    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xmlContent);
    } on XmlException catch (e) {
      throw GpxParseException('Malformed GPX XML: ${e.message}');
    }

    final trkpts = doc.findAllElements('trkpt').toList();
    if (trkpts.isEmpty) {
      throw const GpxParseException('GPX file has no <trkpt> elements.');
    }

    // Extract the optional top-level <metadata><name> for the import dialog
    // to suggest as the Track / Session name. Trimmed; empty → null.
    String? metadataName;
    for (final meta in doc.findAllElements('metadata')) {
      final nameEl = _firstChildLocal(meta, 'name');
      if (nameEl != null) {
        final t = nameEl.innerText.trim();
        if (t.isNotEmpty) {
          metadataName = t;
          break;
        }
      }
    }

    final lat = <double>[];
    final lon = <double>[];
    final latDeg = <double>[];
    final lonDeg = <double>[];
    final ele = <double>[];
    final timestampsMs = <int>[];
    final hr = <double>[];
    final cad = <double>[];
    final power = <double>[];
    final speedKmh = <double>[];
    final heading = <double>[];

    var sawAnyHr = false;
    var sawAnyCad = false;
    var sawAnyPower = false;
    var sawAnyTimestamp = false;
    var sawAnySpeed = false;
    var sawAnyCourse = false;

    for (final pt in trkpts) {
      final latStr = pt.getAttribute('lat');
      final lonStr = pt.getAttribute('lon');
      if (latStr == null || lonStr == null) {
        throw const GpxParseException(
          '<trkpt> missing required lat/lon attribute.',
        );
      }
      final latVal = double.tryParse(latStr);
      final lonVal = double.tryParse(lonStr);
      if (latVal == null || lonVal == null) {
        throw GpxParseException(
          '<trkpt> has unparseable lat/lon: lat="$latStr" lon="$lonStr"',
        );
      }
      lat.add(latVal * _coordScale);
      lon.add(lonVal * _coordScale);
      latDeg.add(latVal);
      lonDeg.add(lonVal);

      final eleEl = _firstChildLocal(pt, 'ele');
      ele.add(eleEl != null ? (double.tryParse(eleEl.innerText) ?? 0.0) : 0.0);

      final timeEl = _firstChildLocal(pt, 'time');
      if (timeEl != null) {
        final dt = DateTime.tryParse(timeEl.innerText);
        if (dt != null) {
          sawAnyTimestamp = true;
          timestampsMs.add(dt.toUtc().millisecondsSinceEpoch);
        } else {
          // Push a sentinel so per-point arrays stay aligned; replaced below
          // if we end up using interpolated timestamps.
          timestampsMs.add(0);
        }
      } else {
        timestampsMs.add(0);
      }

      // Extension fields (Garmin TrackPointExtension + Strava power). Match
      // by local name so the namespace prefix (gpxtpx, ns3, etc.) is irrelevant.
      final hrEl = _findDescendantLocal(pt, 'hr');
      if (hrEl != null) {
        final v = double.tryParse(hrEl.innerText);
        if (v != null) {
          sawAnyHr = true;
          hr.add(v);
        } else {
          hr.add(0);
        }
      } else {
        hr.add(0);
      }

      final cadEl = _findDescendantLocal(pt, 'cad');
      if (cadEl != null) {
        final v = double.tryParse(cadEl.innerText);
        if (v != null) {
          sawAnyCad = true;
          cad.add(v);
        } else {
          cad.add(0);
        }
      } else {
        cad.add(0);
      }

      final powerEl = _findDescendantLocal(pt, 'power');
      if (powerEl != null) {
        final v = double.tryParse(powerEl.innerText);
        if (v != null) {
          sawAnyPower = true;
          power.add(v);
        } else {
          power.add(0);
        }
      } else {
        power.add(0);
      }

      // GPX <speed> is metres per second per the schema. Convert to km/h to
      // match the firmware-side `GPS_SpeedKmh` channel naming.
      final speedEl = _findDescendantLocal(pt, 'speed');
      if (speedEl != null) {
        final v = double.tryParse(speedEl.innerText);
        if (v != null) {
          sawAnySpeed = true;
          speedKmh.add(v * 3.6);
        } else {
          speedKmh.add(0);
        }
      } else {
        speedKmh.add(0);
      }

      // GPX <course> is degrees from true north, 0..360.
      final courseEl = _findDescendantLocal(pt, 'course');
      if (courseEl != null) {
        final v = double.tryParse(courseEl.innerText);
        if (v != null) {
          sawAnyCourse = true;
          heading.add(v);
        } else {
          heading.add(0);
        }
      } else {
        heading.add(0);
      }
    }

    // GPS sample rate inference. GPX is typically 1 Hz from Garmin/Strava but
    // smart-recording can yield variable spacing. Use the median of consecutive
    // deltas — robust to gaps from auto-pause.
    String? warning;
    double sampleRateHz;
    if (sawAnyTimestamp && timestampsMs.length >= 2) {
      final deltas = <int>[];
      for (var i = 1; i < timestampsMs.length; i++) {
        final d = timestampsMs[i] - timestampsMs[i - 1];
        if (d > 0) deltas.add(d);
      }
      if (deltas.isEmpty) {
        sampleRateHz = 1.0;
        warning = 'GPX has no timestamps — using interpolated 1 Hz.';
      } else {
        deltas.sort();
        final medianMs = deltas[deltas.length ~/ 2];
        sampleRateHz = medianMs > 0 ? 1000.0 / medianMs : 1.0;
      }
    } else {
      sampleRateHz = 1.0;
      warning = 'GPX has no timestamps — using interpolated 1 Hz.';
      // Synthesize timestamps at 1 Hz starting at epoch zero.
      for (var i = 0; i < timestampsMs.length; i++) {
        timestampsMs[i] = i * 1000;
      }
    }

    final firstTimestamp = timestampsMs.first;

    // Derive speed (km/h) and heading (compass degrees, 0=N, CW) from
    // consecutive lat/lon/time deltas when the GPX didn't include them
    // directly. Variance projection consumes `GPS_Heading`; Distance
    // synthesis (channel_provider.dart) consumes `GPS_SpeedKmh`. Without
    // these, both pipelines silently degrade for GPX imports.
    if (!sawAnySpeed) {
      _deriveSpeedKmh(latDeg, lonDeg, timestampsMs, speedKmh);
    }
    if (!sawAnyCourse) {
      _deriveHeading(latDeg, lonDeg, heading);
    }

    final channels = <ChannelData>[
      ChannelData(
        channelId: 'GPS_Latitude',
        sampleRateHz: sampleRateHz,
        samples: lat,
      ),
      ChannelData(
        channelId: 'GPS_Longitude',
        sampleRateHz: sampleRateHz,
        samples: lon,
      ),
      ChannelData(
        channelId: 'GPS_Altitude',
        sampleRateHz: sampleRateHz,
        samples: ele,
      ),
      ChannelData(
        channelId: 'GPS_EpochMs',
        sampleRateHz: sampleRateHz,
        samples: timestampsMs.map((ms) => ms.toDouble()).toList(),
      ),
      if (sawAnyHr)
        ChannelData(
          channelId: 'HR_BPM',
          sampleRateHz: sampleRateHz,
          samples: hr,
        ),
      if (sawAnyCad)
        ChannelData(
          channelId: 'Cadence_RPM',
          sampleRateHz: sampleRateHz,
          samples: cad,
        ),
      if (sawAnyPower)
        ChannelData(
          channelId: 'Power_W',
          sampleRateHz: sampleRateHz,
          samples: power,
        ),
      ChannelData(
        channelId: 'GPS_SpeedKmh',
        sampleRateHz: sampleRateHz,
        samples: speedKmh,
      ),
      ChannelData(
        channelId: 'GPS_Heading',
        sampleRateHz: sampleRateHz,
        samples: heading,
      ),
    ];

    final session = Session(
      sessionId: _uuid.v4(),
      deviceId: 'gpx-import',
      timestampUtcMs: firstTimestamp,
      bikeProfileSnapshot: '{}',
      configChecksum: '00000000',
      channels: channels,
    );

    return GpxParseResult(
      session: session,
      warning: warning,
      metadataName: metadataName,
    );
  }

  /// First direct child of [parent] whose local name equals [localName].
  static XmlElement? _firstChildLocal(XmlElement parent, String localName) {
    for (final child in parent.childElements) {
      if (child.name.local == localName) return child;
    }
    return null;
  }

  /// Fills [out] with derived speed in km/h, one entry per position sample.
  ///
  /// Forward differences inside the track and a backward difference for the
  /// last sample so length matches the input. Flat-earth scaling against the
  /// per-sample latitude is good to ~0.1% over a track-day-sized window — the
  /// errors we'd save with haversine are dominated by GPX 1 Hz quantisation.
  ///
  /// `tsMs` is per-sample UTC milliseconds. When `Δt` is zero (or negative,
  /// from out-of-order points), the sample inherits the previous derived
  /// speed to avoid divide-by-zero.
  static void _deriveSpeedKmh(
    List<double> latDeg,
    List<double> lonDeg,
    List<int> tsMs,
    List<double> out,
  ) {
    final n = latDeg.length;
    if (n == 0) return;
    out.clear();
    out.addAll(List<double>.filled(n, 0.0));
    if (n == 1) {
      out[0] = 0.0;
      return;
    }
    const latScale = 111320.0;
    var prev = 0.0;
    for (var i = 0; i < n; i++) {
      final j = (i + 1 < n) ? i + 1 : i - 1;
      final dtMs = tsMs[j] - tsMs[i];
      final dtSec = dtMs.abs() / 1000.0;
      if (dtSec <= 0) {
        out[i] = prev;
        continue;
      }
      final meanLatRad = ((latDeg[i] + latDeg[j]) * 0.5) * math.pi / 180.0;
      final lonScale = latScale * math.cos(meanLatRad);
      final dE = (lonDeg[j] - lonDeg[i]) * lonScale;
      final dN = (latDeg[j] - latDeg[i]) * latScale;
      final distM = math.sqrt(dE * dE + dN * dN);
      final mps = distM / dtSec;
      final kmh = mps * 3.6;
      out[i] = kmh;
      prev = kmh;
    }
  }

  /// Fills [out] with derived heading in compass degrees (0=N, clockwise),
  /// one entry per position sample.
  ///
  /// Initial-bearing approximation in the flat-earth tangent plane — good
  /// enough for a per-sample heading at GPX rates. When the rider is
  /// stationary (Δposition ≈ 0), heading inherits the previous sample to
  /// avoid jittery atan2(0, 0) values that would break variance projection's
  /// heading match.
  static void _deriveHeading(
    List<double> latDeg,
    List<double> lonDeg,
    List<double> out,
  ) {
    final n = latDeg.length;
    if (n == 0) return;
    out.clear();
    out.addAll(List<double>.filled(n, 0.0));
    if (n == 1) {
      out[0] = 0.0;
      return;
    }
    const latScale = 111320.0;
    var prev = 0.0;
    for (var i = 0; i < n; i++) {
      final j = (i + 1 < n) ? i + 1 : i - 1;
      final meanLatRad = ((latDeg[i] + latDeg[j]) * 0.5) * math.pi / 180.0;
      final lonScale = latScale * math.cos(meanLatRad);
      final dE = (lonDeg[j] - lonDeg[i]) * lonScale;
      final dN = (latDeg[j] - latDeg[i]) * latScale;
      // For the last sample (j = i-1), invert so heading points forward.
      final ddE = (j < i) ? -dE : dE;
      final ddN = (j < i) ? -dN : dN;
      if (ddE.abs() < 1e-6 && ddN.abs() < 1e-6) {
        out[i] = prev;
        continue;
      }
      // atan2(dE, dN) yields compass radians (0=N, CW); convert to degrees
      // and wrap to [0, 360).
      var deg = math.atan2(ddE, ddN) * 180.0 / math.pi;
      if (deg < 0) deg += 360.0;
      out[i] = deg;
      prev = deg;
    }
  }

  /// First descendant of [parent] whose local name equals [localName].
  ///
  /// Used for `<extensions>` content where the element is nested under one
  /// or more wrapper elements (`<extensions><gpxtpx:TrackPointExtension>...`)
  /// and the namespace prefix varies between exporters.
  static XmlElement? _findDescendantLocal(
    XmlElement parent,
    String localName,
  ) {
    for (final el in parent.descendantElements) {
      if (el.name.local == localName) return el;
    }
    return null;
  }
}
