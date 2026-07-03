import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/app_settings.dart';
import '../../../providers/drive_sync_provider.dart';
import '../../../providers/settings_provider.dart';
import '../../brand/brand.dart';
import 'firmware_update_section.dart';

/// One of the seven Settings sections, used to drive the desktop two-pane
/// selection. The order matches the narrow stacked layout top-to-bottom.
enum _SettingsSection {
  /// Rider profile — debounced rider-name field.
  profile('profile'),

  /// Unit system toggle + read-only unit summary.
  units('units'),

  /// Google Drive sign-in + auto-sync switches.
  driveSync('drive sync'),

  /// OTA firmware push + commit card.
  firmware('firmware'),

  /// Read-only chart keyboard / mouse shortcut reference.
  controls('controls'),

  /// In-app how-to articles + full reference link.
  howTos('how-tos'),

  /// App version / schema / build + licenses + report issue.
  about('about');

  const _SettingsSection(this.label);

  /// Uppercase-tracked section-head label.
  final String label;
}

/// Width breakpoint (dp) at and above which Settings switches to the
/// desktop two-pane (section list + detail) layout. Matches the Data tab's
/// established wide breakpoint so the desktop chrome stays consistent
/// (`docs/IDL0_SPEC.md §24.2`).
const double _wideBreakpoint = 720;

/// Selected Settings section for the desktop two-pane layout.
///
/// Local to the Settings tab — deliberately not promoted into
/// `app/lib/providers` since it is pure view state with no cross-tab
/// consumers. Defaults to [_SettingsSection.profile].
final _selectedSettingsSectionProvider =
    StateProvider.autoDispose<_SettingsSection>(
  (_) => _SettingsSection.profile,
);

/// Tab 5 — Settings. See §27.
///
/// Seven sections: Profile, Units, Drive Sync, Firmware, Controls, How-Tos,
/// About.
///
/// Narrow (< [_wideBreakpoint] dp): a single scroll view stacks every
/// section under a quiet-field-manual head; Firmware is a [CollapsibleSection]
/// collapsed by default because OTA is run rarely.
///
/// Wide (≥ [_wideBreakpoint] dp): a two-pane desktop layout — a left list of
/// the seven sections as selectable rows and a right detail pane showing the
/// selected section's content. Every control is reachable in both layouts.
class SettingsTab extends ConsumerWidget {
  /// Creates [SettingsTab].
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isWide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    return isWide ? const _SettingsTwoPane() : const _SettingsStacked();
  }
}

/// Narrow (< [_wideBreakpoint] dp) layout — every section stacked under a
/// head in one scroll view. Unchanged from the pre-redesign Settings tab.
class _SettingsStacked extends StatelessWidget {
  const _SettingsStacked();

  @override
  Widget build(BuildContext context) {
    return const SingleChildScrollView(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MinimalSectionHead(label: 'profile'),
          _ProfileSection(),
          SizedBox(height: 12),
          MinimalSectionHead(label: 'units'),
          _UnitsSection(),
          SizedBox(height: 12),
          MinimalSectionHead(label: 'drive sync'),
          _DriveSyncSection(),
          SizedBox(height: 12),
          CollapsibleSection(
            label: 'firmware',
            child: FirmwareUpdateSection(),
          ),
          MinimalSectionHead(label: 'controls'),
          _ControlsSection(),
          SizedBox(height: 12),
          MinimalSectionHead(label: 'how-tos'),
          _HowTosSection(),
          SizedBox(height: 12),
          MinimalSectionHead(label: 'about'),
          _AboutSection(),
          SizedBox(height: 32),
        ],
      ),
    );
  }
}

/// Wide (≥ [_wideBreakpoint] dp) layout — a fixed-width left section list and
/// a right detail pane. Mirrors the Data tab's list-plus-detail desktop
/// chrome (`docs/IDL0_SPEC.md §24.2`) with a hairline [VerticalDivider]
/// between the panes.
class _SettingsTwoPane extends ConsumerWidget {
  const _SettingsTwoPane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(_selectedSettingsSectionProvider);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 240,
          child: _SectionList(selected: selected),
        ),
        const VerticalDivider(width: 1, color: brandRule),
        Expanded(child: _SectionDetail(section: selected)),
      ],
    );
  }
}

