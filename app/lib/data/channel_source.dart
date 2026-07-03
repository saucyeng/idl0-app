import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// §5.2 channel registry `data_type` enumeration.
///
/// Wire encoding follows the declaration order — `u8 = 0`, `u16 = 1`, …,
/// `f64 = 7` (see [DataTypeExt.wireId]).
enum DataType {
  /// 8-bit unsigned integer.
  u8,

  /// 16-bit unsigned integer.
  u16,

  /// 32-bit unsigned integer.
  u32,

  /// 8-bit signed integer.
  i8,

  /// 16-bit signed integer.
  i16,

  /// 32-bit signed integer.
  i32,

  /// 32-bit IEEE-754 float.
  f32,

  /// 64-bit IEEE-754 float.
  f64,
}

/// Width and §5.2 wire id of a [DataType].
extension DataTypeExt on DataType {
  /// Byte width of one sample in this type.
  int get byteWidth {
    switch (this) {
      case DataType.u8:
      case DataType.i8:
        return 1;
      case DataType.u16:
      case DataType.i16:
        return 2;
      case DataType.u32:
      case DataType.i32:
      case DataType.f32:
        return 4;
      case DataType.f64:
        return 8;
    }
  }

  /// Wire id used in the §5.2 channel registry entry's `data_type` byte.
  int get wireId => index;
}

/// One §5.2 channel registry entry as the app sees it.
///
/// Used at session-start to declare what each channel_id means, and by the
/// `+ Add channel…` flow / parser to materialise channel metadata.
@immutable
class RegistryEntry {
  /// Creates a [RegistryEntry].
  const RegistryEntry({
    required this.channelId,
    required this.dataType,
    required this.sampleRateHz,
    required this.scale,
    required this.offset,
    required this.name,
    required this.units,
  });

  /// 0..255, unique per session.
  final int channelId;

  /// Sample data type — see §5.2.
  final DataType dataType;

  /// 0 means event-driven (not fixed rate).
  final int sampleRateHz;

  /// Applied as `physical = stored × scale + offset`.
  final double scale;

  /// Applied as `physical = stored × scale + offset`.
  final double offset;

  /// Null-terminated ASCII channel name, max 20 chars on the wire.
  final String name;

  /// Null-terminated ASCII units, max 8 chars on the wire.
  final String units;

  @override
  bool operator ==(Object other) =>
      other is RegistryEntry &&
      other.channelId == channelId &&
      other.dataType == dataType &&
      other.sampleRateHz == sampleRateHz &&
      other.scale == scale &&
      other.offset == offset &&
      other.name == name &&
      other.units == units;

  @override
  int get hashCode => Object.hash(
        channelId,
        dataType,
        sampleRateHz,
        scale,
        offset,
        name,
        units,
      );
}

/// One row in the channels table — a single recordable channel within a
/// [ChannelSource].
class ChannelRow {
  /// Creates a [ChannelRow].
  const ChannelRow({
    required this.channelName,
    required this.units,
    required this.scale,
    required this.offset,
    required this.enabled,
    required this.buildDialog,
  });

  /// Display name (e.g. `IMU0_AccelX`, `HR_BPM`).
  final String channelName;

  /// Display units (e.g. `g`, `bpm`).
  final String units;

  /// Effective scale (read-only display — the source-level dialog usually
  /// drives the underlying field that determines this value).
  final double scale;

  /// Effective offset.
  final double offset;

  /// Whether the channel is enabled in the active profile.
  final bool enabled;

  /// Builds the per-row edit dialog. Sources whose rows are read-only (e.g.
  /// GPS-derived channels) return a no-op / informational widget.
  final Widget Function(BuildContext, WidgetRef) buildDialog;
}

/// A logical source of one or more recorded channels.
///
/// Every group in the Device-tab channels table is one [ChannelSource]:
/// the three IMUs (`ImuSource`), GPS (`GpsSource`), the wheel-speed slots
/// (`WheelSource`), each user-added analog channel (`AnalogChannelSource`),
/// each user-added digital channel (`DigitalSource`), and the future HRM
/// (`HrmSource` — Spec 2).
///
/// Each implementation is a thin **view** over a slot in the active
/// `BikeProfile.config` map — sources do not store state. Mutations flow
/// through `profileProvider.updateConfig`.
abstract class ChannelSource {
  /// Stable identifier within the profile config (e.g. `imu0`, `wheel_front`,
  /// `analog/strain_left`, `digital/marker_btn`). Used for table-state keys.
  String get sourceKey;

  /// User-facing label for the parent row (e.g. `IMU0 (sprung)`).
  String get sourceLabel;

  /// Effective rate for the parent row. `null` = event-driven.
  int? get sampleRateHz;

  /// Whole-source enable bit — drives the parent-row checkbox.
  bool get enabled;

  /// Child channels this source contributes. Length depends on the source.
  List<ChannelRow> get channels;

  /// Resolves the §5.2 registry entries this source contributes — one per
  /// enabled child channel. Empty list when the whole source is disabled.
  /// Used at push-time and by the binary dump tool.
  List<RegistryEntry> resolveRegistryEntries();

  /// Builds the source-level dialog (settings shared across all child
  /// channels — e.g. IMU ODR + ranges, GPS dynamic model, ADC rate).
  Widget buildSourceDialog(BuildContext context, WidgetRef ref);
}
