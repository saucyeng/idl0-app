/// ATT result codes returned by the IDL0 Control characteristic (FF03).
library;

/// Write completed successfully.
const int kIdl0AckOk = 0x00;

/// Write rejected because the requested action conflicts with the
/// WiFi-vs-logging mutex (e.g., WiFi-on while a recording session is active,
/// or start-logging while WiFi AP is up).
const int kIdl0AckMutexRefused = 0x03;

/// Write rejected because the device is currently busy with another
/// transient operation (calibration, OTA verify, mount). Retry later.
const int kIdl0AckBusy = 0x80;

/// Write rejected because a precondition is not met (e.g., calibration
/// requires the bike to be stationary).
const int kIdl0AckPrecondition = 0x81;

/// The command byte is known but is not yet implemented on this firmware build.
const int kIdl0AckNotImplemented = 0x82;

/// Command byte values (mirror `idl0_ble_command_t` in firmware).
const int kIdl0CmdWifiOn       = 0x01;
/// CMD_WIFI_OFF — stop the device WiFi AP.
const int kIdl0CmdWifiOff      = 0x02;
/// CMD_START_LOGGING — begin a recording session.
const int kIdl0CmdStartLogging = 0x03;
/// CMD_STOP_LOGGING — end the active recording session.
const int kIdl0CmdStopLogging  = 0x04;
/// CMD_CALIBRATE_IMU — collect static samples and recompute rotation matrix.
const int kIdl0CmdCalibrateImu = 0x05;
/// CMD_OTA_CONFIRM — commit the pending OTA image (cancel rollback).
const int kIdl0CmdOtaConfirm   = 0x06;

/// Maps an `(ATT code, command byte)` pair to a user-facing reason string.
///
/// Used by [CommandRefusedException.reason] so UI layers can surface a
/// short, friendly explanation without re-implementing the lookup. Returns
/// a `Device refused command (0xNN)` fallback for unrecognised codes so
/// failures are never silent.
String defaultAckReason(int code, int cmd) {
  assert(
    code != kIdl0AckOk,
    'defaultAckReason is for refusals (non-OK), not success.',
  );
  if (code == kIdl0AckMutexRefused) {
    switch (cmd) {
      case kIdl0CmdWifiOn:       return 'WiFi cannot start while recording.';
      case kIdl0CmdStartLogging: return 'Recording cannot start while WiFi is on.';
      default:                   return 'Device refused command (mutex, 0x03).';
    }
  }
  if (code == kIdl0AckBusy) return 'Device is busy; try again.';
  if (code == kIdl0AckPrecondition) return 'Device preconditions not met.';
  if (code == kIdl0AckNotImplemented) return 'Command not implemented on device.';
  final hex = code.toRadixString(16).padLeft(2, '0').toUpperCase();
  return 'Device refused command (0x$hex).';
}
