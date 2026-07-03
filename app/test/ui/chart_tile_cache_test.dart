import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/ui/tabs/analyze/chart_tile_cache.dart';

Float64List _tile(double v) =>
    Float64List.fromList(List<double>.filled(ChartTileCache.tileSizeBuckets * 2, v));

void main() {
  test('ChartTileCache.get — miss — returns null', () {
    // Arrange
    final cache = ChartTileCache();

    // Act
    final result = cache.get('s', 'ch', 0, 0);

    // Assert
    expect(result, isNull);
  });

  test('ChartTileCache.put then get — same key — returns inserted tile', () {
    // Arrange
    final cache = ChartTileCache();
    final tile = _tile(1.0);

    // Act
    cache.put('s', 'ch', 0, 0, tile);
    final result = cache.get('s', 'ch', 0, 0);

    // Assert
    expect(result, equals(tile));
  });

  test('ChartTileCache — distinct keys — stored independently', () {
    // Arrange
    final cache = ChartTileCache();

    // Act
    cache.put('s', 'ch', 0, 0, _tile(1.0));
    cache.put('s', 'ch', 0, 1, _tile(2.0));
    cache.put('s', 'ch', 1, 0, _tile(3.0));
    cache.put('s', 'other', 0, 0, _tile(4.0));

    // Assert — distinct retrievals
    expect(cache.get('s', 'ch', 0, 0)![0], equals(1.0));
    expect(cache.get('s', 'ch', 0, 1)![0], equals(2.0));
    expect(cache.get('s', 'ch', 1, 0)![0], equals(3.0));
    expect(cache.get('s', 'other', 0, 0)![0], equals(4.0));
  });

  test('ChartTileCache — same channelId across distinct sessions — stored independently', () {
    // Arrange
    final cache = ChartTileCache();

    // Act
    cache.put('sessA', 'ch', 0, 0, _tile(1.0));
    cache.put('sessB', 'ch', 0, 0, _tile(2.0));

    // Assert — distinct sessions yield distinct cache entries even for the same channelId
    expect(cache.get('sessA', 'ch', 0, 0)![0], equals(1.0));
    expect(cache.get('sessB', 'ch', 0, 0)![0], equals(2.0));
  });

  test('ChartTileCache.invalidateChannel — drops only that channel', () {
    // Arrange
    final cache = ChartTileCache();
    cache.put('s', 'keep', 0, 0, _tile(1.0));
    cache.put('s', 'drop', 0, 0, _tile(2.0));
    cache.put('s', 'drop', 1, 0, _tile(3.0));

    // Act
    cache.invalidateChannel('s', 'drop');

    // Assert
    expect(cache.get('s', 'keep', 0, 0), isNotNull);
    expect(cache.get('s', 'drop', 0, 0), isNull);
    expect(cache.get('s', 'drop', 1, 0), isNull);
  });

  test('ChartTileCache.invalidateSession — drops only that session', () {
    // Arrange
    final cache = ChartTileCache();
    cache.put('keep', 'ch', 0, 0, _tile(1.0));
    cache.put('drop', 'ch', 0, 0, _tile(2.0));
    cache.put('drop', 'ch', 1, 0, _tile(3.0));

    // Act
    cache.invalidateSession('drop');

    // Assert
    expect(cache.get('keep', 'ch', 0, 0), isNotNull);
    expect(cache.get('drop', 'ch', 0, 0), isNull);
    expect(cache.get('drop', 'ch', 1, 0), isNull);
  });

  test('ChartTileCache.clear — empties cache', () {
    // Arrange
    final cache = ChartTileCache();
    cache.put('s', 'ch', 0, 0, _tile(1.0));

    // Act
    cache.clear();

    // Assert
    expect(cache.get('s', 'ch', 0, 0), isNull);
  });

  test('ChartTileCache LRU eviction — exceeds cap — drops least-recently-used', () {
    // Arrange — small test cap of 2 tiles' worth (16 KB × 2 = 32 KB).
    final cache = ChartTileCache(maxBytes: 32 * 1024);
    cache.put('s', 'ch', 0, 0, _tile(1.0)); // 16 KB
    cache.put('s', 'ch', 0, 1, _tile(2.0)); // 32 KB total

    // Act — touch tile 0 (so tile 1 becomes LRU), then insert a 3rd tile
    cache.get('s', 'ch', 0, 0);
    cache.put('s', 'ch', 0, 2, _tile(3.0));

    // Assert — tile 0 and tile 2 remain; tile 1 was evicted
    expect(cache.get('s', 'ch', 0, 0), isNotNull);
    expect(cache.get('s', 'ch', 0, 1), isNull);
    expect(cache.get('s', 'ch', 0, 2), isNotNull);
  });

  test('ChartTileCache constants — tile size and default cap — match spec', () {
    // Arrange / Act / Assert — locks spec values.
    expect(ChartTileCache.tileSizeBuckets, equals(1024));
    expect(ChartTileCache.defaultMaxBytes, equals(30 * 1024 * 1024));
  });

  test('ChartTileCache.getOrBuild — miss — invokes builder and caches result', () async {
    // Arrange
    final cache = ChartTileCache();
    var buildCount = 0;
    final tile = _tile(7.0);

    // Act
    final result = await cache.getOrBuild(
      sessionId: 's',
      channelId: 'ch',
      tier: 0,
      tileIndex: 0,
      build: (sId, cId, t, ti) async {
        buildCount += 1;
        return tile;
      },
    );

    // Assert
    expect(result, equals(tile));
    expect(buildCount, equals(1));
    expect(cache.get('s', 'ch', 0, 0), equals(tile));
  });

  test('ChartTileCache.getOrBuild — hit — does not invoke builder', () async {
    // Arrange
    final cache = ChartTileCache();
    cache.put('s', 'ch', 0, 0, _tile(1.0));
    var buildCount = 0;

    // Act
    final result = await cache.getOrBuild(
      sessionId: 's',
      channelId: 'ch',
      tier: 0,
      tileIndex: 0,
      build: (a, b, c, d) async {
        buildCount += 1;
        return _tile(99.0);
      },
    );

    // Assert
    expect(result[0], equals(1.0));
    expect(buildCount, equals(0));
  });

  test('ChartTileCache.getOrBuild — concurrent same-key calls — builder runs once', () async {
    // Arrange
    final cache = ChartTileCache();
    var buildCount = 0;
    final completer = Completer<Float64List>();

    // Act — two concurrent calls; the second must reuse the first's in-flight Future
    final f1 = cache.getOrBuild(
      sessionId: 's',
      channelId: 'ch',
      tier: 0,
      tileIndex: 0,
      build: (a, b, c, d) {
        buildCount += 1;
        return completer.future;
      },
    );
    final f2 = cache.getOrBuild(
      sessionId: 's',
      channelId: 'ch',
      tier: 0,
      tileIndex: 0,
      build: (a, b, c, d) {
        buildCount += 1;
        return Future.value(_tile(99.0)); // should never run
      },
    );
    completer.complete(_tile(42.0));
    final r1 = await f1;
    final r2 = await f2;

    // Assert
    expect(buildCount, equals(1));
    expect(r1[0], equals(42.0));
    expect(r2[0], equals(42.0));
  });

  test('ChartTileCache.getOrBuild — builder throws — does not poison cache', () async {
    // Arrange
    final cache = ChartTileCache();
    final goodTile = _tile(42.0);

    // Act — first call throws; second call (after) succeeds
    await expectLater(
      cache.getOrBuild(
        sessionId: 's',
        channelId: 'ch',
        tier: 0,
        tileIndex: 0,
        build: (_, __, ___, ____) async => throw StateError('boom'),
      ),
      throwsStateError,
    );
    final result = await cache.getOrBuild(
      sessionId: 's',
      channelId: 'ch',
      tier: 0,
      tileIndex: 0,
      build: (_, __, ___, ____) async => goodTile,
    );

    // Assert — retry succeeds because _inFlight slot was cleaned up
    expect(result, equals(goodTile));
  });

  test(
    "ChartTileCache.invalidateChannelAcrossSessions — drops every session's tiles for that channel",
    () {
      // Arrange
      final cache = ChartTileCache();
      cache.put('sessA', 'math1', 0, 0, _tile(1.0));
      cache.put('sessB', 'math1', 0, 0, _tile(2.0));
      cache.put('sessA', 'other', 0, 0, _tile(3.0));

      // Act
      cache.invalidateChannelAcrossSessions('math1');

      // Assert — math1 dropped in both sessions; 'other' survives
      expect(cache.get('sessA', 'math1', 0, 0), isNull);
      expect(cache.get('sessB', 'math1', 0, 0), isNull);
      expect(cache.get('sessA', 'other', 0, 0), isNotNull);
    },
  );

  group('pickTier', () {
    test('pickTier — 144k samples, 1000 px chart — returns tier 2', () {
      // Arrange / Act
      final tier = pickTier(samplesInView: 144000, chartPixelWidth: 1000);

      // Assert — log8(288) ≈ 2.7 → floor → 2
      expect(tier, equals(2));
    });

    test('pickTier — 1k samples, 1000 px chart — returns tier 0 (raw)', () {
      // Arrange / Act
      final tier = pickTier(samplesInView: 1000, chartPixelWidth: 1000);

      // Assert — 2 samples/pixel → log8(2) ≈ 0.33 → floor → 0
      expect(tier, equals(0));
    });

    test('pickTier — 100M samples, 1000 px chart — picks tier above 4', () {
      // Arrange / Act — samplesPerPixel = 1e5; floor(log8(2e5)) = 5.
      final tier = pickTier(samplesInView: 100000000, chartPixelWidth: 1000);

      // Assert — the old tier-4 ceiling produced ~24k buckets (~49k spots)
      // for a 1000 px chart; tier 5 keeps the bucket count pixel-scale.
      expect(tier, equals(5));
    });

    test('pickTier — clamps to coarsest tier 6', () {
      // Arrange / Act — huge sample count, tiny chart
      final tier = pickTier(samplesInView: 1000000000000, chartPixelWidth: 10);

      // Assert
      expect(tier, equals(6));
    });

    test('pickTier — zero pixel width — returns 0 (degenerate-safe)', () {
      // Arrange / Act
      final tier = pickTier(samplesInView: 1000, chartPixelWidth: 0);

      // Assert — must not crash; tier 0 is the safe fallback
      expect(tier, equals(0));
    });
  });
}
