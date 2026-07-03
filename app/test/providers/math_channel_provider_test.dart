import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/math_channel.dart';
import 'package:idl0/data/workbook.dart';
import 'package:idl0/providers/channel_provider.dart';
import 'package:idl0/providers/math_channel_provider.dart';
import 'package:idl0/providers/workbook_provider.dart';
import 'package:idl0/ui/tabs/analyze/chart_tile_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

MathChannel _makeChannel({
  String id = 'ch-0001',
  String name = 'Test channel',
  String expression = 'integrate([IMU1_AccelZ])',
}) =>
    MathChannel(
      id: id,
      name: name,
      quantity: 'Velocity',
      units: 'm/s',
      sampleRateHz: 0.0,
      decimalPlaces: 3,
      color: '#FF2196F3',
      expression: expression,
    );

MathConstant _makeConstant({
  String id = 'const-0001',
  String name = 'g',
  double value = 9.81,
}) =>
    MathConstant(id: id, name: name, value: value);

/// In-memory [WorkbookNotifier] stand-in: holds a mutable workbook list and
/// reflects [updateWorkbook] mutations into [state] so the math-channel
/// provider (which is backed by the active workbook) can be exercised without
/// the SQLite cache / Drive stack.
class _FakeWorkbookNotifier extends WorkbookNotifier {
  _FakeWorkbookNotifier(this._workbooks);

  final List<Workbook> _workbooks;

  @override
  Future<List<Workbook>> build() async => List.of(_workbooks);

  @override
  Future<void> updateWorkbook(Workbook workbook) async {
    final i = _workbooks.indexWhere((w) => w.workbookId == workbook.workbookId);
    if (i >= 0) {
      _workbooks[i] = workbook;
    } else {
      _workbooks.add(workbook);
    }
    state = AsyncData(List.of(_workbooks));
  }
}

/// Records every cache invalidation so tests can assert that CRUD on a math
/// channel drops its stale decimated tiles. Subclassing keeps the real LRU
/// behaviour while spying on the cross-session invalidation call.
class _SpyTileCache extends ChartTileCache {
  final List<String> invalidatedChannelIds = [];

  @override
  void invalidateChannelAcrossSessions(String channelId) {
    invalidatedChannelIds.add(channelId);
    super.invalidateChannelAcrossSessions(channelId);
  }
}

