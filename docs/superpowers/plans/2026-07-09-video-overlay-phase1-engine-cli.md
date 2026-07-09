# Video Overlay Phase 1 (Engine + CLI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Headless video-overlay export — `idl-rs overlay` renders session telemetry (gauges, attitude, trace strip, track map, lap panel) onto a video via a tiny-skia rasterizer and a sidecar-ffmpeg driver, with GPMF auto-sync (`idl-rs video sync`) and container probing (`idl-rs video probe`).

**Architecture:** Per `docs/superpowers/specs/2026-07-08-video-overlay-design.md`: a canvas-agnostic `overlay::{model,sample}` in the pure core; `video::{mp4box,gpmf,sync,render}` beside it; a new `video-export` crate that owns all process spawning (ffprobe/ffmpeg); three new CLI subcommands compose them. The engine never links or spawns ffmpeg.

**Tech Stack:** Rust. New core deps: `tiny-skia 0.11` (+`png` feature for golden tests), `fontdue 0.9`. New crate `video-export` deps: `serde`, `serde_json`, `rayon`. Hand-rolled ISO-BMFF walker (no `mp4` crate — its `TrackType` rejects `gpmd`-handler tracks). Fonts: vendored IBM Plex Mono (OFL).

## Global Constraints

- Two repos: engine/CLI code + tests commit in `c:\Users\isaac\Documents\Saucy\saucyeng\idl-rs`; SPEC/CHANGELOG/TASKS/design-doc commits in `c:\Users\isaac\Documents\Saucy\saucyeng\idl0-app`. Never mix.
- **NEVER add Co-Authored-By or any AI-attribution trailer to commits.**
- Core purity: `core/` has no process spawning, no I/O beyond `std::fs`, no clap/FRB. All `std::process` use lives in `video-export` and `cli`.
- Error shape: unit-enum `kind` + `message` structs (match `ConfigError` in `core/src/config.rs`), never `panic!` on bad input data.
- Every public symbol gets a doc comment; units mandatory (`_s` seconds, `_ms` milliseconds, `_deg` degrees, `_mps` m/s, coordinates at raw channel scale = degrees × 1e7 unless suffixed `_deg`).
- Tests: Arrange/Act/Assert with blank lines; names `method — condition — expected`. Run `cargo test` from the `idl-rs` repo root; all tests green before every commit.
- TODO format: `// TODO(idl0): …`.
- Time model: `session_time_s = video_time_s + sync_offset_s`. All sampling is in session recording-time seconds (the synthesized `Time` channel's domain).
- `cargo fmt` before each commit.

---

### Task 1: SPEC section (spec-first gate)

**Files:**
- Modify: `c:\Users\isaac\Documents\Saucy\saucyeng\idl0-app\docs\IDL0_SPEC.md` (append new §33 after §30; add TOC entry)

**Interfaces:**
- Produces: the normative contract every later task implements. No code.

- [ ] **Step 1: Append §33 to the spec**

Add to the Table of Contents: `§33 Video Overlay (engine + CLI)`. Append at the end of the spec:

```markdown
## 33. Video Overlay (engine + CLI)

Phase 1 of the video feature (design doc
`docs/superpowers/specs/2026-07-08-video-overlay-design.md`): headless
burned-in overlay export. App data layer (workspace v8 links) and UI are
phases 2–3 and are NOT described here yet.

### 33.1 Overlay model (canvas-agnostic)

`overlay::model::OverlayLayout` — stored in the workbook (`.idl0wb`,
`workbook_version: 2`, additive field `overlay_layouts`). Elements: `gauge`
(styles `numeric | bar | dial`; fields `channel`, `label`, `min`, `max`),
`attitude` (styles `roll | steer`; fields `channel`, `range_deg`),
`trace_strip` (`channels[]`, `window_s`), `track_map`, `lap_panel`. Rects are
normalized `[x, y, w, h]` fractions of the canvas. `canvas` (`"1920x1080"`) is
design-space for stroke/font scaling only — never an output resolution.
Channel references resolve like charts (raw, synthesized, math); a missing
channel degrades that element to its no-data state (`—`), never fails the
render.

### 33.2 Sampling

`overlay::sample::SampleContext::prepare(handle, layout, laps)` materializes
referenced channels once; `sample(t_secs)` returns a `FrameSample` (gauge
values, trace windows normalized to session min/max, GPS position normalized
to the session track bbox, lap state). Rate-based channels interpolate
linearly; event-driven channels carry forward. `t` outside a channel's span →
no-data.

### 33.3 GPMF & sync

`video::mp4box` walks ISO-BMFF (no ffmpeg): `gpmd` sample payloads with
video-relative timestamps, `mvhd creation_time`, video-track
width/height/fps/duration. `video::gpmf` parses GPMF KLV (`DEVC`→`STRM`→
`GPS5|GPS9` with `SCAL`/`GPSU`) → `VideoTelemetry`. `video::sync::
estimate_sync` returns `SyncEstimate { offset_s, confidence, method }`:
`gpmf` (UTC anchor vs `GPS_EpochMs`-anchored session clock, confidence 0.9)
else `creation_time` (confidence 0.3). Manual offsets always win; rendering
never re-estimates. Video/session overlap is validated — none → typed error
listing both ranges.

### 33.4 Rendering

`video::render::render_overlay_frame(layout, sample, w, h)` → straight
(un-premultiplied) RGBA bytes via tiny-skia; text via embedded IBM Plex Mono
(OFL). Deterministic (golden-image tested). The video compositor is the first
consumer of the overlay model, not its owner.

### 33.5 Export driver (`video-export` crate)

The only process-spawning component. `ffprobe` (JSON) probes width/height/
fps/duration/rotation/audio; `ffmpeg` receives rendered frames as a second
rawvideo RGBA input piped to stdin, `filter_complex overlay`, audio
stream-copied, `libx264` default (`--encoder` overrides), `+faststart`.
Output writes to `<out>.part`, renamed on success. VFR input is normalized to
CFR; rotation metadata is applied at probe time. Progress = frames fed /
total; cancel kills the child and removes the `.part`.

### 33.6 CLI

- `idl-rs overlay <session.idl0> --video <v.mp4> --workbook <w.idl0wb>
  [--layout <name>] [--track <t.idl0t>] [--offset <s>] [--start <s>]
  [--duration <s>] [--output <out.mp4>] [--encoder <name>] [--ffmpeg <path>]`
  — bulk command (§29.7 envelope: artifact on success, error envelope on
  stderr). `--layout` optional only when the workbook has exactly one layout.
  `--track` enables the lap panel; without it lap elements render no-data.
  `--offset` skips auto-sync. Math channels are applied (`apply_workbook`)
  before sampling.
- `idl-rs video sync <session.idl0> --video <v.mp4>` — structured command:
  offset/confidence/method (text or `--format json`).
- `idl-rs video probe --video <v.mp4>` — structured command: container info +
  GPMF presence (pure-Rust walker; no ffprobe).
```

- [ ] **Step 2: Commit (idl0-app repo)**

```bash
cd c:\Users\isaac\Documents\Saucy\saucyeng\idl0-app
git add docs/IDL0_SPEC.md
git commit -m "SPEC §33: video overlay engine + CLI (phase 1, spec-first)"
```

---

### Task 2: `overlay::model` — layout types + JSON

**Files:**
- Create: `core/src/overlay/mod.rs`, `core/src/overlay/model.rs` (in idl-rs repo)
- Modify: `core/src/lib.rs` (add `pub mod overlay;` after `pub mod math;`)

**Interfaces:**
- Produces:
  - `overlay::model::{OverlayLayout, OverlayElement, GaugeStyle, AttitudeStyle, Rect}`
  - `OverlayLayout { pub id: String, pub name: String, pub canvas: String, pub elements: Vec<OverlayElement> }`
  - `OverlayLayout::canvas_size(&self) -> (u32, u32)` (parses `"1920x1080"`, falls back to `(1920, 1080)` on malformed input)
  - `OverlayLayout::referenced_channels(&self) -> Vec<String>` (unique, document order)
  - `OverlayElement` serde-tagged enum (`type` tag, snake_case):
    `Gauge { rect: Rect, channel: String, style: GaugeStyle, label: String, min: f64, max: f64 }`,
    `Attitude { rect: Rect, channel: String, style: AttitudeStyle, range_deg: f64 }`,
    `TraceStrip { rect: Rect, channels: Vec<String>, window_s: f64 }`,
    `TrackMap { rect: Rect }`, `LapPanel { rect: Rect }`
  - `Rect { pub x: f32, pub y: f32, pub w: f32, pub h: f32 }` — (de)serializes as the JSON array `[x, y, w, h]`

- [ ] **Step 1: Write the failing tests** (inline `#[cfg(test)]` in `model.rs`)

```rust
#[cfg(test)]
mod tests {
    use super::*;

    const LAYOUT_JSON: &str = r#"{
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
    }"#;

    #[test]
    fn deserialize — full_layout_json — parses_all_five_element_kinds() {
        // Arrange: LAYOUT_JSON above

        // Act
        let l: OverlayLayout = serde_json::from_str(LAYOUT_JSON).unwrap();

        // Assert
        assert_eq!(l.name, "MTB default");
        assert_eq!(l.elements.len(), 5);
        assert!(matches!(&l.elements[0], OverlayElement::Gauge { style: GaugeStyle::Numeric, .. }));
        assert!(matches!(&l.elements[1], OverlayElement::Attitude { style: AttitudeStyle::Roll, .. }));
        match &l.elements[2] {
            OverlayElement::TraceStrip { rect, channels, window_s } => {
                assert_eq!(rect.x, 0.30f32);
                assert_eq!(channels.len(), 2);
                assert_eq!(*window_s, 8.0);
            }
            other => panic!("expected TraceStrip, got {other:?}"),
        }
    }

    #[test]
    fn roundtrip — serialize_then_deserialize — identical() {
        // Arrange
        let l: OverlayLayout = serde_json::from_str(LAYOUT_JSON).unwrap();

        // Act
        let back: OverlayLayout =
            serde_json::from_str(&serde_json::to_string(&l).unwrap()).unwrap();

        // Assert
        assert_eq!(l, back);
    }

    #[test]
    fn canvas_size — well_formed_and_malformed — parses_or_defaults() {
        // Arrange
        let mut l: OverlayLayout = serde_json::from_str(LAYOUT_JSON).unwrap();

        // Act + Assert
        assert_eq!(l.canvas_size(), (1920, 1080));
        l.canvas = "garbage".into();
        assert_eq!(l.canvas_size(), (1920, 1080));
    }

    #[test]
    fn referenced_channels — duplicates_across_elements — unique_document_order() {
        // Arrange
        let l: OverlayLayout = serde_json::from_str(LAYOUT_JSON).unwrap();

        // Act
        let chans = l.referenced_channels();

        // Assert
        assert_eq!(chans, vec!["GPS_SpeedKmh", "Roll_deg", "TravelFront_mm", "TravelRear_mm"]);
    }
}
```

Note: Rust test names cannot contain `—`; use the repo's actual convention — look at one existing core test file and match it (they use `snake_case` with double underscores, e.g. `deserialize__full_layout_json__parses_all_five_element_kinds`). Apply that to every test in this plan.

- [ ] **Step 2: Run to verify failure**

Run: `cd c:\Users\isaac\Documents\Saucy\saucyeng\idl-rs && cargo test -p idl-rs overlay::`
Expected: compile error — `overlay` module does not exist.

- [ ] **Step 3: Implement**

`core/src/overlay/mod.rs`:

```rust
//! Canvas-agnostic overlay system: positioned, channel-bound elements sampled
//! at a time. The video compositor (`video::render`) is the first consumer;
//! chart-canvas overlays are future work. See docs/IDL0_SPEC.md §33.

pub mod model;
pub mod sample;
```

(`sample` lands in Task 4 — until then leave the line commented with `// TODO(idl0): sample lands with SampleContext` and uncomment there, or create an empty `sample.rs` now; prefer the empty file.)

`core/src/overlay/model.rs`:

```rust
//! Overlay layout model. Stored in the workbook (`.idl0wb` v2,
//! `overlay_layouts`); rects are normalized [x, y, w, h] canvas fractions;
//! `canvas` ("1920x1080") is design-space for stroke/font scaling only.
//! See docs/IDL0_SPEC.md §33.1.

use serde::{Deserialize, Serialize};

/// Normalized placement rectangle: fractions of the canvas in [0, 1].
/// Serialized as the JSON array `[x, y, w, h]`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(from = "[f32; 4]", into = "[f32; 4]")]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl From<[f32; 4]> for Rect {
    fn from(a: [f32; 4]) -> Self {
        Rect { x: a[0], y: a[1], w: a[2], h: a[3] }
    }
}
impl From<Rect> for [f32; 4] {
    fn from(r: Rect) -> Self {
        [r.x, r.y, r.w, r.h]
    }
}

/// Gauge visual style.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GaugeStyle {
    Numeric,
    Bar,
    Dial,
}

/// Attitude indicator style for signed, zero-centered channels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AttitudeStyle {
    /// Tilting horizon/bike glyph + degree readout (roll angle).
    Roll,
    /// Zero-centered needle/arc + degree readout (steering angle).
    Steer,
}

/// One positioned overlay element. `channel` names resolve like chart
/// channels (raw, synthesized, or math); a missing channel degrades the
/// element to its no-data state.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum OverlayElement {
    Gauge { rect: Rect, channel: String, style: GaugeStyle, label: String, min: f64, max: f64 },
    Attitude { rect: Rect, channel: String, style: AttitudeStyle, range_deg: f64 },
    TraceStrip { rect: Rect, channels: Vec<String>, window_s: f64 },
    TrackMap { rect: Rect },
    LapPanel { rect: Rect },
}

/// A named overlay layout: workbook asset, canvas-agnostic.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OverlayLayout {
    /// Stable UUIDv4.
    pub id: String,
    /// Display name; the CLI `--layout` selector.
    pub name: String,
    /// Design-space size as "WxH" pixels, e.g. "1920x1080".
    pub canvas: String,
    pub elements: Vec<OverlayElement>,
}

impl OverlayLayout {
    /// Parse `canvas`; malformed input falls back to (1920, 1080).
    pub fn canvas_size(&self) -> (u32, u32) {
        let mut it = self.canvas.split('x');
        match (
            it.next().and_then(|s| s.trim().parse::<u32>().ok()),
            it.next().and_then(|s| s.trim().parse::<u32>().ok()),
        ) {
            (Some(w), Some(h)) if w > 0 && h > 0 => (w, h),
            _ => (1920, 1080),
        }
    }

    /// Every channel any element references — unique, document order.
    pub fn referenced_channels(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        let mut push = |name: &str| {
            if !out.iter().any(|c| c == name) {
                out.push(name.to_string());
            }
        };
        for e in &self.elements {
            match e {
                OverlayElement::Gauge { channel, .. } | OverlayElement::Attitude { channel, .. } => push(channel),
                OverlayElement::TraceStrip { channels, .. } => channels.iter().for_each(|c| push(c)),
                OverlayElement::TrackMap { .. } | OverlayElement::LapPanel { .. } => {}
            }
        }
        out
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cargo test -p idl-rs overlay::`
Expected: 4 passed.

- [ ] **Step 5: Commit (idl-rs repo)**

```bash
cd c:\Users\isaac\Documents\Saucy\saucyeng\idl-rs
cargo fmt && git add core/src/overlay core/src/lib.rs
git commit -m "overlay::model: canvas-agnostic layout types (SPEC 33.1)"
```

---

### Task 3: Workbook v2 — `overlay_layouts`

**Files:**
- Modify: `core/src/workbook/model.rs` (Workbook struct + `SUPPORTED_WORKBOOK_VERSION`)

**Interfaces:**
- Consumes: `overlay::model::OverlayLayout` (Task 2).
- Produces:
  - `Workbook.overlay_layouts: Vec<OverlayLayout>` (`#[serde(default)]`)
  - `Workbook::overlay_layout(&self, name: Option<&str>) -> Result<&OverlayLayout, String>` — `None` OK only with exactly one layout; `Err` message lists available names (used verbatim by the CLI).
  - `SUPPORTED_WORKBOOK_VERSION == 2`.

- [ ] **Step 1: Write the failing tests** (append to the existing `#[cfg(test)]` module in `core/src/workbook/model.rs` — read it first and follow its fixture style)

```rust
#[test]
fn workbook__v2_with_overlay_layouts__parses_layout_list() {
    // Arrange
    let json = r#"{
      "workbook_id": "w1", "name": "wb", "workbook_version": 2,
      "overlay_layouts": [
        { "id": "L1", "name": "A", "canvas": "1920x1080",
          "elements": [ { "type": "track_map", "rect": [0.8, 0.0, 0.2, 0.3] } ] }
      ]
    }"#;

    // Act
    let wb = crate::workbook::read::parse_workbook(json.as_bytes()).unwrap();

    // Assert
    assert_eq!(wb.overlay_layouts.len(), 1);
    assert_eq!(wb.overlay_layouts[0].name, "A");
}

#[test]
fn workbook__v1_without_field__empty_layouts_and_still_supported() {
    // Arrange
    let json = r#"{ "workbook_id": "w1", "name": "wb", "workbook_version": 1 }"#;

    // Act
    let wb = crate::workbook::read::parse_workbook(json.as_bytes()).unwrap();

    // Assert
    assert!(wb.overlay_layouts.is_empty());
}

#[test]
fn overlay_layout__none_with_two_layouts__err_lists_names() {
    // Arrange
    let json = r#"{ "workbook_id": "w1", "name": "wb", "workbook_version": 2,
      "overlay_layouts": [
        { "id": "L1", "name": "A", "canvas": "1920x1080", "elements": [] },
        { "id": "L2", "name": "B", "canvas": "1920x1080", "elements": [] } ] }"#;
    let wb = crate::workbook::read::parse_workbook(json.as_bytes()).unwrap();

    // Act
    let err = wb.overlay_layout(None).unwrap_err();
    let ok = wb.overlay_layout(Some("B")).unwrap();

    // Assert
    assert!(err.contains("A") && err.contains("B"));
    assert_eq!(ok.name, "B");
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p idl-rs workbook::`
Expected: compile error — no field `overlay_layouts`.

- [ ] **Step 3: Implement**

In `core/src/workbook/model.rs`:
- `pub const SUPPORTED_WORKBOOK_VERSION: u32 = 2;`
- Add to `Workbook`:

```rust
    /// Overlay layouts (SPEC §33.1); empty when absent (v1 files).
    #[serde(default)]
    pub overlay_layouts: Vec<crate::overlay::model::OverlayLayout>,
```

- Add to `impl Workbook`:

```rust
    /// Select an overlay layout by `name`, or the sole layout when `name` is
    /// `None`. `Err` carries a user-facing message listing available names.
    pub fn overlay_layout(&self, name: Option<&str>) -> Result<&crate::overlay::model::OverlayLayout, String> {
        let names = || self.overlay_layouts.iter().map(|l| l.name.as_str()).collect::<Vec<_>>().join(", ");
        match name {
            Some(n) => self
                .overlay_layouts
                .iter()
                .find(|l| l.name == n)
                .ok_or_else(|| format!("no overlay layout named '{n}'; available: {}", names())),
            None => match self.overlay_layouts.len() {
                0 => Err("workbook has no overlay layouts".to_string()),
                1 => Ok(&self.overlay_layouts[0]),
                _ => Err(format!("workbook has multiple overlay layouts, pass --layout; available: {}", names())),
            },
        }
    }
```

- [ ] **Step 4: Run the full core suite** (version bump may touch `VersionedConfig` tests — if a test pins `SUPPORTED_WORKBOOK_VERSION == 1` or feeds a v2 file expecting `UnsupportedVersion`, update that fixture to v3-expecting-rejection)

Run: `cargo test -p idl-rs`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
cargo fmt && git add core/src/workbook/model.rs
git commit -m "workbook v2: overlay_layouts field + layout selection (SPEC 33.1)"
```

---

### Task 4: `overlay::sample` — SampleContext + FrameSample

**Files:**
- Create: `core/src/overlay/sample.rs`
- Modify: `core/src/overlay/mod.rs` (ensure `pub mod sample;`)

**Interfaces:**
- Consumes: `OverlayLayout`/`OverlayElement` (Task 2); `SessionHandle::{channel_samples, channel_sample_times, channels, channel_min_max}`; `gps::build_gps_track`; `laps::model::Lap`.
- Produces:

```rust
pub struct SampleContext { /* private prepared state */ }
impl SampleContext {
    /// Materialize every channel `layout` references (samples + per-sample
    /// times for event-driven), the session GPS polyline (normalized to its
    /// bbox), and the lap list. Call once; `sample()` per frame is cheap.
    pub fn prepare(handle: &SessionHandle, layout: &OverlayLayout, laps: Vec<Lap>) -> SampleContext;
    /// Sample every element at session-time `t_secs` (recording-time seconds).
    pub fn sample(&self, t_secs: f64) -> FrameSample;
    /// Normalized session GPS polyline for the track map (empty = no GPS).
    pub fn track_polyline(&self) -> &[(f32, f32)];
}

/// Per-element samples, parallel to `layout.elements` (same indices).
pub struct FrameSample { pub elements: Vec<ElementSample>, pub t_secs: f64 }

pub enum ElementSample {
    /// Gauge/Attitude: `None` = no data at `t`.
    Value(Option<f64>),
    /// TraceStrip: per channel, points normalized to the element
    /// ((0,0)=left/bottom, x = position in window, y = session-min/max range);
    /// empty vec = no data.
    Trace(Vec<Vec<(f32, f32)>>),
    /// TrackMap: current position normalized to the track bbox (y up).
    MapPos(Option<(f32, f32)>),
    /// LapPanel state at `t`.
    Laps(LapState),
}

#[derive(Default)]
pub struct LapState {
    pub current_lap: Option<u32>,
    /// Seconds into the current lap.
    pub lap_elapsed_s: f64,
    pub last_lap_ms: Option<i64>,
    pub best_lap_ms: Option<i64>,
}
```

- [ ] **Step 1: Write the failing tests** (inline module; build sessions with `SessionHandle::from_channels` — see the fixture in `core/src/workbook/apply.rs` tests for the exact `SessionMetaInput` shape)

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::laps::model::Lap;
    use crate::overlay::model::*;
    use crate::session::handle::{ChannelInput, SessionHandle, SessionMetaInput};

    fn meta() -> SessionMetaInput {
        SessionMetaInput { session_id: String::new(), device_id: String::new(), timestamp_utc_ms: 0, config_checksum: String::new() }
    }

    /// 10 Hz ramp 0..100 over 10 s.
    fn ramp_handle() -> SessionHandle {
        let samples: Vec<f64> = (0..=100).map(|i| i as f64).collect();
        SessionHandle::from_channels(meta(), vec![ChannelInput { channel_id: "Speed".into(), sample_rate_hz: 10.0, samples, sample_times_secs: None }])
    }

    fn gauge_layout(channel: &str) -> OverlayLayout {
        OverlayLayout { id: "L".into(), name: "L".into(), canvas: "1920x1080".into(),
            elements: vec![OverlayElement::Gauge { rect: [0.0, 0.0, 0.1, 0.1].into(), channel: channel.into(), style: GaugeStyle::Numeric, label: String::new(), min: 0.0, max: 100.0 }] }
    }

    #[test]
    fn sample__rate_based_between_samples__linear_interpolation() {
        // Arrange
        let ctx = SampleContext::prepare(&ramp_handle(), &gauge_layout("Speed"), vec![]);

        // Act
        let s = ctx.sample(1.25); // 10 Hz ramp: index 12.5 → value 12.5

        // Assert
        match &s.elements[0] { ElementSample::Value(Some(v)) => assert!((v - 12.5).abs() < 1e-9), other => panic!("{other:?}") }
    }

    #[test]
    fn sample__t_outside_channel_span__no_data() {
        // Arrange
        let ctx = SampleContext::prepare(&ramp_handle(), &gauge_layout("Speed"), vec![]);

        // Act
        let s = ctx.sample(999.0);

        // Assert
        assert!(matches!(&s.elements[0], ElementSample::Value(None)));
    }

    #[test]
    fn sample__missing_channel__no_data_not_error() {
        // Arrange
        let ctx = SampleContext::prepare(&ramp_handle(), &gauge_layout("Nope"), vec![]);

        // Act
        let s = ctx.sample(1.0);

        // Assert
        assert!(matches!(&s.elements[0], ElementSample::Value(None)));
    }

    #[test]
    fn sample__event_driven_channel__carries_forward() {
        // Arrange: beats at t = 1, 2, 4 s with values 60, 62, 64
        let h = SessionHandle::from_channels(meta(), vec![ChannelInput {
            channel_id: "HR_BPM".into(), sample_rate_hz: 0.0,
            samples: vec![60.0, 62.0, 64.0], sample_times_secs: Some(vec![1.0, 2.0, 4.0]) }]);
        let ctx = SampleContext::prepare(&h, &gauge_layout("HR_BPM"), vec![]);

        // Act + Assert: t=3 is between beats → last beat (62); t=0.5 predates → None
        match &ctx.sample(3.0).elements[0] { ElementSample::Value(Some(v)) => assert_eq!(*v, 62.0), o => panic!("{o:?}") }
        assert!(matches!(&ctx.sample(0.5).elements[0], ElementSample::Value(None)));
    }

    #[test]
    fn sample__trace_strip__window_points_normalized() {
        // Arrange
        let layout = OverlayLayout { id: "L".into(), name: "L".into(), canvas: "1920x1080".into(),
            elements: vec![OverlayElement::TraceStrip { rect: [0.0, 0.0, 0.5, 0.2].into(), channels: vec!["Speed".into()], window_s: 2.0 }] };
        let ctx = SampleContext::prepare(&ramp_handle(), &layout, vec![]);

        // Act
        let s = ctx.sample(5.0); // window [3, 5] of the 0..100 ramp (values 30..50)

        // Assert
        match &s.elements[0] {
            ElementSample::Trace(series) => {
                let pts = &series[0];
                assert!(!pts.is_empty());
                let (x0, y0) = pts[0];
                let (xn, yn) = *pts.last().unwrap();
                assert!(x0 >= 0.0 && x0 < 0.05, "window start at left edge");
                assert!((xn - 1.0).abs() < 0.05, "now at right edge");
                assert!((y0 - 0.30).abs() < 0.02 && (yn - 0.50).abs() < 0.02, "y normalized to session 0..100");
            }
            o => panic!("{o:?}"),
        }
    }

    #[test]
    fn sample__lap_state_mid_second_lap__current_last_best() {
        // Arrange: two finished laps (40 s @ 35 s lap-time, 45 s) then t inside lap 3
        let lap = |n: u32, s: f64, e: f64, ms: i64| Lap { lap_number: n, start_ms: (s * 1000.0) as i64, end_ms: (e * 1000.0) as i64,
            start_time_secs: s, end_time_secs: e, raw_elapsed_ms: ms, lap_time_ms: ms, sectors: vec![], neutral_zone_visits: vec![] };
        let laps = vec![lap(1, 0.0, 40.0, 35_000), lap(2, 40.0, 85.0, 45_000), lap(3, 85.0, 130.0, 45_000)];
        let layout = OverlayLayout { id: "L".into(), name: "L".into(), canvas: "1920x1080".into(),
            elements: vec![OverlayElement::LapPanel { rect: [0.0, 0.0, 0.2, 0.2].into() }] };
        let ctx = SampleContext::prepare(&ramp_handle(), &layout, laps);

        // Act
        let s = ctx.sample(95.0);

        // Assert
        match &s.elements[0] {
            ElementSample::Laps(ls) => {
                assert_eq!(ls.current_lap, Some(3));
                assert!((ls.lap_elapsed_s - 10.0).abs() < 1e-9);
                assert_eq!(ls.last_lap_ms, Some(45_000));
                assert_eq!(ls.best_lap_ms, Some(35_000));
            }
            o => panic!("{o:?}"),
        }
    }
}
```

- [ ] **Step 2: Run to verify failure** — `cargo test -p idl-rs overlay::sample` → compile error.

- [ ] **Step 3: Implement `core/src/overlay/sample.rs`**

Key structure (complete the bodies exactly as described):

```rust
//! Frame sampling for overlay rendering: prepare once, sample per frame.
//! All `t` are session recording-time seconds. See docs/IDL0_SPEC.md §33.2.

use std::collections::HashMap;

use crate::gps::build_gps_track;
use crate::laps::model::Lap;
use crate::overlay::model::{OverlayElement, OverlayLayout};
use crate::session::handle::SessionHandle;

/// One prepared channel: samples plus its time base.
struct PreparedChannel {
    samples: Vec<f64>,
    /// `None` → rate-based (`rate_hz` applies); `Some` → event-driven times (s).
    times_s: Option<Vec<f64>>,
    rate_hz: f64,
    /// Session-wide (min, max) for stable trace axes; None when empty/flat.
    min_max: Option<(f64, f64)>,
}

impl PreparedChannel {
    /// Linear interpolation (rate-based) or carry-forward (event-driven).
    /// None outside the channel's span.
    fn value_at(&self, t: f64) -> Option<f64> { /* rate-based: idx = t*rate;
        i0 = floor, i1 = i0+1 clamp; None if t < 0 or idx > len-1.
        event-driven: binary search times_s for last time <= t (partition_point);
        None if before first. */ }
}

pub struct SampleContext {
    elements: Vec<OverlayElement>,
    channels: HashMap<String, PreparedChannel>,
    /// Normalized (x, y-up) polyline of the whole session, bbox-fitted.
    polyline: Vec<(f32, f32)>,
    /// GPS fix (t_secs, normalized x, normalized y) for position lookup.
    gps_norm: Vec<(f64, f32, f32)>,
    laps: Vec<Lap>,
}
```

`prepare`: for each `layout.referenced_channels()` present in `handle.channels()`, store `PreparedChannel { samples: handle.channel_samples(id), times_s: handle.channel_sample_times(id), rate_hz: meta.sample_rate_hz, min_max: handle.channel_min_max(id) }`. GPS: `build_gps_track(handle)` (raw ×1e7 scale — fine for bbox normalization); map each fix through `handle.epoch_ms_to_time_secs` (one batch call) to get `t_secs`; compute bbox over all fixes; normalize `x = (lon-lon_min)/(lon_max-lon_min)`, `y = (lat-lat_min)/(lat_max-lat_min)` (y up); guard zero-extent bbox (single point → polyline of one point at (0.5, 0.5)). Downsample the polyline to ≤ 1024 points by stride.

`sample(t)`: walk `elements`; `Gauge`/`Attitude` → `Value(ch.and_then(|c| c.value_at(t)))`; `TraceStrip` → for each channel, take window `[t - window_s, t]`, collect ≤ 256 points by stride from the sample range (rate-based: index range; event-driven: time-filtered), normalize `x = (ts - (t - window_s)) / window_s`, `y = (v - min) / (max - min)` from `min_max` (flat channel → y = 0.5); `TrackMap` → `MapPos`: binary-search `gps_norm` for last fix at-or-before `t` (None before first/after last + 5 s); `LapPanel` → scan `laps` for `start_time_secs <= t < end_time_secs` → `current_lap`/`lap_elapsed_s`; `last_lap_ms` = lap with greatest `end_time_secs <= t`; `best_lap_ms` = min `lap_time_ms` among laps with `end_time_secs <= t`.

- [ ] **Step 4: Run tests** — `cargo test -p idl-rs overlay::` → all pass (Task 2's plus these 6).

- [ ] **Step 5: Commit**

```bash
cargo fmt && git add core/src/overlay
git commit -m "overlay::sample: SampleContext/FrameSample per-frame sampling (SPEC 33.2)"
```

---

### Task 5: `video::mp4box` — ISO-BMFF walker

**Files:**
- Create: `core/src/video/mod.rs` (`pub mod mp4box; pub mod gpmf; pub mod sync; pub mod render;` — create empty `gpmf.rs`/`sync.rs`/`render.rs` stubs), `core/src/video/mp4box.rs`
- Modify: `core/src/lib.rs` (add `pub mod video;`)

**Interfaces:**
- Produces:

```rust
/// Container facts read without ffmpeg. Durations in seconds; creation time
/// in UTC ms (None when the mvhd epoch field is zero).
pub struct Mp4Info {
    pub width: u32, pub height: u32,
    pub fps: f64, pub duration_s: f64,
    pub creation_time_utc_ms: Option<i64>,
    pub has_gpmd: bool,
}
/// One gpmd sample: video-relative time (s) + raw GPMF payload bytes.
pub struct GpmdSample { pub t_video_s: f64, pub payload: Vec<u8> }

pub fn read_info(bytes: &[u8]) -> Result<Mp4Info, VideoError>;
pub fn read_gpmd_samples(bytes: &[u8]) -> Result<Vec<GpmdSample>, VideoError>;
/// std::fs conveniences over the byte-slice functions.
pub fn read_info_path(path: &str) -> Result<Mp4Info, VideoError>;
pub fn read_gpmd_samples_path(path: &str) -> Result<Vec<GpmdSample>, VideoError>;

/// Error family for the video subsystem (kind + message, ConfigError-style).
pub struct VideoError { pub kind: VideoErrorKind, pub message: String }
pub enum VideoErrorKind { Io, Parse, NoGpmf, NoOverlap, Export }
```

Put `VideoError`/`VideoErrorKind` in `core/src/video/mod.rs` (shared by gpmf/sync and re-used by CLI mapping). Mirror `ConfigError`'s constructor/Display style exactly.

**Scope:** only what phase 1 needs — `mvhd` (creation_time, timescale, duration), per-`trak`: `hdlr` handler type, `mdhd` timescale, `tkhd` width/height (video track), and the `stbl` sample tables (`stsd` for fps denominator? no — fps = video track `stts` total sample count / track duration), `stts` (decode times), `stsz` (sizes), `stco`/`co64` (chunk offsets), `stsc` (sample-to-chunk). `read_gpmd_samples` expands `stsc` to per-sample file offsets, reads payloads, computes `t_video_s` from cumulative `stts` deltas / `mdhd` timescale. 64-bit `co64` and version-1 `mvhd`/`mdhd` handled; anything else missing → `VideoError { kind: Parse }`. MP4 epoch note: `creation_time` is seconds since 1904-01-01 UTC; convert with offset `2_082_844_800` s; a zero field → `None`.

- [ ] **Step 1: Write the test fixture builder + failing tests**

Tests build a minimal in-memory MP4 (no real footage exists yet — explicit design-doc gap). Write a `tests` helper that assembles boxes from parts:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn boxb(kind: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut v = Vec::with_capacity(8 + payload.len());
        v.extend_from_slice(&((payload.len() as u32 + 8).to_be_bytes()));
        v.extend_from_slice(kind);
        v.extend_from_slice(payload);
        v
    }
    fn full(version: u8, payload: &[u8]) -> Vec<u8> {
        let mut v = vec![version, 0, 0, 0];
        v.extend_from_slice(payload);
        v
    }

    /// Build a synthetic MP4: one video trak (1920x1080, 100 samples over
    /// 10 s → 10 fps) + one gpmd trak with `payloads` at 1 Hz, and an mdat
    /// carrying the gpmd payloads. Returns bytes with correct stco offsets.
    fn synthetic_mp4(creation_1904_s: u64, gpmd_payloads: &[&[u8]]) -> Vec<u8> {
        // Assemble in two passes: build moov with stco=0 placeholders sized
        // identically to the final values (u32), compute mdat data offsets
        // (ftyp.len + moov.len + 8), then rebuild with real offsets.
        // Video trak carries no mdat data (stsz all zero, stco empty chunks
        // is invalid — give it 1 chunk at offset of mdat start, sizes 0).
        // gpmd trak: mdhd timescale 1000, stts = N samples × delta 1000,
        // stsc = 1 chunk-run (all samples one chunk), stsz = payload sizes,
        // stco = one chunk at the first payload's file offset.
        /* full body in implementation-committed test helper — assemble
           ftyp("isom") + moov(mvhd(timescale 1000, duration 10_000,
           creation_time) + trak_video + trak_gpmd) + mdat(payload concat).
           hdlr for video: handler_type "vide"; for gpmd: "meta" with the
           component subtype box name "gpmd" in stsd entry format 'gpmd'. */
        unimplemented!("write during Step 1 alongside the assertions below")
    }

    #[test]
    fn read_info__synthetic_two_track_mp4__dims_fps_duration_creation() {
        // Arrange
        let bytes = synthetic_mp4(2_082_844_800 + 1_000, &[b"x"]); // epoch 1970+1000s

        // Act
        let info = read_info(&bytes).unwrap();

        // Assert
        assert_eq!((info.width, info.height), (1920, 1080));
        assert!((info.fps - 10.0).abs() < 0.01);
        assert!((info.duration_s - 10.0).abs() < 1e-6);
        assert_eq!(info.creation_time_utc_ms, Some(1_000_000));
        assert!(info.has_gpmd);
    }

    #[test]
    fn read_gpmd_samples__three_payloads__times_and_bytes_roundtrip() {
        // Arrange
        let bytes = synthetic_mp4(0, &[b"aaaa", b"bb", b"cccccc"]);

        // Act
        let samples = read_gpmd_samples(&bytes).unwrap();

        // Assert
        assert_eq!(samples.len(), 3);
        assert_eq!(samples[0].payload, b"aaaa");
        assert_eq!(samples[2].payload, b"cccccc");
        assert!((samples[1].t_video_s - 1.0).abs() < 1e-6, "1 Hz gpmd track");
    }

    #[test]
    fn read_gpmd_samples__no_gpmd_track__no_gpmf_error() {
        // Arrange
        let bytes = synthetic_mp4(0, &[]); // builder omits gpmd trak when empty

        // Act
        let err = read_gpmd_samples(&bytes).unwrap_err();

        // Assert
        assert!(matches!(err.kind, VideoErrorKind::NoGpmf));
    }

    #[test]
    fn read_info__truncated_garbage__parse_error_not_panic() {
        // Arrange + Act
        let err = read_info(&[0u8; 16]).unwrap_err();

        // Assert
        assert!(matches!(err.kind, VideoErrorKind::Parse));
    }
}
```

The `synthetic_mp4` builder must be completed as real code in this step (it is test infrastructure, not production). Budget the bulk of this task's effort here; it is also reused by Task 6 and Task 11.

- [ ] **Step 2: Run to verify failure** — `cargo test -p idl-rs video::mp4box` → compile error.

- [ ] **Step 3: Implement the walker**

Parsing skeleton — a cursor over `&[u8]` reading `(size: u32 BE, kind: [u8;4])` headers, `size == 1` → 64-bit largesize, recursing into container boxes (`moov`, `trak`, `mdia`, `minf`, `stbl`). Collect per-trak: handler (from `hdlr` bytes 8..12 of payload after version/flags), `mdhd` timescale (v0: u32 at offset 12; v1: u32 at offset 20), sample tables. gpmd track identification: `hdlr` handler_type == `meta` AND `stsd` first entry format == `gpmd` (fallback: accept handler_type == `gpmd` — some muxers write it there). Expand `stsc` runs against `stco`/`co64` chunk offsets and `stsz` sizes into absolute per-sample `(offset, size)`; cumulative `stts` deltas ÷ timescale → `t_video_s`. fps = video-trak `stts` sample count ÷ (video-trak `mdhd` duration ÷ timescale). Every read is bounds-checked (`get(..)` + `ok_or_else(parse_err)`) — no slicing panics.

- [ ] **Step 4: Run tests** — `cargo test -p idl-rs video::` → 4 pass.

- [ ] **Step 5: Commit**

```bash
cargo fmt && git add core/src/video core/src/lib.rs
git commit -m "video::mp4box: ISO-BMFF walker for gpmd samples + container info (SPEC 33.3)"
```

---

### Task 6: `video::gpmf` — KLV → VideoTelemetry

**Files:**
- Modify: `core/src/video/gpmf.rs` (replace stub)

**Interfaces:**
- Consumes: `GpmdSample` (Task 5).
- Produces:

```rust
/// One camera GPS fix on the video clock.
pub struct TelemetryFix { pub t_video_s: f64, pub lat_deg: f64, pub lon_deg: f64, pub speed_mps: f64 }
/// Camera telemetry extracted from GPMF.
pub struct VideoTelemetry {
    /// (video time s, UTC epoch ms) pair from the first GPSU stamp.
    pub utc_anchor: Option<(f64, i64)>,
    pub fixes: Vec<TelemetryFix>,
}
pub fn parse_gpmf(samples: &[GpmdSample]) -> Result<VideoTelemetry, VideoError>;
```

**GPMF format facts the implementer needs** (from GoPro's published spec):
- KLV: 4-byte FourCC key, 1-byte type char, 1-byte struct size, 2-byte BE repeat count; payload = size×repeat bytes, padded to 4-byte alignment. Type `0x00` (null) = nested container: recurse into payload.
- Under `DEVC` → `STRM` streams. A GPS stream contains `GPS5` (type `'l'` i32, struct 20 B: lat, lon, alt, speed2d, speed3d — scaled) or `GPS9` (newer, struct includes lat, lon, alt, speed2d, speed3d, days, secs, dop, fix — per-sample time), plus `SCAL` (type `'l'`, one divisor per GPS5 column) and `GPSU` (type `'U'` UTC string `yymmddhhmmss.sss`).
- Values: `lat_deg = raw / scal[0]`, `lon_deg = raw / scal[1]`, `speed_mps = speed2d / scal[3]`.
- GPS5 has no per-sample time: distribute a payload's N fixes evenly across `[sample.t_video_s, next_sample.t_video_s)`.
- `GPSU` parse: `"240607143025.123"` → UTC epoch ms (assume 20xx); anchor at the *containing payload's* `t_video_s`.

- [ ] **Step 1: Write the failing tests** — a `klv(fourcc, type_char, size, repeat, payload)` builder plus:

```rust
#[test]
fn parse_gpmf__gps5_with_scal_and_gpsu__scaled_fixes_and_anchor() {
    // Arrange: one gpmd payload at t=2.0 s: DEVC{ STRM{ GPSU("240607143025.000"),
    // SCAL([10_000_000, 10_000_000, 1000, 1000, 100]),
    // GPS5(2 fixes: (471234567, 82345678, 0, 5000, 0), (471234667, 82345778, 0, 6000, 0)) } }
    let payload = devc(&strm(&[gpsu_box("240607143025.000"), scal_box(&[10_000_000, 10_000_000, 1000, 1000, 100]), gps5_box(&[[471_234_567, 82_345_678, 0, 5_000, 0], [471_234_667, 82_345_778, 0, 6_000, 0]])]));
    let samples = vec![GpmdSample { t_video_s: 2.0, payload }, GpmdSample { t_video_s: 3.0, payload: vec![] }];

    // Act
    let t = parse_gpmf(&samples).unwrap();

    // Assert
    assert_eq!(t.fixes.len(), 2);
    assert!((t.fixes[0].lat_deg - 47.1234567).abs() < 1e-9);
    assert!((t.fixes[0].speed_mps - 5.0).abs() < 1e-9);
    assert!((t.fixes[0].t_video_s - 2.0).abs() < 1e-9);
    assert!((t.fixes[1].t_video_s - 2.5).abs() < 1e-9, "2 fixes spread over [2,3)");
    let (t0, epoch_ms) = t.utc_anchor.unwrap();
    assert_eq!(t0, 2.0);
    assert_eq!(epoch_ms, 1_717_770_625_000); // 2024-06-07T14:30:25Z
}

#[test]
fn parse_gpmf__no_gps_stream__empty_fixes_no_anchor() { /* DEVC with an
    accelerometer-only STRM → Ok(VideoTelemetry { utc_anchor: None, fixes: [] }) */ }

#[test]
fn parse_gpmf__truncated_klv__parse_error_not_panic() { /* feed half a KLV header */ }
```

- [ ] **Step 2: Run to verify failure** — `cargo test -p idl-rs video::gpmf` → compile error.

- [ ] **Step 3: Implement** — recursive KLV walker (bounds-checked cursor, 4-byte alignment after each value block); per STRM collect `GPS5`/`GPS9` raws + `SCAL` + `GPSU`; convert per the format facts above; distribute GPS5 times; first `GPSU` wins as anchor. GPS9 per-sample time: `days` since 2000-01-01 + `secs` of day → epoch ms (also usable as anchor when GPSU absent).

- [ ] **Step 4: Run tests** — `cargo test -p idl-rs video::` → pass.

- [ ] **Step 5: Commit**

```bash
cargo fmt && git add core/src/video/gpmf.rs
git commit -m "video::gpmf: GPMF KLV parser -> VideoTelemetry (SPEC 33.3)"
```

---

### Task 7: `video::sync` — offset estimation

**Files:**
- Modify: `core/src/video/sync.rs` (replace stub)

**Interfaces:**
- Consumes: `VideoTelemetry` (Task 6), `Mp4Info` (Task 5), `SessionHandle::{epoch_ms_to_time_secs, metadata}`.
- Produces:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SyncMethod { Gpmf, CreationTime }

#[derive(Debug, Clone, Serialize)]
pub struct SyncEstimate {
    /// session_time_s = video_time_s + offset_s.
    pub offset_s: f64,
    /// 0.9 for gpmf, 0.3 for creation_time.
    pub confidence: f64,
    pub method: SyncMethod,
}

/// GPMF UTC anchor when available, else container creation_time.
/// Err(NoOverlap) when the mapped video span misses the session span
/// entirely — message carries both ranges in seconds.
pub fn estimate_sync(telemetry: Option<&VideoTelemetry>, info: &Mp4Info, handle: &SessionHandle) -> Result<SyncEstimate, VideoError>;
```

- [ ] **Step 1: Write the failing tests** — synthetic handle whose `GPS_EpochMs` channel anchors the session clock (use `SessionHandle::from_channels` with a `GPS_EpochMs` channel at 1 Hz plus any data channel; check `epoch_ms_to_time_secs` maps your chosen epochs before finalizing expectations — read `core/src/session/handle.rs:293` first):

```rust
#[test]
fn estimate_sync__gpmf_utc_anchor__offset_from_epoch_mapping() {
    // Arrange: session epoch t=0 s ↔ 1_717_770_600_000 ms; camera anchor
    // says video t=2.0 s ↔ 1_717_770_625_000 ms (25 s into session) → offset 23.0
    let h = handle_with_epoch_channel(1_717_770_600_000, 120 /* seconds long */);
    let telem = VideoTelemetry { utc_anchor: Some((2.0, 1_717_770_625_000)), fixes: vec![] };
    let info = Mp4Info { width: 1920, height: 1080, fps: 30.0, duration_s: 60.0, creation_time_utc_ms: None, has_gpmd: true };

    // Act
    let est = estimate_sync(Some(&telem), &info, &h).unwrap();

    // Assert
    assert!((est.offset_s - 23.0).abs() < 1e-6);
    assert_eq!(est.method, SyncMethod::Gpmf);
    assert!((est.confidence - 0.9).abs() < 1e-9);
}

#[test]
fn estimate_sync__no_gpmf_creation_time__low_confidence() { /* telemetry None,
    creation_time_utc_ms = session start + 30 s → offset 30.0, method CreationTime, confidence 0.3 */ }

#[test]
fn estimate_sync__video_ends_before_session_starts__no_overlap_error_lists_ranges() {
    /* creation_time far before session; assert kind NoOverlap and message
       contains both formatted ranges */ }

#[test]
fn estimate_sync__no_anchor_no_creation_time__parse_error() { /* both None → Err */ }
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement** — anchor epoch → `handle.epoch_ms_to_time_secs(&[epoch as f64])[0]` = session seconds; `offset_s = session_s - t_video_s`. Overlap check: video span `[offset, offset + duration_s]` vs session `[0, metadata().duration_ms / 1000]`; disjoint → `NoOverlap`. Prefer GPMF (anchor present) over creation_time; GPS9-derived anchors count as GPMF.

- [ ] **Step 4: Run tests** — pass. **Step 5: Commit**

```bash
cargo fmt && git add core/src/video/sync.rs
git commit -m "video::sync: GPMF/creation-time offset estimation (SPEC 33.3)"
```

---

### Task 8: Fonts + `video::render` text primitives

**Files:**
- Create: `core/assets/fonts/IBMPlexMono-Regular.ttf`, `core/assets/fonts/IBMPlexMono-SemiBold.ttf`, `core/assets/fonts/OFL.txt`
- Modify: `core/Cargo.toml` (add `tiny-skia = { version = "0.11", features = ["png"] }`, `fontdue = "0.9"`), `core/src/video/render.rs` (start: `text` submodule inside)

**Interfaces:**
- Produces (module-private to `video::render`, used by Task 9):

```rust
/// Embedded IBM Plex Mono faces (OFL — license vendored beside the files).
pub(crate) fn font_regular() -> &'static fontdue::Font;
pub(crate) fn font_semibold() -> &'static fontdue::Font;
/// Draw `text` left-aligned at (x, y=baseline) in `px` pixel size onto the
/// pixmap, straight-alpha blended, monospaced advance. Returns drawn width px.
pub(crate) fn draw_text(pm: &mut tiny_skia::Pixmap, font: &fontdue::Font, text: &str, x: f32, y: f32, px: f32, color: [u8; 4]) -> f32;
```

- [ ] **Step 1: Vendor the fonts**

```bash
cd c:\Users\isaac\Documents\Saucy\saucyeng\idl-rs
mkdir -p core/assets/fonts
curl -L -o core/assets/fonts/IBMPlexMono-Regular.ttf "https://github.com/google/fonts/raw/main/ofl/ibmplexmono/IBMPlexMono-Regular.ttf"
curl -L -o core/assets/fonts/IBMPlexMono-SemiBold.ttf "https://github.com/google/fonts/raw/main/ofl/ibmplexmono/IBMPlexMono-SemiBold.ttf"
curl -L -o core/assets/fonts/OFL.txt "https://raw.githubusercontent.com/google/fonts/main/ofl/ibmplexmono/OFL.txt"
```

Verify each TTF is 50–200 KB (`ls -la core/assets/fonts`) — an HTML error page instead of a font will be a few KB and `fontdue::Font::from_bytes` will reject it in the test.

- [ ] **Step 2: Write the failing test**

```rust
#[test]
fn draw_text__hello_on_black__pixels_covered_and_deterministic() {
    // Arrange
    let mut pm = tiny_skia::Pixmap::new(200, 60).unwrap();

    // Act
    let w = draw_text(&mut pm, font_regular(), "HELLO", 4.0, 40.0, 24.0, [255, 255, 255, 255]);
    let lit = pm.data().chunks(4).filter(|p| p[0] > 0).count();

    // Assert
    assert!(w > 50.0, "monospace advance accumulates");
    assert!(lit > 100, "glyph coverage rendered");
    let mut pm2 = tiny_skia::Pixmap::new(200, 60).unwrap();
    draw_text(&mut pm2, font_regular(), "HELLO", 4.0, 40.0, 24.0, [255, 255, 255, 255]);
    assert_eq!(pm.data(), pm2.data(), "deterministic");
}
```

- [ ] **Step 3: Run to verify failure**, then **Step 4: Implement** — `include_bytes!("../../assets/fonts/IBMPlexMono-Regular.ttf")` + `std::sync::OnceLock<fontdue::Font>`; `draw_text`: per char `font.rasterize(ch, px)` → alpha bitmap; blend into pixmap at `(x + advance + metrics.xmin, y - metrics.ymin - metrics.height)` with `out = src*a + dst*(1-a)` per channel (pixmap stays premultiplied — multiply color by alpha when writing); advance by `metrics.advance_width` (constant for Plex Mono).

- [ ] **Step 5: Run test — pass. Commit**

```bash
cargo fmt && git add core/assets core/Cargo.toml core/src/video/render.rs Cargo.lock
git commit -m "video::render: embedded IBM Plex Mono + text rasterization (SPEC 33.4)"
```

---

### Task 9: `video::render` — element renderers + goldens

**Files:**
- Modify: `core/src/video/render.rs`
- Create: `core/tests/golden/overlay_full.png`, `core/tests/golden/overlay_nodata.png` (generated in Step 4)

**Interfaces:**
- Consumes: `OverlayLayout` (Task 2), `FrameSample`/`ElementSample`/`LapState` + `SampleContext::track_polyline` (Task 4), text primitives (Task 8).
- Produces:

```rust
/// Rasterize one overlay frame at (w, h). `polyline` is the normalized track
/// from `SampleContext::track_polyline`. Returns STRAIGHT-alpha RGBA bytes,
/// w*h*4, row-major — ffmpeg `rawvideo rgba` order (tiny-skia's premultiplied
/// buffer is demultiplied on the way out).
pub fn render_overlay_frame(layout: &OverlayLayout, sample: &FrameSample, polyline: &[(f32, f32)], w: u32, h: u32) -> Vec<u8>;
```

**Visual spec (v1, deliberately plain — matches design doc):** global scale `s = h / canvas_h`. Every element: rounded-rect panel, fill `rgba(10,10,14,168)`, 1.5·s px border `rgba(255,255,255,64)`, corner radius 8·s. Padding 8·s. Colors: text white; accent `rgb(255,179,0)` (amber); trace series palette `[amber, rgb(64,196,255), rgb(120,255,120), rgb(255,120,180)]`; no-data glyph `—` centered, 50 % white.
- `Gauge/Numeric`: value SemiBold at 0.42·rect_h px (1 decimal ≥ 10, 2 below), label Regular 0.14·rect_h at bottom-left.
- `Gauge/Bar`: label top-left; horizontal track 0.18·rect_h tall, filled `((v-min)/(max-min)).clamp(0,1)` in accent; value text right-aligned above.
- `Gauge/Dial`: 240° arc (−210°..30°), 3·s px stroke; needle from center to `angle = -210° + 240°·frac`; value + label under center.
- `Attitude/Roll`: horizon line through panel center rotated by `-v` deg (clamped ±range_deg), 3·s px accent; small center triangle marker; readout `{v:+.0}°` bottom-center.
- `Attitude/Steer`: bottom-anchored needle rotated `v/range_deg · 90°` from vertical; zero tick; same readout.
- `TraceStrip`: per-series polyline of the normalized points mapped into the padded rect (y flipped), 2·s px; "now" = right edge; vertical hairline at right edge, 1·s px 50 % white.
- `TrackMap`: polyline mapped into padded rect preserving aspect (letterbox by centering the smaller dimension), 2·s px 70 % white; position dot radius 4·s accent at `MapPos` (no dot when None).
- `LapPanel`: three Regular text rows at 0.22·rect_h line height: `LAP {n}  {mm:ss.d}` (elapsed), `LAST {mm:ss.ss}`, `BEST {mm:ss.ss}` (accent); missing values → `—`.

- [ ] **Step 1: Write the failing tests**

```rust
#[cfg(test)]
mod render_tests {
    use super::*;
    // Reuse Task 4's fixtures: build the 5-element LAYOUT_JSON layout, a
    // ramp_handle-based SampleContext with the 3-lap list, sample at t=95.0.

    fn golden(name: &str, rgba: &[u8], w: u32, h: u32) {
        let path = format!("{}/tests/golden/{name}.png", env!("CARGO_MANIFEST_DIR"));
        if std::env::var("GOLDEN_WRITE").is_ok() {
            let mut pm = tiny_skia::Pixmap::new(w, h).unwrap();
            // straight → premultiplied copy for encode
            /* fill pm from rgba, premultiplying */ 
            pm.save_png(&path).unwrap();
            return;
        }
        let want = tiny_skia::Pixmap::load_png(&path).expect("golden missing — rerun with GOLDEN_WRITE=1");
        /* decode want to straight rgba and byte-compare to `rgba` */
    }

    #[test]
    fn render_overlay_frame__full_sample_640x360__matches_golden() {
        // Arrange (layout + prepared context + sample at t=95.0, laps present)
        // Act
        let rgba = render_overlay_frame(&layout, &sample, ctx.track_polyline(), 640, 360);
        // Assert
        assert_eq!(rgba.len(), 640 * 360 * 4);
        golden("overlay_full", &rgba, 640, 360);
    }

    #[test]
    fn render_overlay_frame__all_channels_missing__nodata_golden_no_panic() {
        // Arrange: same layout, SampleContext over a session with none of the
        // referenced channels and no laps/GPS → every element no-data.
        // Act + Assert
        let rgba = render_overlay_frame(&layout, &sample, &[], 640, 360);
        golden("overlay_nodata", &rgba, 640, 360);
    }

    #[test]
    fn render_overlay_frame__output_is_straight_alpha() {
        // Arrange: a layout with one full-opacity white numeric gauge.
        // Act: render; find a pixel with 0 < a < 255 (panel edge antialiasing).
        // Assert: at least one such pixel has channel value > its alpha —
        // impossible under premultiplied encoding, guaranteed by demultiply.
    }
}
```

- [ ] **Step 2: Run to verify failure. Step 3: Implement** — build `tiny_skia::Pixmap::new(w, h)`; helper `to_px(rect, w, h) -> (f32, f32, f32, f32)`; each element via `PathBuilder` strokes/fills + Task 8 text; finally demultiply: `pixmap.data()` chunks → straight rgba out (`c = c_premul * 255 / a` when `a > 0`).

- [ ] **Step 4: Generate goldens, inspect, pin**

```bash
GOLDEN_WRITE=1 cargo test -p idl-rs render_overlay_frame
# open core/tests/golden/overlay_full.png and visually sanity-check:
# five panels, amber accents, lap rows read "LAP 3", traces slope upward.
cargo test -p idl-rs render_overlay_frame   # now compares — must pass
git add core/tests/golden
```

- [ ] **Step 5: Full suite + commit**

```bash
cargo test -p idl-rs
cargo fmt && git add core/src/video/render.rs core/tests/golden
git commit -m "video::render: element renderers + golden-image tests (SPEC 33.4)"
```

---

### Task 10: `video-export` crate — probe, argv, driver

**Files:**
- Create: `video-export/Cargo.toml`, `video-export/src/lib.rs`, `video-export/src/probe.rs`, `video-export/src/args.rs`, `video-export/src/export.rs`
- Modify: root `Cargo.toml` (`members = ["core", "bridge", "cli", "video-export"]` + `[profile.dev.package.idl-rs-video-export] opt-level = 3`)

**Interfaces:**
- Consumes: nothing from `idl-rs` — the driver is engine-agnostic by design (frames arrive via closure).
- Produces (crate `idl-rs-video-export`):

```rust
// probe.rs
pub struct VideoProbe { pub width: u32, pub height: u32, pub fps: f64,
    pub duration_s: f64, pub rotation_deg: i32, pub has_audio: bool }
/// Parse `ffprobe -print_format json -show_streams -show_format` output.
pub fn parse_ffprobe_json(json: &str) -> Result<VideoProbe, ExportError>;
/// Spawn ffprobe at `ffprobe_path` and parse.
pub fn probe(video: &Path, ffprobe_path: &str) -> Result<VideoProbe, ExportError>;

// args.rs
pub struct ExportPlan { pub video: PathBuf, pub output: PathBuf,
    pub probe: VideoProbe, pub start_s: Option<f64>, pub duration_s: Option<f64>,
    pub encoder: String /* default "libx264" */, pub ffmpeg_path: String }
impl ExportPlan {
    /// Output frame count after clipping (fps × effective duration, ceil).
    pub fn total_frames(&self) -> u64;
    /// Effective overlay width/height after rotation swap (90/270 swaps).
    pub fn frame_dims(&self) -> (u32, u32);
    /// The ffmpeg argv (no program name). Deterministic, unit-tested.
    pub fn ffmpeg_args(&self, part_path: &Path) -> Vec<String>;
}

// export.rs
pub struct Progress { pub frames_done: u64, pub frames_total: u64 }
pub struct ExportError { pub kind: ExportErrorKind, pub message: String }
pub enum ExportErrorKind { FfmpegMissing, Probe, Pipe, FfmpegFailed, Cancelled, Io }
/// Run the export: spawn ffmpeg, pump `render(i)` frames (RGBA, straight,
/// frame_dims-sized) into stdin in order, rename .part on success. `render`
/// runs on a rayon pool in ordered chunks of 32. Progress after each chunk.
/// `cancel` true → kill child, delete .part, Err(Cancelled).
pub fn run_export<F>(plan: &ExportPlan, render: F, progress: &mut dyn FnMut(Progress), cancel: &AtomicBool) -> Result<(), ExportError>
where F: Fn(u64) -> Vec<u8> + Sync;
```

**ffmpeg argv shape** (what `ffmpeg_args` must produce, in order):

```
-hide_banner -y
[-ss {start_s}] -i {video}                       # input 0: source (clip via -ss/-t)
[-t {duration_s}]
-f rawvideo -pix_fmt rgba -s {w}x{h} -r {fps} -i pipe:0   # input 1: overlay
-filter_complex [0:v][1:v]overlay=format=auto[out]
-map [out] [-map 0:a? -c:a copy]                 # audio only when probe.has_audio
-r {fps} -vsync cfr                              # CFR normalization (VFR sources)
-c:v {encoder} -pix_fmt yuv420p -movflags +faststart
{part_path}
```

- [ ] **Step 1: Crate scaffold + failing pure-function tests**

`video-export/Cargo.toml`:

```toml
[package]
name = "idl-rs-video-export"
version = "0.1.0"
edition = "2021"
description = "Sidecar-ffmpeg export driver for idl-rs video overlays (the only process-spawning component)."
license = "MIT"

[dependencies]
serde = { version = "1", features = ["derive"] }
serde_json = "1"
rayon = "1.10"
```

Tests (in `args.rs` / `probe.rs` inline modules):

```rust
#[test]
fn parse_ffprobe_json__video_and_audio_streams__fields_extracted() {
    // Arrange: a captured-shape ffprobe JSON literal — video stream with
    // width 1920, height 1080, r_frame_rate "60000/1001",
    // side_data_list [{"rotation": -90}], plus an audio stream; format.duration "63.4".
    let json = r#"{ "streams": [
        { "codec_type": "video", "width": 1920, "height": 1080,
          "r_frame_rate": "60000/1001", "avg_frame_rate": "60000/1001",
          "side_data_list": [ { "rotation": -90 } ] },
        { "codec_type": "audio" } ],
      "format": { "duration": "63.400000" } }"#;

    // Act
    let p = parse_ffprobe_json(json).unwrap();

    // Assert
    assert_eq!((p.width, p.height), (1920, 1080));
    assert!((p.fps - 59.94).abs() < 0.01);
    assert_eq!(p.rotation_deg, -90);
    assert!(p.has_audio);
    assert!((p.duration_s - 63.4).abs() < 1e-6);
}

