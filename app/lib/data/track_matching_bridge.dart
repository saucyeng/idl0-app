import 'package:uuid/uuid.dart';

import '../src/rust/tracks.dart' as rust;
import 'lap_detector.dart' show GpsFix;
import 'session_model.dart' show Lap;
import 'track.dart';
import 'workspace.dart' show TrackVisit;

/// Maps the Dart Track library to the `idl_rs::tracks` FFI args and the engine's
/// visit windows back to app [TrackVisit]s. Reference-polyline coordinates pass
/// at the raw degrees × 1e7 channel scale (the engine geometry is
/// scale-invariant, so nothing is rescaled).

const _uuid = Uuid();

/// Converts a [Track] to the FFI [rust.TrackArg] (id + reference polyline).
rust.TrackArg trackArg(Track t) => rust.TrackArg(
      trackId: t.trackId,
      polyline: [
        for (final f in t.referencePolyline)
          rust.GpsFixArg(
            timestampMs: f.timestampMs,
            lat: f.latitudeDeg,
            lon: f.longitudeDeg,
          ),
      ],
    );

/// Maps an engine [rust.VisitWindow] to a [TrackVisit], minting a fresh UUID so
/// each rescan yields new identities (the cache-invalidation contract — see
/// §17.2 and the [TrackVisit] doc comment). [laps] are the laps detected within
/// the window, cached on the visit for the Data tab (§17.4); pass `const []`
/// when laps are not (yet) computed.
TrackVisit visitFromWindow(rust.VisitWindow w, {List<Lap> laps = const []}) =>
    TrackVisit(
      visitId: _uuid.v4(),
      trackId: w.trackId,
      startTimestampMs: w.startTimestampMs,
      endTimestampMs: w.endTimestampMs,
      laps: laps,
    );

/// Maps an engine [rust.GpsFixArg] to a Dart [GpsFix] (for authoring a Track's
/// reference polyline from a session handle).
GpsFix gpsFixFromArg(rust.GpsFixArg a) =>
    GpsFix(timestampMs: a.timestampMs, latitudeDeg: a.lat, longitudeDeg: a.lon);
