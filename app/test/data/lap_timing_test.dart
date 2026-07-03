import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/lap_detector.dart';
import 'package:idl0/data/lap_timing.dart';

void main() {
  const g1 = LapGate(lat1Deg: 1, lon1Deg: 2, lat2Deg: 3, lon2Deg: 4, name: 'A');
  const g2 = LapGate(lat1Deg: 5, lon1Deg: 6, lat2Deg: 7, lon2Deg: 8, name: 'B');

  test('Circuit round-trips through JSON', () {
    const c = Circuit(startFinish: g1, name: 'Lap');
    final json = c.toJson();
    final back = LapTiming.fromJson(json) as Circuit;
    expect(back.name, 'Lap');
    expect(back.startFinish.lat1Deg, g1.lat1Deg);
  });

  test('PointToPoint round-trips through JSON', () {
    const p = PointToPoint(start: g1, finish: g2);
    final json = p.toJson();
    final back = LapTiming.fromJson(json) as PointToPoint;
    expect(back.start.lat1Deg, g1.lat1Deg);
    expect(back.finish.lat1Deg, g2.lat1Deg);
  });

  test('LapTiming.fromJson — unknown kind throws', () {
    expect(
      () => LapTiming.fromJson({'kind': 'wat'}),
      throwsA(isA<FormatException>()),
    );
  });

  test('NeutralZone round-trips through JSON', () {
    const z = NeutralZone(name: 'Pit', enter: g1, exit: g2);
    final back = NeutralZone.fromJson(z.toJson());
    expect(back.name, 'Pit');
    expect(back.enter.lat1Deg, g1.lat1Deg);
    expect(back.exit.lat2Deg, g2.lat2Deg);
  });

  test('NeutralZoneVisit.durationMs', () {
    const v =
        NeutralZoneVisit(neutralZoneName: 'Pit', enterMs: 100, exitMs: 250);
    expect(v.durationMs, 150);
  });
}
