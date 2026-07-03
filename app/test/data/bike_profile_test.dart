import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/bike_profile.dart';
import 'package:idl0/data/exceptions.dart';

void main() {
  group('BikeProfile', () {
    final goodJson = {
      'profile_id': '550e8400-e29b-41d4-a716-446655440000',
      'profile_name': 'DH harness v2',
      'created_at_ms': 1716210000000,
      'updated_at_ms': 1716210000000,
      'config': {
        'config_version': 1,
        'device_id': '',
        'bike_profile': {'name': 'Trek Session 2024', 'default_rider': 'Isaac'},
        'imu': {'sample_rate_hz': 800},
        'gps': {'sample_rate_hz': 5},
        'wheel_speed': <String, dynamic>{},
        'analog': {'sample_rate_hz': 100, 'channels': <Map<String, dynamic>>[]},
        'digital': {'channels': <Map<String, dynamic>>[]},
      },
    };

    test('fromJson — well-formed profile — returns matching fields', () {
      // Arrange
      final json = Map<String, dynamic>.from(goodJson);

      // Act
      final p = BikeProfile.fromJson(json);

      // Assert
      expect(p.profileId, '550e8400-e29b-41d4-a716-446655440000');
      expect(p.profileName, 'DH harness v2');
      expect(p.createdAtMs, 1716210000000);
      expect(p.updatedAtMs, 1716210000000);
      expect((p.config['bike_profile'] as Map)['name'], 'Trek Session 2024');
    });

    test('toJson — round-trips through fromJson', () {
      // Arrange
      final json = Map<String, dynamic>.from(goodJson);

      // Act
      final p = BikeProfile.fromJson(json);
      final back = p.toJson();

      // Assert
      expect(back, equals(json));
    });

    test('fromJson — missing profile_id — throws ProfileParseException', () {
      // Arrange
      final bad = Map<String, dynamic>.from(goodJson)..remove('profile_id');

      // Act + Assert
      expect(() => BikeProfile.fromJson(bad),
          throwsA(isA<ProfileParseException>()),);
    });

    test('fromJson — empty profile_id — throws ProfileParseException', () {
      // Arrange
      final bad = Map<String, dynamic>.from(goodJson)..['profile_id'] = '';

      // Act + Assert
      expect(() => BikeProfile.fromJson(bad),
          throwsA(isA<ProfileParseException>()),);
    });

    test('fromJson — missing config — throws ProfileParseException', () {
      // Arrange
      final bad = Map<String, dynamic>.from(goodJson)..remove('config');

      // Act + Assert
      expect(() => BikeProfile.fromJson(bad),
          throwsA(isA<ProfileParseException>()),);
    });

    test('fromJson — missing profile_name — defaults to empty string', () {
      // Arrange
      final json = Map<String, dynamic>.from(goodJson)..remove('profile_name');

      // Act
      final p = BikeProfile.fromJson(json);

      // Assert
      expect(p.profileName, '');
    });

    test('copyWith — changes only the given field, keeps profileId', () {
      // Arrange
      final p = BikeProfile.fromJson(Map<String, dynamic>.from(goodJson));

      // Act
      final renamed = p.copyWith(profileName: 'Race day', updatedAtMs: 9999);

      // Assert
      expect(renamed.profileName, 'Race day');
      expect(renamed.updatedAtMs, 9999);
      expect(renamed.profileId, p.profileId);
      expect(renamed.createdAtMs, p.createdAtMs);
      expect(renamed.config, equals(p.config));
    });
  });

  group('BikeProfile.migrateLegacyConfig', () {
    test('drops bike_profile.type and imu_count', () {
      // Arrange
      final legacy = <String, dynamic>{
        'config_version': 1,
        'bike_profile': {
          'name': 'X',
          'type': 'full_suspension',
          'imu_count': 3,
          'default_rider': 'Y',
        },
        'imu': {'sample_rate_hz': 800},
      };

      // Act
      final migrated = BikeProfile.migrateLegacyConfig(legacy);

      // Assert
      expect(migrated['bike_profile'], {'name': 'X', 'default_rider': 'Y'});
    });

    test('converts analog.scaling map to analog.channels[] array', () {
      // Arrange
      final legacy = <String, dynamic>{
        'analog': {
          'sample_rate_hz': 100,
          'pressure_front_enabled': true,
          'pressure_rear_enabled': false,
          'scaling': {
            'pressure_front': {'units': 'bar', 'scale': 0.5, 'offset': -1.0},
            'pressure_rear': {'units': 'bar', 'scale': 0.6, 'offset': -1.2},
          },
        },
      };

      // Act
      final migrated = BikeProfile.migrateLegacyConfig(legacy);

      // Assert
      final analog = migrated['analog'] as Map<String, dynamic>;
      final list = (analog['channels'] as List).cast<Map<String, dynamic>>();
      expect(list, hasLength(2));
      expect(list[0]['key'], 'pressure_front');
      expect(list[0]['enabled'], true);
      expect(list[0]['scale'], 0.5);
      expect(list[1]['key'], 'pressure_rear');
      expect(list[1]['enabled'], false);
      expect(analog.containsKey('scaling'), isFalse);
      expect(analog.containsKey('pressure_front_enabled'), isFalse);
      expect(analog.containsKey('pressure_rear_enabled'), isFalse);
    });

    test('adds empty digital.channels array when missing', () {
      // Arrange
      final legacy = <String, dynamic>{'imu': <String, dynamic>{}};

      // Act
      final migrated = BikeProfile.migrateLegacyConfig(legacy);

      // Assert
      expect(migrated['digital'], {'channels': <Map<String, dynamic>>[]});
    });

    test('leaves already-migrated config untouched', () {
      // Arrange
      final modern = <String, dynamic>{
        'bike_profile': {'name': 'X', 'default_rider': 'Y'},
        'analog': {
          'sample_rate_hz': 100,
          'channels': [
            {
              'key': 'k',
              'label': 'L',
              'adc_pin': 4,
              'units': 'v',
              'scale': 1.0,
              'offset': 0.0,
              'enabled': true,
            },
          ],
        },
        'digital': {'channels': <Map<String, dynamic>>[]},
      };

      // Act
      final migrated = BikeProfile.migrateLegacyConfig(modern);

      // Assert
      expect(migrated, equals(modern));
    });

    test('does not mutate the input map', () {
      // Arrange
      final legacy = <String, dynamic>{
        'bike_profile': {
          'name': 'X',
          'type': 'full_suspension',
          'imu_count': 3,
        },
      };
      final before = Map<String, dynamic>.from(legacy['bike_profile'] as Map);

      // Act
      BikeProfile.migrateLegacyConfig(legacy);

      // Assert
      expect(legacy['bike_profile'], equals(before));
    });
  });
}
