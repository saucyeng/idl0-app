import 'package:flutter/material.dart';
import 'package:flutter_adaptive_scaffold/flutter_adaptive_scaffold.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auto_connect.dart';
import '../brand/brand.dart';
import '../tabs/analyze/analyze_tab.dart';
import '../tabs/data/data_tab.dart';
import '../tabs/device/device_tab.dart';
import '../tabs/maths/maths_tab.dart';
import '../tabs/settings/settings_tab.dart';

// ---------------------------------------------------------------------------
// Shell index provider
// ---------------------------------------------------------------------------

/// Active tab index shared across the app so any tab can programmatically
/// navigate to another tab. See §24 (Settings tab — Runs tab redirect).
final shellIndexProvider = StateProvider<int>((_) => 0);

// ---------------------------------------------------------------------------
// AdaptiveShell
// ---------------------------------------------------------------------------

/// Top-level navigation shell.
///
/// Hosts the [AdaptiveScaffold] which renders a [NavigationBar] (small
/// breakpoint, < 600 dp) or [NavigationRail] (medium and up) with
/// uppercase tracked labels and the [brandHivis] active indicator, per
/// Field Manual brand.
///
/// Tab widget state is preserved across switches via [IndexedStack].
/// Use [shellIndexProvider] to navigate programmatically from any widget.
class AdaptiveShell extends ConsumerWidget {
  /// Creates [AdaptiveShell].
  const AdaptiveShell({super.key});

  static const List<Widget> _pages = [
    DeviceTab(),
    DataTab(),
    MathsTab(),
    AnalyzeTab(),
    SettingsTab(),
  ];

  static const List<NavigationDestination> _destinations = [
    NavigationDestination(icon: Icon(Icons.bluetooth), label: 'DEVICE'),
    NavigationDestination(icon: Icon(Icons.travel_explore), label: 'DATA'),
    NavigationDestination(icon: Icon(Icons.functions), label: 'MATHS'),
    NavigationDestination(icon: Icon(Icons.analytics), label: 'ANALYZE'),
    NavigationDestination(icon: Icon(Icons.settings), label: 'SETTINGS'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedIndex = ref.watch(shellIndexProvider);
    // Fire the one-shot auto-connect on app open (headphones model). Non-
    // autoDispose, so it runs once for the session regardless of tab.
    ref.watch(autoConnectControllerProvider);

    return AdaptiveScaffold(
      selectedIndex: selectedIndex,
      onSelectedIndexChange: (i) =>
          ref.read(shellIndexProvider.notifier).state = i,
      useDrawer: false,
      // Trim the stock 192 dp extended rail to reclaim horizontal space for
      // the Analyze charts. The destination labels (DEVICE … SETTINGS) are
      // short and left-aligned, so 192 dp left dead space between the rail and
      // the body; 160 dp still clears the longest label (SETTINGS) without
      // horizontal clipping (the rail only scrolls vertically). See §22.
      extendedNavigationRailWidth: 160,
      destinations: _destinations,
      body: (_) => IndexedStack(
        index: selectedIndex,
        children: _pages,
      ),
    );
  }
}
