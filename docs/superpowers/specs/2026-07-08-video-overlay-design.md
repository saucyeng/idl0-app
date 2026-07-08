# Video Overlay & Synchronized Video — Design

**Date:** 2026-07-08
**Status:** Approved design, pre-implementation
**Spec disposition:** Spec-first (new architectural surface — spec text lands before code)

---

## 1. Goal

Two products on one shared foundation:

1. **Burned-in overlay export** — a new video file with telemetry rendered into the
   frames (gauges, traces, track map, lap timing), producible from the desktop app
   and headlessly from the `idl-rs` CLI.
2. **In-app synchronized playback** — video plays inside an Analyze worksheet,
   locked to the worksheet cursor for play/pause/scrub (the existing
   "Synchronized video channel" backlog entry in TASKS.md).

Sequencing: export first (engine + CLI is self-contained and headlessly testable),
then app data layer, then app UI.

### Requirements (from brainstorm)

- Input video: arbitrary MP4/MOV from any camera. GoPro GPMF telemetry is a
  first-class **auto-sync** source when present.
- Export platforms: **desktop + headless CLI**. Android export is out of scope for v1.
- Overlay parameters (layouts) live in the **workbook** (`.idl0wb`), so the CLI
  needs only `--workbook`; the video↔session link + sync offset live in the
  **workspace** (`.idl0w`) as derived data. `.idl0` files remain immutable.
- v1 overlay elements: numeric gauges, scrolling trace strip, track map +
  position dot, lap/timing panel, and a purpose-built **attitude element** for
  signed zero-centered channels (roll = tilting bike/horizon glyph + degree
  readout; steering = zero-centered needle/arc). Other elements stay visually
  plain in v1; iterate on looks in code.

## 2. Architecture decision

**Chosen: Approach A — Rust rasterizes overlay frames; ffmpeg runs as a sidecar
process for decode/composite/encode.**

The CLI-headless requirement forces the overlay renderer into Rust (no Flutter
runtime headlessly). Once it lives there, using the same rasterizer for CLI
export, app export, and the app's live preview gives WYSIWYG for free — the
layout tuned in the app is pixel-identical in the export.

The engine never links ffmpeg. Video encoding is not bike physics; it is
quarantined in a small driver crate that spawns a sidecar `ffmpeg` process.

**Rejected:**

- *Flutter renders the overlay, export captures it offscreen* — headless CLI is
  impossible without Flutter; would require a second renderer that drifts from
  the app's. Fails a stated requirement.
- *Link libav into Rust (`ffmpeg-next`)* — libav cross-compilation on
  Windows + cargokit, LGPL/GPL distribution questions, per-platform build
  breakage. The sidecar costs one external executable and buys ffmpeg's
  hardware encoders with zero build entanglement.

## 3. Components & layer placement

### `rust/core` (`idl-rs`) — new `video` module, all pure

| Submodule | Responsibility |
|---|---|
| `video::gpmf` | Demux the `gpmd` track from MP4 (pure-Rust `mp4` crate) and parse GPMF KLV → `VideoTelemetry` (UTC anchor, GPS fixes at video-relative timestamps, camera IMU). |
| `video::sync` | `estimate_sync(telemetry, session) → SyncEstimate { offset_s, confidence, method }`. GPMF UTC vs the session's GPS-anchored wall clock (`GPS_EpochMs`); fallback MP4 `creation_time`. **No signal-correlation refinement** — precision beyond ~1 s is manual (see §5). |
| `video::overlay` | `OverlayLayout` model — `Gauge`, `TraceStrip`, `TrackMap`, `LapPanel`, `Attitude` elements: normalized rect, channel references, style fields. JSON (de)serialization for the workbook. |
| `video::sample` | `(session handle, layout, t_video, offset) → FrameSample` — the values / trace window / GPS position / lap state one frame needs. Rides on the existing derived-channel store + math eval. |
| `video::render` | `render_overlay_frame(layout, sample, w, h) → RGBA` via `tiny-skia`; text via an embedded IBM Plex subset (OFL). Deterministic → golden-image testable; frames are independent → rayon-parallel. |

