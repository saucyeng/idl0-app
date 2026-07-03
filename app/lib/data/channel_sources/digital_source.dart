import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/tabs/device/source_dialogs/digital_dialog.dart';
import '../channel_source.dart';

/// Discriminator for the three kinds of digital input.
enum DigitalKind {
  /// Momentary push button — event-driven, value = monotonic press counter.
  marker,

  /// Sampled binary state — low-rate (e.g. 50 Hz) 0/1.
  level,

  /// Frequency or duty-cycle input — low-rate u32.
  pwm,
}

/// One user-added digital input channel.
///
/// Spec 1 ships [DigitalKind.marker] in the `+ Add channel…` picker;
/// [DigitalKind.level] and [DigitalKind.pwm] are supported in this class
/// but not yet exposed in the picker (factory registry omits them).
class DigitalSource extends ChannelSource {
  /// Creates a [DigitalSource].
  DigitalSource({
    required this.key,
    required this.digitalConfig,
    required this.channelIdBase,
  });

  /// Identifier inside `config.digital.channels[]` (e.g. `marker_btn`).
  final String key;

  /// View into `config['digital']`.
  final Map<String, dynamic> digitalConfig;

  /// `channel_id` this source occupies when enabled.
  final int channelIdBase;

  Map<String, dynamic>? get _entry {
    final list = digitalConfig['channels'];
    if (list is! List) return null;
    for (final raw in list) {
      if (raw is Map<String, dynamic> && raw['key'] == key) return raw;
    }
    return null;
  }

  /// The [DigitalKind] discriminator. Defaults to [DigitalKind.marker] for
  /// unknown values.
  DigitalKind get kind {
    switch (_entry?['kind']) {
      case 'level':
        return DigitalKind.level;
      case 'pwm':
        return DigitalKind.pwm;
      case 'marker':
      default:
        return DigitalKind.marker;
    }
  }

  @override
  String get sourceKey => 'digital/$key';

  @override
  String get sourceLabel => (_entry?['label'] as String?) ?? key;

  @override
  int? get sampleRateHz {
    switch (kind) {
      case DigitalKind.marker:
        return null;
      case DigitalKind.level:
      case DigitalKind.pwm:
        return 50;
    }
  }

  @override
  bool get enabled => (_entry?['enabled'] as bool?) ?? false;

  String get _units {
    switch (kind) {
      case DigitalKind.marker:
        return 'event';
      case DigitalKind.level:
        return 'bool';
      case DigitalKind.pwm:
        return 'Hz';
    }
  }

  DataType get _dataType {
    switch (kind) {
      case DigitalKind.marker:
      case DigitalKind.level:
        return DataType.u8;
      case DigitalKind.pwm:
        return DataType.u32;
    }
  }

  int get _wireRate => kind == DigitalKind.marker ? 0 : 50;

  @override
  List<ChannelRow> get channels {
    final e = _entry;
    if (e == null) return const [];
    return [
      ChannelRow(
        channelName: (e['label'] as String?) ?? key,
        units: _units,
        scale: 1.0,
        offset: 0.0,
        enabled: enabled,
        buildDialog: (_, __) => DigitalChannelDialog(channelKey: key),
      ),
    ];
  }

  @override
  List<RegistryEntry> resolveRegistryEntries() {
    if (!enabled) return const [];
    final e = _entry!;
    return [
      RegistryEntry(
        channelId: channelIdBase,
        dataType: _dataType,
        sampleRateHz: _wireRate,
        scale: 1.0,
        offset: 0.0,
        name: (e['label'] as String?) ?? key,
        units: _units,
      ),
    ];
  }

  @override
  Widget buildSourceDialog(BuildContext context, WidgetRef ref) =>
      DigitalChannelDialog(channelKey: key);

  /// Used by `kChannelSourceFactories` to create a fresh marker source when
  /// the user picks "Marker button" in `+ Add channel…`.
  static DigitalSource marker() => DigitalSource(
        key: '__new__',
        digitalConfig: const {'channels': <Map<String, dynamic>>[]},
        channelIdBase: 0,
      );
}
