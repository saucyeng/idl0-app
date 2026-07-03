import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/lap_detector.dart';
import 'package:idl0/data/lap_timing.dart';
import 'package:idl0/data/track.dart';

void main() {
  const g1 = LapGate(lat1Deg: 1, lon1Deg: 2, lat2Deg: 3, lon2Deg: 4, name: 'A');
  const g2 = LapGate(lat1Deg: 5, lon1Deg: 6, lat2Deg: 7, lon2Deg: 8, name: 'B');

  Map<String, dynamic> baseJson() => {
        'track_id': 'tid',
        'name': 'T',
        'venue_name': 'V',
        'sector_gates': <Map<String, dynamic>>[],
        'reference_polyline': <Map<String, dynamic>>[],
        'created_at_ms': 1,
        'updated_at_ms': 2,
      };

  test('legacy lap_gates: [] migrates to lapTiming = null', () {
    final t =
        Track.fromJson({...baseJson(), 'lap_gates': <Map<String, dynamic>>[]});
    expect(t.lapTiming, isNull);
  });

  test('legacy lap_gates: [g1] migrates to Circuit', () {
    final t = Track.fromJson({
      ...baseJson(),
      'lap_gates': [g1.toJson()],
    });
    expect(t.lapTiming, isA<Circuit>());
    expect((t.lapTiming! as Circuit).startFinish.lat1Deg, g1.lat1Deg);
  });

  test('legacy lap_gates: [g1, g2] migrates to PointToPoint', () {
    final t = Track.fromJson({
      ...baseJson(),
      'lap_gates': [g1.toJson(), g2.toJson()],
    });
    expect(t.lapTiming, isA<PointToPoint>());
    final p = t.lapTiming! as PointToPoint;
    expect(p.start.lat1Deg, g1.lat1Deg);
    expect(p.finish.lat1Deg, g2.lat1Deg);
  });

  test('legacy lap_gates: [g1, g2, g3] truncates to PointToPoint(g1, g2)', () {
    const g3 = LapGate(lat1Deg: 9, lon1Deg: 9, lat2Deg: 9, lon2Deg: 9);
    final t = Track.fromJson({
      ...baseJson(),
      'lap_gates': [g1.toJson(), g2.toJson(), g3.toJson()],
    });
    final p = t.lapTiming! as PointToPoint;
    expect(p.start.lat1Deg, g1.lat1Deg);
    expect(p.finish.lat1Deg, g2.lat1Deg);
  });

  test('new shape lap_timing round-trips', () {
    const lt = PointToPoint(start: g1, finish: g2);
    final t = Track.create(
      name: 'T',
      venueName: 'V',
      lapTiming: lt,
      neutralZones: const [NeutralZone(name: 'Pit', enter: g1, exit: g2)],
    );
    final back = Track.fromJson(t.toJson());
    expect(back.lapTiming, isA<PointToPoint>());
    expect(back.neutralZones.length, 1);
    expect(back.neutralZones[0].name, 'Pit');
  });

  test('toJson does not emit legacy lap_gates field', () {
    final t = Track.create(
      name: 'T',
      venueName: 'V',
      lapTiming: const Circuit(startFinish: g1),
    );
    expect(t.toJson().containsKey('lap_gates'), isFalse);
    expect(t.toJson()['lap_timing'], isNotNull);
  });
}