### `rust/video-export` (new crate)

The one place allowed to spawn processes. Probes the source (`ffprobe` JSON),
spawns sidecar `ffmpeg`, pipes rendered RGBA frames as a second rawvideo input
(`filter_complex overlay`), stream-copies audio, reports progress, handles
cancel. Consumed by **both** `idl-rs-cli` and the FRB bridge — the driver exists
once. Core purity is preserved.

### `rust/cli`

- `idl-rs overlay --session s.idl0 --video v.mp4 --workbook w.idl0wb [--layout <name>] [--offset 12.34] [--start T --duration D] [--encoder X] [--ffmpeg PATH]`
  — `--layout` may be omitted when the workbook holds exactly one layout;
  with several, omitting it is an error listing the available names.
- `idl-rs video sync` — print estimated offset + confidence.
- `idl-rs video probe` — dimensions/fps/duration/telemetry presence.

### `app/lib/data`

- `.idl0w` v7→v8: `videos[]` link entries (see §4).
- `.idl0wb` workbook_version 1→2: `overlay_layouts[]` (see §4).

### `app/lib/ui`

Analyze video panel (media_kit), cursor↔playback sync, live overlay preview via
the engine renderer, manual sync nudge UI, desktop export dialog with FRB
progress stream. Settings: ffmpeg path (v1 = system/user-pointed; bundling
deferred).

## 4. Data model & schemas

### `.idl0w` v8 — video links (derived data; `.idl0` untouched)

```json
"videos": [
  {
    "id": "uuid",
    "path": "relative-or-absolute path to .mp4/.mov",
    "file_size_bytes": 123456789,
    "file_mtime_ms": 1751000000000,
    "sync_offset_s": 12.340,
    "sync_method": "gpmf | creation_time | manual",
    "sync_confidence": 0.97,          // null when sync_method = "manual"
    "label": "Chest cam"
  }
]
```

- `session_time = video_time + sync_offset_s`; millisecond resolution suffices.
- Multiple entries per session; GoPro chapter files are separate entries, each
  with its own offset.
- `file_size_bytes` + `file_mtime_ms` give cheap re-link validation without
  hashing multi-GB files. A missing/moved file degrades to a "re-link video"
  prompt — never blocks workspace load.

### `.idl0wb` v2 — overlay layouts (session-agnostic, portable, CLI-consumable)

```json
"overlay_layouts": [
  {
    "id": "uuid",
    "name": "MTB default",
    "canvas": "1920x1080",
    "elements": [
      { "type": "gauge",       "rect": [0.02, 0.80, 0.14, 0.16], "channel": "GPS_SpeedKmh",
        "style": "dial | bar | numeric", "label": "km/h", "min": 0, "max": 80 },
      { "type": "attitude",    "rect": [0.18, 0.80, 0.10, 0.16], "channel": "Roll_deg",
        "style": "roll | steer", "range_deg": 60 },
      { "type": "trace_strip", "rect": [0.30, 0.82, 0.40, 0.15],
        "channels": ["TravelFront_mm", "TravelRear_mm"], "window_s": 8.0 },
      { "type": "track_map",   "rect": [0.84, 0.04, 0.14, 0.25] },
      { "type": "lap_panel",   "rect": [0.02, 0.04, 0.16, 0.14] }
    ]
  }
]
```

- Rects normalized `[x, y, w, h]`; fonts/strokes scale from the canvas ratio, so
  one layout serves 1080p and 4K.
- Channel names resolve exactly as charts do (raw, math, estimator-derived).
  A referenced channel missing from a session degrades that element to `—`;
  never blocks the render.
- Colors/units default from existing channel metadata; per-element overrides
  are style fields.
- Not stored: per-session layout tweaks (duplicate the layout instead); no
  overlay state in `.idl0w` beyond link + offset.

