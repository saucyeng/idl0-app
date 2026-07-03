/// Sentinel for [CursorPair.copyWith] so callers can distinguish "leave alone"
/// from "clear to null".
const Object _unset = Object();

/// Immutable pair of A/B cursor positions for one worksheet.
///
/// A cursor with both values null = no cursors placed. Either cursor may be
/// set independently. Stored as elapsed seconds from session start.
class CursorPair {
  /// Cursor A position in seconds, or null when unset.
  final double? aSecs;

  /// Cursor B position in seconds, or null when unset.
  final double? bSecs;

  /// Creates a [CursorPair].
  const CursorPair({this.aSecs, this.bSecs});

  /// Returns a copy with the given fields replaced.
  ///
  /// Pass `aSecs: null` or `bSecs: null` to explicitly clear those fields.
  /// Omit a parameter to leave it unchanged.
  CursorPair copyWith({
    Object? aSecs = _unset,
    Object? bSecs = _unset,
  }) =>
      CursorPair(
        aSecs: identical(aSecs, _unset) ? this.aSecs : aSecs as double?,
        bSecs: identical(bSecs, _unset) ? this.bSecs : bSecs as double?,
      );

  /// Serializes to a JSON-compatible map. Null fields are omitted to keep
  /// the on-disk representation compact.
  Map<String, dynamic> toJson() => {
        if (aSecs != null) 'aSecs': aSecs,
        if (bSecs != null) 'bSecs': bSecs,
      };

  /// Deserializes from a JSON map produced by [toJson]. Missing keys load
  /// as null.
  factory CursorPair.fromJson(Map<String, dynamic> json) => CursorPair(
        aSecs: (json['aSecs'] as num?)?.toDouble(),
        bSecs: (json['bSecs'] as num?)?.toDouble(),
      );

  @override
  bool operator ==(Object other) =>
      other is CursorPair && other.aSecs == aSecs && other.bSecs == bSecs;

  @override
  int get hashCode => Object.hash(aSecs, bSecs);

  @override
  String toString() => 'CursorPair(a: $aSecs, b: $bSecs)';
}