/// Builds a container whose active workbook is a single empty workbook, so the
/// math-channel provider's CRUD operates on a known clean slate.
Future<ProviderContainer> _makeContainer({
  List<Override> extraOverrides = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  final workbook = Workbook.create(
    name: 'Test workbook',
    workbookId: 'wb-test',
  );
  final container = ProviderContainer(
    overrides: [
      workbookProvider.overrideWith(() => _FakeWorkbookNotifier([workbook])),
      ...extraOverrides,
    ],
  );
  addTearDown(container.dispose);
  // Resolve the workbook list so the active workbook is available.
  await container.read(workbookProvider.future);
  return container;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('mathChannelProvider — initial state —', () {
    test('an empty active workbook yields empty channel + constant lists',
        () async {
      // Arrange / Act
      final container = await _makeContainer();

      // Assert
      final state = container.read(mathChannelProvider);
      expect(state.channels, isEmpty);
      expect(state.constants, isEmpty);
      expect(state.activeChannelId, isNull);
      expect(state.validationError, isNull);
    });
  });

  group('mathChannelProvider — addChannel —', () {
    test('addChannel — new channel — active workbook contains it', () async {
      // Arrange
      final container = await _makeContainer();
      final ch = _makeChannel();

      // Act
      await container.read(mathChannelProvider.notifier).addChannel(ch);

      // Assert
      final channels = container.read(mathChannelProvider).channels;
      expect(channels, hasLength(1));
      expect(channels.first.id, equals('ch-0001'));
      expect(channels.first.name, equals('Test channel'));
    });

    test('addChannel — two channels — both present', () async {
      // Arrange
      final container = await _makeContainer();
      final notifier = container.read(mathChannelProvider.notifier);

      // Act
      await notifier.addChannel(_makeChannel(id: 'ch-0001', name: 'First'));
      await notifier.addChannel(_makeChannel(id: 'ch-0002', name: 'Second'));

      // Assert
      final channels = container.read(mathChannelProvider).channels;
      expect(channels, hasLength(2));
      expect(channels.map((c) => c.id), containsAll(['ch-0001', 'ch-0002']));
    });
  });

  group('mathChannelProvider — deleteChannel —', () {
    test('deleteChannel — existing channel — removed', () async {
      // Arrange
      final container = await _makeContainer();
      final notifier = container.read(mathChannelProvider.notifier);
      await notifier.addChannel(_makeChannel(id: 'ch-del-01'));

      // Act
      await notifier.deleteChannel('ch-del-01');

      // Assert
      expect(container.read(mathChannelProvider).channels, isEmpty);
    });

    test('deleteChannel — active channel deleted — activeChannelId cleared',
        () async {
      // Arrange
      final container = await _makeContainer();
      final notifier = container.read(mathChannelProvider.notifier);
      await notifier.addChannel(_makeChannel(id: 'ch-active'));
      notifier.setActiveChannel('ch-active');

      // Act
      await notifier.deleteChannel('ch-active');

      // Assert
      expect(container.read(mathChannelProvider).activeChannelId, isNull);
    });

    test('deleteChannel — non-active channel — activeChannelId unchanged',
        () async {
      // Arrange
      final container = await _makeContainer();
      final notifier = container.read(mathChannelProvider.notifier);
      await notifier.addChannel(_makeChannel(id: 'ch-keep'));
      await notifier.addChannel(_makeChannel(id: 'ch-remove'));
      notifier.setActiveChannel('ch-keep');

      // Act
      await notifier.deleteChannel('ch-remove');

      // Assert
      expect(
        container.read(mathChannelProvider).activeChannelId,
        equals('ch-keep'),
      );
    });
  });

  group('mathChannelProvider — updateChannel —', () {
    test('updateChannel — matched by stable id — reflects the change',
        () async {
      // Arrange
      final container = await _makeContainer();
      final notifier = container.read(mathChannelProvider.notifier);
      await notifier.addChannel(_makeChannel(id: 'ch-upd', name: 'Old name'));

      // Act — rename via the stable id (id unchanged).
      await notifier.updateChannel(
        _makeChannel(id: 'ch-upd', name: 'New name'),
      );

      // Assert
      final ch = container
          .read(mathChannelProvider)
          .channels
          .firstWhere((c) => c.id == 'ch-upd');
      expect(ch.name, equals('New name'));
    });
  });

  group('mathChannelProvider — cache invalidation after a workbook edit —', () {
    test('updateChannel — drops the channel\'s stale tiles, does not throw',
        () async {
      // Arrange — a single edit (the Maths-tab "change a number in the
      // expression" path) writes through workbookProvider, which build()
      // watches; the post-mutation cache read must not trip Riverpod's
      // "_didChangeDependency" assertion. See regression in
      // math_channel_provider.dart.
      final spy = _SpyTileCache();
      final container = await _makeContainer(
        extraOverrides: [chartTileCacheProvider.overrideWithValue(spy)],
      );
      final notifier = container.read(mathChannelProvider.notifier);
      await notifier.addChannel(_makeChannel(id: 'ch-edit', name: 'Speed'));

      // Act — edit the expression's numeric value, then immediately again.
      await notifier.updateChannel(
        _makeChannel(id: 'ch-edit', name: 'Speed', expression: '[Speed] * 2'),
      );
      await notifier.updateChannel(
        _makeChannel(id: 'ch-edit', name: 'Speed', expression: '[Speed] * 3'),
      );

      // Assert — both edits invalidated the channel's tiles (by name — tiles
      // are stored under the channel name, so 'Speed', not the id 'ch-edit')
      // and the channel reflects the last edit.
      expect(spy.invalidatedChannelIds, equals(['Speed', 'Speed']));
      expect(
        container
            .read(mathChannelProvider)
            .channels
            .single
            .expression,
        equals('[Speed] * 3'),
      );
    });

    test('deleteChannel — drops the channel\'s stale tiles, does not throw',
        () async {
      // Arrange
      final spy = _SpyTileCache();
      final container = await _makeContainer(
        extraOverrides: [chartTileCacheProvider.overrideWithValue(spy)],
      );
      final notifier = container.read(mathChannelProvider.notifier);
      await notifier.addChannel(_makeChannel(id: 'ch-gone'));

      // Act
      await notifier.deleteChannel('ch-gone');

      // Assert — invalidated by name ('Test channel'), not the id 'ch-gone'.
      expect(spy.invalidatedChannelIds, equals(['Test channel']));
      expect(container.read(mathChannelProvider).channels, isEmpty);
    });
  });

  group('mathChannelProvider — renameChannel —', () {
    test('renameChannel — rewrites [OldName] refs in other expressions',
        () async {
      // Arrange — Velocity depends on [Accel]; renaming Accel must update it.
      final container = await _makeContainer();
      final notifier = container.read(mathChannelProvider.notifier);
      await notifier.addChannel(
        _makeChannel(
          id: 'ch-accel',
          name: 'Accel',
          expression: 'declip([IMU1_AccelZ])',
        ),
      );
      await notifier.addChannel(
        _makeChannel(
          id: 'ch-vel',
          name: 'Velocity',
          expression: 'integrate([Accel])',
        ),
      );

      // Act
      await notifier.renameChannel('ch-accel', 'Acceleration');

      // Assert — the renamed channel and the dependent expression both updated.
      final channels = container.read(mathChannelProvider).channels;
      expect(
        channels.firstWhere((c) => c.id == 'ch-accel').name,
        equals('Acceleration'),
      );
      expect(
        channels.firstWhere((c) => c.id == 'ch-vel').expression,
        equals('integrate([Acceleration])'),
      );
    });

    test('renameChannel — keeps the stable id so chart refs survive', () async {
      // Arrange
      final container = await _makeContainer();
      final notifier = container.read(mathChannelProvider.notifier);
      await notifier.addChannel(_makeChannel(id: 'ch-keep', name: 'A'));

      // Act
      await notifier.renameChannel('ch-keep', 'B');

      // Assert
      final ch = container.read(mathChannelProvider).channels.single;
      expect(ch.id, equals('ch-keep'));
      expect(ch.name, equals('B'));
    });

    test('renameChannel — unchanged or empty name — no-op', () async {
      // Arrange
      final container = await _makeContainer();
      final notifier = container.read(mathChannelProvider.notifier);
      await notifier.addChannel(_makeChannel(id: 'ch-x', name: 'X'));

      // Act
      await notifier.renameChannel('ch-x', 'X'); // unchanged
      await notifier.renameChannel('ch-x', ''); // empty

      // Assert
      expect(
        container.read(mathChannelProvider).channels.single.name,
        equals('X'),
      );
    });
  });

  group('mathTileInvalidationNames —', () {
    test('no dependents — returns just the changed channel', () {
      // Arrange
      final channels = [
        _makeChannel(id: 'a', name: 'A', expression: 'integrate([IMU1_AccelZ])'),
        _makeChannel(id: 'b', name: 'B', expression: 'integrate([IMU1_AccelX])'),
      ];

      // Act
      final names = mathTileInvalidationNames(channels, 'A');

      // Assert
      expect(names, equals({'A'}));
    });

    test('transitive chain — includes every downstream dependent', () {
      // Arrange — C depends on B depends on A.
      final channels = [
        _makeChannel(id: 'a', name: 'A', expression: 'declip([IMU1_AccelZ])'),
        _makeChannel(id: 'b', name: 'B', expression: 'integrate([A])'),
        _makeChannel(id: 'c', name: 'C', expression: 'detrend([B])'),
      ];

      // Act
      final names = mathTileInvalidationNames(channels, 'A');

      // Assert — editing A makes A, B and C all stale.
      expect(names, equals({'A', 'B', 'C'}));
    });

    test('unrelated channel — excluded from the closure', () {
      // Arrange
      final channels = [
        _makeChannel(id: 'a', name: 'A', expression: 'declip([IMU1_AccelZ])'),
        _makeChannel(id: 'b', name: 'B', expression: 'integrate([A])'),
        _makeChannel(id: 'z', name: 'Z', expression: 'integrate([IMU1_AccelX])'),
      ];

      // Act
      final names = mathTileInvalidationNames(channels, 'A');

      // Assert
      expect(names, equals({'A', 'B'}));
      expect(names, isNot(contains('Z')));
    });

    test('bracket delimiters — a name is not a substring of a longer name', () {
      // Arrange — "[Fork]" must not match a reference to "[Fork vel]".
      final channels = [
        _makeChannel(id: 'f', name: 'Fork', expression: 'declip([IMU1_AccelZ])'),
        _makeChannel(
          id: 'fv',
          name: 'Fork vel',
          expression: 'integrate([IMU1_AccelX])',
        ),
        _makeChannel(id: 'd', name: 'D', expression: 'detrend([Fork vel])'),
      ];

      // Act
      final names = mathTileInvalidationNames(channels, 'Fork');

      // Assert — "Fork vel" and its dependent "D" are unrelated to "Fork".
      expect(names, equals({'Fork'}));
    });
  });

  group('mathChannelProvider — tile invalidation is keyed by name —', () {
    test('updateChannel — invalidates by the channel name, not the UUID',
        () async {
      // Arrange — tiles are stored under the channel *name* (storeAs), so
      // invalidation must use the name. The id ("ch-edit") would never match.
      final spy = _SpyTileCache();
      final container = await _makeContainer(
        extraOverrides: [chartTileCacheProvider.overrideWithValue(spy)],
      );
      final notifier = container.read(mathChannelProvider.notifier);
      await notifier.addChannel(_makeChannel(id: 'ch-edit', name: 'Speed'));

      // Act
      await notifier.updateChannel(
        _makeChannel(id: 'ch-edit', name: 'Speed', expression: '[Speed] + 1'),
      );

      // Assert
      expect(spy.invalidatedChannelIds, equals(['Speed']));
    });

    test('updateChannel — cascades to transitive dependents', () async {
      // Arrange — Velocity = integrate([Accel]); Travel = detrend([Velocity]).
      // Editing Accel must drop the stale tiles of Velocity AND Travel — the
      // bug that made fork travel/velocity show old values at full zoom.
      final spy = _SpyTileCache();
      final container = await _makeContainer(
        extraOverrides: [chartTileCacheProvider.overrideWithValue(spy)],
      );
      final notifier = container.read(mathChannelProvider.notifier);
      await notifier.addChannel(
        _makeChannel(id: 'ch-accel', name: 'Accel', expression: 'declip([IMU1_AccelZ])'),
      );
      await notifier.addChannel(
        _makeChannel(id: 'ch-vel', name: 'Velocity', expression: 'integrate([Accel])'),
      );
      await notifier.addChannel(
        _makeChannel(id: 'ch-trav', name: 'Travel', expression: 'detrend([Velocity])'),
      );

      // Act — edit the upstream channel's expression.
      await notifier.updateChannel(
        _makeChannel(id: 'ch-accel', name: 'Accel', expression: 'declip([IMU1_AccelX])'),
      );

      // Assert — every stale channel's tiles were dropped, by name.
      expect(
        spy.invalidatedChannelIds.toSet(),
        equals({'Accel', 'Velocity', 'Travel'}),
      );
    });

    test('deleteChannel — invalidates the deleted name and its dependents',
        () async {
      // Arrange
      final spy = _SpyTileCache();
      final container = await _makeContainer(
        extraOverrides: [chartTileCacheProvider.overrideWithValue(spy)],
      );
      final notifier = container.read(mathChannelProvider.notifier);
      await notifier.addChannel(
        _makeChannel(id: 'ch-base', name: 'Base', expression: 'declip([IMU1_AccelZ])'),
      );
      await notifier.addChannel(
        _makeChannel(id: 'ch-dep', name: 'Dep', expression: 'integrate([Base])'),
      );

      // Act
      await notifier.deleteChannel('ch-base');

      // Assert — the deleted channel and its now-broken dependent are dropped.
      expect(spy.invalidatedChannelIds.toSet(), equals({'Base', 'Dep'}));
    });

    test('renameChannel — drops the orphaned old-name tiles', () async {
      // Arrange
      final spy = _SpyTileCache();
      final container = await _makeContainer(
        extraOverrides: [chartTileCacheProvider.overrideWithValue(spy)],
      );
      final notifier = container.read(mathChannelProvider.notifier);
      await notifier.addChannel(_makeChannel(id: 'ch-r', name: 'OldName'));

      // Act
      await notifier.renameChannel('ch-r', 'NewName');

      // Assert — tiles keyed by the now-orphaned old name are freed.
      expect(spy.invalidatedChannelIds, equals(['OldName']));
    });
  });

  group('mathChannelProvider — setActiveChannel —', () {
    test('setActiveChannel — valid id — activeChannelId updated', () async {
      // Arrange
      final container = await _makeContainer();
      final notifier = container.read(mathChannelProvider.notifier);
      await notifier.addChannel(_makeChannel(id: 'ch-sel'));

      // Act
      notifier.setActiveChannel('ch-sel');

      // Assert
      expect(
        container.read(mathChannelProvider).activeChannelId,
        equals('ch-sel'),
      );
    });

    test('setActiveChannel — null — activeChannelId cleared', () async {
      // Arrange
      final container = await _makeContainer();
      final notifier = container.read(mathChannelProvider.notifier);
      await notifier.addChannel(_makeChannel(id: 'ch-clr'));
      notifier.setActiveChannel('ch-clr');

      // Act
      notifier.setActiveChannel(null);

      // Assert
      expect(container.read(mathChannelProvider).activeChannelId, isNull);
    });
  });

  group('mathChannelProvider — validate —', () {
    test('validate — empty expression — validationError is non-null', () async {
      // Arrange
      final container = await _makeContainer();

      // Act
      container.read(mathChannelProvider.notifier).validate('', const []);

      // Assert
      expect(container.read(mathChannelProvider).validationError, isNotNull);
    });

    test('validate — valid expression — validationError is null', () async {
      // Arrange
      final container = await _makeContainer();

      // Act
      container.read(mathChannelProvider.notifier).validate(
        'integrate([Speed])',
        const ['Speed'],
      );

      // Assert
      expect(container.read(mathChannelProvider).validationError, isNull);
    });
  });

  group('mathExpressionChannelNamesProvider —', () {
    test('unions session + math channel names, sorted & deduped', () async {
      // Arrange
      final container = await _makeContainer(
        extraOverrides: [
          availableChannelNamesProvider
              .overrideWithValue(const ['IMU1_AccelX', 'Time']),
        ],
      );
      await container
          .read(mathChannelProvider.notifier)
          .addChannel(_makeChannel(id: 'ch-m1', name: 'Declipped'));

      // Act
      final names = container.read(mathExpressionChannelNamesProvider);

      // Assert
      expect(names, equals(const ['Declipped', 'IMU1_AccelX', 'Time']));
    });

    test('a math name shared with a session channel appears once', () async {
      // Arrange
      final container = await _makeContainer(
        extraOverrides: [
          availableChannelNamesProvider.overrideWithValue(const ['Speed']),
        ],
      );
      await container
          .read(mathChannelProvider.notifier)
          .addChannel(_makeChannel(id: 'ch-dup', name: 'Speed'));

      // Act
      final names = container.read(mathExpressionChannelNamesProvider);

      // Assert
      expect(names, equals(const ['Speed']));
    });
  });

  group('mathChannelProvider — duplicateChannel —', () {
    test('duplicateChannel — copy gets a new id and " copy" name', () async {
      // Arrange
      final container = await _makeContainer();
      await container.read(mathChannelProvider.notifier).addChannel(
            _makeChannel(id: 'ch-src', name: 'Fork velocity'),
          );

      // Act
      final newId = await container
          .read(mathChannelProvider.notifier)
          .duplicateChannel('ch-src');

      // Assert
      final channels = container.read(mathChannelProvider).channels;
      expect(channels, hasLength(2));
      final copy = channels.firstWhere((c) => c.id == newId);
      expect(copy.id, isNot('ch-src'));
      expect(copy.name, equals('Fork velocity copy'));
      expect(copy.expression, equals('integrate([IMU1_AccelZ])'));
    });

    test('duplicateChannel — name collision — appends " copy 2"', () async {
      // Arrange
      final container = await _makeContainer();
      final notifier = container.read(mathChannelProvider.notifier);
      await notifier.addChannel(_makeChannel(id: 'ch-a', name: 'Speed'));
      await notifier.addChannel(_makeChannel(id: 'ch-b', name: 'Speed copy'));

      // Act
      final newId = await notifier.duplicateChannel('ch-a');

      // Assert
      final copy = container
          .read(mathChannelProvider)
          .channels
          .firstWhere((c) => c.id == newId);
      expect(copy.name, equals('Speed copy 2'));
    });

    test('duplicateChannel — unknown id — returns null, no new channel',
        () async {
      // Arrange
      final container = await _makeContainer();

      // Act
      final newId = await container
          .read(mathChannelProvider.notifier)
          .duplicateChannel('nope');

      // Assert
      expect(newId, isNull);
      expect(container.read(mathChannelProvider).channels, isEmpty);
    });
  });

  group('mathChannelProvider — constants —', () {
    test('addConstant — new constant — present on the active workbook',
        () async {
      // Arrange
      final container = await _makeContainer();

      // Act
      await container
          .read(mathChannelProvider.notifier)
          .addConstant(_makeConstant());

      // Assert
      expect(container.read(mathChannelProvider).constants, hasLength(1));
      expect(
        container.read(mathChannelProvider).constants.first.name,
        equals('g'),
      );
    });

    test('removeConstant — existing constant — removed', () async {
      // Arrange
      final container = await _makeContainer();
      await container
          .read(mathChannelProvider.notifier)
          .addConstant(_makeConstant(id: 'const-del'));

      // Act
      await container
          .read(mathChannelProvider.notifier)
          .removeConstant('const-del');

      // Assert
      expect(container.read(mathChannelProvider).constants, isEmpty);
    });
  });

  group('mathChannelProvider — generations —', () {
    test('updateChannel — bumps generation for the channel and its dependents',
        () async {
      // Arrange — base "A" and dependent "B" referencing [A].
      final container = await _makeContainer();
      final notifier = container.read(mathChannelProvider.notifier);
      final a = _makeChannel(id: 'a', name: 'A', expression: 'integrate([X])');
      final b = _makeChannel(id: 'b', name: 'B', expression: '[A] * 2');
      await notifier.addChannel(a);
      await notifier.addChannel(b);

      // Act — edit A.
      await notifier.updateChannel(a.copyWith(expression: 'integrate([X]) + 1'));

      // Assert — both A and its dependent B bumped past 0.
      final gens = container.read(mathChannelProvider).generations;
      expect(gens['A'], greaterThan(0));
      expect(gens['B'], greaterThan(0));
    });

    test('deleteChannel — bumps generation for the deleted name and dependents',
        () async {
      // Arrange
      final container = await _makeContainer();
      final notifier = container.read(mathChannelProvider.notifier);
      final a = _makeChannel(id: 'a', name: 'A', expression: 'integrate([X])');
      final b = _makeChannel(id: 'b', name: 'B', expression: '[A] * 2');
      await notifier.addChannel(a);
      await notifier.addChannel(b);

      // Act
      await notifier.deleteChannel('a');

      // Assert — the dependent B's slices must re-cut, so B is bumped.
      final gens = container.read(mathChannelProvider).generations;
      expect(gens['B'], greaterThan(0));
    });
  });
}