Both bumps are spec-first: `.idl0w` v8 → SPEC §11.4/§15; workbook v2 → §17a;
plus a new appended spec section for the video subsystem.

## 5. Sync model

One number per linked video: `sync_offset_s`. No drift/scale term in v1 —
camera clock drift over a sub-hour session is well under a frame (recorded as a
known simplification).

1. **GPMF auto-sync** (GoPro): coarse offset from GPMF UTC vs `GPS_EpochMs` —
   typically within ~1 s. That is the whole auto path; no correlation
   refinement (deliberately dropped as unreliable complexity).
2. **`creation_time` fallback** (any MP4/MOV): coarse only, confidence reported
   low; UI nudges the user to refine.
3. **Manual fine-tune**: the app's sync mode — scrub **with audio**, align the
   landing you hear with the spike you see, ±1-frame / ±0.1 s / ±1 s nudge
   buttons. CLI: `--offset`. `sync_method: "manual"` is never silently
   overwritten by auto-sync.

Estimation is a pure engine function; the stored offset in `.idl0w` is always
authoritative at render time — rendering never re-estimates.

Edge cases: zero overlap → typed error listing both time ranges; GPMF present
but GPS-empty → fall through to `creation_time`; chapters sync independently.

**Future (not v1):** a session-start LED blink on the next hardware iteration,
visible on camera — exact sync, trivially verifiable, later auto-detectable.

## 6. Export pipeline (the `video-export` driver)

1. **Probe** with sidecar `ffprobe` (JSON): dimensions, frame rate, duration,
   rotation metadata, audio presence.
2. **Plan**: output = source resolution + frame rate, full length by default.
   Out-of-overlap frames render elements in a "no data" state (dimmed / `—`).
   `--start`/`--duration` map to ffmpeg `-ss`/`-t` with the overlay clock
   offset accordingly — the fast iterate-on-a-clip loop.
3. **Frame loop**: `t_video = start + i/fps` → `video::sample` →
   `video::render` on a rayon pool, delivered in order through a bounded queue
   (backpressure) → ffmpeg stdin as rawvideo RGBA.
4. **One ffmpeg invocation**: input 0 = source (decode), input 1 = RGBA pipe;
   `filter_complex overlay`; audio stream-copied; `libx264` default with
   `--encoder` escape hatch (nvenc/qsv/videotoolbox); mp4 + faststart.
5. **Progress & cancel**: frames-fed vs total + ffmpeg `-progress` parsing →
   one progress callback (CLI bar; FRB stream). Cancel kills the child and
   removes partial output.

**Output hygiene:** the export is a terminal artifact — nothing references it,
no intermediate frames touch disk. Writes go to `<name>.mp4.part`, renamed on
success, so a half-written file is never mistakable for a finished export.
Re-render = overwrite or new file; "garbage collection" is deleting a file.

**Real-world gotchas handled:** VFR phone footage is normalized to CFR (fps
filter) and the overlay clock follows *output* timestamps, so overlay never
drifts against a VFR source. Rotation metadata is applied at probe time so the
overlay canvas matches displayed orientation.

Throughput: 1080p60 RGBA ≈ 500 MB/s through the pipe — trivial; encode is the
bottleneck and rasterization parallelizes ahead of it. 4K works, just slower.

## 7. In-app playback & live overlay

- **Placement:** a video panel as a new Analyze worksheet slot kind (participates
  in worksheet layout). Appears when the viewed session has linked videos;
  multiple links → source picker in the panel header.
- **Player:** `media_kit` (all target platforms, hardware-decoded).
- **Sync loop, one rule two directions:** charts → video: cursor A moves → seek
  to `cursor − offset`. Video → charts: playback ticker drives cursor A
  (`video + offset`) through the existing `worksheetCursors` state, so every
  chart follows via the §26.7 synchronized-cursor contract. A guard flag
  prevents seek↔cursor feedback; cursor writes throttle to display refresh.
