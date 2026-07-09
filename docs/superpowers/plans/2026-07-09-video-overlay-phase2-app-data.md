# Video Overlay Phase 2 (App Data Layer) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The app can link videos to sessions — `.idl0w` v8 stores `videos[]` link entries, the workbook (v2) gains a Dart `overlay_layouts` model matching the engine schema, and linking runs GPMF auto-sync through new bridge wrappers.

**Architecture:** Per `docs/superpowers/specs/2026-07-08-video-overlay-design.md` §4/§5 and SPEC §33: pure-Dart schema work in `app/lib/data/` (workspace v8, workbook v2), one new bridge module (`bridge/src/video.rs`) wrapping the phase-1 engine (`mp4box`/`gpmf`/`sync`), FRB codegen, and a link-time flow (workspace mutators + a link-builder provider) with engine-estimated offsets degrading to manual.

**Tech Stack:** Dart/Flutter (Riverpod), flutter_rust_bridge `=2.12.0` (pinned), Rust bridge crate `idl_rs_bridge`.

## Global Constraints

- **Repo topology:** app work in `c:\Users\isaac\Documents\Saucy\saucyeng\idl0-app` on branch `video-overlay-phase2`; bridge work in the **submodule checkout** `idl0-app\rust` (NOT the sibling `saucyeng\idl-rs` clone) on its own `video-overlay-phase2` branch, after fast-forwarding it from the sibling (phase 1 is unpushed; the submodule is 16 commits behind). Worktrees are impractical here — FRB codegen (`rust_root: ../rust/bridge`) and cargokit both resolve the submodule path relative to `app/`.
- **NEVER add Co-Authored-By or any AI-attribution trailer to commits.**
- **Never run workspace-wide `cargo fmt` in the rust repo** — it is not rustfmt-formatted (66-file churn incident in phase 1). Match style by hand; stage files individually (`git add <file>`, never a directory).
- Bridge crate: thin `#[frb]` wrappers only; errors cross as freezed-free pairs (unit-enum `kind` + `message` String — the `ParseFailure` precedent in `bridge/src/session.rs:36-60`).
- Dart: Riverpod only; typed exceptions (`app/lib/data/exceptions.dart`), never bare `Exception(...)`; doc comments on public symbols with units (`_s` seconds, `Ms` milliseconds).
- JSON schema must match SPEC §33.1 / the engine byte-for-byte: snake_case keys, `rect` as a 4-element `[x, y, w, h]` array, lowercase style strings, `"type"` discriminator.
- Tests: Arrange/Act/Assert; `group('ClassName —')` / `test('method — condition — result')`; tests needing the native bridge carry `skip: 'Requires the idl-rs bridge native library (not loaded under flutter test).'`.
- `flutter test` green + `flutter analyze` clean before every idl0-app commit; `cargo test` green before every rust commit.
- Spec disposition: **spec-during** — SPEC §11.4/§15 (workspace v8) and §17a (workbook v2) land in Task 7 with the code.

---

### Task 1: Fast-forward the submodule and branch both repos

**Files:** none created — git state only.

**Interfaces:**
- Produces: `idl0-app` on branch `video-overlay-phase2`; submodule `idl0-app\rust` on branch `video-overlay-phase2` at commit `05c9296` (phase-1 tip) + all engine/CLI phase-1 code available to cargokit and codegen.

- [ ] **Step 1: Branch the app repo**

```bash
cd c:\Users\isaac\Documents\Saucy\saucyeng\idl0-app
git checkout -b video-overlay-phase2
```

- [ ] **Step 2: Fast-forward the submodule from the sibling clone and branch it**

```bash
cd c:\Users\isaac\Documents\Saucy\saucyeng\idl0-app\rust
rm -f Cargo.lock                    # untracked; phase-1 main carries a tracked one
git fetch "c:\Users\isaac\Documents\Saucy\saucyeng\idl-rs" main
git checkout main && git merge --ff-only FETCH_HEAD
git checkout -b video-overlay-phase2
git log --oneline -1                # expect: 05c9296 Drop incidental rustfmt churn ...
```

- [ ] **Step 3: Verify the submodule builds + tests green**

```bash
cd c:\Users\isaac\Documents\Saucy\saucyeng\idl0-app\rust
cargo test 2>&1 | grep "test result"
```
Expected: all suites `ok` (584 core + 51/2/2 CLI + 10 video-export).

No commit — the idl0-app submodule-pointer bump lands in Task 7 (pointing at the final submodule commit).

---

### Task 2: Bridge module `video.rs`

**Files:**
- Create: `rust/bridge/src/video.rs` (in the submodule checkout)
- Modify: `rust/bridge/src/lib.rs` (add `pub mod video;` to the module list, alphabetical — after `pub mod tracks;`)

**Interfaces:**
- Consumes: `idl_rs::video::{mp4box, gpmf, sync, VideoError, VideoErrorKind}`, `idl_rs::session::handle::SessionHandle`.
- Produces (Dart names after codegen in parentheses):
  - `VideoInfo { width: u32, height: u32, fps: f64, duration_s: f64, creation_time_utc_ms: Option<i64>, has_gpmd: bool }`
  - `VideoSyncOutcome { offset_s: f64, confidence: f64, method: VideoSyncMethod }`, `VideoSyncMethod { Gpmf, CreationTime }` (plain Dart enum)
  - `VideoFailure { kind: VideoFailureKind, message: String }`, `VideoFailureKind { Io, Parse, NoGpmf, NoOverlap, Export }`
  - `pub fn video_probe(path: String) -> Result<VideoInfo, VideoFailure>` (`videoProbe({required String path})`)
  - `pub fn estimate_video_sync(handle: &SessionHandle, video_path: String) -> Result<VideoSyncOutcome, VideoFailure>` (`estimateVideoSync({required SessionHandle handle, required String videoPath})`)

- [ ] **Step 1: Write `rust/bridge/src/video.rs`**

