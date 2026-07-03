import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/transport/ack.dart';

void main() {
  group('defaultAckReason', () {
    test('0x03 + WIFI_ON -> "WiFi cannot start while recording"', () {
      expect(
        defaultAckReason(kIdl0AckMutexRefused, kIdl0CmdWifiOn),
        equals('WiFi cannot start while recording.'),
      );
    });

    test('0x03 + START_LOGGING -> "Recording cannot start while WiFi is on"', () {
      expect(
        defaultAckReason(kIdl0AckMutexRefused, kIdl0CmdStartLogging),
        equals('Recording cannot start while WiFi is on.'),
      );
    });

    test('0x80 (BUSY) -> generic busy reason', () {
      expect(defaultAckReason(kIdl0AckBusy, kIdl0CmdWifiOn), contains('busy'));
    });

    test('unknown code -> "Device refused command (0xNN)"', () {
      expect(
        defaultAckReason(0x99, kIdl0CmdWifiOn),
        equals('Device refused command (0x99).'),
      );
    });

    test('0x00 (OK) -> asserts (use is for refusals only)', () {
      expect(
        () => defaultAckReason(kIdl0AckOk, kIdl0CmdWifiOn),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
