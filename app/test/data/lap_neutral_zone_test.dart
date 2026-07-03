import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/lap_timing.dart';
import 'package:idl0/data/session_model.dart';

void main() {
  test('Lap with no neutral visits — lapTimeMs equals rawElapsedMs', () {
    const lap = Lap(
      lapNumber: 1,
      startTimestampMs: 100,
      endTimestampMs: 1100,
      rawElapsedMs: 1000,
      lapTimeMs: 1000,
    );
    expect(lap.lapTimeMs, lap.rawElapsedMs);
    expect(lap.neutralZoneVisits, isEmpty);
  });

  test('Lap with neutral visit — lapTimeMs = raw - sumOfDurations', () {
    const lap = Lap(
      lapNumber: 1,
      startTimestampMs: 0,
      endTimestampMs: 1000,
      rawElapsedMs: 1000,
      lapTimeMs: 800,
      neutralZoneVisits: [
        NeutralZoneVisit(
          neutralZoneName: 'Pit',
          enterMs: 200,
          exitMs: 400,
        ),
      ],
    );
    expect(lap.lapTimeMs, 800);
    expect(lap.neutralZoneVisits.length, 1);
    expect(lap.neutralZoneVisits[0].durationMs, 200);
  });

  test('Lap round-trips through JSON with neutral visits', () {
    const lap = Lap(
      lapNumber: 3,
      startTimestampMs: 0,
      endTimestampMs: 1000,
      rawElapsedMs: 1000,
      lapTimeMs: 750,
      neutralZoneVisits: [
        NeutralZoneVisit(
          neutralZoneName: 'Pit',
          enterMs: 100,
          exitMs: 350,
        ),
      ],
    );
    final back = Lap.fromJson(lap.toJson());
    expect(back.lapNumber, 3);
    expect(back.rawElapsedMs, 1000);
    expect(back.lapTimeMs, 750);
    expect(back.neutralZoneVisits.length, 1);
    expect(back.neutralZoneVisits[0].neutralZoneName, 'Pit');
  });

  test('Lap.fromJson accepts legacy v1 missing rawElapsedMs/neutralZoneVisits',
      () {
    // Older sessions on disk: lapTimeMs absent in JSON keys, computed from
    // start/end. fromJson should default rawElapsedMs to (end - start),
    // lapTimeMs to the same, and neutralZoneVisits to empty.
    final back = Lap.fromJson({
      'lap_number': 1,
      'start_timestamp_ms': 0,
      'end_timestamp_ms': 1000,
      'sectors': <Map<String, dynamic>>[],
    });
    expect(back.rawElapsedMs, 1000);
    expect(back.lapTimeMs, 1000);
    expect(back.neutralZoneVisits, isEmpty);
  });
}
