/// Root of the IDL0 exception hierarchy. See §16.1.
abstract class IdlException implements Exception {
  /// Human-readable description of the failure.
  final String message;

  /// Creates an [IdlException] with [message].
  const IdlException(this.message);

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when a binary log file or workspace file cannot be parsed.
abstract class ParseException extends IdlException {
  /// Creates a [ParseException] with [message].
  const ParseException(super.message);
}

/// The first 4 bytes of a `.idl0` file are not `IDL0`.
class InvalidMagicBytesException extends ParseException {
  /// Creates an [InvalidMagicBytesException] with [message].
  const InvalidMagicBytesException(super.message);
}

/// The schema version field is higher than this build of the app supports.
class UnsupportedSchemaVersionException extends ParseException {
  /// Creates an [UnsupportedSchemaVersionException] with [message].
  const UnsupportedSchemaVersionException(super.message);
}

/// The file ends mid-record. Partial data before this point is still valid.
class TruncatedRecordException extends ParseException {
  /// Creates a [TruncatedRecordException] with [message].
  const TruncatedRecordException(super.message);
}

/// The `.idl0` file could not be read from disk (missing, permission denied,
/// or an I/O error). Surfaced when the Rust engine's path entry point fails
/// before parsing begins. See §16, §17.
class FileReadException extends ParseException {
  /// Creates a [FileReadException] with [message].
  const FileReadException(super.message);
}

/// A `.idl0t` portable Track artifact could not be parsed — malformed JSON, a
/// missing `track` object, or a `track_artifact_version` newer than this build
/// supports. See §17b.
class TrackArtifactException extends IdlException {
  /// Creates a [TrackArtifactException] with [message].
  const TrackArtifactException(super.message);
}

/// A record type byte is not in the v2 record type table. Skip and continue.
class UnknownRecordTypeException extends ParseException {
  /// Creates an [UnknownRecordTypeException] with [message].
  const UnknownRecordTypeException(super.message);
}

/// Thrown when a `.idl0p` bike-profile file cannot be parsed.
///
/// Covers: malformed JSON, missing required fields (`profile_id`, `config`),
/// or fields with the wrong type. See §23.
class ProfileParseException extends ParseException {
  /// Creates a [ProfileParseException] with [message].
  ProfileParseException(super.message);

  @override
  String toString() => 'ProfileParseException: $message';
}

/// Thrown when a `.gpx` (Garmin/Strava export) file cannot be parsed.
///
/// Covers: empty input, malformed XML, no `<trkpt>` elements, or a `<trkpt>`
/// missing required `lat`/`lon` attributes. See §12.
class GpxParseException extends ParseException {
  /// Creates a [GpxParseException] with [message].
  const GpxParseException(super.message);
}

/// The `.idl0w` workspace_version is higher than this build of the app
/// supports. The user must update the app to open this workspace.
///
/// Per §9.4: surfaces a clean error rather than silently loading partial data.
class UnsupportedWorkspaceVersionException extends ParseException {
  /// workspace_version found in the file.
  final int found;

  /// Highest workspace_version this app version understands.
  final int supported;

  /// Creates an [UnsupportedWorkspaceVersionException] for a workspace whose
  /// [found] version exceeds the [supported] maximum.
  UnsupportedWorkspaceVersionException({
    required this.found,
    required this.supported,
  }) : super(
          'This workspace was created with a newer version of IDL0 '
          '(workspace_version $found, max supported $supported). '
          'Update the app.',
        );
}

/// Thrown when IMU calibration cannot produce a valid rotation matrix.
abstract class CalibrationException extends IdlException {
  /// Creates a [CalibrationException] with [message].
  const CalibrationException(super.message);
}

/// Not enough motion during calibration to distinguish sensor axes.
class InsufficientMotionException extends CalibrationException {
  /// Creates an [InsufficientMotionException] with [message].
  const InsufficientMotionException(super.message);
}

/// Thrown when a math channel expression cannot be evaluated.
abstract class MathChannelException extends IdlException {
  /// Creates a [MathChannelException] with [message].
  const MathChannelException(super.message);
}

/// A channel referenced in an expression is not present in this session.
class UnknownChannelException extends MathChannelException {
  /// Creates an [UnknownChannelException] with [message].
  const UnknownChannelException(super.message);
}

/// The expression text is syntactically invalid.
class ExpressionSyntaxException extends MathChannelException {
  /// Creates an [ExpressionSyntaxException] with [message].
  const ExpressionSyntaxException(super.message);
}

/// Division by zero detected during math channel evaluation.
class DivisionByZeroException extends MathChannelException {
  /// Creates a [DivisionByZeroException] with [message].
  const DivisionByZeroException(super.message);
}

/// Thrown when a math channel expression fails at evaluation time.
///
/// Covers runtime errors surfaced by the Rust math engine (`idl_rs::math`, via
/// `eval_math`): mismatched sample rates between operand channels, wrong
/// argument types or counts, calls to unimplemented functions, and type errors
/// in operator chains. Distinct from [ExpressionSyntaxException] (parse-time
/// failures from [MathChannelValidator]) and [UnknownChannelException] (missing
/// channel refs). See §16.
class MathChannelEvaluationException extends MathChannelException {
  /// Creates a [MathChannelEvaluationException] with [message].
  const MathChannelEvaluationException(super.message);
}

/// Thrown by the transport layer (BLE / WiFi).
abstract class TransportException extends IdlException {
  /// Creates a [TransportException] with [message].
  const TransportException(super.message);
}

/// No device with the expected BLE service UUID was found during scan.
class DeviceNotFoundException extends TransportException {
  /// Creates a [DeviceNotFoundException] with [message].
  const DeviceNotFoundException(super.message);
}

/// The device WiFi AP did not respond — connection refused, host unreachable,
/// or HTTP-level failure (non-200 status on a control endpoint).
///
/// Distinct from [DeviceNotFoundException] which covers BLE scan misses.
class DeviceUnreachableException extends TransportException {
  /// Creates a [DeviceUnreachableException] with [message].
  const DeviceUnreachableException(super.message);
}

/// A file transfer did not complete within the retry budget.
class TransferTimeoutException extends TransportException {
  /// Creates a [TransferTimeoutException] with [message].
  const TransferTimeoutException(super.message);
}

/// The received file checksum does not match the expected value.
class TransferChecksumException extends TransportException {
  /// Creates a [TransferChecksumException] with [message].
  const TransferChecksumException(super.message);
}

/// `POST /ota` returned a non-200 status that the device-side OTA handler
/// emits intentionally. See §6.1 OTA contract.
///
/// [statusCode] is the HTTP status: 400 for a validation failure inside
/// `esp_ota_end` (image hash bad / truncated upload), 500 for a flash-write
/// or recv error during the upload. Transport-level failures (refused
/// connection, mid-stream socket close) surface as [DeviceUnreachableException]
/// instead — those are network problems, not device-emitted rejections.
class FirmwarePushException extends TransportException {
  /// HTTP status code from the device — 400 or 500.
  final int statusCode;

