import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// LRU cache for decimated chart tiles, keyed by
/// (sessionId, channelId, tier, tileIndex).
///
/// Each tile stores `2 * tileSizeBuckets` floats interleaved [min, max, ...]
/// — 16 KB per tile at the default tile size. Eviction is byte-tracked:
/// least-recently-used entries are dropped when total bytes exceed
/// [maxBytes].
///
/// Channel IDs are session-scoped registry names (e.g. `IMU0_AccelX` is the
/// same string across sessions), so the cache must key by session as well to
/// avoid cross-session collisions. The Rust side already keys by
/// `(session_id, channel_id)`; this mirrors that.
class ChartTileCache {
  /// Number of buckets per tile, at every tier. Mirrors the Rust constant.
  static const int tileSizeBuckets = 1024;

  /// Default cache size cap — 30 MB allows ~1900 tiles cached.
  static const int defaultMaxBytes = 30 * 1024 * 1024;

  /// Creates a cache with an optional byte cap. Default is [defaultMaxBytes].
  ChartTileCache({int? maxBytes}) : maxBytes = maxBytes ?? defaultMaxBytes;

  /// Soft cap on stored bytes. Eviction triggers when exceeded.
  final int maxBytes;

  // LinkedHashMap preserves insertion order; we move entries to MRU on read
  // by removing + reinserting.
  final LinkedHashMap<_TileKey, Float64List> _entries = LinkedHashMap();

  int _bytesUsed = 0;

  /// Returns the cached tile or null if absent. Touching a hit promotes it
  /// to most-recently-used.
  Float64List? get(String sessionId, String channelId, int tier, int tileIndex) {
    final key = _TileKey(sessionId, channelId, tier, tileIndex);
    final hit = _entries.remove(key);
    if (hit == null) return null;
    _entries[key] = hit; // reinsert at end (MRU)
    return hit;
  }

  /// Inserts or replaces a tile under the given key. Triggers LRU eviction
  /// if the byte cap is exceeded.
  void put(
    String sessionId,
    String channelId,
    int tier,
    int tileIndex,
    Float64List tile,
  ) {
    final key = _TileKey(sessionId, channelId, tier, tileIndex);
    final existing = _entries.remove(key);
    if (existing != null) {
      _bytesUsed -= existing.lengthInBytes;
    }
    _entries[key] = tile;
    _bytesUsed += tile.lengthInBytes;
    _evictIfNeeded();
  }

  /// Drops every tile for [channelId] within [sessionId], regardless of tier
  /// or tile index. Called when a math expression changes for that channel —
  /// other sessions' tiles for the same channelId are untouched.
  void invalidateChannel(String sessionId, String channelId) {
    final toRemove = _entries.keys
        .where((k) => k.sessionId == sessionId && k.channelId == channelId)
        .toList();
    for (final k in toRemove) {
      final t = _entries.remove(k);
      if (t != null) _bytesUsed -= t.lengthInBytes;
    }
  }

  /// Drops every tile for [channelId] across all sessions, regardless of
  /// tier or tile index. Called when a math channel expression changes —
  /// the channel ID stays the same but every session's cached output is
  /// now stale.
  void invalidateChannelAcrossSessions(String channelId) {
    final toRemove =
        _entries.keys.where((k) => k.channelId == channelId).toList();
    for (final k in toRemove) {
      final t = _entries.remove(k);
      if (t != null) _bytesUsed -= t.lengthInBytes;
    }
  }

  /// Drops every tile for [sessionId], regardless of channel/tier/index.
  /// Called from the workspace provider when a session is removed.
  void invalidateSession(String sessionId) {
    final toRemove =
        _entries.keys.where((k) => k.sessionId == sessionId).toList();
    for (final k in toRemove) {
      final t = _entries.remove(k);
      if (t != null) _bytesUsed -= t.lengthInBytes;
    }
  }

  /// Drops every tile in the cache.
  void clear() {
    _entries.clear();
    _bytesUsed = 0;
  }

  /// In-flight builders keyed by tile — used to deduplicate concurrent
  /// requests for the same tile (e.g. during a fast pinch gesture).
  final Map<_TileKey, Future<Float64List>> _inFlight = {};

  /// Returns the cached tile, or kicks off the builder and caches the result.
  /// Concurrent requests for the same key share one in-flight Future.
  ///
  /// `build` is a callback rather than an inline Rust call so tests can
  /// inject a fake decimator without needing a Rust runtime.
  ///
  /// If the builder throws, the in-flight slot is cleared via a `try/finally`
  /// block so a transient error does not poison the cache for that tile. The
  /// next `getOrBuild` call for the same key will retry from scratch. See
  /// CLAUDE.md §5 — hard crashes in response to bad data are never acceptable.
  Future<Float64List> getOrBuild({
    required String sessionId,
    required String channelId,
    required int tier,
    required int tileIndex,
    required Future<Float64List> Function(
      String sessionId,
      String channelId,
      int tier,
      int tileIndex,
    ) build,
  }) {
    final key = _TileKey(sessionId, channelId, tier, tileIndex);
    final hit = _entries.remove(key);
    if (hit != null) {
      _entries[key] = hit; // promote to MRU
      return Future.value(hit);
    }
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final Future<Float64List> future = () async {
      try {
        final tile = await build(sessionId, channelId, tier, tileIndex);
        put(sessionId, channelId, tier, tileIndex, tile);
        return tile;
      } finally {
        _inFlight.remove(key);
      }
    }();
    _inFlight[key] = future;
    return future;
  }

  void _evictIfNeeded() {
    while (_bytesUsed > maxBytes && _entries.isNotEmpty) {
      final firstKey = _entries.keys.first; // least-recently-used
      final t = _entries.remove(firstKey);
      if (t != null) _bytesUsed -= t.lengthInBytes;
    }
  }
}

class _TileKey {
  const _TileKey(this.sessionId, this.channelId, this.tier, this.tileIndex);
  final String sessionId;
  final String channelId;
  final int tier;
  final int tileIndex;

  @override
  bool operator ==(Object other) =>
      other is _TileKey &&
      other.sessionId == sessionId &&
      other.channelId == channelId &&
      other.tier == tier &&
      other.tileIndex == tileIndex;

  @override
  int get hashCode => Object.hash(sessionId, channelId, tier, tileIndex);
}

/// Picks the decimation tier for a viewport.
///
/// Returns the smallest tier `k` whose bucket size of `8^k` raw samples is
/// at least `samplesPerPixel × 2` (Nyquist-style buffer). Clamped to
/// `[0, 6]` — tier 6 buckets 262 144 raw samples, so one tile spans ~268M
/// samples: enough for any session at full zoom-out while keeping the spot
/// count pixel-scale. High tiers are cheap engine-side: `decimate_tile`
/// folds raw columns per bucket without materializing. Degenerate inputs
/// (zero or negative pixel width) return 0.
///
/// See spec §5 for the formula.
int pickTier({
  required num samplesInView,
  required num chartPixelWidth,
}) {
  if (chartPixelWidth <= 0 || samplesInView <= 0) return 0;
  final samplesPerPixel = samplesInView / chartPixelWidth;
  final log8 = math.log(samplesPerPixel * 2.0) / math.log(8.0);
  final tier = log8.floor();
  if (tier < 0) return 0;
  if (tier > 6) return 6;
  return tier;
}

/// Process-wide tile cache provider. Lives for the lifetime of the app —
/// chart widgets read it and ask for tiles; the cache survives widget rebuilds.
final chartTileCacheProvider = Provider<ChartTileCache>((ref) => ChartTileCache());
