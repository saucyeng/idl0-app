import '../channel_source.dart';
import 'analog_channel_source.dart';
import 'digital_source.dart';

/// Signature for a factory that creates a fresh [ChannelSource] when the
/// user picks "+ Add channel…" → its picker entry.
typedef ChannelSourceFactory = ChannelSource Function();

/// One entry in the "+ Add channel…" picker.
class ChannelSourcePickerEntry {
  /// Creates a [ChannelSourcePickerEntry].
  const ChannelSourcePickerEntry({
    required this.label,
    required this.description,
    required this.factory,
  });

  /// User-facing label (e.g. `Analog channel`, `Marker button`).
  final String label;

  /// Short helper text shown under the label in the picker.
  final String description;

  /// Constructs a fresh source instance to seed the new channel.
  final ChannelSourceFactory factory;
}

/// Picker registry for `+ Add channel…`.
///
/// Hardware-pinned sources (IMU, GPS, wheels) are not in this map — they
/// are always present in a profile. Spec 2 adds an `'hrm'` entry.
final Map<String, ChannelSourcePickerEntry> kChannelSourceFactories = {
  'wheel_front': const ChannelSourcePickerEntry(
    label: 'Wheel — front',
    description:
        'Hall-effect pulse counter on the front wheel for ground-truth speed.',
    factory: _placeholderFactory,
  ),
  'wheel_rear': const ChannelSourcePickerEntry(
    label: 'Wheel — rear',
    description: 'Hall-effect pulse counter on the rear wheel.',
    factory: _placeholderFactory,
  ),
  'analog': const ChannelSourcePickerEntry(
    label: 'Analog channel',
    description: 'A signal on one ADC pin (strain gauge, potentiometer, …).',
    factory: AnalogChannelSource.empty,
  ),
  'marker': const ChannelSourcePickerEntry(
    label: 'Marker button',
    description:
        'Handlebar push-button that places a timestamped marker in the log.',
    factory: DigitalSource.marker,
  ),
};

/// Placeholder factory for picker entries (wheel_front / wheel_rear) whose
/// "add" action is just toggling a config flag, not instantiating a new
/// source. The picker dispatches by entry key in `add_channel_picker.dart`
/// — these factories are never actually invoked.
ChannelSource _placeholderFactory() =>
    throw UnsupportedError('placeholder factory — handled by picker dispatch');
