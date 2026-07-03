/// One named group of channel names plus the loose, ungrouped names, produced
/// by [groupChannelNames]. Presentation-only.
class ChannelGroups {
  /// Ordered groups. Each entry is `(label, channels)` where `label` is the
  /// shared prefix (e.g. `IMU0`) and `channels` are its member names in input
  /// order. Group order follows first appearance of each prefix in the input.
  final List<({String label, List<String> channels})> groups;

  /// Channel names that belong to no group (no `_`, or only a trailing `_`),
  /// in input order.
  final List<String> ungrouped;

  /// Creates a [ChannelGroups].
  const ChannelGroups({required this.groups, required this.ungrouped});
}

/// Buckets [names] into expandable groups by the substring before the first
/// `_`. A name with no `_`, or with nothing after its first `_`, is ungrouped.
///
/// Pure and deterministic: the same input list always yields the same result,
/// and both group order and within-group order follow [names] order (callers
/// pass an already-sorted list, so GPS/IMU0/IMU1/IMU2 come out alphabetically).
ChannelGroups groupChannelNames(List<String> names) {
  final order = <String>[]; // group labels in first-appearance order
  final byLabel = <String, List<String>>{};
  final ungrouped = <String>[];

  for (final name in names) {
    final us = name.indexOf('_');
    // No underscore, leading underscore, or trailing underscore (nothing
    // after) → ungrouped.
    if (us <= 0 || us == name.length - 1) {
      ungrouped.add(name);
      continue;
    }
    final label = name.substring(0, us);
    if (!byLabel.containsKey(label)) {
      byLabel[label] = <String>[];
      order.add(label);
    }
    byLabel[label]!.add(name);
  }

  return ChannelGroups(
    groups: [for (final l in order) (label: l, channels: byLabel[l]!)],
    ungrouped: ungrouped,
  );
}