/// Left rail of the desktop two-pane layout — the seven sections as selectable
/// rows. Tapping a row sets [_selectedSettingsSectionProvider].
class _SectionList extends ConsumerWidget {
  const _SectionList({required this.selected});

  final _SettingsSection selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final section in _SettingsSection.values)
          _SectionListRow(
            section: section,
            isSelected: section == selected,
            onTap: () => ref
                .read(_selectedSettingsSectionProvider.notifier)
                .state = section,
          ),
      ],
    );
  }
}

/// A single selectable row in the desktop section list.
class _SectionListRow extends StatelessWidget {
  const _SectionListRow({
    required this.section,
    required this.isSelected,
    required this.onTap,
  });

  final _SettingsSection section;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: isSelected ? brandControlActive : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 14,
              color: isSelected ? brandGood : Colors.transparent,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                section.label.toUpperCase(),
                style: plexMono(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: isSelected ? brandFg : brandFgDim,
                  letterSpacing: brandLabelTracking,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Right detail pane of the desktop two-pane layout — the selected section's
/// head plus its full content in a scroll view. The Firmware section renders
/// its content directly (not collapsed) since it is the focused pane.
class _SectionDetail extends StatelessWidget {
  const _SectionDetail({required this.section});

  final _SettingsSection section;

  Widget _content() {
    return switch (section) {
      _SettingsSection.profile => const _ProfileSection(),
      _SettingsSection.units => const _UnitsSection(),
      _SettingsSection.driveSync => const _DriveSyncSection(),
      _SettingsSection.firmware => const FirmwareUpdateSection(),
      _SettingsSection.controls => const _ControlsSection(),
      _SettingsSection.howTos => const _HowTosSection(),
      _SettingsSection.about => const _AboutSection(),
    };
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 8, bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MinimalSectionHead(label: section.label),
          const SizedBox(height: 4),
          _content(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// §01 — Profile
// ---------------------------------------------------------------------------

class _ProfileSection extends ConsumerStatefulWidget {
  const _ProfileSection();

  @override
  ConsumerState<_ProfileSection> createState() => _ProfileSectionState();
}

class _ProfileSectionState extends ConsumerState<_ProfileSection> {
  late TextEditingController _nameCtrl;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _nameCtrl = TextEditingController(text: settings.riderName);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _nameCtrl.dispose();
    super.dispose();
  }

  void _onNameChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      ref.read(settingsProvider.notifier).setRiderName(value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: TextField(
        controller: _nameCtrl,
        decoration: const InputDecoration(
          labelText: 'RIDER NAME',
          hintText: 'Pre-filled into new sessions',
          isDense: true,
        ),
        textCapitalization: TextCapitalization.words,
        onChanged: _onNameChanged,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// §02 — Units
// ---------------------------------------------------------------------------

class _UnitsSection extends ConsumerWidget {
  const _UnitsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final system = ref.watch(settingsProvider.select((s) => s.unitSystem));

    final isImperial = system == UnitSystem.imperial;
    final speed = isImperial ? 'mph' : 'km/h';
    final distance = isImperial ? 'ft / mi' : 'm / km';
    final pressure = isImperial ? 'psi' : 'kPa';
    final temp = isImperial ? '°F' : '°C';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<UnitSystem>(
            segments: const [
              ButtonSegment(
                value: UnitSystem.imperial,
                label: Text('IMPERIAL'),
              ),
              ButtonSegment(
                value: UnitSystem.metric,
                label: Text('METRIC'),
              ),
            ],
            selected: {system},
            onSelectionChanged: (s) =>
                ref.read(settingsProvider.notifier).setUnitSystem(s.first),
          ),
          const SizedBox(height: 12),
          SpecRow(label: 'Speed', value: speed),
          SpecRow(label: 'Distance', value: distance),
          SpecRow(label: 'Pressure', value: pressure),
          SpecRow(label: 'Temperature', value: temp),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// §03 — Drive Sync
// ---------------------------------------------------------------------------

class _DriveSyncSection extends ConsumerWidget {
  const _DriveSyncSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final driveState = ref.watch(driveSyncProvider);
    final settings = ref.watch(settingsProvider);

    final isSignedIn = driveState.isSignedIn;
    final badgeLabel =
        isSignedIn ? (driveState.accountEmail ?? 'SIGNED IN') : 'NOT SIGNED IN';
    final dotColor = isSignedIn ? brandGood : brandFgDim;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: StatusDot(label: badgeLabel, color: dotColor),
              ),
              if (driveState.isSigningIn)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                )
              else
                QuietButton(
                  label: isSignedIn ? 'Sign out' : 'Sign in',
                  onPressed: isSignedIn
                      ? () => ref.read(driveSyncProvider.notifier).signOut()
                      : () => ref.read(driveSyncProvider.notifier).signIn(),
                ),
            ],
          ),
          const SizedBox(height: 16),
          _DriveSyncSwitch(
            title: 'AUTO-SYNC AFTER DOWNLOAD',
            subtitle: 'Upload to Drive when a session finishes',
            value: settings.autoSyncOnDownload,
            onChanged: (v) =>
                ref.read(settingsProvider.notifier).setAutoSyncOnDownload(v),
          ),
          _DriveSyncSwitch(
            title: 'SYNC ON WIFI ONLY',
            subtitle: 'Restrict uploads to WiFi connections',
            value: settings.syncOnWifiOnly,
            onChanged: (v) =>
                ref.read(settingsProvider.notifier).setSyncOnWifiOnly(v),
          ),
          _DriveSyncSwitch(
            title: 'AUTO-SYNC ON CONNECT',
            subtitle: 'Connect-and-forget: download all new files '
                'automatically. Off shows a file picker.',
            value: settings.autoSyncOnOpen,
            onChanged: (v) =>
                ref.read(settingsProvider.notifier).setAutoSyncOnOpen(v),
          ),
          if (driveState.lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: NoteBlock(
                borderColor: brandAccent,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text(
                  driveState.lastError!,
                  style: plexSans(
                    color: brandAccent,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One Drive-sync toggle row — an uppercase mono title + sans subtitle over a
/// [SwitchListTile] whose "on" colour resolves to a saturated brand token
/// ([brandGood]) per the saturated-palette guidance, instead of the Material
/// default. Kept a switch (not a checkbox) per the Settings re-skin decision.
class _DriveSyncSwitch extends StatelessWidget {
  const _DriveSyncSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  /// Uppercase tracked mono title.
  final String title;

  /// Sans-serif explainer beneath the title — kept legible for the long
  /// auto-sync-on-connect copy.
  final String subtitle;

  /// Current toggle value.
  final bool value;

  /// Called with the new value when the switch is flipped.
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      activeThumbColor: brandGood,
      title: Text(
        title,
        style: plexMono(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: brandFg,
          letterSpacing: brandLabelTracking,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: plexSans(fontSize: 12, color: brandFgDim),
      ),
      value: value,
      onChanged: onChanged,
    );
  }
}

// ---------------------------------------------------------------------------
// §04 — Controls (chart shortcut reference)
// ---------------------------------------------------------------------------

/// Read-only reference of the chart keyboard / mouse shortcuts so they are
/// discoverable outside the right-click menu. The keyboard rows mirror
/// [kDefaultChartBindings] and the wheel rows mirror [wheelModeFor]
/// ([WheelMode] in `chart_action.dart`) — keep them in sync when those change.
/// Settings-backed rebinding is a v2 follow-up.
class _ControlsSection extends StatelessWidget {
  const _ControlsSection();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ControlsGroup(
            title: 'mouse wheel',
            rows: [
              ('Zoom at cursor', 'Ctrl + Wheel'),
              ('Pan', 'Shift + Wheel'),
              ('Scroll worksheet', 'Wheel'),
            ],
          ),
          SizedBox(height: 12),
          _ControlsGroup(
            title: 'mouse',
            rows: [
              ('Place cursor', 'Left-click'),
              ('Context menu', 'Right-click'),
              ('Zoom to box', 'Right-click + drag'),
              ('Reset view', 'Double-click'),
            ],
          ),
          SizedBox(height: 12),
          _ControlsGroup(
            title: 'keyboard',
            rows: [
              ('Zoom X in / out', 'Alt + → / ←'),
              ('Zoom Y in / out', 'Alt + ↑ / ↓'),
              ('Pan', 'Shift + Arrows'),
              ('Zoom X full out', 'F2'),
              ('Zoom Y full out', 'Alt + F2'),
              ('Zoom to cursors', 'Z'),
              ('Swap cursors', 'X'),
              ('Copy cursor values', 'Ctrl + Shift + C'),
              ('Chart properties', 'F5'),
            ],
          ),
        ],
      ),
    );
  }
}

/// A titled group of `(description, keystroke)` shortcut rows rendered with
/// the field-manual [SpecRow] leader-dot style.
class _ControlsGroup extends StatelessWidget {
  const _ControlsGroup({required this.title, required this.rows});

  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            title.toUpperCase(),
            style: plexMono(
              fontSize: 10,
              color: brandFgFaint,
              letterSpacing: brandLabelTracking,
            ),
          ),
        ),
        for (final (label, value) in rows) SpecRow(label: label, value: value),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// §05 — How-Tos
// ---------------------------------------------------------------------------

class _HowTosSection extends StatelessWidget {
  const _HowTosSection();

  static const _articles = [
    _Article(
      index: '05.1',
      title: 'First Setup',
      subtitle: 'Pair your device. Record your first session.',
      asset: 'assets/howtos/first_setup.md',
    ),
    _Article(
      index: '05.2',
      title: 'WiFi Download',
      subtitle: 'Connect to the device AP. Pull sessions over WiFi.',
      asset: 'assets/howtos/wifi_download.md',
    ),
    _Article(
      index: '05.3',
      title: 'GPS Lap Gate',
      subtitle: 'Set a GPS gate. Auto-detect lap times.',
      asset: 'assets/howtos/lap_gate.md',
    ),
    _Article(
      index: '05.4',
      title: 'Math Channels',
      subtitle: 'Derive new channels via the expression editor.',
      asset: 'assets/howtos/math_channels.md',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final article in _articles) ...[
            _HowToTile(article: article),
            const SizedBox(height: 8),
          ],
          QuietButton(
            label: 'Full reference',
            onPressed: () {
              // TODO(idl0): replace with production documentation URL
              launchUrl(Uri.parse('https://example.com/idl0/docs'));
            },
          ),
        ],
      ),
    );
  }
}

