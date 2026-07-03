import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/session_model.dart';

void main() {
  group('SessionMetadata —', () {
    test('round-trip — serialize to JSON, deserialize, verify all fields', () {
      // Arrange
      const original = SessionMetadata(
        sessionId: 'a1b2c3d4-0000-0000-0000-000000000001',
        filePath: '/storage/IDL0/sessions/a1b2.idl0',
        workspacePath: '/storage/IDL0/sessions/a1b2.idl0w',
        createdTimestampMs: 1_714_000_000_000,
        fileSizeBytes: 52_428_800,
        rider: 'Isaac',
        bike: 'Trek Session 2024',
        bikeComment: 'Fresh tires',
        venueName: 'Whistler Bike Park',
        eventName: 'BC Cup',
        eventSession: 'Race run',
        shortComment: 'Best run of the weekend',
        longComment: 'Nailed the rock garden, lost time in the steep chute.',
        deviceId: 'A3F1',
        lapCount: 3,
        durationMs: 180_000,
      );

      // Act
      final json = original.toJson();
      final restored = SessionMetadata.fromJson(json);

      // Assert
      expect(restored.sessionId, equals(original.sessionId));
      expect(restored.filePath, equals(original.filePath));
      expect(restored.workspacePath, equals(original.workspacePath));
      expect(restored.createdTimestampMs, equals(original.createdTimestampMs));
      expect(restored.fileSizeBytes, equals(original.fileSizeBytes));
      expect(restored.rider, equals(original.rider));
      expect(restored.bike, equals(original.bike));
      expect(restored.bikeComment, equals(original.bikeComment));
      expect(restored.venueName, equals(original.venueName));
      expect(restored.eventName, equals(original.eventName));
      expect(restored.eventSession, equals(original.eventSession));
      expect(restored.shortComment, equals(original.shortComment));
      expect(restored.longComment, equals(original.longComment));
      expect(restored.deviceId, equals(original.deviceId));
      expect(restored.lapCount, equals(original.lapCount));
      expect(restored.durationMs, equals(original.durationMs));
    });

    test('round-trip — null optional fields survive JSON round-trip', () {
      // Arrange
      const original = SessionMetadata(
        sessionId: 'a1b2c3d4-0000-0000-0000-000000000002',
        filePath: '/storage/IDL0/sessions/a1b2.idl0',
        workspacePath: '/storage/IDL0/sessions/a1b2.idl0w',
        createdTimestampMs: 1_714_000_000_000,
        fileSizeBytes: 0,
        rider: '',
        bike: '',
        bikeComment: '',
        venueName: '',
        eventName: '',
        eventSession: '',
        shortComment: '',
        longComment: '',
        deviceId: '',
      );

      // Act
      final restored = SessionMetadata.fromJson(original.toJson());

      // Assert
      expect(restored.lapCount, isNull);
      expect(restored.durationMs, isNull);
    });

    test('computeDurationMs — 800 000 samples at 800 Hz — returns 1 000 000 ms',
        () {
      // Arrange
      const sampleCount = 800_000;
      const sampleRateHz = 800.0;

      // Act
      final durationMs =
          SessionMetadata.computeDurationMs(sampleCount, sampleRateHz);

      // Assert — 800 000 / 800 Hz = 1 000 s = 1 000 000 ms
      expect(durationMs, equals(1_000_000));
    });

    test('computeDurationMs — 1 sample at 100 Hz — returns 10 ms', () {
      // Arrange / Act / Assert
      expect(SessionMetadata.computeDurationMs(1, 100.0), equals(10));
    });

    test(
        'fromBikeProfile — rider pre-populated from bike profile default_rider',
        () {
      // Arrange
      const profile = BikeProfile(
        profileId: 'profile-uuid-1',
        name: 'Trek Session 2024',
        type: 'full_suspension',
        imuCount: 3,
        defaultRider: 'Isaac',
        wheelCircumferenceFrontMm: 2300,
        wheelCircumferenceRearMm: 2300,
      );

      // Act
      final meta = SessionMetadata.fromBikeProfile(
        profile,
        sessionId: 'session-uuid-1',
        filePath: '/storage/IDL0/sessions/test.idl0',
        workspacePath: '/storage/IDL0/sessions/test.idl0w',
        createdTimestampMs: 1_714_000_000_000,
        fileSizeBytes: 1024,
        deviceId: 'A3F1',
      );

      // Assert — rider comes from profile.defaultRider; bike from profile.name
      expect(meta.rider, equals('Isaac'));
      expect(meta.bike, equals('Trek Session 2024'));
    });

    test('fromBikeProfile — all editable fields default to empty string', () {
      // Arrange
      const profile = BikeProfile(
        profileId: 'profile-uuid-2',
        name: 'Specialized Enduro',
        type: 'full_suspension',
        imuCount: 2,
        defaultRider: 'Rider',
        wheelCircumferenceFrontMm: 2280,
        wheelCircumferenceRearMm: 2280,
      );

      // Act
      final meta = SessionMetadata.fromBikeProfile(
        profile,
        sessionId: 'session-uuid-2',
        filePath: '/foo.idl0',
        workspacePath: '/foo.idl0w',
        createdTimestampMs: 0,
        fileSizeBytes: 0,
        deviceId: 'B4E2',
      );

      // Assert
      expect(meta.bikeComment, isEmpty);
      expect(meta.venueName, isEmpty);
      expect(meta.eventName, isEmpty);
      expect(meta.eventSession, isEmpty);
      expect(meta.shortComment, isEmpty);
      expect(meta.longComment, isEmpty);
      expect(meta.lapCount, isNull);
      expect(meta.durationMs, isNull);
    });
  });

  group('Lap —', () {
    test('lapTimeMs — computed from start and end timestamps', () {
      // Arrange
      const lap = Lap(
        lapNumber: 1,
        startTimestampMs: 1_000_000,
        endTimestampMs: 1_095_432,
        rawElapsedMs: 95_432,
        lapTimeMs: 95_432,
      );

      // Act / Assert — 95 432 ms elapsed
      expect(lap.lapTimeMs, equals(95_432));
    });

    test('round-trip — lap with sectors serializes and deserializes correctly',
        () {
      // Arrange
      const original = Lap(
        lapNumber: 2,
        startTimestampMs: 1_000_000,
        endTimestampMs: 1_090_000,
        rawElapsedMs: 90_000,
        lapTimeMs: 90_000,
        sectors: [
          Sector(
              name: 'S1',
              startTimestampMs: 1_000_000,
              endTimestampMs: 1_040_000,),
          Sector(
              name: 'S2',
              startTimestampMs: 1_040_000,
              endTimestampMs: 1_090_000,),
        ],
      );

      // Act
      final restored = Lap.fromJson(original.toJson());

      // Assert
      expect(restored.lapNumber, equals(2));
      expect(restored.lapTimeMs, equals(90_000));
      expect(restored.sectors.length, equals(2));
      expect(restored.sectors[0].name, equals('S1'));
      expect(restored.sectors[0].sectorTimeMs, equals(40_000));
      expect(restored.sectors[1].name, equals('S2'));
      expect(restored.sectors[1].sectorTimeMs, equals(50_000));
    });

    test('toJson/fromJson — round-trips recording-seconds', () {
      // Arrange
      const original = Lap(
        lapNumber: 1,
        startTimestampMs: 1_000_000,
        endTimestampMs: 1_090_000,
        rawElapsedMs: 90_000,
        lapTimeMs: 90_000,
        startTimeSecs: 0.0,
        endTimeSecs: 90.0,
      );

      // Act
      final restored = Lap.fromJson(original.toJson());

      // Assert
      expect(restored.startTimeSecs, equals(0.0));
      expect(restored.endTimeSecs, equals(90.0));
    });
  });

  group('Sector —', () {
    test('sectorTimeMs — computed from start and end timestamps', () {
      // Arrange
      const sector = Sector(
        name: 'Rock garden',
        startTimestampMs: 2_000_000,
        endTimestampMs: 2_018_750,
      );

      // Act / Assert — 18 750 ms elapsed
      expect(sector.sectorTimeMs, equals(18_750));
    });
  });

  group('ChannelData —', () {
    test('durationMs — 8000 samples at 800 Hz — returns 10 000 ms', () {
      // Arrange
      final channel = ChannelData(
        channelId: 'IMU0_AccelZ',
        sampleRateHz: 800.0,
        samples: List.filled(8000, 0.0),
      );

      // Act / Assert — 8000 / 800 Hz = 10 s = 10 000 ms
      expect(channel.durationMs, equals(10_000));
    });

    test('durationMs — event-driven channel (sampleRateHz == 0) — returns 0',
        () {
      // Arrange
      const channel = ChannelData(
        channelId: 'WheelFront',
        sampleRateHz: 0.0,
        samples: [1.0, 2.0, 3.0],
      );

      // Act / Assert
      expect(channel.durationMs, equals(0));
    });
  });

  group('BikeProfile —', () {
    test('round-trip — serialize to JSON, deserialize, verify all fields', () {
      // Arrange
      const original = BikeProfile(
        profileId: 'profile-uuid-rt',
        name: 'Trek Session 2024',
        type: 'full_suspension',
        imuCount: 3,
        defaultRider: 'Isaac',
        wheelCircumferenceFrontMm: 2300,
        wheelCircumferenceRearMm: 2300,
      );

      // Act
      final restored = BikeProfile.fromJson(original.toJson());

      // Assert
      expect(restored.profileId, equals(original.profileId));
      expect(restored.name, equals(original.name));
      expect(restored.type, equals(original.type));
      expect(restored.imuCount, equals(original.imuCount));
      expect(restored.defaultRider, equals(original.defaultRider));
      expect(restored.wheelCircumferenceFrontMm,
          equals(original.wheelCircumferenceFrontMm),);
      expect(restored.wheelCircumferenceRearMm,
          equals(original.wheelCircumferenceRearMm),);
    });
  });
}
