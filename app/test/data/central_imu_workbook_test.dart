import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/workbook.dart';
import 'package:idl0/data/worksheet.dart';

/// Path to the dev artifact, relative to the `app/` package root (the cwd
/// `flutter test` runs from).
const _kArtifactPath = 'dev/central_imu_workbook.idl0wb';

void main() {
  group('central_imu_workbook.idl0wb —', () {
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
      expect(workbook.name, 'Central IMU + GPS + HR');
      expect(workbook.workbookVersion, 1);
    });

    test('worksheets — appear in the intended analysis-flow order', () {
      final names = workbook.worksheets.map((w) => w.name).toList();
      expect(
        names,
        equals([
          'Session',
          'Speed & line',
          'Cornering & braking g',
          'Ride roughness + FFT',
          'Attitude rates',
          'Heart rate / effort',
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

    test('channel guard — only IMU0 / GPS / HR raw channels are referenced', () {
      final ids = <String>{
        for (final ws in workbook.worksheets)
          for (final c in ws.charts) ...c.channelIds,
      };
      expect(ids, isNotEmpty);
      for (final id in ids) {
        expect(
          id.startsWith('IMU0_') ||
              id.startsWith('GPS_') ||
              id.startsWith('HR_'),
          isTrue,
          reason: 'unexpected raw channel "$id" — unit has no IMU1/IMU2',
        );
      }
      expect(
        ids.any((id) => id.startsWith('IMU1_') || id.startsWith('IMU2_')),
        isFalse,
      );
    });

    test('math-reference integrity — every chart math id is a defined channel',
        () {
      final defined = {for (final c in workbook.mathChannels) c.name};
      final referenced = <String>{
        for (final ws in workbook.worksheets)
          for (final c in ws.charts) ...c.mathChannelIds,
      };
      expect(referenced, isNotEmpty);
      expect(
        defined.containsAll(referenced),
        isTrue,
        reason: 'undefined math channel(s): ${referenced.difference(defined)}',
      );
    });

    test('math channels — declipped + de-tilted vehicle-frame set', () {
      final byName = {for (final c in workbook.mathChannels) c.name: c};
      expect(
        byName.keys,
        containsAll([
          'Longitudinal accel',
          'Lateral accel',
          'Vertical accel',
          'Combined horizontal g',
          'Roll rate',
          'Pitch rate',
          'Yaw rate',
        ]),
      );

      // Accel axes declip then de-rotate the 30° mount tilt about Y.
      final vert = byName['Vertical accel']!;
      expect(vert.units, 'g');
      expect(vert.expression, contains('declip([IMU0_AccelZ])'));
      expect(vert.expression, contains('rotate_axis('));
      expect(vert.expression, contains('deg2rad(30)'));

      // Combined horizontal g composes the two levelled accel channels.
      final comb = byName['Combined horizontal g']!;
      expect(comb.expression, contains('[Longitudinal accel]'));
      expect(comb.expression, contains('[Lateral accel]'));
      expect(comb.expression, contains('sqrt('));

      // Gyro rates de-rotate the same tilt.
      expect(byName['Yaw rate']!.units, 'deg/s');
      expect(byName['Yaw rate']!.expression, contains('rotate_axis('));
      expect(byName['Roll rate']!.expression, contains('[IMU0_GyroX]'));
    });

    test('Ride sheet — raw AccelZ paired with corrected Vertical, FFT on math',
        () {
      final ride = workbook.worksheets[3];
      expect(ride.charts[0].channelIds, contains('IMU0_AccelZ'));
      expect(ride.charts[0].mathChannelIds, contains('Vertical accel'));
      final fft =
          ride.charts.firstWhere((c) => c.chartType == ChartType.fft);
      expect(fft.mathChannelIds, contains('Vertical accel'));
    });

    test('toJson → fromJson — re-encoding round-trips structurally', () {
      final re = Workbook.fromJson(workbook.toJson());
      expect(re.workbookId, workbook.workbookId);
      expect(re.name, workbook.name);
      expect(
        re.worksheets.map((w) => w.name).toList(),
        equals(workbook.worksheets.map((w) => w.name).toList()),
      );
      expect(
        re.mathChannels.map((c) => c.expression).toList(),
        equals(workbook.mathChannels.map((c) => c.expression).toList()),
      );
      for (var i = 0; i < workbook.worksheets.length; i++) {
        expect(
          re.worksheets[i].charts.map((c) => c.chartType).toList(),
          equals(
            workbook.worksheets[i].charts.map((c) => c.chartType).toList(),
          ),
        );
      }
    });
  });
}
