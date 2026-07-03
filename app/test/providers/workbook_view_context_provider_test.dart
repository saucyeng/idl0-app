import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/workbook.dart';
import 'package:idl0/providers/workbook_provider.dart';
import 'package:idl0/providers/workbook_view_context_provider.dart';
import 'package:idl0/providers/workspace_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Minimal fake WorkbookNotifier — avoids async overhead in cross-provider tests
// ---------------------------------------------------------------------------

class _FakeWorkbookNotifier extends WorkbookNotifier {
  @override
  Future<List<Workbook>> build() async => [];

  @override
  Future<void> updateWorkbook(Workbook workbook) async {}

  @override
  Future<Workbook> createWorkbook({required String name}) async =>
      Workbook.create(name: name);
}

/// Builds a [ProviderContainer] with [workbookProvider] overridden so
/// [workspaceProvider] can build without hitting SQLite or Drive.
ProviderContainer _buildCrossProviderContainer() {
  SharedPreferences.setMockInitialValues(const {});
  final container = ProviderContainer(
    overrides: [
      workbookProvider.overrideWith(() => _FakeWorkbookNotifier()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('WorkbookViewContext —', () {
    test('initial state — primary and overlay are null', () {
      // Arrange
      final c = ProviderContainer();
      addTearDown(c.dispose);

      // Act
      final ctx = c.read(workbookViewContextProvider);

      // Assert
      expect(ctx.primarySessionId, isNull);
      expect(ctx.overlaySessionId, isNull);
    });

    test('setPrimary — replaces primary, leaves overlay intact', () {
      // Arrange
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(workbookViewContextProvider.notifier).setPrimary('sess-A');
      c.read(workbookViewContextProvider.notifier).setOverlay('sess-B');

      // Act
      c.read(workbookViewContextProvider.notifier).setPrimary('sess-C');

      // Assert
      final ctx = c.read(workbookViewContextProvider);
      expect(ctx.primarySessionId, 'sess-C');
      expect(ctx.overlaySessionId, 'sess-B');
    });

    test('clearPrimary — nulls primary only', () {
      // Arrange
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(workbookViewContextProvider.notifier).setPrimary('A');
      c.read(workbookViewContextProvider.notifier).setOverlay('B');

      // Act
      c.read(workbookViewContextProvider.notifier).clearPrimary();

      // Assert
      final ctx = c.read(workbookViewContextProvider);
      expect(ctx.primarySessionId, isNull);
      expect(ctx.overlaySessionId, 'B');
    });

    test('setOverlay — replaces overlay, leaves primary intact', () {
      // Arrange
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(workbookViewContextProvider.notifier).setPrimary('A');

      // Act
      c.read(workbookViewContextProvider.notifier).setOverlay('B');

      // Assert
      final ctx = c.read(workbookViewContextProvider);
      expect(ctx.primarySessionId, 'A');
      expect(ctx.overlaySessionId, 'B');
    });

    test('clearOverlay — nulls overlay only', () {
      // Arrange
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(workbookViewContextProvider.notifier).setPrimary('A');
      c.read(workbookViewContextProvider.notifier).setOverlay('B');

      // Act
      c.read(workbookViewContextProvider.notifier).clearOverlay();

      // Assert
      final ctx = c.read(workbookViewContextProvider);
      expect(ctx.primarySessionId, 'A');
      expect(ctx.overlaySessionId, isNull);
    });
  });

  group('WorkbookViewContextNotifier — cursor/zoom reset —', () {
    test('setPrimary — first bind does not clear worksheet view state', () {
      // Arrange — fresh container, workspace has a worksheet range set.
      final c = _buildCrossProviderContainer();
      c.read(workspaceProvider.notifier).setXAxisRange('ws-1', 1.0, 5.0);
      expect(c.read(workspaceProvider).worksheetRanges, isNotEmpty);

      // Act — first ever primary bind (null → A).
      c.read(workbookViewContextProvider.notifier).setPrimary('A');

      // Assert — range is untouched, because there's no "prior session" to
      // leak from. Same-session rebind shouldn't churn UI state either.
      expect(c.read(workspaceProvider).worksheetRanges, isNotEmpty);
    });

    test('setPrimary — bind transition (A → B) clears ranges + cursors', () {
      // Arrange — bind A, populate range.
      final c = _buildCrossProviderContainer();
      c.read(workbookViewContextProvider.notifier).setPrimary('A');
      c.read(workspaceProvider.notifier).setXAxisRange('ws-1', 1.0, 5.0);

      // Act — switch to B.
      c.read(workbookViewContextProvider.notifier).setPrimary('B');

      // Assert — range cleared.
      expect(c.read(workspaceProvider).worksheetRanges, isEmpty);
    });

    test('setPrimary — idempotent rebind (A → A) leaves UI state intact', () {
      // Arrange — bind A, populate range.
      final c = _buildCrossProviderContainer();
      c.read(workbookViewContextProvider.notifier).setPrimary('A');
      c.read(workspaceProvider.notifier).setXAxisRange('ws-1', 1.0, 5.0);

      // Act — re-bind same session.
      c.read(workbookViewContextProvider.notifier).setPrimary('A');

      // Assert — range untouched.
      expect(c.read(workspaceProvider).worksheetRanges, isNotEmpty);
    });
  });
}