#[test]
fn frame_dims__rotation_minus_90__swaps_width_height() { /* 1920x1080 → (1080, 1920) */ }

#[test]
fn ffmpeg_args__no_audio_no_clip__omits_ss_t_and_audio_map() { /* assert exact Vec */ }

#[test]
fn ffmpeg_args__clip_and_audio__ss_before_input_t_after_and_audio_copied() {
    // Arrange
    let plan = plan_with(/* start 10.0, duration 5.0, has_audio true, fps 30.0, 1280x720 */);

    // Act
    let args = plan.ffmpeg_args(Path::new("out.mp4.part"));

    // Assert — exact expected argv (write the full vec![] literal here from
    // the shape block above; keep it byte-exact so drift is caught)
    assert_eq!(args, expected);
}

#[test]
fn total_frames__29_97fps_10s__300() { /* ceil(10 * 29.97) = 300 */ }
```

- [ ] **Step 2: Run to verify failure** — `cargo test -p idl-rs-video-export` → compile errors.

- [ ] **Step 3: Implement `probe.rs` + `args.rs`** (pure parts). `fps` parse: `"60000/1001"` → num/den; fall back to `avg_frame_rate`; rotation from the first video stream's `side_data_list[].rotation` (0 when absent).

- [ ] **Step 4: Implement `export.rs`** — `run_export`: spawn `Command::new(&plan.ffmpeg_path)` with args + `stdin(piped) stderr(piped) stdout(null)`; spawn a stderr-drain thread keeping the last 4 KB; loop over frame indices in chunks of 32: `chunk.par_iter().map(|i| render(*i)).collect::<Vec<_>>()` (rayon preserves order in collect) then write each to stdin, checking `cancel` between chunks; drop stdin; `child.wait()`; non-zero status → `FfmpegFailed` with the stderr tail; success → `fs::rename(part, output)`. Spawn error `NotFound` → `FfmpegMissing` ("ffmpeg not found at '{path}' — install ffmpeg or pass --ffmpeg"). Cancel path kills child + removes part file.

- [ ] **Step 5: Ignored end-to-end smoke test** (runs only when ffmpeg exists)

```rust
#[test]
fn run_export__synthetic_input_e2e__produces_playable_mp4() {
    // Auto-skip when ffmpeg absent:
    if std::process::Command::new("ffmpeg").arg("-version").output().is_err() { return; }
    // Arrange: generate a 1 s 64x64 30 fps test input with ffmpeg lavfi
    // (color=red), probe it, plan with a render closure producing a moving
    // white square on transparent background.
    // Act: run_export.
    // Assert: output exists, .part gone, probe(output) parses w/h correctly.
}
```

- [ ] **Step 6: Full suite + commit**

```bash
cargo test
cargo fmt && git add video-export Cargo.toml Cargo.lock
git commit -m "video-export: ffprobe/argv/driver sidecar-ffmpeg crate (SPEC 33.5)"
```

---

### Task 11: CLI `video probe` / `video sync`

**Files:**
- Modify: `cli/src/main.rs` (new `Video` subcommand with `Probe`/`Sync` sub-subcommands)

**Interfaces:**
- Consumes: `video::mp4box::{read_info_path, read_gpmd_samples_path}`, `video::gpmf::parse_gpmf`, `video::sync::estimate_sync`, `SessionHandle::from_path`, envelope `emit_success`/`CliError`.
- Produces (structured commands, §29.7 envelope; text default, `--format json`):

```
idl-rs video probe --video v.mp4 [--format json]
  → width/height/fps/duration_s/creation_time_utc_ms/has_gpmd