```rust
//! FRB wrappers for the video subsystem (SPEC §33.3): container probing and
//! sync-offset estimation at link time. The export driver is NOT bridged in
//! phase 2 — desktop export UI is phase 3.

use idl_rs::session::handle::SessionHandle;
use idl_rs::video::gpmf::parse_gpmf;
use idl_rs::video::mp4box::{read_gpmd_samples_path, read_info_path};
use idl_rs::video::sync::{estimate_sync, SyncMethod};
use idl_rs::video::{VideoError, VideoErrorKind};

/// Discriminant for [`VideoFailure`] — freezed-free error crossing (the
/// `ParseFailure` precedent). Mirrors `idl_rs::video::VideoErrorKind`.
pub enum VideoFailureKind {
    Io,
    Parse,
    NoGpmf,
    NoOverlap,
    Export,
}

/// Error returned by the video bridge entry points.
pub struct VideoFailure {
    pub kind: VideoFailureKind,
    pub message: String,
}

impl From<VideoError> for VideoFailure {
    fn from(e: VideoError) -> Self {
        let kind = match e.kind {
            VideoErrorKind::Io => VideoFailureKind::Io,
            VideoErrorKind::Parse => VideoFailureKind::Parse,
            VideoErrorKind::NoGpmf => VideoFailureKind::NoGpmf,
            VideoErrorKind::NoOverlap => VideoFailureKind::NoOverlap,
            VideoErrorKind::Export => VideoFailureKind::Export,
        };
        VideoFailure { kind, message: e.message }
    }
}

/// Container facts for a video file (pure-Rust ISO-BMFF walk; no ffmpeg).
/// `fps` in frames/second, `duration_s` seconds, creation time in UTC ms.
pub struct VideoInfo {
    pub width: u32,
    pub height: u32,
    pub fps: f64,
    pub duration_s: f64,
    pub creation_time_utc_ms: Option<i64>,
    pub has_gpmd: bool,
}

/// How a sync offset was estimated. Plain unit enum → plain Dart enum.
pub enum VideoSyncMethod {
    Gpmf,
    CreationTime,
}

/// An estimated video↔session sync: `session_time_s = video_time_s +
/// offset_s`; confidence 0.9 (gpmf) / 0.3 (creation_time).
pub struct VideoSyncOutcome {
    pub offset_s: f64,
    pub confidence: f64,
    pub method: VideoSyncMethod,
}

/// Probe an `.mp4`/`.mov` container (SPEC §33.6 `video probe`, in-process).
pub fn video_probe(path: String) -> Result<VideoInfo, VideoFailure> {
    let info = read_info_path(&path)?;
    Ok(VideoInfo {
        width: info.width,
        height: info.height,
        fps: info.fps,
        duration_s: info.duration_s,
        creation_time_utc_ms: info.creation_time_utc_ms,
        has_gpmd: info.has_gpmd,
    })
}