  /// Creates a [FirmwarePushException] for [statusCode] with [message].
  const FirmwarePushException(this.statusCode, super.message);
}

/// The firmware release feed could not be fetched or parsed — network error,
/// a non-2xx from the host, or malformed release JSON. A missing or empty
/// release is NOT an error (the catalog returns null for that). See §27.7.
class FirmwareCatalogException extends TransportException {
  /// Creates a [FirmwareCatalogException] with [message].
  const FirmwareCatalogException(super.message);
}

/// A firmware image download failed mid-stream or failed SHA-256 verification
/// against the host-published checksum. See §27.7.
class FirmwareDownloadException extends TransportException {
  /// Creates a [FirmwareDownloadException] with [message].
  const FirmwareDownloadException(super.message);
}

/// The `/files` endpoint returned a response that could not be parsed as the
/// expected JSON array `[{"name":"...","size":N}]`.
///
/// Typically indicates a firmware version mismatch — the endpoint may still
/// be returning HTML (see TODO #10 in §2).
class FileListParseException extends TransportException {
  /// Creates a [FileListParseException] with [message].
  const FileListParseException(super.message);
}

/// Thrown when a Google Drive operation fails due to missing or invalid
/// authentication. See §13 and §16.
///
/// Surfaces when [DriveService.signIn] has not been called, the OAuth token
/// has been revoked, or the Drive scope was not granted by the user.
class DriveAuthException extends TransportException {
  /// Creates a [DriveAuthException] with [message].
  const DriveAuthException(super.message);
}

/// Thrown when a Google Drive file upload fails at the API or I/O level.
/// See §13 and §16.
///
/// Surfaces on Drive API HTTP errors, quota exceeded responses, or failures
/// reading the source file from disk. [DriveAuthException] is thrown instead
/// when the root cause is authentication.
class DriveUploadException extends TransportException {
  /// Creates a [DriveUploadException] with [message].
  const DriveUploadException(super.message);
}

/// Thrown when [Workbook.fromJson] receives a `workbook_version` newer than
/// this build supports.
class UnsupportedWorkbookVersionException extends ParseException {
  /// The version found in the file.
  final int found;

  /// The highest version this build supports.
  final int supported;

  /// Creates an [UnsupportedWorkbookVersionException] for a workbook whose
  /// [found] version exceeds the [supported] maximum.
  UnsupportedWorkbookVersionException({
    required this.found,
    required this.supported,
  }) : super(
          'This workbook was created with a newer version of IDL0 '
          '(workbook_version $found, max supported $supported). '
          'Update the app.',
        );
}

/// Thrown when a `.idl0wb` file cannot be parsed as JSON or is missing
/// required fields.
class WorkbookParseException extends ParseException {
  /// Creates a [WorkbookParseException] with [message].
  const WorkbookParseException(super.message);
}

/// A video file could not be linked to a session — missing, unreadable, or
/// the container failed to open at all (SPEC §33.3).
class VideoLinkException extends IdlException {
  /// Creates a [VideoLinkException] with [message].
  const VideoLinkException(super.message);
}

/// The video's time range does not overlap the session at all — almost
/// certainly footage from a different ride. Surfaced to the user instead of
/// storing a meaningless offset (SPEC §33.3).
class VideoSyncMismatchException extends IdlException {
  /// Creates a [VideoSyncMismatchException] with [message].
  const VideoSyncMismatchException(super.message);
}

/// Thrown when the firmware refuses a Control-characteristic write by
/// returning a non-zero ATT result code.
///
/// Distinct from [DeviceUnreachableException] (transport-level failures
/// like disconnect mid-write): the device received the command, parsed it,
/// and chose to reject it. UI layers should treat this as a normal, expected
/// outcome (e.g., user tried to start WiFi while a recording was active) and
/// surface [reason] inline.
class CommandRefusedException extends TransportException {
  /// ATT result code returned by the firmware (e.g. `kIdl0AckMutexRefused`).
  final int attCode;

  /// Command byte we sent (e.g. `kIdl0CmdWifiOn`).
  final int command;

  /// Creates a [CommandRefusedException] with a user-facing [reason]
  /// (passed to [IdlException.message]) plus the raw [attCode] / [command]
  /// bytes for callers that want richer rendering.
  const CommandRefusedException({
    required this.attCode,
    required this.command,
    required String reason,
  }) : super(reason);

  /// User-facing explanation for this refusal. Alias of [message].
  String get reason => message;
}