- **Live overlay:** panel toggle. Engine renders `render_overlay_frame` at the
  current time, sized to the panel (cheap), composited over the video widget.
  Same rasterizer as export → preview is pixel-for-pixel the shipped output.
- **Manual sync UI** lives in this panel (sync mode: offset field + nudges +
  audio scrubbing).
- **Deferred from v1:** WYSIWYG layout drag-editing (v1 edits layouts as a
  simple form/JSON), multi-video simultaneous playback, frame-stepping beyond
  nudge buttons.

## 8. Error handling

New `VideoError` family (typed, per SPEC §14; no hard crashes):

| Condition | Behavior |
|---|---|
| ffmpeg/ffprobe missing | Typed setup error: CLI → "install ffmpeg or pass `--ffmpeg`"; app → Settings path prompt. |
| ffmpeg fails mid-render | `ExportFailedException` carrying the stderr tail; `.part` deleted. |
| Video file moved/deleted | Workspace loads; panel shows re-link prompt. Degraded state, not an error. |
| No/unparseable GPMF | Silent fallthrough to `creation_time` (low confidence); parse anomalies are warnings. |
| No video↔session overlap | Typed error stating both time ranges. |
| Layout references missing channel | Element renders `—`; one warning; other elements unaffected. |

## 9. Testing

Scaled deliberately — no real camera recordings exist yet.

- **Rust core (>90%):** GPMF parser against **synthetic KLV fixtures** built
  from GoPro's published GPMF spec (real-footage fixtures added once recordings
  exist — explicit gap); sync estimator recovers a planted offset; frame
  sampler returns known values + correct no-data states at boundaries;
  renderer **golden-image tests** (tiny-skia is deterministic → byte-compare
  RGBA against checked-in goldens); layout JSON round-trips.
- **`video-export`:** ffprobe-JSON parsing from recorded fixtures; ffmpeg argv
  construction as a pure function (VFR / rotation / clip-range / encoder
  cases); one end-to-end smoke test (1 s synthetic video) that auto-skips when
  ffmpeg is absent.
- **Dart data layer (>80%):** `.idl0w` v7→v8 silent forward migration; link +
  layout serialization round-trips; cursor↔video-time mapping as pure
  functions. Player/process boundaries mocked; media_kit/ffmpeg internals not
  tested.

## 10. Phasing

1. **Engine + CLI** — `video::{gpmf,sync,overlay,sample,render}`,
   `video-export` driver, `idl-rs overlay|video sync|video probe`. Headless,
   fully testable, delivers export-first.
2. **App data layer** — `.idl0w` v8 links, workbook v2 layouts, GPMF auto-sync
   at link time.
3. **App UI** — Analyze video panel, cursor↔playback sync, live overlay
   preview, manual sync nudge UI, desktop export dialog.

Each phase independently shippable. FRB codegen reruns when the bridge surface
lands (phase 2+).

## 11. Spec & docs plan

- **SPEC:** new appended top-level video-subsystem section (entities, sync
  contract, overlay layout schema, export pipeline, CLI commands); touches to
  §11.4/§15 (workspace v8), §17a (workbook v2), §26 (Analyze video panel),
  §29 (CLI).
- **design_rationale.md:** sidecar-ffmpeg-vs-linking; one-renderer WYSIWYG.
- **TASKS.md:** queue decomposition happens in the implementation plan; the
  existing "Synchronized video channel" backlog entry is superseded by this doc.
- **CHANGELOG.md:** at ship time per phase.

## 12. Future work (recorded, not v1)

- Session-start LED blink for exact sync (next hardware iteration); later
  auto-detection of the blink in footage.
- WYSIWYG overlay layout editor in-app.
- Android export (MediaCodec or maintained ffmpeg-kit fork).
- Bundled ffmpeg (licensing-clean LGPL build) instead of system-installed.
- Drift/scale term in the sync model for long sessions.
- Hardware-encoder auto-detection.
