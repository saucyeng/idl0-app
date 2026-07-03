/// Bounds the native memory held by resident `SessionHandle`s so analyzing a
/// season's worth of sessions does not exhaust memory. Pure Dart policy — no
/// Riverpod, no Rust — so it unit-tests without the bridge. Wired into
/// Riverpod by `handleResidencyProvider` (see channel_provider.dart).
///
/// A handle is *resident* once its provider builds and pins it with
/// `ref.keepAlive()`. The controller keeps every currently-selected session
/// resident (pinned, never counted against the budget) plus the
/// most-recently-used deselected sessions whose engine-reported resident
/// bytes fit within [maxWarmBytes]; beyond that it evicts the
/// least-recently-used by closing its keep-alive link (the handle then
/// autodisposes — the provider's `onDispose` calls `handle.dispose()`, freeing
/// the Rust samples deterministically) and dropping its cached chart tiles.
class HandleResidencyController {
  /// [invalidateTiles] drops an evicted session's chart tiles
  /// (`ChartTileCache.invalidateSession`). [maxWarmBytes] is the byte budget
  /// for deselected (warm) handles — default 1 GiB. The byte figure per
  /// handle comes from the engine (`session_resident_bytes`), so the policy
  /// scales with actual session size instead of a fixed handle count.
  HandleResidencyController({
    required void Function(String sessionId) invalidateTiles,
    int maxWarmBytes = 1 << 30,
  })  : _invalidateTiles = invalidateTiles,
        _maxWarmBytes = maxWarmBytes;

  final void Function(String sessionId) _invalidateTiles;

  /// Byte budget for deselected (warm) handles. Selected handles are pinned
  /// and never count against it.
  final int _maxWarmBytes;

  /// sessionId → closure that closes that handle's `KeepAliveLink`.
  final Map<String, void Function()> _release = {};

  /// sessionId → engine-reported resident sample-storage bytes at
  /// registration time.
  final Map<String, int> _bytes = {};

  /// Resident sessionIds in LRU order — least-recently-used first, MRU last.
  final List<String> _order = [];

  /// Currently-selected sessionIds — pinned, never evicted while selected.
  Set<String> _selected = const {};

  /// Records a freshly built+kept-alive handle as resident
  /// (most-recently-used). [releaseHandle] closes its keep-alive link.
  /// [residentBytes] is the engine-reported sample-storage size of the
  /// handle. Triggers eviction if the warm set now exceeds the byte budget.
  void register(
    String sessionId,
    void Function() releaseHandle, {
    required int residentBytes,
  }) {
    _release[sessionId] = releaseHandle;
    _bytes[sessionId] = residentBytes;
    _touch(sessionId);
    _evictIfNeeded();
  }

  /// Updates the pinned set when the active selection changes. Selected
  /// sessions that are already resident are promoted to most-recently-used;
  /// eviction is recomputed (a newly deselected session may now push the warm
  /// set over budget).
  void sync(Set<String> selectedIds) {
    _selected = selectedIds;
    for (final id in selectedIds) {
      if (_release.containsKey(id)) _touch(id);
    }
    _evictIfNeeded();
  }

  void _touch(String sessionId) {
    _order.remove(sessionId);
    _order.add(sessionId);
  }

  void _evictIfNeeded() {
    final warm = _order.where((id) => !_selected.contains(id)).toList();
    var warmBytes = warm.fold<int>(0, (sum, id) => sum + (_bytes[id] ?? 0));
    var victim = 0;
    while (warmBytes > _maxWarmBytes && victim < warm.length) {
      final id = warm[victim]; // least-recently-used first
      victim++;
      warmBytes -= _bytes[id] ?? 0;
      _order.remove(id);
      _bytes.remove(id);
      _release.remove(id)?.call();
      _invalidateTiles(id);
    }
  }
}
