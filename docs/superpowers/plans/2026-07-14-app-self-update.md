# App Self-Update — Implementation Plan (Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The app checks GitHub Releases for a newer app version on every platform and can fully self-install on **Android**; Linux/Windows install land in follow-on plans.

**Architecture:** Two parts mirroring the firmware OTA (SPEC §27.7). (A) An `app-release.yml` CI workflow builds + signs + publishes per-platform artifacts to GitHub Releases on a `v*` tag. (B) An in-app updater — `AppReleaseCatalog` (generalized GitHub-Releases client) + `appUpdateProvider` (version-check state machine) + a **Settings → App updates** section + an Android install handoff to the OS package installer.

**Tech Stack:** Flutter/Dart, Riverpod, `http`, `crypto`, `pub_semver`, `package_info_plus` (new), Kotlin (Android install channel), GitHub Actions, `appimagetool` (later phases).

## Global Constraints

- **Layer separation:** all of this is Dart + platform-channel/CI. No `idl-rs` (Rust) changes. (CLAUDE.md §2.)
- **State management: Riverpod only.** No setState except local widget state. (CLAUDE.md §2.)
- **Version of record = the git tag**, leading `v` stripped; CI stamps `--build-name=<ver>` so `package_info_plus` reports it. (SPEC §31.1.)
- **Offer an update only when hosted `>` current** (semver via `pub_semver`); hosted `<` current → informational "ahead of channel", never a downgrade; `==` → up to date. (SPEC §27.7, §31.2.)
- **Exactly one asset per platform per release**, versioned filenames: `idl0-app-v<ver>.apk`, `idl0-app-v<ver>-x86_64.AppImage`, `idl0-app-v<ver>-windows-x64.zip`, each with a `.sha256` sidecar in `sha256sum` format (`<hex>  <filename>`, first whitespace token is the digest). (SPEC §31.1.)
- **App repo slug:** `saucyeng/idl0-app`. App and firmware versions are independent. (SPEC §31.1.)
- **Updates are always user-initiated.** No forced update. (SPEC §31.2.)
- **Every public symbol gets a doc comment with units where applicable; no bare `// TODO` — use `// TODO(idl0):`.** (CLAUDE.md §4.)
- **Tests:** Arrange/Act/Assert with a blank line between sections; name `'method — condition — expected result'`; `app/lib/data`-equivalent logic targets apply — new Dart logic here should be well covered. (CLAUDE.md §3.)
- **Reference implementations to READ and mirror** (do not duplicate blindly — copy structure, adapt names): `app/lib/transport/firmware_catalog.dart` (catalog), `app/lib/providers/firmware_update_provider.dart` (provider + live re-derivation), `app/lib/ui/tabs/settings/firmware_update_section.dart` `_UpdateControls` (UI). The firmware release workflow lives in the *firmware* repo (`idl0-firmware/.github/workflows/firmware-release.yml`) — not in this repo — so `app-release.yml` is new here.

---

### Task 1: Add `package_info_plus` + a current-app-version helper

**Files:**
- Modify: `app/pubspec.yaml` (add dependency)
- Create: `app/lib/data/app_version.dart`
- Test: `app/test/data/app_version_test.dart`

**Interfaces:**
- Produces: `Future<Version> currentAppVersion()` — parses the running app's version (`package_info_plus`) into a `pub_semver` `Version`. `parseAppVersion(String raw) → Version` (pure, testable; strips a leading `v`, drops any `+build` suffix).

- [ ] **Step 1: Add the dependency**

In `app/pubspec.yaml`, under `dependencies:` (alphabetical, next to the other `package:` deps), add:

```yaml
  package_info_plus: ^8.0.0
```

Run: `cd app && flutter pub get`
Expected: resolves, `package_info_plus` appears in `pubspec.lock`.

- [ ] **Step 2: Write the failing test for the pure parser**

Create `app/test/data/app_version_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/app_version.dart';
import 'package:pub_semver/pub_semver.dart';

void main() {
  test('parseAppVersion — plain semver — parses unchanged', () {
    // Arrange
    const raw = '1.4.2';

    // Act
    final v = parseAppVersion(raw);

    // Assert
    expect(v, equals(Version.parse('1.4.2')));
  });

  test('parseAppVersion — leading v and +build suffix — both stripped', () {
    // Arrange
    const raw = 'v1.4.2+37';

    // Act
    final v = parseAppVersion(raw);

    // Assert
    expect(v, equals(Version.parse('1.4.2')));
  });

  test('parseAppVersion — prerelease tag — preserved', () {
    // Arrange
    const raw = '1.5.0-beta.1';

    // Act
    final v = parseAppVersion(raw);

    // Assert
    expect(v, equals(Version.parse('1.5.0-beta.1')));
  });
}
```

- [ ] **Step 3: Run it — verify it fails**

Run: `cd app && flutter test test/data/app_version_test.dart`
Expected: FAIL — `app_version.dart` / `parseAppVersion` not defined.

- [ ] **Step 4: Implement `app_version.dart`**

Create `app/lib/data/app_version.dart`:

```dart
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pub_semver/pub_semver.dart';

/// Parses an app version string into a semver [Version].
///
/// Strips a single leading `v` and any `+build` metadata suffix, so both a
/// git tag (`v1.4.2`) and a pubspec version (`1.4.2+37`) normalize to the same
/// value. Throws [FormatException] if the remainder is not valid semver.
Version parseAppVersion(String raw) {
  var s = raw.trim();
  if (s.startsWith('v')) s = s.substring(1);
  final plus = s.indexOf('+');
  if (plus >= 0) s = s.substring(0, plus);
  return Version.parse(s);
}

/// The running app's version, from the embedded package metadata (set by CI
/// via `--build-name`, SPEC §31.1). See [parseAppVersion] for normalization.
Future<Version> currentAppVersion() async {
  final info = await PackageInfo.fromPlatform();
  return parseAppVersion(info.version);
}
```

- [ ] **Step 5: Run tests — verify pass**

Run: `cd app && flutter test test/data/app_version_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/data/app_version.dart app/test/data/app_version_test.dart
git commit -m "App self-update: package_info_plus + version helper"
```

---

### Task 2: `AppReleaseCatalog` — GitHub Releases feed + per-platform asset selection

**Files:**
- Create: `app/lib/transport/app_release_catalog.dart`
- Test: `app/test/transport/app_release_catalog_test.dart`

**Read first:** `app/lib/transport/firmware_catalog.dart` — this task mirrors its `GitHubReleasesCatalog` structure (stable → `/releases/latest`, beta → `/releases` newest non-draft; `sha256sum`-format sidecar). The differences: (a) asset selection is by a **platform suffix** instead of `.bin`; (b) `download` writes to a **file** (artifacts are tens of MB and the Android installer needs a path), not memory.