/// Estimate the sync offset for `video_path` against the session: GPMF UTC
/// anchor when present, else container creation time. GPMF *absence* falls
/// through silently (normal); other errors surface. SPEC §33.3.
pub fn estimate_video_sync(
    handle: &SessionHandle,
    video_path: String,
) -> Result<VideoSyncOutcome, VideoFailure> {
    let info = read_info_path(&video_path)?;
    let telemetry = match read_gpmd_samples_path(&video_path) {
        Ok(samples) => Some(parse_gpmf(&samples)?),
        Err(e) if e.kind == VideoErrorKind::NoGpmf => None,
        Err(e) => return Err(e.into()),
    };
    let est = estimate_sync(telemetry.as_ref(), &info, handle)?;
    Ok(VideoSyncOutcome {
        offset_s: est.offset_s,
        confidence: est.confidence,
        method: match est.method {
            SyncMethod::Gpmf => VideoSyncMethod::Gpmf,
            SyncMethod::CreationTime => VideoSyncMethod::CreationTime,
        },
    })
}
```

- [ ] **Step 2: Register the module** — in `rust/bridge/src/lib.rs`, after `pub mod tracks;` add:

```rust
pub mod video;
```

- [ ] **Step 3: Build + test the workspace**

```bash
cd c:\Users\isaac\Documents\Saucy\saucyeng\idl0-app\rust
cargo test 2>&1 | grep "test result"
```
Expected: all green (the bridge has no tests of its own; core covers the logic — this is a compile gate).

- [ ] **Step 4: Commit (submodule repo — stage files individually)**

```bash
cd c:\Users\isaac\Documents\Saucy\saucyeng\idl0-app\rust
git add bridge/src/video.rs bridge/src/lib.rs
git commit -m "bridge: video probe + sync-estimate wrappers (SPEC 33.3, phase 2)"
```

---

### Task 3: FRB codegen

**Files:**
- Generated: `app/lib/src/rust/video.dart` (new), `app/lib/src/rust/frb_generated*.dart` (regenerated), `rust/bridge/src/frb_generated.rs` (regenerated)

**Interfaces:**
- Produces: Dart `videoProbe({required String path})`, `estimateVideoSync({required SessionHandle handle, required String videoPath})`, classes `VideoInfo`, `VideoSyncOutcome`, `VideoFailure`, enums `VideoSyncMethod`, `VideoFailureKind` — importable as `import '../src/rust/video.dart' as rust_video;`.

- [ ] **Step 1: Run codegen from `app/`** (per CLAUDE.md §7 — signature change → codegen)

```bash
cd c:\Users\isaac\Documents\Saucy\saucyeng\idl0-app\app
flutter_rust_bridge_codegen generate
```
Expected: exits 0; `app/lib/src/rust/video.dart` exists and declares `Future<VideoInfo> videoProbe(...)` and `Future<VideoSyncOutcome> estimateVideoSync(...)`. If the tool is missing: `cargo install flutter_rust_bridge_codegen --version 2.12.0 --locked` (must match the pinned crate version).

- [ ] **Step 2: Gate — analyzer + Rust build still green**

```bash
cd c:\Users\isaac\Documents\Saucy\saucyeng\idl0-app\app && flutter analyze
cd c:\Users\isaac\Documents\Saucy\saucyeng\idl0-app\rust && cargo build -p idl_rs_bridge
```

- [ ] **Step 3: Commit both repos**

```bash
cd c:\Users\isaac\Documents\Saucy\saucyeng\idl0-app\rust
git add bridge/src/frb_generated.rs
git commit -m "bridge: regenerate FRB glue for the video module"
cd c:\Users\isaac\Documents\Saucy\saucyeng\idl0-app
git add app/lib/src/rust
git commit -m "FRB codegen: video probe + sync bindings"
```

---

### Task 4: `VideoLink` model + Workspace v8

**Files:**
- Modify: `app/lib/data/workspace.dart` (version const at :41, doc changelog :14-40, class `Workspace` :226 — field/ctor/`empty`/`copyWith`/`toJson` :460/`fromJson` :496)
- Test: `app/test/data/workspace_test.dart`

**Interfaces:**
- Consumes: nothing new (pure Dart).
- Produces:
  - `class VideoLink { final String id; final String path; final int fileSizeBytes; final int fileMtimeMs; final double syncOffsetS; final String syncMethod; final double? syncConfidence; final String? label; }` with `const VideoLink({...})`, `VideoLink copyWith({double? syncOffsetS, String? syncMethod, double? syncConfidence, String? label})`, `Map<String, dynamic> toJson()`, `factory VideoLink.fromJson(Map<String, dynamic>)`.
  - `Workspace.videos: List<VideoLink>` (default `const []`); `Workspace.supportedVersion == 8`.
  - `syncMethod` is one of `'gpmf' | 'creation_time' | 'manual'` (SPEC §33.3; stored as a string, matching the engine's serde tags).

- [ ] **Step 1: Write the failing tests** (append inside the existing top-level group of `app/test/data/workspace_test.dart`)

```dart
group('Workspace v8 — videos —', () {
  Map<String, dynamic> v8Json() => {
        'workspace_version': 8,
        'session_id': 's-1',
        'lap_gates': [],
        'sector_gates': [],
        'math_channels': [],
        'workbook_layout': [],
        'videos': [
          {
            'id': 'v-uuid-1',
            'path': 'C:/rides/GX010001.mp4',
            'file_size_bytes': 123456789,
            'file_mtime_ms': 1751000000000,
            'sync_offset_s': 12.34,
            'sync_method': 'gpmf',
            'sync_confidence': 0.9,
            'label': 'Chest cam',
          },
          {
            'id': 'v-uuid-2',
            'path': 'C:/rides/GX020001.mp4',
            'file_size_bytes': 1,
            'file_mtime_ms': 2,
            'sync_offset_s': 0.0,
            'sync_method': 'manual',
          },
        ],
      };

  test('fromJson — v8 with two links — parses fields and null confidence', () {
    // Arrange
    final json = v8Json();

    // Act
    final ws = Workspace.fromJson(json);

    // Assert
    expect(ws.videos, hasLength(2));
    expect(ws.videos.first.path, 'C:/rides/GX010001.mp4');
    expect(ws.videos.first.syncOffsetS, closeTo(12.34, 1e-9));
    expect(ws.videos.first.syncMethod, 'gpmf');
    expect(ws.videos.first.syncConfidence, closeTo(0.9, 1e-9));
    expect(ws.videos.last.syncConfidence, isNull);
    expect(ws.videos.last.label, isNull);
  });

  test('toJson/fromJson — round-trip — identical videos', () {
    // Arrange
    final ws = Workspace.fromJson(v8Json());

    // Act
    final back = Workspace.fromJson(ws.toJson());

    // Assert
    expect(back.videos, hasLength(2));
    expect(back.toJson()['videos'], ws.toJson()['videos']);
  });

  test('fromJson — v7 file without videos — defaults to empty', () {
    // Arrange
    final json = v8Json()
      ..['workspace_version'] = 7
      ..remove('videos');

    // Act
    final ws = Workspace.fromJson(json);

    // Assert
    expect(ws.videos, isEmpty);
  });

  test('toJson — no videos — omits the key', () {
    // Arrange
    final ws = Workspace.empty('s-1');

    // Act + Assert
    expect(ws.toJson().containsKey('videos'), isFalse);
    expect(ws.workspaceVersion, 8);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd app && flutter test test/data/workspace_test.dart`
Expected: compile errors — `videos` / `VideoLink` undefined.

- [ ] **Step 3: Implement in `workspace.dart`**

Bump the constant and document:

```dart
/// - v8: adds `videos` — video↔session links (SPEC §33.3): file identity
///   (path + size/mtime for cheap re-link validation) and the sync offset
///   (`session_time_s = video_time_s + sync_offset_s`).
const int _kSupportedWorkspaceVersion = 8;
```

New class (place above `class Workspace`, following `TrackVisit`'s style):

```dart
/// One video linked to this session (SPEC §33.3). `path` may live outside
/// the session folder; `fileSizeBytes` + `fileMtimeMs` give cheap re-link
/// validation without hashing multi-GB files. `syncOffsetS` is in seconds
/// (`session_time_s = video_time_s + sync_offset_s`); `syncMethod` is
/// `'gpmf' | 'creation_time' | 'manual'`; `syncConfidence` is null for
/// manual syncs.
class VideoLink {
  final String id;
  final String path;
  final int fileSizeBytes;
  final int fileMtimeMs;
  final double syncOffsetS;
  final String syncMethod;
  final double? syncConfidence;
  final String? label;

  const VideoLink({
    required this.id,
    required this.path,
    required this.fileSizeBytes,
    required this.fileMtimeMs,
    required this.syncOffsetS,
    required this.syncMethod,
    this.syncConfidence,
    this.label,
  });

  VideoLink copyWith({
    double? syncOffsetS,
    String? syncMethod,
    double? syncConfidence,
    String? label,
  }) =>
      VideoLink(
        id: id,
        path: path,
        fileSizeBytes: fileSizeBytes,
        fileMtimeMs: fileMtimeMs,
        syncOffsetS: syncOffsetS ?? this.syncOffsetS,
        syncMethod: syncMethod ?? this.syncMethod,
        syncConfidence: syncConfidence ?? this.syncConfidence,
        label: label ?? this.label,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'path': path,
        'file_size_bytes': fileSizeBytes,
        'file_mtime_ms': fileMtimeMs,
        'sync_offset_s': syncOffsetS,
        'sync_method': syncMethod,
        if (syncConfidence != null) 'sync_confidence': syncConfidence,
        if (label != null) 'label': label,
      };

  factory VideoLink.fromJson(Map<String, dynamic> json) => VideoLink(
        id: json['id'] as String,
        path: json['path'] as String,
        fileSizeBytes: json['file_size_bytes'] as int,
        fileMtimeMs: json['file_mtime_ms'] as int,
        syncOffsetS: (json['sync_offset_s'] as num).toDouble(),
        syncMethod: json['sync_method'] as String,
        syncConfidence: (json['sync_confidence'] as num?)?.toDouble(),
        label: json['label'] as String?,
      );
}
```

Wire into `Workspace` exactly like `trackVisits`: field `final List<VideoLink> videos;`, constructor param `this.videos = const []`, thread through `copyWith` (`List<VideoLink>? videos` → `videos: videos ?? this.videos`) **and every `clearX()` reconstructor** (each rebuilds the full field list — add `videos: videos` to all five), `toJson` emit-when-nonempty (`if (videos.isNotEmpty) 'videos': videos.map((v) => v.toJson()).toList()`), `fromJson` default-empty (`videos: (json['videos'] as List<dynamic>? ?? []).map((v) => VideoLink.fromJson(v as Map<String, dynamic>)).toList()`).

- [ ] **Step 4: Run tests**

Run: `cd app && flutter test test/data/workspace_test.dart && flutter analyze`
Expected: all pass (new + pre-existing), analyzer clean.

- [ ] **Step 5: Commit (idl0-app)**

```bash
git add app/lib/data/workspace.dart app/test/data/workspace_test.dart
git commit -m "workspace v8: VideoLink entries (SPEC 33.3, phase 2)"
```

---

### Task 5: Workbook v2 — Dart `OverlayLayout`

**Files:**
- Create: `app/lib/data/overlay_layout.dart`
- Modify: `app/lib/data/workbook.dart` (version const :8, fields :27-51, ctor :54, `create` :70/`createDefault` :95/`createBlank` :117, `copyWith` :133, `toJson` :162, `fromJson` :176)
- Test: `app/test/data/overlay_layout_test.dart` (new), `app/test/data/workbook_test.dart`

**Interfaces:**
- Produces:
  - `class OverlayLayout { final String id; final String name; final String canvas; final List<OverlayElement> elements; }` + `toJson`/`fromJson`.
  - `sealed class OverlayElement` with subtypes `GaugeElement(rect, channel, style, label, min, max)`, `AttitudeElement(rect, channel, style, rangeDeg)`, `TraceStripElement(rect, channels, windowS)`, `TrackMapElement(rect)`, `LapPanelElement(rect)`; `rect` is `List<double>` (length 4, `[x, y, w, h]`); styles are plain strings validated against the engine sets (`numeric|bar|dial`, `roll|steer`).
  - `Workbook.overlayLayouts: List<OverlayLayout>` (default `const []`); `Workbook.supportedVersion == 2`.

**Parity requirement:** the JSON must be byte-shape identical to what the engine reads (SPEC §33.1). The test fixture below is the engine's own `LAYOUT_JSON` from `core/src/overlay/model.rs` — keep them in lockstep.

- [ ] **Step 1: Write the failing tests** (`app/test/data/overlay_layout_test.dart`)

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/overlay_layout.dart';

/// Engine parity fixture — mirrors LAYOUT_JSON in idl-rs
/// core/src/overlay/model.rs. Keep in lockstep.
const _layoutJson = '''
{
  "id": "11111111-2222-3333-4444-555555555555",
  "name": "MTB default",
  "canvas": "1920x1080",
  "elements": [
    { "type": "gauge", "rect": [0.02, 0.80, 0.14, 0.16], "channel": "GPS_SpeedKmh",
      "style": "numeric", "label": "km/h", "min": 0, "max": 80 },
    { "type": "attitude", "rect": [0.18, 0.80, 0.10, 0.16], "channel": "Roll_deg",
      "style": "roll", "range_deg": 60 },
    { "type": "trace_strip", "rect": [0.30, 0.82, 0.40, 0.15],
      "channels": ["TravelFront_mm", "TravelRear_mm"], "window_s": 8.0 },
    { "type": "track_map", "rect": [0.84, 0.04, 0.14, 0.25] },
    { "type": "lap_panel", "rect": [0.02, 0.04, 0.16, 0.14] }
  ]
}
''';

void main() {
  group('OverlayLayout —', () {
    test('fromJson — engine parity fixture — parses all five element kinds', () {
      // Arrange
      final json = jsonDecode(_layoutJson) as Map<String, dynamic>;

      // Act
      final layout = OverlayLayout.fromJson(json);

      // Assert
      expect(layout.name, 'MTB default');
      expect(layout.elements, hasLength(5));
      final gauge = layout.elements[0] as GaugeElement;
      expect(gauge.channel, 'GPS_SpeedKmh');
      expect(gauge.style, 'numeric');
      expect(gauge.rect, [0.02, 0.80, 0.14, 0.16]);
      final attitude = layout.elements[1] as AttitudeElement;
      expect(attitude.rangeDeg, 60);
      final trace = layout.elements[2] as TraceStripElement;
      expect(trace.channels, ['TravelFront_mm', 'TravelRear_mm']);
      expect(trace.windowS, 8.0);
      expect(layout.elements[3], isA<TrackMapElement>());
      expect(layout.elements[4], isA<LapPanelElement>());
    });

    test('toJson — round-trip — re-parses identically', () {
      // Arrange
      final layout = OverlayLayout.fromJson(
          jsonDecode(_layoutJson) as Map<String, dynamic>);

      // Act
      final back = OverlayLayout.fromJson(layout.toJson());

      // Assert
      expect(back.toJson(), layout.toJson());
      expect((back.elements[0] as GaugeElement).max, 80);
    });

    test('fromJson — unknown element type — throws FormatException', () {
      // Arrange
      final json = jsonDecode(_layoutJson) as Map<String, dynamic>;
      (json['elements'] as List)[0] = {'type': 'hologram', 'rect': [0, 0, 1, 1]};

      // Act + Assert
      expect(() => OverlayLayout.fromJson(json), throwsFormatException);
    });
  });
}
```

And in `app/test/data/workbook_test.dart`, append:

```dart
group('Workbook v2 — overlay layouts —', () {
  test('fromJson — v1 json without overlay_layouts — defaults to empty', () {
    // Arrange
    final wb = Workbook.create(name: 'wb');
    final json = wb.toJson()
      ..['workbook_version'] = 1
      ..remove('overlay_layouts');

    // Act
    final back = Workbook.fromJson(json);

    // Assert
    expect(back.overlayLayouts, isEmpty);
  });

  test('toJson/fromJson — with a layout — round-trips and version is 2', () {
    // Arrange
    final layout = OverlayLayout(
      id: 'L1',
      name: 'A',
      canvas: '1920x1080',
      elements: const [TrackMapElement(rect: [0.8, 0.0, 0.2, 0.3])],
    );
    final wb = Workbook.create(name: 'wb').copyWith(overlayLayouts: [layout]);

    // Act
    final back = Workbook.fromJson(wb.toJson());

    // Assert
    expect(back.workbookVersion, 2);
    expect(back.overlayLayouts.single.name, 'A');
    expect(back.overlayLayouts.single.elements.single, isA<TrackMapElement>());
  });
});
```

(Add `import 'package:idl0/data/overlay_layout.dart';` to the workbook test's imports. If the app's package name differs from `idl0`, match the existing imports in that test file.)

- [ ] **Step 2: Run to verify failure** — `cd app && flutter test test/data/overlay_layout_test.dart` → compile error (file missing).

- [ ] **Step 3: Implement `app/lib/data/overlay_layout.dart`**

```dart
/// Overlay layout model — Dart mirror of the engine's `overlay::model`
/// (SPEC §33.1). Stored on the workbook (`.idl0wb` v2, `overlay_layouts`);
/// the engine consumes this JSON directly (`idl-rs overlay --workbook`), so
/// the wire shape is engine-defined: snake_case keys, `rect` as an
/// `[x, y, w, h]` array of canvas fractions, lowercase style strings.
library;

/// A named overlay layout (workbook asset, canvas-agnostic).
class OverlayLayout {
  final String id;
  final String name;

  /// Design-space size as `"WxH"` pixels (stroke/font scaling only).
  final String canvas;
  final List<OverlayElement> elements;

  const OverlayLayout({
    required this.id,
    required this.name,
    required this.canvas,
    required this.elements,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'canvas': canvas,
        'elements': elements.map((e) => e.toJson()).toList(),
      };

  factory OverlayLayout.fromJson(Map<String, dynamic> json) => OverlayLayout(
        id: json['id'] as String,
        name: json['name'] as String,
        canvas: json['canvas'] as String,
        elements: (json['elements'] as List<dynamic>? ?? [])
            .map((e) => OverlayElement.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

List<double> _rect(Map<String, dynamic> json) =>
    (json['rect'] as List<dynamic>).map((v) => (v as num).toDouble()).toList();

/// One positioned overlay element. `rect` is normalized `[x, y, w, h]`.
sealed class OverlayElement {
  /// Normalized `[x, y, w, h]` canvas fractions.
  final List<double> rect;

  const OverlayElement({required this.rect});

  Map<String, dynamic> toJson();

  factory OverlayElement.fromJson(Map<String, dynamic> json) =>
      switch (json['type'] as String?) {
        'gauge' => GaugeElement(
            rect: _rect(json),
            channel: json['channel'] as String,
            style: json['style'] as String,
            label: json['label'] as String? ?? '',
            min: (json['min'] as num).toDouble(),
            max: (json['max'] as num).toDouble(),
          ),
        'attitude' => AttitudeElement(
            rect: _rect(json),
            channel: json['channel'] as String,
            style: json['style'] as String,
            rangeDeg: (json['range_deg'] as num).toDouble(),
          ),
        'trace_strip' => TraceStripElement(
            rect: _rect(json),
            channels: (json['channels'] as List<dynamic>)
                .map((c) => c as String)
                .toList(),
            windowS: (json['window_s'] as num).toDouble(),
          ),
        'track_map' => TrackMapElement(rect: _rect(json)),
        'lap_panel' => LapPanelElement(rect: _rect(json)),
        final other =>
          throw FormatException('unknown overlay element type: $other'),
      };
}

/// Single-value readout; `style` ∈ `numeric | bar | dial`; `min`/`max`
/// bound bar/dial travel in channel units.
class GaugeElement extends OverlayElement {
  final String channel;
  final String style;
  final String label;
  final double min;
  final double max;

  const GaugeElement({
    required super.rect,
    required this.channel,
    required this.style,
    required this.label,
    required this.min,
    required this.max,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'gauge',
        'rect': rect,
        'channel': channel,
        'style': style,
        'label': label,
        'min': min,
        'max': max,
      };
}

/// Signed zero-centered indicator; `style` ∈ `roll | steer`; `rangeDeg` is
/// full-scale deflection in degrees.
class AttitudeElement extends OverlayElement {
  final String channel;
  final String style;
  final double rangeDeg;

  const AttitudeElement({
    required super.rect,
    required this.channel,
    required this.style,
    required this.rangeDeg,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'attitude',
        'rect': rect,
        'channel': channel,
        'style': style,
        'range_deg': rangeDeg,
      };
}

/// Scrolling time-series strip: trailing `windowS` seconds, "now" at the
/// right edge.
class TraceStripElement extends OverlayElement {
  final List<String> channels;
  final double windowS;

  const TraceStripElement({
    required super.rect,
    required this.channels,
    required this.windowS,
  });

  @override
  Map<String, dynamic> toJson() => {
        'type': 'trace_strip',
        'rect': rect,
        'channels': channels,
        'window_s': windowS,
      };
}

/// Session GPS outline with current-position dot.
class TrackMapElement extends OverlayElement {
  const TrackMapElement({required super.rect});

  @override
  Map<String, dynamic> toJson() => {'type': 'track_map', 'rect': rect};
}

/// Current/last/best lap readout.
class LapPanelElement extends OverlayElement {
  const LapPanelElement({required super.rect});

  @override
  Map<String, dynamic> toJson() => {'type': 'lap_panel', 'rect': rect};
}
```

- [ ] **Step 4: Wire into `Workbook`** (`app/lib/data/workbook.dart`)

- `const int _kSupportedWorkbookVersion = 2;` (line 8) with a doc note: `// v2: adds overlay_layouts (SPEC §33.1); additive — v1 files load with an empty list.`
- `import 'overlay_layout.dart';`
- Field `final List<OverlayLayout> overlayLayouts;`; add `this.overlayLayouts = const []` to the const constructor and thread through `Workbook.create` / `createDefault` / `createBlank` (default empty), `copyWith` (`List<OverlayLayout>? overlayLayouts`), `toJson` (`if (overlayLayouts.isNotEmpty) 'overlay_layouts': overlayLayouts.map((l) => l.toJson()).toList()`), `fromJson` (`overlayLayouts: (json['overlay_layouts'] as List<dynamic>? ?? []).map((l) => OverlayLayout.fromJson(l as Map<String, dynamic>)).toList()`).

- [ ] **Step 5: Run tests** — `cd app && flutter test test/data/ && flutter analyze` → all green (the full data dir catches workbook-index/migration regressions from the version bump).

- [ ] **Step 6: Commit**

```bash
git add app/lib/data/overlay_layout.dart app/lib/data/workbook.dart app/test/data/overlay_layout_test.dart app/test/data/workbook_test.dart
git commit -m "workbook v2: Dart OverlayLayout model, engine-parity JSON (SPEC 33.1)"
```

---

### Task 6: Link flow — workspace mutators + auto-sync link builder

**Files:**
- Modify: `app/lib/providers/session_workspace_provider.dart` (mutator seam at :261-265), `app/lib/data/exceptions.dart`
- Create: `app/lib/providers/video_link_provider.dart`
- Test: `app/test/providers/video_link_provider_test.dart` (new), `app/test/providers/session_workspace_provider_test.dart` (extend if it exists; else cover mutators via the workspace test — check `app/test/providers/` first and follow what's there)

**Interfaces:**
- Consumes: `VideoLink`/`Workspace.videos` (Task 4); Dart bindings `videoProbe`/`estimateVideoSync` (Task 3); `sessionHandleProvider` (`app/lib/providers/channel_provider.dart:45`); `SessionWorkspaceNotifier._persist` pattern.
- Produces:
  - Mutators on `SessionWorkspaceNotifier`: `Future<void> linkVideo(VideoLink link)`, `Future<void> unlinkVideo(String videoId)`, `Future<void> setVideoSync(String videoId, {required double offsetS, required String method, double? confidence})` — each `_persist(ws.copyWith(videos: ...))`.
  - `buildVideoLink(...)` — a **pure** assembler, unit-testable without the bridge:

```dart
/// Assemble a [VideoLink] from file stats + an optional engine sync
/// estimate. Pure: no I/O, no bridge. `estimate == null` (no anchor in the
/// container, or estimation failed benignly) → manual sync at offset 0 with
/// null confidence, for the user to nudge in phase 3.
VideoLink buildVideoLink({
  required String id,
  required String path,
  required int fileSizeBytes,
  required int fileMtimeMs,
  ({double offsetS, double confidence, String method})? estimate,
  String? label,
});
```

  - `videoLinkerProvider` — the impure edge: stats the file, calls `videoProbe` + `estimateVideoSync`, maps outcomes:

```dart
/// Builds a ready-to-persist [VideoLink] for [videoPath] against the
/// session's handle. GPMF/creation-time estimation happens engine-side;
/// a Parse failure (no anchor at all) degrades to manual/offset-0; a
/// NoOverlap failure throws [VideoSyncMismatchException] (the user picked
/// a video from a different ride — surface it, don't store it).
final videoLinkerProvider = Provider<VideoLinker>(...);
class VideoLinker {
  Future<VideoLink> link({required String sessionId, required String videoPath, String? label});
}
```

  - New typed exceptions in `app/lib/data/exceptions.dart` (§16 style, match neighbors): `VideoLinkException(String message)` (unreadable/unparseable container) and `VideoSyncMismatchException(String message)` (no time overlap).

- [ ] **Step 1: Write the failing tests for the pure parts** (`app/test/providers/video_link_provider_test.dart`)

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/workspace.dart';
import 'package:idl0/providers/video_link_provider.dart';

void main() {
  group('buildVideoLink —', () {
    test('with estimate — stores engine offset/method/confidence', () {
      // Arrange + Act
      final link = buildVideoLink(
        id: 'v1',
        path: 'C:/rides/a.mp4',
        fileSizeBytes: 10,
        fileMtimeMs: 20,
        estimate: (offsetS: 23.4, confidence: 0.9, method: 'gpmf'),
      );

      // Assert
      expect(link.syncOffsetS, closeTo(23.4, 1e-9));
      expect(link.syncMethod, 'gpmf');
      expect(link.syncConfidence, closeTo(0.9, 1e-9));
    });

    test('without estimate — degrades to manual at offset 0, null confidence', () {
      // Arrange + Act
      final link = buildVideoLink(
        id: 'v1',
        path: 'C:/rides/a.mp4',
        fileSizeBytes: 10,
        fileMtimeMs: 20,
        estimate: null,
      );

      // Assert
      expect(link.syncOffsetS, 0.0);
      expect(link.syncMethod, 'manual');
      expect(link.syncConfidence, isNull);
    });
  });
}
```

And mutator tests — follow the persistence-seam fake already used by workspace tests (`workspaceSaverFactoryProvider`, session_workspace_provider.dart:278-280); assert `linkVideo` appends, `unlinkVideo` removes by id, `setVideoSync` rewrites offset/method/confidence on the matching link and leaves others untouched, and that a manual `setVideoSync` (method `'manual'`) sets `syncConfidence` null even when a confidence is passed as null.

- [ ] **Step 2: Run to verify failure** — `cd app && flutter test test/providers/video_link_provider_test.dart` → compile error.

- [ ] **Step 3: Implement**

`app/lib/providers/video_link_provider.dart`:

```dart
/// Link-time video flow (SPEC §33.3, phase 2): stat the file, probe the
/// container, estimate the sync offset engine-side, and assemble the
/// [VideoLink] the workspace persists. The UI (picker, nudge controls,
/// playback) is phase 3.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/exceptions.dart';
import '../data/workspace.dart';
import '../src/rust/video.dart' as rust_video;
import 'channel_provider.dart';

/// Assemble a [VideoLink] from file stats + an optional engine sync
/// estimate. Pure: no I/O, no bridge. `estimate == null` → manual sync at
/// offset 0 (seconds) with null confidence, for the user to nudge later.
VideoLink buildVideoLink({
  required String id,
  required String path,
  required int fileSizeBytes,
  required int fileMtimeMs,
  ({double offsetS, double confidence, String method})? estimate,
  String? label,
}) =>
    VideoLink(
      id: id,
      path: path,
      fileSizeBytes: fileSizeBytes,
      fileMtimeMs: fileMtimeMs,
      syncOffsetS: estimate?.offsetS ?? 0.0,
      syncMethod: estimate?.method ?? 'manual',
      syncConfidence: estimate?.confidence,
      label: label,
    );

/// Impure edge: file stat + bridge calls. Kept thin so everything above it
/// is testable without the native library.
class VideoLinker {
  VideoLinker(this._ref);
  final Ref _ref;

  Future<VideoLink> link({
    required String sessionId,
    required String videoPath,
    String? label,
  }) async {
    final stat = await File(videoPath).stat();
    if (stat.type == FileSystemEntityType.notFound) {
      throw VideoLinkException('video file not found: $videoPath');
    }
    final handle =
        await _ref.read(sessionHandleProvider(sessionId).future);

    ({double offsetS, double confidence, String method})? estimate;
    try {
      final est = await rust_video.estimateVideoSync(
          handle: handle, videoPath: videoPath);
      estimate = (
        offsetS: est.offsetS,
        confidence: est.confidence,
        method: switch (est.method) {
          rust_video.VideoSyncMethod.gpmf => 'gpmf',
          rust_video.VideoSyncMethod.creationTime => 'creation_time',
        },
      );
    } on rust_video.VideoFailure catch (e) {
      switch (e.kind) {
        case rust_video.VideoFailureKind.noOverlap:
          throw VideoSyncMismatchException(e.message);
        case rust_video.VideoFailureKind.parse:
          estimate = null; // no anchor — manual sync, user nudges in phase 3
        case rust_video.VideoFailureKind.io:
        case rust_video.VideoFailureKind.noGpmf:
        case rust_video.VideoFailureKind.export:
          throw VideoLinkException(e.message);
      }
    }

    return buildVideoLink(
      id: const Uuid().v4(),
      path: videoPath,
      fileSizeBytes: stat.size,
      fileMtimeMs: stat.modified.millisecondsSinceEpoch,
      estimate: estimate,
      label: label,
    );
  }
}

/// The app-wide linker. Overridable in tests.
final videoLinkerProvider = Provider<VideoLinker>(VideoLinker.new);
```

(Check `pubspec.yaml` for `uuid` — the workbook/`Workbook.create` path already generates UUIDs; reuse whatever it uses. If it's not `package:uuid`, match the existing mechanism.)

Mutators in `SessionWorkspaceNotifier` (session_workspace_provider.dart, beside the existing mutators):

```dart
/// Append a video link (SPEC §33.3). Persists immediately.
Future<void> linkVideo(VideoLink link) async {
  final ws = state.valueOrNull;
  if (ws == null) return;
  await _persist(ws.copyWith(videos: [...ws.videos, link]));
}

/// Remove the link with [videoId]. No-op when absent.
Future<void> unlinkVideo(String videoId) async {
  final ws = state.valueOrNull;
  if (ws == null) return;
  await _persist(
      ws.copyWith(videos: ws.videos.where((v) => v.id != videoId).toList()));
}

/// Rewrite one link's sync fields (manual nudge / re-estimate). A manual
/// method always stores a null confidence (SPEC §33.3).
Future<void> setVideoSync(
  String videoId, {
  required double offsetS,
  required String method,
  double? confidence,
}) async {
  final ws = state.valueOrNull;
  if (ws == null) return;
  await _persist(ws.copyWith(
    videos: [
      for (final v in ws.videos)
        if (v.id == videoId)
          v.copyWith(
            syncOffsetS: offsetS,
            syncMethod: method,
            syncConfidence: method == 'manual' ? null : confidence,
          )
        else
          v,
    ],
  ));
}
```

**Note:** `VideoLink.copyWith` as written in Task 4 can't null out `syncConfidence` (the `?? this.` pattern). Fix during this task: give `copyWith` a sentinel-free variant for that one field — replace the parameter with `Object? syncConfidence = _unset` (`static const _unset = Object();`) and `syncConfidence: identical(syncConfidence, _unset) ? this.syncConfidence : syncConfidence as double?`. Mirror how `Workspace.clearX()` handles nullables if the codebase prefers dedicated methods — check first and match.

Exceptions (`app/lib/data/exceptions.dart`, matching neighboring style):

```dart
/// A video file could not be linked (missing, unreadable, or unparseable
/// container).
class VideoLinkException implements Exception {
  final String message;
  const VideoLinkException(this.message);
  @override
  String toString() => 'VideoLinkException: $message';
}

/// The video's time range does not overlap the session at all — almost
/// certainly footage from a different ride.
class VideoSyncMismatchException implements Exception {
  final String message;
  const VideoSyncMismatchException(this.message);
  @override
  String toString() => 'VideoSyncMismatchException: $message';
}
```

- [ ] **Step 4: Run tests** — `cd app && flutter test test/providers/video_link_provider_test.dart test/data/ && flutter analyze` → green. (Any test that would exercise `VideoLinker.link` end-to-end needs the native library — either override `videoLinkerProvider` with a fake or carry the standard `skip:` marker.)

- [ ] **Step 5: Commit**

```bash
git add app/lib/providers/video_link_provider.dart app/lib/providers/session_workspace_provider.dart app/lib/data/exceptions.dart app/lib/data/workspace.dart app/test/providers/video_link_provider_test.dart
git commit -m "video link flow: workspace mutators + auto-sync link builder (SPEC 33.3)"
```

---

### Task 7: Spec-during + docs closure + submodule pointer

**Files:**
- Modify: `docs/IDL0_SPEC.md` (§11.4 :897, §15, §17a :1389), `CHANGELOG.md`, `TASKS.md`, plus the idl0-app submodule pointer.

- [ ] **Step 1: SPEC §11.4** — in the workspace-version paragraph under the file-model table, note v8; **SPEC §15** — add a short "Video links" subsection: the `videos[]` schema (field list + semantics verbatim from the design doc §4), `session_time_s = video_time_s + sync_offset_s`, missing file → re-link prompt, never blocks load, immutable-`.idl0` untouched; cross-reference §33. **SPEC §17a** — in the schema section, add `overlay_layouts` (v2, additive; element vocabulary defined in §33.1; v1 files load with an empty list).

- [ ] **Step 2: CHANGELOG.md** — under `### Added`:

```markdown
- **Video overlay phase 2 — app data layer (2026-07-09).** `.idl0w` v8:
  `videos[]` link entries (path, size+mtime re-link identity, sync offset/
  method/confidence). Workbook v2 Dart model: `overlay_layouts` mirroring
  the engine schema byte-for-byte. New bridge module (`video_probe`,
  `estimate_video_sync`) + FRB codegen; linking a video auto-syncs via GPMF
  UTC (else creation time), degrading to manual/offset-0 when the container
  has no anchor. **Spec disposition:** spec-during — §11.4/§15/§17a updated
  with the code; subsystem contract in §33. UI (picker, playback, nudge) is
  phase 3.
```

- [ ] **Step 3: TASKS.md** — tick the phase-2 entry (`- [x]`), append a one-line completion note with the date, leave phase 3 queued.

- [ ] **Step 4: Commit docs, then merge + submodule pointer**

```bash
cd c:\Users\isaac\Documents\Saucy\saucyeng\idl0-app
git add docs/IDL0_SPEC.md CHANGELOG.md TASKS.md
git commit -m "Docs: video overlay phase 2 shipped (spec-during: 11.4/15/17a)"
```

Then finish per superpowers:finishing-a-development-branch: merge the submodule branch into the submodule's `main`, sync the sibling clone (`cd c:\Users\isaac\Documents\Saucy\saucyeng\idl-rs && git fetch c:\Users\isaac\Documents\Saucy\saucyeng\idl0-app\rust main && git merge --ff-only FETCH_HEAD`), then in idl0-app merge `video-overlay-phase2` to `main` **including the submodule pointer bump**:

```bash
cd c:\Users\isaac\Documents\Saucy\saucyeng\idl0-app
git add rust
git commit -m "rust: bump submodule to video overlay phases 1+2"
```

(Ordering note: the pointer commit must come after the submodule branch is merged to the submodule's main, so the pinned commit is on a persistent branch. Remind the user the engine work is still unpushed to `github.com/saucyeng/idl-rs` — CI/other machines need a `git push` from either checkout.)

---

## Self-review checklist (ran at plan time)

- **Spec coverage:** design doc §4 workspace schema → Task 4; §4 workbook schema → Task 5; §5 sync-at-link (auto → manual degradation, NoOverlap surfaced, manual never silently overwritten — `setVideoSync` is explicit-only) → Tasks 2/6; §7 Android `content://` wrinkle → *deliberately deferred to phase 3* (it binds to the picker UI; noted in TASKS phase-3 entry already); TASKS phase-2 entry items all covered.
- **Placeholder scan:** the two "check first and match" notes (uuid mechanism, nullable-copyWith house style) are genuine repo-convention lookups with a stated default, not deferred design.
- **Type consistency:** `VideoLink` fields (T4) = `buildVideoLink` output (T6) = the JSON keys in T4's tests = SPEC §33.3/design-doc §4 schema. Bridge names (T2) = generated Dart names (T3) = call sites (T6): `videoProbe`/`estimateVideoSync`/`VideoSyncMethod.{gpmf,creationTime}`/`VideoFailureKind.{io,parse,noGpmf,noOverlap,export}` (FRB lower-camels Dart enum variants). `Workbook.overlayLayouts` (T5) matches the `overlay_layouts` key the engine reads (T3 of phase 1).
- **Known risk, called out:** FRB codegen output names/casing are generator-determined — Task 3 verifies the generated signatures before Task 6 consumes them; if the generator renders `VideoFailure` as an exception type differently (e.g. `AnyhowException`), Task 6's `on rust_video.VideoFailure catch` must be adjusted to whatever `video.dart` actually declares. Verify at Task 3, not assume.