idl-rs video sync <session.idl0> --video v.mp4 [--format json]
  → offset_s/confidence/method (+ text hint "pass --offset to override")
```

- [ ] **Step 1: Add the clap arms** (follow the existing `Laps` arm shape — positional session file, flags, `OutFormat`):

```rust
    /// Inspect a video container / estimate video↔session sync offset.
    #[command(subcommand)]
    Video(VideoCmd),

#[derive(Subcommand)]
enum VideoCmd {
    /// Container facts + GPMF presence (pure-Rust; no ffprobe needed).
    Probe {
        #[arg(long)]
        video: PathBuf,
        #[arg(long, value_enum, default_value_t = OutFormat::Text)]
        format: OutFormat,
    },
    /// Estimate the sync offset (GPMF UTC, else container creation time).
    Sync {
        /// Path to an `.idl0` log file.
        file: PathBuf,
        #[arg(long)]
        video: PathBuf,
        #[arg(long, value_enum, default_value_t = OutFormat::Text)]
        format: OutFormat,
    },
}
```

Handler sketch (map `VideoError` → `CliError`: `Io→CliError::io`, others → `CliError::new(ErrorKind::…, e.message)` — pick the closest existing `ErrorKind` variants after reading `cli/src/envelope.rs:38`; add a new variant only if none fits):

```rust
VideoCmd::Probe { video, format } => {
    let info = mp4box::read_info_path(video.to_str().unwrap_or_default()).map_err(video_err)?;
    // text: aligned "key: value" lines; json: emit_success("video probe",
    // json!({ "width": info.width, …, "has_gpmd": info.has_gpmd }), vec![])
}
VideoCmd::Sync { file, video, format } => {
    let handle = SessionHandle::from_path(...)?;
    let info = mp4box::read_info_path(...)?;
    let telemetry = match mp4box::read_gpmd_samples_path(...) {
        Ok(s) => Some(gpmf::parse_gpmf(&s).map_err(video_err)?),
        Err(e) if matches!(e.kind, VideoErrorKind::NoGpmf) => None,  // normal, not an error
        Err(e) => return ... video_err(e),
    };
    let est = estimate_sync(telemetry.as_ref(), &info, &handle).map_err(video_err)?;
    // text: "offset: 23.412 s  (method: gpmf, confidence: 0.9)"
}
```

- [ ] **Step 2: CLI integration test** — `cli/tests/video_cmd.rs`: write Task 5's `synthetic_mp4` bytes to a temp file (export the builder behind `#[cfg(any(test, feature = "test-fixtures"))]` in core, or duplicate the tiny builder in the CLI test — prefer a core `pub` fn under a `test-fixtures` cargo feature enabled by the CLI's dev-dependencies), run the binary with `assert_cmd`-style `std::process::Command::new(env!("CARGO_BIN_EXE_idl-rs"))`, assert JSON output parses and `has_gpmd == true`. Check `cli/Cargo.toml` for an existing integration-test pattern first and follow it.