**Interfaces:**
- Produces:
  - `enum AppUpdateChannel { stable, beta }`
  - `class AppRelease { Version version; AppUpdateChannel channel; Uri assetUrl; String assetName; int sizeBytes; Uri? sha256Url; String notes; }`
  - `const String kAppRepoSlug = 'saucyeng/idl0-app';`
  - `String appAssetSuffix()` — the current platform's release-asset suffix (`.apk` / `.AppImage` / `-windows-x64.zip`); throws `UnsupportedError` on unsupported platforms.
  - `abstract class AppReleaseCatalog { Future<AppRelease?> latest(AppUpdateChannel); Future<File> download(AppRelease, {String destPath, void Function(int,int)? onProgress}); }`
  - `class GitHubAppReleasesCatalog implements AppReleaseCatalog` — ctor `(http.Client client, {String slug = kAppRepoSlug, String? assetSuffix})`; `assetSuffix` defaults to `appAssetSuffix()` and is injectable for tests.
- Consumes: `AppReleaseCatalogException` / `AppDownloadException` (Task 2 Step 1 adds them to `app/lib/data/exceptions.dart`).

- [ ] **Step 1: Add typed exceptions**

Read `app/lib/data/exceptions.dart` for the existing exception style, then add (next to the firmware ones):

```dart
/// Thrown when the app-release feed (GitHub Releases) is unreachable or
/// returns an unparseable response. Non-fatal — the update check degrades to
/// "couldn't check". See SPEC §31.2.
class AppReleaseCatalogException extends TransportException {
  /// Creates an [AppReleaseCatalogException].
  const AppReleaseCatalogException(super.message);
}

/// Thrown when an app artifact download fails or its published `sha256` does
/// not match the bytes received. See SPEC §31.2.
class AppDownloadException extends TransportException {
  /// Creates an [AppDownloadException].
  const AppDownloadException(super.message);
}
```

- [ ] **Step 2: Write the failing tests (asset selection + parse)**

Create `app/test/transport/app_release_catalog_test.dart`:

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idl0/transport/app_release_catalog.dart';
import 'package:pub_semver/pub_semver.dart';

Map<String, dynamic> _release(String tag, List<String> assetNames,
    {bool prerelease = false, bool draft = false}) {
  return {
    'tag_name': tag,
    'prerelease': prerelease,
    'draft': draft,
    'body': 'notes',
    'assets': [
      for (final n in assetNames)
        {
          'name': n,
          'browser_download_url': 'https://dl/$n',
          'size': 1234,
        },
    ],
  };
}

void main() {
  test('latest — stable — selects the platform asset by suffix', () async {
    // Arrange — an APK-suffix catalog against a release carrying all 3 assets.
    final client = MockClient((req) async {
      expect(req.url.path, '/repos/saucyeng/idl0-app/releases/latest');
      return http.Response(
        jsonEncode(_release('v1.5.0', [
          'idl0-app-v1.5.0.apk',
          'idl0-app-v1.5.0.apk.sha256',
          'idl0-app-v1.5.0-x86_64.AppImage',
        ])),
        200,
      );
    });
    final catalog =
        GitHubAppReleasesCatalog(client, assetSuffix: '.apk');

    // Act
    final rel = await catalog.latest(AppUpdateChannel.stable);

    // Assert
    expect(rel!.version, equals(Version.parse('1.5.0')));
    expect(rel.assetName, equals('idl0-app-v1.5.0.apk'));
    expect(rel.assetUrl, equals(Uri.parse('https://dl/idl0-app-v1.5.0.apk')));
    expect(rel.sha256Url,
        equals(Uri.parse('https://dl/idl0-app-v1.5.0.apk.sha256')));
  });

  test('latest — no asset for this platform — returns null', () async {
    // Arrange — release has only the AppImage; we ask for the APK suffix.
    final client = MockClient((req) async => http.Response(
          jsonEncode(_release('v1.5.0', ['idl0-app-v1.5.0-x86_64.AppImage'])),
          200,
        ));
    final catalog = GitHubAppReleasesCatalog(client, assetSuffix: '.apk');

    // Act
    final rel = await catalog.latest(AppUpdateChannel.stable);

    // Assert
    expect(rel, isNull);
  });

  test('latest — stable feed 404 (no release yet) — returns null', () async {
    // Arrange
    final client = MockClient((req) async => http.Response('', 404));
    final catalog = GitHubAppReleasesCatalog(client, assetSuffix: '.apk');

    // Act
    final rel = await catalog.latest(AppUpdateChannel.stable);

    // Assert
    expect(rel, isNull);
  });

  test('latest — feed unreachable — throws AppReleaseCatalogException',
      () async {
    // Arrange
    final client = MockClient((req) async => throw Exception('offline'));
    final catalog = GitHubAppReleasesCatalog(client, assetSuffix: '.apk');

    // Act / Assert
    expect(
      () => catalog.latest(AppUpdateChannel.stable),
      throwsA(isA<AppReleaseCatalogException>()),
    );
  });
}
```

- [ ] **Step 3: Run — verify fail**

Run: `cd app && flutter test test/transport/app_release_catalog_test.dart`
Expected: FAIL — `app_release_catalog.dart` not defined.

- [ ] **Step 4: Implement `app_release_catalog.dart`**

Create `app/lib/transport/app_release_catalog.dart`:

```dart
/// Remote app-release feed + artifact download. See SPEC §31.1/§31.2.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

import '../data/exceptions.dart';

/// GitHub `owner/repo` the app pulls its own releases from. See SPEC §31.1.
const String kAppRepoSlug = 'saucyeng/idl0-app';

/// App-update channel; maps onto the GitHub prerelease flag (SPEC §31.1).
enum AppUpdateChannel {
  /// Latest non-prerelease release.
  stable,

  /// Latest release including prereleases.
  beta,
}

/// The release-asset filename suffix for the current platform (SPEC §31.1).
///
/// Throws [UnsupportedError] where in-app update is not offered (iOS/macOS/web).
String appAssetSuffix() {
  if (Platform.isAndroid) return '.apk';
  if (Platform.isLinux) return '-x86_64.AppImage';
  if (Platform.isWindows) return '-windows-x64.zip';
  throw UnsupportedError('app self-update unsupported on this platform');
}

/// One published app build, normalized from a GitHub release.
class AppRelease {
  /// Semver from the release tag (leading `v` stripped).
  final Version version;

  /// Channel this was selected for.
  final AppUpdateChannel channel;

  /// Direct download URL of the platform asset.
  final Uri assetUrl;

  /// The platform asset's filename (e.g. `idl0-app-v1.5.0.apk`).
  final String assetName;

  /// Asset size in bytes (drives the download progress bar).
  final int sizeBytes;

