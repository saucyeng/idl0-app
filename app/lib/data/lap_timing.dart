import 'lap_detector.dart';

/// Defines how a Track's lap is bounded — the two gate-arrangement modes.
/// See `docs/IDL0_SPEC.md §16`.
sealed class LapTiming {
  const LapTiming();

  /// Deserializes from JSON. Throws [FormatException] on unknown `kind`.
  factory LapTiming.fromJson(Map<String, dynamic> json) {
    switch (json['kind']) {
      case 'circuit':
        return Circuit(
          name: json['name'] as String? ?? '',
          startFinish:
              LapGate.fromJson(json['start_finish'] as Map<String, dynamic>),
        );
      case 'point_to_point':
        return PointToPoint(
          start: LapGate.fromJson(json['start'] as Map<String, dynamic>),
          finish: LapGate.fromJson(json['finish'] as Map<String, dynamic>),
        );
      default:
        throw FormatException(
          'Unknown LapTiming kind: ${json['kind']}',
        );
    }
  }

  /// Serializes to JSON. Each variant emits a `kind` discriminator.
  Map<String, dynamic> toJson();
}

/// Single gate; start equals finish. Lap n runs between consecutive crossings.
class Circuit extends LapTiming {
  /// Display label for the gate, e.g. `Start/Finish`. May be empty.
  final String name;

  /// The shared start-and-finish gate.
  final LapGate startFinish;

  /// Creates a [Circuit].
  const Circuit({required this.startFinish, this.name = ''});

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'circuit',
        'name': name,
        'start_finish': startFinish.toJson(),
      };
}

/// Two distinct gates; lap = next start crossing → next finish crossing.
class PointToPoint extends LapTiming {
  /// Gate that opens a lap.
  final LapGate start;

  /// Gate that closes a lap.
  final LapGate finish;

  /// Creates a [PointToPoint].
  const PointToPoint({required this.start, required this.finish});

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'point_to_point',
        'start': start.toJson(),
        'finish': finish.toJson(),
      };
}

/// A region whose duration is excluded from lap timing. Crossing [enter]
/// while in a lap pauses the timer; crossing [exit] resumes. The duration
/// `(exitMs - enterMs)` is subtracted from the lap. See `docs/IDL0_SPEC.md §16`.
class NeutralZone {
  /// Display name, e.g. `Pit lane`. May be empty.
  final String name;

  /// Gate that pauses lap timing on crossing.
  final LapGate enter;

  /// Gate that resumes lap timing on crossing.
  final LapGate exit;

  /// Creates a [NeutralZone].
  const NeutralZone({
    required this.name,
    required this.enter,
    required this.exit,
  });

  /// Deserializes from JSON.
  factory NeutralZone.fromJson(Map<String, dynamic> json) => NeutralZone(
        name: json['name'] as String? ?? '',
        enter: LapGate.fromJson(json['enter'] as Map<String, dynamic>),
        exit: LapGate.fromJson(json['exit'] as Map<String, dynamic>),
      );

  /// Serializes to JSON.
  Map<String, dynamic> toJson() => {
        'name': name,
        'enter': enter.toJson(),
        'exit': exit.toJson(),
      };
}

/// One detected enter→exit pair within a lap. Recorded on `Lap.neutralZoneVisits`
/// so the lap table can show what was excluded and why.
class NeutralZoneVisit {
  /// Name of the [NeutralZone] this visit belongs to.
  final String neutralZoneName;

  /// Enter-crossing timestamp, UTC ms.
  final int enterMs;

  /// Exit-crossing timestamp, UTC ms.
  final int exitMs;

  /// Creates a [NeutralZoneVisit].
  const NeutralZoneVisit({
    required this.neutralZoneName,
    required this.enterMs,
    required this.exitMs,
  });

  /// Visit duration in ms. Always non-negative for valid pairs.
  int get durationMs => exitMs - enterMs;

  /// Deserializes from JSON.
  factory NeutralZoneVisit.fromJson(Map<String, dynamic> json) =>
      NeutralZoneVisit(
        neutralZoneName: json['neutral_zone_name'] as String,
        enterMs: json['enter_ms'] as int,
        exitMs: json['exit_ms'] as int,
      );

  /// Serializes to JSON.
  Map<String, dynamic> toJson() => {
        'neutral_zone_name': neutralZoneName,
        'enter_ms': enterMs,
        'exit_ms': exitMs,
      };
}