class _HowToTile extends StatelessWidget {
  final _Article article;
  const _HowToTile({required this.article});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _HowToPage(article: article),
        ),
      ),
      child: NoteBlock(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Text(
              '§${article.index}',
              style: plexMono(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: brandFgDim,
                letterSpacing: brandLabelTracking,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    article.title.toUpperCase(),
                    style: plexMono(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: brandFg,
                      letterSpacing: brandLabelTracking,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    article.subtitle,
                    style: plexMono(fontSize: 12, color: brandFgDim),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: brandFgDim),
          ],
        ),
      ),
    );
  }
}

class _Article {
  final String index;
  final String title;
  final String subtitle;
  final String asset;

  const _Article({
    required this.index,
    required this.title,
    required this.subtitle,
    required this.asset,
  });
}

class _HowToPage extends StatelessWidget {
  final _Article article;
  const _HowToPage({required this.article});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('§${article.index}  ${article.title.toUpperCase()}'),
      ),
      body: FutureBuilder<String>(
        future: DefaultAssetBundle.of(context).loadString(article.asset),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return const Center(child: Text('Could not load article.'));
          }
          return Markdown(
            data: snapshot.data!,
            padding: const EdgeInsets.all(16),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// §06 — About
// ---------------------------------------------------------------------------

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  // Version hardcoded — package_info_plus not present in pubspec. See §24.
  static const _appVersion = '0.1.0';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SpecRow(label: 'App Version', value: _appVersion),
        const SpecRow(label: 'Schema', value: 'IDL0 v1'),
        const SpecRow(label: 'Build', value: 'dev'),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: QuietButton(
                  label: 'Licenses',
                  onPressed: () => showLicensePage(context: context),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: QuietButton(
                  label: 'Report issue',
                  onPressed: () {
                    // TODO(idl0): replace with production issue tracker URL
                    launchUrl(
                      Uri.parse('https://github.com/example/idl0/issues'),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
