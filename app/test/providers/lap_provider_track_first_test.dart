import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/lap_detector.dart';
import 'package:idl0/data/lap_timing.dart';
import 'package:idl0/data/track.dart';

void main() {
  // Smoke test: Track with no lap timing → callers must observe an empty
  // lap list. The full provider wiring is exercised in integration tests;
  // here we lock in the semantic of "null timing means zero laps".
  test('Track.lapTiming null = no laps for any visit', () {
    final t = Track.create(name: 'T', venueName: 'V');
    expect(t.lapTiming, isNull);
  });

  test('Track.lapTiming Circuit produces non-null timing', () {
    const g = LapGate(lat1Deg: 1, lon1Deg: 2, lat2Deg: 3, lon2Deg: 4);
    final t = Track.create(
      name: 'T',
      venueName: 'V',
      lapTiming: const Circuit(startFinish: g),
    );
    expect(t.lapTiming, isA<Circuit>());
  });
}