  /// URL of the `*.sha256` sidecar, or null if none was published.
  final Uri? sha256Url;

  /// Release notes (GitHub release body).
  final String notes;

  /// Creates an [AppRelease].
  const AppRelease({
    required this.version,
    required this.channel,
    required this.assetUrl,
    required this.assetName,
    required this.sizeBytes,
    required this.sha256Url,
    required this.notes,
  });
}

/// Remote source of published app builds.
abstract class AppReleaseCatalog {
  /// Latest published build on [channel] carrying an asset for this platform,
  /// or null when none exists. Throws [AppReleaseCatalogException] only on a
  /// hard transport/parse failure.
  Future<AppRelease?> latest(AppUpdateChannel channel);

  /// Downloads [release]'s asset to [destPath], reporting `(received, total)`.
  /// Verifies the published `sha256` when present. Returns the written file.
  /// Throws [AppDownloadException] on failure or checksum mismatch.
  Future<File> download(
    AppRelease release, {
    required String destPath,
    void Function(int received, int total)? onProgress,
  });
}

/// [AppReleaseCatalog] over the public GitHub Releases REST API. Mirrors
/// `GitHubReleasesCatalog` (firmware_catalog.dart).
class GitHubAppReleasesCatalog implements AppReleaseCatalog {
  final http.Client _client;
  final String _slug;
  final String _assetSuffix;

  /// Creates a catalog for [slug] over [client]. [assetSuffix] defaults to the
  /// current platform's suffix ([appAssetSuffix]) and is injectable for tests.
  GitHubAppReleasesCatalog(
    http.Client client, {
    String slug = kAppRepoSlug,
    String? assetSuffix,
  })  : _client = client,
        _slug = slug,
        _assetSuffix = assetSuffix ?? appAssetSuffix();

  static const _accept = {'Accept': 'application/vnd.github+json'};

  @override
  Future<AppRelease?> latest(AppUpdateChannel channel) async {
    final release = switch (channel) {
      AppUpdateChannel.stable => await _latestStable(),
      AppUpdateChannel.beta => await _latestBeta(),
    };
    if (release == null) return null;
    return _toRelease(release, channel);
  }

  Future<Map<String, dynamic>?> _latestStable() async {
    final uri = Uri.https('api.github.com', '/repos/$_slug/releases/latest');
    final resp = await _get(uri);
    if (resp.statusCode == 404) return null;
    _ensureOk(resp);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>?> _latestBeta() async {
    final uri = Uri.https(
        'api.github.com', '/repos/$_slug/releases', {'per_page': '20'});
    final resp = await _get(uri);
    if (resp.statusCode == 404) return null;
    _ensureOk(resp);
    final list = (jsonDecode(resp.body) as List).cast<Map<String, dynamic>>();
    for (final r in list) {
      if (r['draft'] == true) continue;
      return r;
    }
    return null;
  }

  Future<http.Response> _get(Uri uri) async {
    try {
      return await _client.get(uri, headers: _accept);
    } on Object catch (e) {
      throw AppReleaseCatalogException('app release feed unreachable: $e');
    }
  }

  void _ensureOk(http.Response resp) {
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw AppReleaseCatalogException('app release feed HTTP ${resp.statusCode}');
    }
  }

