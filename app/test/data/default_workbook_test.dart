import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/workbook.dart';
import 'package:idl0/data/worksheet.dart';

/// Path to the dev artifact, relative to the `app/` package root (the cwd
/// `flutter test` runs from).
const _kArtifactPath = 'dev/default_workbook.idl0wb';

void main() {
  group('default_workbook.idl0wb —', () {
    late Workbook workbook;

    setUp(() {
      final file = File(_kArtifactPath);
      expect(
        file.existsSync(),
        isTrue,
        reason: 'dev artifact missing at $_kArtifactPath',
      );
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      workbook = Workbook.fromJson(json);
    });

    test('Workbook.fromJson — parses the artifact without throwing', () {
      expect(workbook.workbookId, isNotEmpty);
      expect(workbook.name, 'Default Analysis');
      expect(workbook.workbookVersion, 1);
    });

    test('worksheets — appear in the intended analysis-flow order', () {
      final names = workbook.worksheets.map((w) => w.name).toList();

      expect(
        names,
        equals([
          'Session',
          'Bike',
          'Suspension',
          'Airborne diag',
          'Gravity cal',
          'Frequencies',
          'Rider inputs',
        ]),
      );
    });

    test('Session sheet — is a sessionSheet with the three pinned charts', () {
      final session = workbook.worksheets.first;

      expect(session.kind, WorksheetKind.sessionSheet);
      expect(
        session.charts.map((c) => c.chartType).toList(),
        equals([
          ChartType.gpsMap,
          ChartType.lapTable,
          ChartType.lapProgression,
        ]),
      );
    });

    test('Bike sheet — speed, sprung accel (raw + declipped), frame-at-axle',
        () {
      final bike = workbook.worksheets[1];

      final channelIds = bike.charts.expand((c) => c.channelIds).toList();
      expect(channelIds, contains('GPS_SpeedKmh'));
      expect(channelIds, contains('IMU0_AccelZ'));

      final mathIds = bike.charts.expand((c) => c.mathChannelIds).toList();
      expect(mathIds, contains('Frame accel declipped'));
      expect(mathIds, contains('Front axle vert accel'));
      expect(mathIds, contains('Rear axle vert accel'));
    });

    test('Suspension sheet — accel, velocity, travel, velocity histogram', () {
      final susp = workbook.worksheets[2];

      // Per-IMU vertical axis: fork (IMU1) mounted X-up, shock (IMU2) Y-up.
      final accel = susp.charts[0];
      expect(accel.channelIds, equals(['IMU1_AccelX', 'IMU2_AccelY']));
      expect(
        accel.mathChannelIds,
        equals(['Fork accel declipped', 'Shock accel declipped']),
      );

      final velocity = susp.charts[1];
      expect(
        velocity.mathChannelIds,
        equals(['Fork velocity', 'Shock velocity']),
      );

      final travel = susp.charts[2];
      expect(
        travel.mathChannelIds,
        equals(['Fork travel', 'Shock travel']),
      );

      // Signed suspension-velocity distribution: symmetric (zero-centred)
      // histogram of the fork + shock velocity channels.
      final hist = susp.charts[3];
      expect(hist.chartType, ChartType.histogram);
      expect(hist.mathChannelIds, equals(['Fork velocity', 'Shock velocity']));
      expect(hist.histogramSymmetric, isTrue);
      expect(hist.histogramBinCount, 40);

      // Geometry-constrained estimator outputs (front/rear wheel travel +
      // velocity), surfaced as auto-evaluating math channels — they ride the
      // normal math-channel chart path (lazy eval, loading spinner), so they
      // live in mathChannelIds, not channelIds.
      final estTravel = susp.charts[4];
      expect(
        estTravel.mathChannelIds,
        equals(['Front travel (mm)', 'Rear travel (mm)']),
      );
      expect(estTravel.channelIds, isEmpty);
      final estVelocity = susp.charts[5];
      expect(
        estVelocity.mathChannelIds,
        equals(['Front velocity (mm/s)', 'Rear velocity (mm/s)']),
      );
    });

    test('Frequencies sheet — has FFT charts for fork and shock accel', () {
      final freqs = workbook.worksheets.firstWhere((w) => w.name == 'Frequencies');

      expect(freqs.charts.every((c) => c.chartType == ChartType.fft), isTrue);
      final channelIds = freqs.charts.expand((c) => c.channelIds).toList();
      expect(channelIds, equals(['IMU1_AccelX', 'IMU2_AccelY']));
    });

    test('baked math channels — declip → velocity → travel + frame-at-axle', () {
      final byName = {for (final c in workbook.mathChannels) c.name: c};

      expect(
        byName.keys,
        containsAll([
          'Frame accel declipped',
          'Fork accel declipped',
          'Shock accel declipped',
          'Fork rel accel',
          'Fork vel raw',
          'Fork velocity',
          'Shock velocity',
          'Fork travel',
          'Shock travel',
          'Front axle vert accel',
          'Rear axle vert accel',
        ]),
      );

      // Declip each IMU's vertical axis (fork X-up, shock Y-up, frame Z-up).
      expect(
        byName['Fork accel declipped']!.expression,
        'declip([IMU1_AccelX])',
      );
      expect(byName['Fork accel declipped']!.units, 'g');

      // The velocity pipeline is split across named channels: declip → relative
      // accel (unsprung − pitch-corrected frame) → pre-integration high-pass +
      // integrate → detrend, so gravity/free-fall cancel and baseline drift is
      // controlled. Assert the chain shape (cutoffs are tunable knobs), not one blob.
      final forkRel = byName['Fork rel accel']!;
      expect(forkRel.expression, contains('[Fork accel declipped]'));
      // Pitch-corrected sprung reference: subtract the frame-at-axle channel,
      // not the bottom-bracket frame accel.
      expect(forkRel.expression, contains('- [Front axle vert accel]'));

      // Pre-integration high-pass (the drift root-cause fix): integrate(butter(…))
      // with a high-pass on the relative accel.
      final forkVelRaw = byName['Fork vel raw']!;
      expect(forkVelRaw.expression, contains('"high"'));
      expect(forkVelRaw.expression, contains('integrate(butter('));

      // Final velocity detrends the raw integrated velocity → m/s.
      final forkVel = byName['Fork velocity']!;
      expect(forkVel.units, 'm/s');
      expect(forkVel.expression, contains('[Fork vel raw]'));

      // Travel integrates the velocity → metres.
      expect(byName['Fork travel']!.expression, contains('[Fork velocity]'));
      expect(byName['Fork travel']!.units, 'm');

      // Frame-at-axle: first-order pitch correction — the frame's vertical accel
      // at each axle = IMU0 vertical + (fore-aft lever × pitch angular accel).
      // Reduces to GyroY alone; the centripetal ω² terms are ~2% and drift-prone,
      // so they're dropped (verified corr 0.99972 vs the full rigid-body form).
      final front = byName['Front axle vert accel']!;
      expect(front.units, 'g');
      expect(front.expression, contains('[IMU0_AccelZ]'));
      expect(front.expression, contains('differentiate([IMU0_GyroY]'));
      expect(front.expression, contains('0.835'));
      expect(
        byName['Rear axle vert accel']!.expression,
        contains('0.445'),
      );

      // Suspension virtual sensors — the offline estimator's outputs as
      // auto-evaluating math channels (routed to suspensionEstimatorProvider by
      // mathChannelEvalProvider, not evaluated as expressions). Names match the
      // Rust bridge's stored ids; expressions are the descriptive wheel_*() forms.
      expect(
        byName.keys,
        containsAll([
          'Front travel (mm)',
          'Front velocity (mm/s)',
          'Rear travel (mm)',
          'Rear velocity (mm/s)',
        ]),
      );
      expect(byName['Front travel (mm)']!.expression, 'wheel_travel("front")');
      expect(byName['Front travel (mm)']!.units, 'mm');
      expect(byName['Rear velocity (mm/s)']!.expression, 'wheel_velocity("rear")');
    });

    test('toJson → fromJson — re-encoding round-trips structurally', () {
      final reDecoded = Workbook.fromJson(workbook.toJson());

      expect(reDecoded.workbookId, workbook.workbookId);
      expect(reDecoded.name, workbook.name);
      expect(
        reDecoded.worksheets.map((w) => w.name).toList(),
        equals(workbook.worksheets.map((w) => w.name).toList()),
      );
      expect(
        reDecoded.worksheets.map((w) => w.kind).toList(),
        equals(workbook.worksheets.map((w) => w.kind).toList()),
      );
      expect(
        reDecoded.mathChannels.map((c) => c.name).toList(),
        equals(workbook.mathChannels.map((c) => c.name).toList()),
      );
      expect(
        reDecoded.mathChannels.map((c) => c.expression).toList(),
        equals(workbook.mathChannels.map((c) => c.expression).toList()),
      );
      // Chart slots survive the round-trip (slot count + types per sheet).
      for (var i = 0; i < workbook.worksheets.length; i++) {
        expect(
          reDecoded.worksheets[i].charts.map((c) => c.chartType).toList(),
          equals(workbook.worksheets[i].charts.map((c) => c.chartType).toList()),
        );
      }
      // Histogram-only fields survive the round-trip.
      final histAfter = reDecoded.worksheets[2].charts[3];
      expect(histAfter.chartType, ChartType.histogram);
      expect(histAfter.histogramSymmetric, isTrue);
      expect(histAfter.histogramBinCount, 40);

      expect(reDecoded.createdAtMs, workbook.createdAtMs);
      expect(reDecoded.updatedAtMs, workbook.updatedAtMs);
    });
  });
}