- [ ] **Step 3: Run** — `cargo test -p idl-rs-cli` → pass (plus manual: `cargo run -p idl-rs-cli -- video probe --video <any mp4 you have>` if one exists).

- [ ] **Step 4: Commit**

```bash
cargo fmt && git add cli
git commit -m "cli: video probe + video sync subcommands (SPEC 33.6)"
```

---

### Task 12: CLI `overlay` — the export command

**Files:**
- Modify: `cli/src/main.rs`, `cli/Cargo.toml` (add `idl-rs-video-export = { path = "../video-export" }`)

**Interfaces:**
- Consumes: everything above, plus `workbook::{read_workbook, apply_workbook}`, `laps::detect_laps`, `track_artifact` (read `.idl0t` → `LapTiming` — read `cli/src/main.rs`'s existing `Laps` arm for the exact track→gates conversion and reuse it verbatim), `MathLapContext::default()` for `apply_workbook`.
- Produces: the `Overlay` bulk command (artifact = video file; errors → stderr envelope via `emit_bulk`):

```rust
    /// Render a workbook overlay layout onto a video (sidecar ffmpeg).
    Overlay {
        /// Path to an `.idl0` log file.
        file: PathBuf,
        #[arg(long)]
        video: PathBuf,
        #[arg(long)]
        workbook: PathBuf,
        /// Layout name; may be omitted when the workbook has exactly one.
        #[arg(long)]
        layout: Option<String>,
        /// `.idl0t` track for the lap panel (optional — lap elements
        /// render no-data without it).
        #[arg(long)]
        track: Option<PathBuf>,
        /// Manual sync offset in seconds (skips auto-sync).
        #[arg(long)]
        offset: Option<f64>,
        /// Clip start in video seconds.
        #[arg(long)]
        start: Option<f64>,
        /// Clip duration in seconds.
        #[arg(long)]
        duration: Option<f64>,
        /// Output path; default: <video stem>_overlay.mp4 beside the video.
        #[arg(short, long)]
        output: Option<PathBuf>,
        /// ffmpeg video encoder (default libx264).
        #[arg(long, default_value = "libx264")]
        encoder: String,
        /// Path to the ffmpeg binary (ffprobe resolved beside it).
        #[arg(long, default_value = "ffmpeg")]
        ffmpeg: String,
    },
```

- [ ] **Step 1: Implement the handler** (order matters):

```rust
// 1. SessionHandle::from_path; workbook::read_workbook.
// 2. apply_workbook(&handle, &wb, &MathLapContext::default()) — math channels
//    into the store; per-channel failures are fine (elements degrade).
// 3. let layout = wb.overlay_layout(layout.as_deref()).map_err(CliError::usage)?;
// 4. laps: track.map(|t| — load .idl0t exactly as the Laps arm does — detect_laps(...)).unwrap_or_default();
// 5. offset: match offset { Some(o) => o, None => {
//        let info = mp4box::read_info_path(&video)?;
//        let telem = read_gpmd_samples_path(..).ok().map(|s| parse_gpmf(&s)).transpose()?;
//        let est = estimate_sync(telem.as_ref(), &info, &handle)?;
//        eprintln!("sync: {:.3} s ({:?}, confidence {})", est.offset_s, est.method, est.confidence);
//        est.offset_s } };
// 6. let probe = idl_rs_video_export::probe(&video, &ffprobe_beside(&ffmpeg))?;
//    (ffprobe_beside: replace the file-stem "ffmpeg" with "ffprobe" in the
//    given path; bare "ffmpeg" → "ffprobe".)
// 7. Build ExportPlan { output: output.unwrap_or_else(default_name), .. }.
// 8. let ctx = SampleContext::prepare(&handle, layout, laps);
//    let (fw, fh) = plan.frame_dims();
//    let clip0 = start.unwrap_or(0.0);
//    let fps = probe.fps;
//    let render = |i: u64| {
//        let t_video = clip0 + i as f64 / fps;
//        let s = ctx.sample(t_video + offset_s);
//        video::render::render_overlay_frame(layout, &s, ctx.track_polyline(), fw, fh)
//    };
// 9. run_export(&plan, render, &mut |p: Progress| {
//        eprint!("\r{} / {} frames", p.frames_done, p.frames_total); }, &AtomicBool::new(false))
//    then eprintln!("\nwrote {}", plan.output.display());
// 10. Errors: map ExportError/VideoError into CliError and emit via emit_bulk("overlay", …).
```

- [ ] **Step 2: Wire + compile** — `cargo build -p idl-rs-cli` clean; `cargo run -p idl-rs-cli -- overlay --help` shows all flags with doc strings.

- [ ] **Step 3: Integration test (no ffmpeg needed)** — `cli/tests/overlay_cmd.rs`: session fixture (reuse whatever `.idl0` fixture the existing CLI tests use — check `cli/tests/`), a temp workbook JSON with two layouts, temp synthetic MP4; run `overlay` with **no** `--layout` → assert exit code non-zero and stderr envelope mentions both layout names (this exercises selection + workbook parse + error path without ffmpeg). A second case with `--offset 0 --layout A` and `--ffmpeg definitely-missing-binary` → assert the `FfmpegMissing` message ("install ffmpeg or pass --ffmpeg").

- [ ] **Step 4: Manual smoke (ffmpeg on PATH)** — if a real MP4 is available: run against any `.idl0` in the repo's test data with `--offset 0 --duration 3`, open the output, confirm panels render. Record the command used in the commit message body.

- [ ] **Step 5: Full suite + commit**

```bash
cargo test
cargo fmt && git add cli Cargo.lock
git commit -m "cli: overlay export command wiring engine + video-export (SPEC 33.6)"
```

---

### Task 13: Docs closure (idl0-app repo)

**Files:**
- Modify: `CHANGELOG.md`, `TASKS.md`, `docs/design_rationale.md`, `docs/superpowers/specs/2026-07-08-video-overlay-design.md`

**Interfaces:** none — documentation.

- [ ] **Step 1: design doc amendment** — in §"CLI" / §3 of the design doc, add `--track <t.idl0t>` to the `idl-rs overlay` signature with the sentence: "the lap panel needs laps; on the CLI they come from `detect_laps` + a track artifact (§29.2 precedent) — omitted → lap elements render no-data." (Implementation-discovered gap; spec §33.6 already includes it from Task 1.)

- [ ] **Step 2: CHANGELOG.md** — append under today's date:

```markdown
- Video overlay phase 1 (engine + CLI): canvas-agnostic `overlay::{model,sample}`,
  GPMF parsing + UTC auto-sync, tiny-skia overlay rasterizer (IBM Plex Mono
  embedded), sidecar-ffmpeg `video-export` crate, and `idl-rs overlay` /
  `video sync` / `video probe` commands. Workbook v2: additive
  `overlay_layouts`. SPEC §33. App phases (workspace links, Analyze panel)
  tracked in TASKS.
```

- [ ] **Step 3: TASKS.md** — under the backlog "Synchronized video channel" entry, replace its body with a pointer: design doc + phase-1 shipped note + remaining phase 2 (app data layer: `.idl0w` v8 video links, workbook v2 Dart model, GPMF auto-sync at link time) and phase 3 (Analyze video panel, cursor sync, live overlay, export dialog, manual sync UI) as two new unticked entries at the top of the active section, each citing the design doc path.

- [ ] **Step 4: design_rationale.md** — one entry: sidecar-ffmpeg-vs-libav (build risk, licensing, hw encoders for one bundled exe) and one-rasterizer WYSIWYG (tiny-skia everywhere; Flutter compositor for chart canvases later; pixel parity between compositors an explicit non-goal).

- [ ] **Step 5: Commit (idl0-app repo)**

```bash
cd c:\Users\isaac\Documents\Saucy\saucyeng\idl0-app
git add CHANGELOG.md TASKS.md docs/design_rationale.md docs/superpowers/specs/2026-07-08-video-overlay-design.md
git commit -m "Docs: video overlay phase 1 shipped (engine + CLI); queue phases 2-3"
```

---

## Self-review checklist (ran at plan time)

- **Spec coverage:** §33.1→Tasks 2–3; §33.2→Task 4; §33.3→Tasks 5–7; §33.4→Tasks 8–9; §33.5→Task 10; §33.6→Tasks 11–12; spec-first gate→Task 1; artifact rules→Task 13. Design-doc items deferred by design: drift term, WYSIWYG editor, Android export, bundled ffmpeg (future work — no tasks, correct).
- **Known deviations from the design doc, both deliberate:** (1) `rayon` lives in `video-export`, not core — parallelism is the driver's concern; core stays lean. (2) `--track` added to the CLI (lap data source); recorded in Task 13's doc amendment.
- **Type consistency:** `SampleContext::prepare(handle, layout, laps)` (T4) matches T12 step 8; `render_overlay_frame(layout, sample, polyline, w, h)` (T9) matches T12; `ExportPlan::ffmpeg_args(part_path)` (T10) matches its own tests; `Workbook::overlay_layout(Option<&str>) -> Result<&OverlayLayout, String>` (T3) matches T12 step 3's `CliError::usage` mapping.
- **Test-name convention:** em-dash names are illegal Rust — Task 2 Step 1 note applies to all tasks (match the repo's existing double-underscore style).