  AppRelease? _toRelease(Map<String, dynamic> r, AppUpdateChannel channel) {
    final tag = (r['tag_name'] as String?) ?? '';
    final Version version;
    try {
      version = Version.parse(tag.startsWith('v') ? tag.substring(1) : tag);
    } on FormatException {
      return null;
    }
    final assets = (r['assets'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    Map<String, dynamic>? asset;
    Map<String, dynamic>? sha;
    for (final a in assets) {
      final name = (a['name'] as String?) ?? '';
      if (name.endsWith('$_assetSuffix.sha256')) {
        sha = a;
      } else if (name.endsWith(_assetSuffix)) {
        asset = a;
      }
    }
    if (asset == null) return null;
    return AppRelease(
      version: version,
      channel: channel,
      assetUrl: Uri.parse(asset['browser_download_url'] as String),
      assetName: asset['name'] as String,
      sizeBytes: (asset['size'] as num?)?.toInt() ?? 0,
      sha256Url:
          sha == null ? null : Uri.parse(sha['browser_download_url'] as String),
      notes: (r['body'] as String?) ?? '',
    );
  }

  @override
  Future<File> download(
    AppRelease release, {
    required String destPath,
    void Function(int received, int total)? onProgress,
  }) async {
    final http.StreamedResponse resp;
    try {
      resp = await _client.send(http.Request('GET', release.assetUrl));
    } on Object catch (e) {
      throw AppDownloadException('download failed: $e');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw AppDownloadException('download HTTP ${resp.statusCode}');
    }
    final total = resp.contentLength ?? release.sizeBytes;
    final file = File(destPath);
    final sink = file.openWrite();
    final digest = AccumulatorSink<Digest>();
    final sha = sha256.startChunkedConversion(digest);
    var received = 0;
    try {
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        sha.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
    } finally {
      await sink.close();
    }
    sha.close();

    final shaUrl = release.sha256Url;
    if (shaUrl != null) {
      final http.Response shaResp;
      try {
        shaResp = await _client.get(shaUrl);
      } on Object catch (e) {
        throw AppDownloadException('checksum fetch failed: $e');
      }
      final expected =
          shaResp.body.trim().split(RegExp(r'\s')).first.toLowerCase();
      final actual = digest.events.single.toString();
      if (actual != expected) {
        await file.delete();
        throw const AppDownloadException('checksum mismatch — download corrupt');
      }
    }
    return file;
  }
}
```

Add the import `import 'dart:convert';` at the top (jsonDecode/jsonEncode). `AccumulatorSink`/`sha256.startChunkedConversion` come from `package:crypto` + `dart:convert` — verify the import resolves; if `AccumulatorSink` is unavailable, fall back to buffering into a `BytesBuilder` as `firmware_catalog.dart` does and hash the bytes.

- [ ] **Step 5: Run tests — verify pass**

Run: `cd app && flutter test test/transport/app_release_catalog_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add app/lib/transport/app_release_catalog.dart app/lib/data/exceptions.dart app/test/transport/app_release_catalog_test.dart
git commit -m "App self-update: AppReleaseCatalog (GitHub releases + platform asset)"
```

---

### Task 3: `appUpdateProvider` — version-check state machine

**Files:**
- Create: `app/lib/providers/app_update_provider.dart`
- Test: `app/test/providers/app_update_provider_test.dart`

**Read first:** `app/lib/providers/firmware_update_provider.dart` — this is the exact shape to mirror (sealed states, `check()`, TransportException → unknown, and the "ahead of channel" case). Differences: current version comes from `currentAppVersion()` (not a device field), and there is no BLE-connection gate (the check works offline-of-device).

**Interfaces:**
- Consumes: `AppReleaseCatalog`, `AppUpdateChannel`, `AppRelease` (Task 2); `currentAppVersion` (Task 1); `settingsProvider` (Task 4 adds `appUpdateChannel`).
- Produces:
  - `sealed class AppUpdateState` with `AppUpdateIdle`, `AppUpdateChecking`, `AppUpToDate(Version current)`, `AppUpdateAvailable(Version current, AppRelease release)`, `AppAheadOfChannel(Version current, AppRelease release)`, `AppUpdateUnknown([String? reason])`.
  - `final appReleaseCatalogProvider = Provider<AppReleaseCatalog>(...)` (overridable in tests).
  - `final currentAppVersionProvider = FutureProvider<Version>((ref) => currentAppVersion())` — overridable in tests to avoid `package_info_plus` platform calls.
  - `class AppUpdateNotifier extends Notifier<AppUpdateState> { Future<void> check(); }`
  - `final appUpdateProvider = NotifierProvider<AppUpdateNotifier, AppUpdateState>(...)`.

- [ ] **Step 1: Write the failing tests**

Create `app/test/providers/app_update_provider_test.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/exceptions.dart';
import 'package:idl0/providers/app_update_provider.dart';
import 'package:idl0/providers/settings_provider.dart';
import 'package:idl0/transport/app_release_catalog.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeCatalog implements AppReleaseCatalog {
  _FakeCatalog({this.result, this.error});
  final AppRelease? result;
  final Object? error;

  @override
  Future<AppRelease?> latest(AppUpdateChannel channel) async {
    if (error != null) throw error!;
    return result;
  }

  @override
  Future<dynamic> download(AppRelease release,
          {required String destPath, void Function(int, int)? onProgress}) async =>
      throw UnimplementedError();
}

AppRelease _rel(String v) => AppRelease(
      version: Version.parse(v),
      channel: AppUpdateChannel.stable,
      assetUrl: Uri.parse('https://dl/app.apk'),
      assetName: 'idl0-app-v$v.apk',
      sizeBytes: 1,
      sha256Url: null,
      notes: '',
    );

ProviderContainer _container({
  required String current,
  AppReleaseCatalog? catalog,
}) {
  final c = ProviderContainer(overrides: [
    currentAppVersionProvider.overrideWith((ref) async => Version.parse(current)),
    appReleaseCatalogProvider
        .overrideWithValue(catalog ?? _FakeCatalog(result: null)),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('check — hosted newer — AppUpdateAvailable', () async {
    // Arrange
    final c = _container(current: '1.4.0', catalog: _FakeCatalog(result: _rel('1.5.0')));

    // Act
    await c.read(appUpdateProvider.notifier).check();

    // Assert
    final s = c.read(appUpdateProvider);
    expect(s, isA<AppUpdateAvailable>());
    expect((s as AppUpdateAvailable).release.version, Version.parse('1.5.0'));
  });

  test('check — hosted older — AppAheadOfChannel', () async {
    // Arrange
    final c = _container(current: '1.6.0', catalog: _FakeCatalog(result: _rel('1.5.0')));

    // Act
    await c.read(appUpdateProvider.notifier).check();

    // Assert
    expect(c.read(appUpdateProvider), isA<AppAheadOfChannel>());
  });

  test('check — hosted equal — AppUpToDate', () async {
    // Arrange
    final c = _container(current: '1.5.0', catalog: _FakeCatalog(result: _rel('1.5.0')));

    // Act
    await c.read(appUpdateProvider.notifier).check();

    // Assert
    expect(c.read(appUpdateProvider), isA<AppUpToDate>());
  });

  test('check — no release — AppUpToDate', () async {
    // Arrange
    final c = _container(current: '1.5.0', catalog: _FakeCatalog(result: null));

    // Act
    await c.read(appUpdateProvider.notifier).check();

    // Assert
    expect(c.read(appUpdateProvider), isA<AppUpToDate>());
  });

  test('check — catalog throws — AppUpdateUnknown', () async {
    // Arrange
    final c = _container(
      current: '1.4.0',
      catalog: _FakeCatalog(error: const AppReleaseCatalogException('offline')),
    );

    // Act
    await c.read(appUpdateProvider.notifier).check();

    // Assert
    expect(c.read(appUpdateProvider), isA<AppUpdateUnknown>());
  });
}
```

- [ ] **Step 2: Run — verify fail**

Run: `cd app && flutter test test/providers/app_update_provider_test.dart`
Expected: FAIL — provider not defined. (Also fails to compile until Task 4 adds `settingsProvider.appUpdateChannel`; for now hardcode `AppUpdateChannel.stable` in `check()` and switch to the setting in Task 4 Step 5.)

- [ ] **Step 3: Implement `app_update_provider.dart`**

Create `app/lib/providers/app_update_provider.dart` (mirror `firmware_update_provider.dart`):

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

import '../data/app_version.dart';
import '../data/exceptions.dart';
import '../transport/app_release_catalog.dart';

/// App-release catalog. Overridden with a fake in tests.
final appReleaseCatalogProvider = Provider<AppReleaseCatalog>(
  (ref) => GitHubAppReleasesCatalog(http.Client()),
);

/// The running app version. Overridden in tests to avoid platform calls.
final currentAppVersionProvider =
    FutureProvider<Version>((ref) => currentAppVersion());

/// Result of the app update check. See SPEC §31.2.
sealed class AppUpdateState {
  const AppUpdateState();
}

/// No check has run yet this session.
class AppUpdateIdle extends AppUpdateState {
  /// Creates an [AppUpdateIdle].
  const AppUpdateIdle();
}

/// A check is in flight.
class AppUpdateChecking extends AppUpdateState {
  /// Creates an [AppUpdateChecking].
  const AppUpdateChecking();
}

/// The app is on the latest published build for its channel.
class AppUpToDate extends AppUpdateState {
  /// The running version.
  final Version current;

  /// Creates an [AppUpToDate].
  const AppUpToDate(this.current);
}

/// A newer build is available on the selected channel.
class AppUpdateAvailable extends AppUpdateState {
  /// The running version.
  final Version current;

  /// The newer published release.
  final AppRelease release;

  /// Creates an [AppUpdateAvailable].
  const AppUpdateAvailable(this.current, this.release);
}

/// The running app is newer than the channel's latest (informational only,
/// never a downgrade prompt — SPEC §31.2/§27.7).
class AppAheadOfChannel extends AppUpdateState {
  /// The running version.
  final Version current;

  /// The channel's latest (older) release.
  final AppRelease release;

  /// Creates an [AppAheadOfChannel].
  const AppAheadOfChannel(this.current, this.release);
}

/// The check could not complete (offline, version unreadable). Non-fatal.
class AppUpdateUnknown extends AppUpdateState {
  /// Optional human-readable reason.
  final String? reason;

  /// Creates an [AppUpdateUnknown].
  const AppUpdateUnknown([this.reason]);
}

/// Compares the running app version against the hosted latest. See SPEC §31.2.
class AppUpdateNotifier extends Notifier<AppUpdateState> {
  @override
  AppUpdateState build() => const AppUpdateIdle();

  /// Runs an update check for the selected channel. Never throws — failures
  /// resolve to [AppUpdateUnknown].
  Future<void> check() async {
    final Version current;
    try {
      current = await ref.read(currentAppVersionProvider.future);
    } on Object {
      state = const AppUpdateUnknown('app version unreadable');
      return;
    }

    // TODO(idl0): replace with settingsProvider.appUpdateChannel in Task 4.
    const channel = AppUpdateChannel.stable;

    state = const AppUpdateChecking();
    try {
      final rel = await ref.read(appReleaseCatalogProvider).latest(channel);
      if (rel == null) {
        state = AppUpToDate(current);
        return;
      }
      if (rel.version > current) {
        state = AppUpdateAvailable(current, rel);
      } else if (rel.version < current) {
        state = AppAheadOfChannel(current, rel);
      } else {
        state = AppUpToDate(current);
      }
    } on TransportException catch (e) {
      state = AppUpdateUnknown(e.message);
    }
  }
}

/// App update-check state provider. See SPEC §31.2.
final appUpdateProvider =
    NotifierProvider<AppUpdateNotifier, AppUpdateState>(AppUpdateNotifier.new);
```

- [ ] **Step 4: Run tests — verify pass**

Run: `cd app && flutter test test/providers/app_update_provider_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/providers/app_update_provider.dart app/test/providers/app_update_provider_test.dart
git commit -m "App self-update: appUpdateProvider version-check state machine"
```

---

### Task 4: Settings — `appUpdateChannel`/`autoCheckAppUpdate` settings + "App updates" UI

**Files:**
- Modify: `app/lib/providers/settings_provider.dart` (add two settings, mirror `firmwareChannel`/`autoCheckFirmware`)
- Modify: `app/lib/providers/app_update_provider.dart:check()` (use the setting instead of the hardcoded `stable`)
- Create: `app/lib/ui/tabs/settings/app_update_section.dart`
- Modify: the Settings tab to mount `AppUpdateSection` (find where `FirmwareUpdateSection` is mounted and add this sibling)
- Test: `app/test/providers/settings_provider_test.dart` (extend), `app/test/ui/settings/app_update_section_test.dart`

**Read first:** `app/lib/providers/settings_provider.dart` (mirror `firmwareChannel`/`autoCheckFirmware` — default key, getter, setter, persistence) and `app/lib/ui/tabs/settings/firmware_update_section.dart` `_UpdateControls` (the exact card/picker/toggle/"Check now" pattern to copy for the *install-only* controls; the OTA push machinery is NOT part of this widget — the install handoff comes in Tasks 6/7).

**Interfaces:**
- Produces: `settings.appUpdateChannel` (`AppUpdateChannel`, default `stable`), `settings.autoCheckAppUpdate` (`bool`, default `true`), setters `setAppUpdateChannel`, `setAutoCheckAppUpdate`. `AppUpdateSection` widget. `onInstall` callback wired to a stub `Future<void> Function(AppRelease)` (Task 7 replaces the stub with the real install).

- [ ] **Step 1: Extend settings tests**

In `app/test/providers/settings_provider_test.dart`, add (mirroring the firmware-channel tests already there):

```dart
  test('appUpdateChannel — defaults to stable, persists a change', () async {
    // Arrange
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);

    // Assert default
    expect(c.read(settingsProvider).appUpdateChannel, AppUpdateChannel.stable);

    // Act
    await c.read(settingsProvider.notifier).setAppUpdateChannel(AppUpdateChannel.beta);

    // Assert
    expect(c.read(settingsProvider).appUpdateChannel, AppUpdateChannel.beta);
  });
```

Add the import `import 'package:idl0/transport/app_release_catalog.dart';` to the test.

- [ ] **Step 2: Run — verify fail**

Run: `cd app && flutter test test/providers/settings_provider_test.dart`
Expected: FAIL — `appUpdateChannel` undefined.

- [ ] **Step 3: Add the settings**

In `app/lib/providers/settings_provider.dart`, mirror the firmware fields exactly:
- Add fields `appUpdateChannel` (`AppUpdateChannel`, default `AppUpdateChannel.stable`) and `autoCheckAppUpdate` (`bool`, default `true`) to the settings state class + `copyWith`.
- Add prefs keys `_kAppUpdateChannel = 'app_update_channel'`, `_kAutoCheckAppUpdate = 'auto_check_app_update'`.
- Load them in the state's `fromPrefs` constructor exactly like `firmwareChannel`/`autoCheckFirmware` (index-clamped enum + bool default true).
- Add `setAppUpdateChannel` / `setAutoCheckAppUpdate` setters that update state + persist.
- Import `../transport/app_release_catalog.dart`.

- [ ] **Step 4: Run — verify pass**

Run: `cd app && flutter test test/providers/settings_provider_test.dart`
Expected: PASS.

- [ ] **Step 5: Wire the channel into `check()`**

In `app/lib/providers/app_update_provider.dart`, replace the hardcoded channel:

```dart
    final channel = ref.read(settingsProvider).appUpdateChannel;
```

Add `import 'settings_provider.dart';`. Re-run Task 3's tests — they override `settingsProvider` via the default (empty prefs → stable), so they still pass:
Run: `cd app && flutter test test/providers/app_update_provider_test.dart`
Expected: PASS.

- [ ] **Step 6: Write the failing widget test**

Create `app/test/ui/settings/app_update_section_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/providers/app_update_provider.dart';
import 'package:idl0/transport/app_release_catalog.dart';
import 'package:idl0/ui/tabs/settings/app_update_section.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubUpdate extends AppUpdateNotifier {
  _StubUpdate(this._s);
  final AppUpdateState _s;
  @override
  AppUpdateState build() => _s;
  @override
  Future<void> check() async {}
}

AppRelease _rel(String v) => AppRelease(
      version: Version.parse(v),
      channel: AppUpdateChannel.stable,
      assetUrl: Uri.parse('https://dl/app.apk'),
      assetName: 'idl0-app-v$v.apk',
      sizeBytes: 1,
      sha256Url: null,
      notes: '',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('update available — shows the update card with target version',
      (tester) async {
    // Arrange
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appUpdateProvider.overrideWith(
          () => _StubUpdate(AppUpdateAvailable(Version.parse('1.4.0'), _rel('1.5.0'))),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: AppUpdateSection())),
    ));
    await tester.pump();

    // Assert
    expect(find.textContaining('1.5.0'), findsWidgets);
  });

  testWidgets('up to date — channel picker + Check now still render',
      (tester) async {
    // Arrange
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appUpdateProvider.overrideWith(() => _StubUpdate(AppUpToDate(Version.parse('1.5.0')))),
      ],
      child: const MaterialApp(home: Scaffold(body: AppUpdateSection())),
    ));
    await tester.pump();

    // Assert
    expect(find.text('Check now'), findsOneWidget);
  });
}
```

- [ ] **Step 7: Implement `AppUpdateSection`**

Create `app/lib/ui/tabs/settings/app_update_section.dart`, copying the structure of `firmware_update_section.dart`'s `_UpdateControls` (channel `SegmentedButton`, auto-check `Switch`, "Check now" `QuietButton`, and an `AppUpdateAvailable` card with an "Update to v…" button). The button's `onPressed` calls a top-level install entry point `installAppUpdate(ref, release)` — for this task implement it as a stub that shows a SnackBar "Update install wired in Task 7"; Task 7 replaces the stub body. Fire an initial `check()` in `initState` gated on `settings.autoCheckAppUpdate` (mirror the firmware section's post-frame check, minus the BLE gate). Add a doc comment referencing SPEC §31.2.

- [ ] **Step 8: Mount it in Settings**

Find where `FirmwareUpdateSection` is placed in the Settings tab (grep `FirmwareUpdateSection(` under `app/lib/ui/tabs/settings/`), and add `const AppUpdateSection()` as a sibling section (with the same section-header treatment). Add the import.

- [ ] **Step 9: Run tests — verify pass**

Run: `cd app && flutter test test/ui/settings/app_update_section_test.dart test/providers/app_update_provider_test.dart`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add app/lib/providers/settings_provider.dart app/lib/providers/app_update_provider.dart app/lib/ui/tabs/settings/app_update_section.dart app/test/providers/settings_provider_test.dart app/test/ui/settings/app_update_section_test.dart app/lib/ui/tabs/settings/*.dart
git commit -m "App self-update: settings + Settings App-updates UI section"
```

---

### Task 5: Android release signing

**Files:**
- Modify: `app/android/app/build.gradle` (release signingConfig from `key.properties`)
- Create: `app/android/key.properties.example`
- Modify: `app/.gitignore` (ignore `**/key.properties` and `*.keystore`/`*.jks`)
- Create/Modify: `app/android/app/src/main/AndroidManifest.xml` (nothing here yet — permission lands in Task 7)

**Note — manual/one-time steps (documented, run by the maintainer, NOT a subagent):** generate the keystore and add CI secrets. Include these commands in the plan output/PR description:

```bash
keytool -genkey -v -keystore idl0-upload.jks -keyalg RSA -keysize 2048 \
  -validity 10000 -alias idl0
# then base64 the keystore for the GitHub secret:
base64 -w0 idl0-upload.jks > idl0-upload.jks.b64
```
Add repo secrets: `ANDROID_KEYSTORE_B64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS`.

- [ ] **Step 1: Ignore secrets**

Append to `app/.gitignore`:

```
# Android release signing (never commit)
android/key.properties
*.jks
*.keystore
```

- [ ] **Step 2: `key.properties.example`**

Create `app/android/key.properties.example`:

```properties
storeFile=idl0-upload.jks
storePassword=changeme
keyAlias=idl0
keyPassword=changeme
```

- [ ] **Step 3: Wire release signing in `build.gradle`**

In `app/android/app/build.gradle`, above `android {`, load the properties if present:

```gradle
def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}
```

Inside `android { ... }` add a `signingConfigs` block and point `buildTypes.release` at it, falling back to debug signing when the keystore is absent (so local `flutter run` still works):

```gradle
    signingConfigs {
        release {
            if (keystorePropertiesFile.exists()) {
                storeFile file(keystoreProperties['storeFile'])
                storePassword keystoreProperties['storePassword']
                keyAlias keystoreProperties['keyAlias']
                keyPassword keystoreProperties['keyPassword']
            }
        }
    }
    buildTypes {
        release {
            signingConfig keystorePropertiesFile.exists()
                ? signingConfigs.release
                : signingConfigs.debug
        }
    }
```

- [ ] **Step 4: Verify local debug build still works**

Run: `cd app && flutter build apk --debug`
Expected: builds (no `key.properties` present → debug signing fallback, no error).

- [ ] **Step 5: Commit**

```bash
git add app/android/app/build.gradle app/android/key.properties.example app/.gitignore
git commit -m "App self-update: Android release signing config (keystore via key.properties)"
```

---

### Task 6: `app-release.yml` — build + sign + publish per platform

**Files:**
- Create: `.github/workflows/app-release.yml`

**Read first:** the firmware pattern (conceptually) — this mirrors `firmware-release.yml`'s tag-trigger + `dist/` staging + release publish, but for Flutter app builds. Verification is a real tag run (**user-gated**, like the firmware R1 release); locally the gate is YAML validity + `flutter build` of each target.

- [ ] **Step 1: Author the workflow**

Create `.github/workflows/app-release.yml`:

```yaml
name: app-release
on:
  push:
    tags: ['v*']

jobs:
  android:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { submodules: recursive }
      - uses: subosito/flutter-action@v2
        with: { channel: stable }
      - name: Version from tag
        run: echo "VERSION=${GITHUB_REF_NAME#v}" >> "$GITHUB_ENV"
      - name: Restore keystore
        run: echo "${{ secrets.ANDROID_KEYSTORE_B64 }}" | base64 -d > app/android/idl0-upload.jks
      - name: key.properties
        run: |
          cat > app/android/key.properties <<EOF
          storeFile=idl0-upload.jks
          storePassword=${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
          keyAlias=${{ secrets.ANDROID_KEY_ALIAS }}
          keyPassword=${{ secrets.ANDROID_KEY_PASSWORD }}
          EOF
      - name: Build APK
        working-directory: app
        run: flutter build apk --release --build-name="$VERSION"
      - name: Stage assets
        run: |
          mkdir dist
          cp app/build/app/outputs/flutter-apk/app-release.apk "dist/idl0-app-v${VERSION}.apk"
          cd dist && sha256sum "idl0-app-v${VERSION}.apk" > "idl0-app-v${VERSION}.apk.sha256"
      - uses: softprops/action-gh-release@v2
        with:
          files: dist/*
          prerelease: ${{ contains(github.ref_name, '-') }}

  linux:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { submodules: recursive }
      - uses: subosito/flutter-action@v2
        with: { channel: stable }
      - name: Version from tag
        run: echo "VERSION=${GITHUB_REF_NAME#v}" >> "$GITHUB_ENV"
      - name: Deps
        run: sudo apt-get update && sudo apt-get install -y ninja-build libgtk-3-dev
      - name: Build Linux
        working-directory: app
        run: flutter build linux --release --build-name="$VERSION"
      # AppImage packaging is added in the Phase 2 plan; for now publish a tarball
      # so the release always carries a Linux artifact.
      - name: Stage tarball
        run: |
          mkdir dist
          tar -C app/build/linux/x64/release/bundle -czf "dist/idl0-app-v${VERSION}-linux-x64.tar.gz" .
          cd dist && sha256sum "idl0-app-v${VERSION}-linux-x64.tar.gz" > "idl0-app-v${VERSION}-linux-x64.tar.gz.sha256"
      - uses: softprops/action-gh-release@v2
        with:
          files: dist/*
          prerelease: ${{ contains(github.ref_name, '-') }}

  windows:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
        with: { submodules: recursive }
      - uses: subosito/flutter-action@v2
        with: { channel: stable }
      - name: Version from tag
        shell: bash
        run: echo "VERSION=${GITHUB_REF_NAME#v}" >> "$GITHUB_ENV"
      - name: Build Windows
        working-directory: app
        run: flutter build windows --release --build-name="$env:VERSION"
      - name: Stage zip
        shell: bash
        run: |
          mkdir dist
          cd app/build/windows/x64/runner/Release
          7z a "$GITHUB_WORKSPACE/dist/idl0-app-v${VERSION}-windows-x64.zip" .
          cd "$GITHUB_WORKSPACE/dist" && sha256sum "idl0-app-v${VERSION}-windows-x64.zip" > "idl0-app-v${VERSION}-windows-x64.zip.sha256"
      - uses: softprops/action-gh-release@v2
        with:
          files: dist/*
          prerelease: ${{ contains(github.ref_name, '-') }}
```

**Note:** the Linux job ships a **tarball** here; the Phase 2 plan swaps in `appimagetool` to produce the `.AppImage` the updater consumes. The Android asset name (`idl0-app-v<ver>.apk`) matches `appAssetSuffix()`'s `.apk` from Task 2 — this is the one the in-app updater actually uses in Phase 1.

- [ ] **Step 2: Validate the YAML**

Run: `cd app && flutter build apk --debug` (proves the app builds; the real workflow gate is a tagged run). Optionally lint the YAML with any local `yamllint`.
Expected: app builds; YAML is well-formed.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/app-release.yml
git commit -m "App self-update: app-release CI (APK signed + Linux tarball + Windows zip)"
```

---

### Task 7: Android in-app install (platform channel → OS package installer)

**Files:**
- Create: `app/lib/transport/app_installer.dart` (Dart side of the channel + orchestration)
- Modify: `app/android/app/src/main/AndroidManifest.xml` (`REQUEST_INSTALL_PACKAGES` + `FileProvider`)
- Create: `app/android/app/src/main/res/xml/file_paths.xml`
- Modify: `app/android/app/src/main/kotlin/com/example/idl0/MainActivity.kt` (MethodChannel handler)
- Modify: `app/lib/ui/tabs/settings/app_update_section.dart` (replace the Task 4 install stub with the real orchestration)
- Test: `app/test/transport/app_installer_test.dart` (Dart orchestration with a fake channel + fake catalog)

**Read first:** `app/android/app/src/main/kotlin/com/example/idl0/` for the existing MethodChannel/plugin registration style (e.g. `LoopbackProxy.kt` / `MainActivity`), and mirror how channels are registered there.

**Interfaces:**
- Produces: `class AppInstaller { Future<void> installFromRelease(AppRelease release, {required AppReleaseCatalog catalog, void Function(int,int)? onProgress}); }` — downloads via the catalog to a cache path, then invokes the platform channel `idl0/app_installer` method `installApk(path)`. On non-Android, throws `UnsupportedError` (Linux/Windows handled by later phases). Channel is injectable for tests (`@visibleForTesting` ctor param).

- [ ] **Step 1: Manifest — permission + FileProvider**

In `app/android/app/src/main/AndroidManifest.xml`, add inside `<manifest>` (above `<application>`):

```xml
    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />
```

and inside `<application>`:

```xml
        <provider
            android:name="androidx.core.content.FileProvider"
            android:authorities="${applicationId}.fileprovider"
            android:exported="false"
            android:grantUriPermissions="true">
            <meta-data
                android:name="android.support.FILE_PROVIDER_PATHS"
                android:resource="@xml/file_paths" />
        </provider>
```

- [ ] **Step 2: `file_paths.xml`**

Create `app/android/app/src/main/res/xml/file_paths.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<paths>
    <cache-path name="downloads" path="." />
    <external-cache-path name="ext-downloads" path="." />
</paths>
```

- [ ] **Step 3: Kotlin channel handler**

In `MainActivity.kt`, register a `MethodChannel("idl0/app_installer")` in `configureFlutterEngine`. Implement `installApk(path)`:
- build a `content://` URI for the file via `FileProvider.getUriForFile(this, "$packageName.fileprovider", File(path))`,
- if `Build.VERSION.SDK_INT >= O && !packageManager.canRequestPackageInstalls()`, launch `Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))` and return `result.error("needs_permission", ...)`,
- otherwise `startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive").addFlags(FLAG_GRANT_READ_URI_PERMISSION or FLAG_ACTIVITY_NEW_TASK))` and `result.success(null)`.

Complete handler body:

```kotlin
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "idl0/app_installer")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) { result.error("bad_args", "path required", null); return@setMethodCallHandler }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            !packageManager.canRequestPackageInstalls()) {
                            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName")))
                            result.error("needs_permission", "install-unknown-apps not granted", null)
                            return@setMethodCallHandler
                        }
                        val uri = FileProvider.getUriForFile(this,
                            "$packageName.fileprovider", File(path))
                        startActivity(Intent(Intent.ACTION_VIEW)
                            .setDataAndType(uri, "application/vnd.android.package-archive")
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
```

(Merge with the existing `MainActivity` body/imports rather than replacing wholesale if channels are already registered there.)

- [ ] **Step 4: Write the failing Dart orchestration test**

Create `app/test/transport/app_installer_test.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/transport/app_installer.dart';
import 'package:idl0/transport/app_release_catalog.dart';
import 'package:pub_semver/pub_semver.dart';

class _FakeCatalog implements AppReleaseCatalog {
  int downloads = 0;
  @override
  Future<AppRelease?> latest(AppUpdateChannel c) async => null;
  @override
  Future<dynamic> download(AppRelease r,
      {required String destPath, void Function(int, int)? onProgress}) async {
    downloads++;
    onProgress?.call(r.sizeBytes, r.sizeBytes);
    return destPath; // stand-in for File
  }
}

AppRelease _rel() => AppRelease(
      version: Version.parse('1.5.0'),
      channel: AppUpdateChannel.stable,
      assetUrl: Uri.parse('https://dl/a.apk'),
      assetName: 'idl0-app-v1.5.0.apk',
      sizeBytes: 10,
      sha256Url: null,
      notes: '',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('installFromRelease — downloads then invokes installApk on the channel',
      () async {
    // Arrange
    final calls = <MethodCall>[];
    final channel = const MethodChannel('idl0/app_installer');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final catalog = _FakeCatalog();
    final installer = AppInstaller(cacheDirPath: '/tmp');

    // Act
    await installer.installFromRelease(_rel(), catalog: catalog);

    // Assert
    expect(catalog.downloads, 1);
    expect(calls.single.method, 'installApk');
    expect((calls.single.arguments as Map)['path'], contains('idl0-app-v1.5.0.apk'));
  });
}
```

- [ ] **Step 5: Run — verify fail**

Run: `cd app && flutter test test/transport/app_installer_test.dart`
Expected: FAIL — `app_installer.dart` not defined.

- [ ] **Step 6: Implement `app_installer.dart`**

Create `app/lib/transport/app_installer.dart`:

```dart
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'app_release_catalog.dart';

/// Downloads an [AppRelease] artifact and hands it to the platform's installer.
///
/// Android: writes the APK to the app cache, then invokes the OS package
/// installer via the `idl0/app_installer` channel (user taps "Install"; the OS
/// enforces the signature match — SPEC §31.1.1). Other platforms are handled by
/// later phases and throw [UnsupportedError] here.
class AppInstaller {
  /// Directory the artifact is downloaded into (the app cache in production).
  final String cacheDirPath;
  final MethodChannel _channel;

  /// Creates an [AppInstaller]. [channel] is injectable for tests.
  AppInstaller({
    required this.cacheDirPath,
    MethodChannel channel = const MethodChannel('idl0/app_installer'),
  }) : _channel = channel;

  /// Downloads [release] via [catalog] and launches the install.
  Future<void> installFromRelease(
    AppRelease release, {
    required AppReleaseCatalog catalog,
    void Function(int received, int total)? onProgress,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('in-app install is Android-only in this phase');
    }
    final dest = p.join(cacheDirPath, release.assetName);
    await catalog.download(release, destPath: dest, onProgress: onProgress);
    await _channel.invokeMethod<void>('installApk', {'path': dest});
  }
}
```

Add `path: ^1.9.0` to `pubspec.yaml` if not already present (`flutter pub get`).

- [ ] **Step 7: Run — verify pass**

Run: `cd app && flutter test test/transport/app_installer_test.dart`
Expected: PASS.

- [ ] **Step 8: Wire into the UI**

In `app/lib/ui/tabs/settings/app_update_section.dart`, replace the Task 4 install stub with: resolve the cache dir (`path_provider` `getTemporaryDirectory()` — add `path_provider` if absent), build an `AppInstaller`, and call `installFromRelease` with the tapped release, showing progress via the existing card and catching `AppDownloadException`/`PlatformException` into an inline error (a `needs_permission` PlatformException → "Enable 'install unknown apps', then retry"). Non-Android platforms show "download available on the release page" (fallback copy per SPEC §31.2 / design §9).

- [ ] **Step 9: Full suite + analyze**

Run: `cd app && flutter analyze && flutter test`
Expected: analyze clean on new files; suite green except the 2 documented pre-existing `chart_workspace_test` failures (TASKS.md).

- [ ] **Step 10: Commit**

```bash
git add app/lib/transport/app_installer.dart app/android/app/src/main app/lib/ui/tabs/settings/app_update_section.dart app/test/transport/app_installer_test.dart app/pubspec.yaml app/pubspec.lock
git commit -m "App self-update: Android in-app install via OS package installer"
```

---

## Docs (end of Phase 1)

- [ ] **CHANGELOG.md** — one `### Added` entry: "App self-update (phase 1): all-platform version check + Settings App-updates UI + Android in-app install; app-release CI. SPEC §31.1/§31.2." Spec disposition: spec-first (already landed).
- [ ] **TASKS.md** — tick Phase 1; queue Phase 2 (Linux AppImage) + Phase 3 (Windows install) + the user-gated first app release tag.
- [ ] **README.md** — one line under install/updates if audience-facing (optional).

## Follow-on plans (separate, not this document)

- **Phase 2 — Linux AppImage:** swap the Linux CI job's tarball for `appimagetool` output (`idl0-app-v<ver>-x86_64.AppImage`); implement the Linux branch of `AppInstaller` (download beside the running AppImage via `$APPIMAGE` env, `sha256`-verify, `chmod +x`, atomic rename, prompt relaunch). Its own plan file.
- **Phase 3 — Windows install:** replace the download-only stub with an in-place swap (helper `.bat`/sidecar that waits for exit, swaps the bundle, relaunches) or MSIX. Its own plan file.

## First app release (user-gated, after Phase 1 merges)

Bump `app/pubspec.yaml` `version:`, tag `v<version>`, push → `app-release.yml` publishes the signed APK. Verify assets: `idl0-app-v<ver>.apk` (+ `.sha256`), not prerelease for a plain tag. Then install that APK on the phone once (so the signing key is established) — subsequent updates self-install.

---

## Self-Review

- **Spec coverage (SPEC §31.1/§31.2, design doc):** release pipeline → Task 6; Android signing → Task 5; version-of-record `--build-name` → Task 6; per-platform assets/`sha256` → Tasks 2/6; `AppReleaseCatalog` + platform asset → Task 2; `appUpdateProvider` + hosted>current / ahead-of-channel / live states → Task 3; Settings App-updates UI (card/channel/auto-check/Check now) → Task 4; Android install (FileProvider + installer intent + permission) → Task 7; user-initiated only → Tasks 4/7 (no auto-install); `package_info_plus` version of record → Task 1. Linux/Windows install are explicitly deferred to follow-on plans (design §2/§8). **No gaps for Phase 1.**
- **Placeholder scan:** the only intentional stubs are (a) Task 3's hardcoded `stable` channel, replaced in Task 4 Step 5, and (b) Task 4's install stub, replaced in Task 7 Step 8 — both have their replacement step named. No bare TODO/TBD remain.
- **Type consistency:** `AppRelease`, `AppUpdateChannel`, `AppReleaseCatalog.download(release, {destPath, onProgress})`, `appAssetSuffix()`, `AppUpdateState` subclasses, `AppInstaller.installFromRelease(release, {catalog, onProgress})` are used with identical signatures across Tasks 2–7. The Android APK asset name `idl0-app-v<ver>.apk` (Task 6) matches the `.apk` suffix the catalog selects (Task 2).
