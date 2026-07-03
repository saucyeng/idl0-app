import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/transport/ble_service.dart';

// ---------------------------------------------------------------------------
// DeviceStatus parsing tests
//
// BleConnection itself (connect, disconnect, control commands) wraps
// flutter_blue_plus final platform classes and requires a real device.
// Those paths are verified by manual on-device testing.
// ---------------------------------------------------------------------------

void main() {
  group('DeviceStatus.fromString —', () {
    test('all fields present — parses wifi, logging, battery correctly', () {
      // Arrange
      const status = 'WiFi: ON\nLogging: RUNNING\nBattery: 85%';

      // Act
      final result = DeviceStatus.fromString(status);

      // Assert
      expect(result.wifiOn, isTrue);
      expect(result.loggingRunning, isTrue);
      expect(result.batteryPercent, equals(85));
    });

    test('wifi OFF, logging STOPPED — parses as false', () {
      // Arrange
      const status = 'WiFi: OFF\nLogging: STOPPED\nBattery: 42%';

      // Act
      final result = DeviceStatus.fromString(status);

      // Assert
      expect(result.wifiOn, isFalse);
      expect(result.loggingRunning, isFalse);
      expect(result.batteryPercent, equals(42));
    });

    test('case-insensitive — lowercase fields parse correctly', () {
      // Arrange
      const status = 'wifi: on\nlogging: running\nbattery: 60%';

      // Act
      final result = DeviceStatus.fromString(status);

      // Assert
      expect(result.wifiOn, isTrue);
      expect(result.loggingRunning, isTrue);
      expect(result.batteryPercent, equals(60));
    });

    test('case-insensitive — mixed case fields parse correctly', () {
      // Arrange
      const status = 'WIFI: ON\nLOGGING: STOPPED\nBATTERY: 10%';

      // Act
      final result = DeviceStatus.fromString(status);

      // Assert
      expect(result.wifiOn, isTrue);
      expect(result.loggingRunning, isFalse);
      expect(result.batteryPercent, equals(10));
    });

    test('battery at 0% — parses as 0', () {
      // Arrange
      const status = 'WiFi: OFF\nLogging: STOPPED\nBattery: 0%';

      // Act
      final result = DeviceStatus.fromString(status);

      // Assert
      expect(result.batteryPercent, equals(0));
    });

    test('battery at 100% — parses as 100', () {
      // Arrange
      const status = 'WiFi: ON\nLogging: STOPPED\nBattery: 100%';

      // Act
      final result = DeviceStatus.fromString(status);

      // Assert
      expect(result.batteryPercent, equals(100));
    });

    test('missing battery field — defaults to 0', () {
      // Arrange
      const status = 'WiFi: ON\nLogging: RUNNING';

      // Act
      final result = DeviceStatus.fromString(status);

      // Assert
      expect(result.batteryPercent, equals(0));
      expect(result.wifiOn, isTrue);
    });

    test('missing wifi field — defaults to false', () {
      // Arrange
      const status = 'Logging: RUNNING\nBattery: 50%';

      // Act
      final result = DeviceStatus.fromString(status);

      // Assert
      expect(result.wifiOn, isFalse);
      expect(result.loggingRunning, isTrue);
    });

    test('empty string — all fields default', () {
      // Arrange / Act
      final result = DeviceStatus.fromString('');

      // Assert
      expect(result.wifiOn, isFalse);
      expect(result.loggingRunning, isFalse);
      expect(result.batteryPercent, equals(0));
    });

    test('unknown lines — silently ignored', () {
      // Arrange — firmware may add fields the app does not yet recognise
      const status = 'WiFi: ON\nLogging: STOPPED\nBattery: 55%\nSD: OK\nTemp: 32C';

      // Act
      final result = DeviceStatus.fromString(status);

      // Assert — known fields still parsed
      expect(result.wifiOn, isTrue);
      expect(result.loggingRunning, isFalse);
      expect(result.batteryPercent, equals(55));
    });

    test('extra whitespace around lines — trimmed correctly', () {
      // Arrange
      const status = '  WiFi: ON  \n  Logging: RUNNING  \n  Battery: 73%  ';

      // Act
      final result = DeviceStatus.fromString(status);

      // Assert
      expect(result.wifiOn, isTrue);
      expect(result.loggingRunning, isTrue);
      expect(result.batteryPercent, equals(73));
    });

    test('full §7.3 status string — all fields populated', () {
      // Arrange
      const raw = 'WiFi: ON\nLogging: RUNNING\nBattery: 87%\n'
          'SD: OK\nGPS: FIX\nIMU: PARTIAL';

      // Act
      final status = DeviceStatus.fromString(raw);

      // Assert
      expect(status.sdState, equals('OK'));
      expect(status.gpsState, equals('FIX'));
      expect(status.imuState, equals('PARTIAL'));
    });

    test('only the P4 lines present — sensor fields are null', () {
      // Arrange
      const raw = 'WiFi: OFF\nLogging: STOPPED\nBattery: 100%';

      // Act
      final status = DeviceStatus.fromString(raw);

      // Assert
      expect(status.sdState, isNull);
      expect(status.gpsState, isNull);
      expect(status.imuState, isNull);
    });

    test('sensor lines lowercase — value normalised to uppercase', () {
      // Arrange
      const raw = 'sd: ok\ngps: no fix\nimu: fail';

      // Act
      final status = DeviceStatus.fromString(raw);

      // Assert
      expect(status.sdState, equals('OK'));
      expect(status.gpsState, equals('NO FIX'));
      expect(status.imuState, equals('FAIL'));
    });

    test('no OTA line — otaPendingVerify is false', () {
      // Arrange — typical status from a committed firmware
      const raw = 'WiFi: ON\nLogging: STOPPED\nBattery: 80%\nIMU: OK';

      // Act
      final status = DeviceStatus.fromString(raw);

      // Assert
      expect(status.otaPendingVerify, isFalse);
    });

    test('OTA: PENDING_VERIFY line present — otaPendingVerify is true', () {
      // Arrange — device booted into a newly-flashed slot, awaiting commit
      const raw = 'WiFi: ON\nLogging: STOPPED\nBattery: 80%\n'
          'IMU: OK\nOTA: PENDING_VERIFY';

      // Act
      final status = DeviceStatus.fromString(raw);

      // Assert
      expect(status.otaPendingVerify, isTrue);
    });

    test('OTA line lowercase / mixed case — still parses', () {
      // Arrange — defensive parse: firmware may emit any casing
      const raw = 'WiFi: ON\nLogging: STOPPED\nBattery: 80%\n'
          'ota: pending_verify';

      // Act
      final status = DeviceStatus.fromString(raw);

      // Assert
      expect(status.otaPendingVerify, isTrue);
    });

    test('OTA line with other value (committed) — otaPendingVerify is false',
        () {
      // Arrange — once the device commits, it may drop the line OR briefly
      // emit `OTA: OK`/`COMMITTED` before dropping it. Anything that is not
      // PENDING_VERIFY must read as false so the panel hides the card.
      const raw = 'WiFi: ON\nLogging: STOPPED\nBattery: 80%\nOTA: OK';

      // Act
      final status = DeviceStatus.fromString(raw);

      // Assert
      expect(status.otaPendingVerify, isFalse);
    });

    test('OTA line in any position — order-independent', () {
      // Arrange — defensive: firmware may emit lines in any order
      const raw = 'OTA: PENDING_VERIFY\nWiFi: ON\nBattery: 80%';

      // Act
      final status = DeviceStatus.fromString(raw);

      // Assert
      expect(status.otaPendingVerify, isTrue);
      expect(status.wifiOn, isTrue);
      expect(status.batteryPercent, equals(80));
    });
  });

  group('DeviceStatus.fromCharacteristicValue —', () {
    test('round-trips UTF-8 bytes to correct status', () {
      // Arrange
      final bytes = utf8.encode('WiFi: ON\nLogging: RUNNING\nBattery: 91%');

      // Act
      final result = DeviceStatus.fromCharacteristicValue(bytes);

      // Assert
      expect(result.wifiOn, isTrue);
      expect(result.loggingRunning, isTrue);
      expect(result.batteryPercent, equals(91));
    });

    test('empty byte list — all fields default', () {
      // Arrange / Act
      final result = DeviceStatus.fromCharacteristicValue([]);

      // Assert
      expect(result.wifiOn, isFalse);
      expect(result.loggingRunning, isFalse);
      expect(result.batteryPercent, equals(0));
    });
  });
}
