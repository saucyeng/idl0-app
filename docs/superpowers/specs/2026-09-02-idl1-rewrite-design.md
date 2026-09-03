# idl1 — rewrite design

**Date:** 2026-09-02 · **Status:** approved design, pre-implementation · **Disposition:** spec-first
**Supersedes:** the on-screen half of "Composition model: one slot schema, Rust owns the picture" (design_rationale 2026-07-29) and TASKS.md "Composition roadmap" sub-projects 1–7.
**Companion:** `2026-09-02-idl1-inventory.md` (Dart data-layer carry-forward inventory).

This document is the record of the decision to end idl0-app and the master design for its successor, **idl1-app** — a new repository. It is written in idl0-app because idl0-app's history should say why it stopped; it becomes idl1-app's first commit. It is a decomposition document: each lane below gets its own spec section in idl1-app's SPEC when picked up, never one monolithic spec.

---

## 1. Why

idl0-app is a Flutter/Dart app over the `idl-rs` Rust engine. Three things drove the rewrite, in the order they were felt:

1. **The charting ceiling.** fl_chart could not do the parts of the app that matter most — pan, zoom, window management — so custom chart types, decimation and a hand-rolled JSON chart language were built around it. Video overlay then forced a *second* set of chart painters in Rust, and the two vocabularies (`ChartSlot` in Dart, `OverlayElement` in Rust) diverged.
2. **Agent-hostile authoring.** The hand-rolled workbook language is one nobody but this project has seen. Agents can edit it, clunkily. Observable Plot and D3 are grammars agents have been trained on at scale.
3. **Dart stopped earning its place.** The engine has absorbed the parser, the math evaluator, the dependency resolver, laps, tracks and workbook parsing. With charts leaving the widget tree, Dart's remaining job was hosting widgets and BLE glue: `Rust → Dart → JS` collapses to `Rust → JS`.

The product goal that frames everything: **the optimised stack for trackside race engineering** — a team, offline, on a pit-lane LAN, analysing and deciding during a race weekend, with agents as first-class authors.

## 2. Decisions

Final, in the order they were made.

| # | Decision |
|---|---|
| D1 | **Full rewrite.** Rust backend + web frontend in **Tauri v2**, desktop and mobile. Flutter/Dart dropped. New repo `idl1-app`. |
| D2 | **Split cell model.** *Math cells* are a curated language evaluated in Rust (the existing evaluator, extended). *Chart/view cells* are JavaScript (Observable Plot, D3, Inputs) executed by `@observablehq/runtime` in a sandbox. Rust computes numbers; JS draws pictures. |
| D3 | **Canonicalise on ingest.** N importers (`.idl0`, `.fit`, `.gpx`, `.csv`) → one Session/Channel model → **Parquet**, one wide file per session. Raw source files immutable and content-addressed. The device still writes `.idl0`. |
| D4 | **Hardware-agnostic.** A decade of FIT/GPX is a first-class target. CSV is low priority ("when in Rome"). |
| D5 | **Mobile is the primary device connection** (BLE download, WiFi config push) and a live "scientific paper" notebook viewer; desktop is the comfortable authoring surface. Isaac owns the native BLE plugin. |
| D6 | **Sync sources always; sync outputs only when content-addressed by their inputs.** Cheap math cells are lazy. Expensive estimators (the iEKF) are *materialised* once post-import, keyed by hash of inputs, and synced as blobs. **Co-editing is cell-granular in v1**: cells carry stable ids (C2) and sync merges per cell, so different cells never conflict and a same-cell conflict yields a conflict copy of that cell only. Character-level CRDT merge and live cursors (`yrs`) are deferred and change only the merge rule. |
| D7 | **LAN sync is v1**, not deferred: mobile import → desktop automatically; desktop workbook → mobile automatically; agent edits the file from anywhere. No SaaS. |
| D8 | **Workbook = Framework-compatible Markdown** (`.idl1wb`): front matter + prose + ` ```js ` cells, plus our ` ```math ` and ` ```table ` extensions. |
| D9 | **Video export is sidelined.** Tag and delete the Rust painters, `video-export`, and the CLI `overlay` command on the idl1 line. Reels return later, rendering from the workbook. |
| D10 | **Catalog = SQLite** (`rusqlite`, bundled), a rebuildable index, never synced. Not SurrealDB/LibSQL. |
| D11 | **One chart library**: Plot + D3. Dense rasters come from Rust. ECharts/ECharts-GL is a recognised possible escape hatch for a chart class D3 can't reach (e.g. GPU 3-D), assumed not needed; adding it later is a bundled-library decision, not an architectural one. |
| D12 | **Frontend: React + TypeScript + Vite** (tentative — low-regret; CodeMirror, Plot and the Runtime are framework-agnostic, so only app chrome is affected by a change). |
| D13 | **Cell editor = Properties + Code** panes now; an **Agent** tab arrives with lane L12. Until then, Claude Code edits the file and the app follows it live. |

## 3. Principles

Named rules the lanes design against. Each is a sentence an implementer can quote in a review.

- **Rust = numbers, JS = pictures.** No number the sync model depends on is computed in JavaScript. No chart is ever drawn in Rust — including video export when it returns: the same JS cells render the overlay frames, and Rust only rasterises SVG and muxes video (§8).
- **The workbook is a file; the app is a live viewer of it.** Any editor — the app, Claude Code, `vim` — writes the file; the app watches it and re-evaluates.
- **Sync sources; outputs only when content-addressed.** A derived file's name is the hash of `(inputs, config, engine version)`. If the hash matches, the bytes are interchangeable. Stale files are orphans, not bugs.
- **The catalog is an index.** It can be deleted and rebuilt by scanning the data directory. It is never synced.
- **No IPC on the interaction path.** Hover, pan and pinch never wait on Rust. IPC happens on gesture *settle*.
- **Canonicalise on ingest.** Format-specific code runs once, at import. Everything downstream reads Parquet.
- **Log files are immutable after download** (carried from idl0). Blobs never change; they are addressed by SHA-256.
- **No renderer-only parameters** (carried). Anything the renderer honours is expressible in the cell.
- **Offline-first means bundled.** Every JS library ships inside the app. No CDN, ever.

## 4. Target architecture

```
idl1-app/
  app/
    src-tauri/        Tauri app crate — thin: builder, plugin registration, mobile plugins (Kotlin/Swift)
    src/              TypeScript (React/Vite): notebook, device, data, settings
  docs/               SPEC (Parts 1–2, 3–10 copied verbatim from idl0; app parts rewritten), rationale, this doc
  rust/               git submodule → idl-rs workspace (shared with idl0-app at a pinned commit)
    core/             idl-rs        pure engine. Gains store/ (arrow model, parquet, CAS, catalog),
                                    importers (fit, gpx, csv), workbook v3 (Markdown), constants,
                                    materialised channels. CLI shares all of it.
    transport/        idl-transport NEW. BLE (btleplug, desktop), WiFi transfer client, config push,
                                    LAN sync server/client (placement: §16). I/O only, no DSP. Never in core.
    tauri/            idl-rs-tauri  NEW. #[tauri::command] handlers + plugin init over core+transport.
                                    The only crate the frontend sees (the role bridge/ had).
    cli/              idl-rs-cli    unchanged in role; gains import/query/migrate subcommands.
    bridge/, video-export/, core/src/overlay, core/src/video, cli overlay cmd — deleted on the idl1 line (D9)
  CLAUDE.md, TASKS.md, CHANGELOG.md, README.md
```

**Layer rule (replaces idl0's Rust/Dart line):** `core` is pure and I/O-light (std::fs only); `transport` is I/O and platform; `tauri` is glue; `app/src` is UI. The frontend never imports anything that isn't `idl-rs-tauri` commands or bundled JS libraries.

**IPC.** Control and metadata cross as JSON. Heavy arrays (tiles, rasters, cursor readouts) cross as raw bytes via `tauri::ipc::Response` → `ArrayBuffer` → `Float32Array` view, no copy. Progress (import, transfer, sync) streams over `tauri::ipc::Channel`. Binary IPC on mobile webviews is verified at M0.

**Data path for a chart.**
```
JS cell asks host for channel "fork_travel" over the visible window at tier k
  → host requests tiles (session, channel, tier, tile_index…) that aren't cached
  → core: Parquet column (mmap) → decimate_channel(tier, tile) + per-pixel-column (min,max,mean)
  → bytes over IPC → Float32Array → transferable ArrayBuffer into the sandbox → Plot.lineY(...)
Spectrogram / dense scatter: core computes STFT or 2-D histogram + colormap → RGBA tile → canvas
under the chart's axes. Plot draws ≤ ~2 points per pixel column per series; density is raster.
```

**Reactive DAG across two runtimes.** `math::resolve` (Rust) orders and evaluates math cells. Each math cell is exposed to the Observable Runtime as a host-provided variable; JS cells depend on it by name; the Runtime schedules JS re-execution. One graph, two schedulers, one file.

## 5. Data model and storage

**Canonical model** is the engine's existing one (see inventory §2): `Session { session_id, device_id, timestamp_utc_ms, config_checksum, channels }`, `Channel { channel_id, sample_rate_hz, column: RawColumn, sample_times_secs: Option<Vec<f64>>, gaps }`. Genuinely multi-rate; `RawColumn` keeps raw `i16/i32` counts with scale/offset, widened lazily. Sources are a naming convention on `channel_id`. Contract C1 formalises the metadata the model needs for non-device sources (FIT/GPX have no `device_id` or `config_checksum`; they get `source_kind` and the blob hash).

**Time is recorded, not assumed.** Every `.idl0` IMU, GPS and HRM sample carries `timestamp_us` on the device's single `esp_timer` clock (SPEC §5.5, §5.6), and that is the time the store keeps — never `i / sample_rate_hz`. Nominal rate is metadata. This changes the engine's `Channel` model, which today represents fixed-rate channels as implicit `i/rate` and so silently replaces the recorded stamps: L1 makes per-sample time mandatory, as int64 microseconds from the session's first sample (delta-encoded in Parquet at near-zero cost; f32 seconds lacks the resolution at 800 Hz over 30 minutes). **Known hazard (C1):** firmware stamps FIFO bursts by walking back from the read instant at the *nominal* ODR, so an IMU whose true ODR differs from nominal yields bursts that overlap or gap at their seams — locally non-monotonic time. The canonical file preserves the recorded stamps verbatim (`<source>_t_recorded_us`) *and* carries a sorted union axis `t` produced by a documented, versioned burst-seam correction (fit burst read-instants → effective ODR → monotonic per-sample time; the burst anchors, not the nominal cadence, are what the correction trusts). The correction's algorithm version is file metadata. All sources share one clock domain (one MCU), so there is no cross-source alignment problem at the storage layer; FIT/GPX bring their own recorded timestamps and the same rule applies.

**`data.parquet` is a function of `(blob, importer version)`.** It is written at import and not modified; when the importer or the seam correction changes version, it is regenerated from the immutable blob. That is why the blob is the truth and the canonical file is a derivative — and why it is content-addressed by its inputs and syncable under D6 like any other derived output.

**Parquet layout — one wide file per session.** One `t` column (int64 µs from the first sample; `timestamp_utc_ms` origin in file metadata), one column per channel, null where the channel did not sample at that instant (union time axis by recorded time). Nulls are run-length encoded — a 10 Hz GPS column in an 800 Hz table costs nothing measurable. Raw integer columns are stored as integers with `scale`/`offset`/`sample_rate_hz` in column key-value metadata, so files stay small and the engine rebuilds compact `RawColumn`s on read by dropping nulls. Column projection and row-group time statistics give "one channel, one time range" reads without touching the rest. External tools read it directly (`SELECT t, IMU1_AccelZ FROM 'sessions/*/data.parquet' WHERE …`). Alternatives rejected: per-rate-group files (file sprawl), long `(channel,t,value)` triples (3× storage, alien to tools), one-row-per-channel nested lists (no range skipping).

**Materialised derived channels.** Expensive, deterministic estimators (the iEKF suspension/attitude chain today) run once after import and persist as `derived/<hash>.parquet`, where `hash = sha256(input column hashes ‖ config ‖ engine version)`. They are **separate files, never appended to `data.parquet`**: the canonical file is written once at import and is immutable like the `.idl0` it came from (Parquet cannot be appended in place regardless); a new iEKF config or engine version writes a new derived file beside the old one and the raw file is untouched; raw syncs once, derived syncs per version. The catalog maps channel name → file, so a session reads as one thing. Cheap math cells stay lazy in the derived store. Materialised files sync as blobs (D6). Floating-point results may differ in the last ulp across CPU architectures; the key is inputs, not outputs, so two devices may hold bitwise-different, equivalent files under one key — sync keeps whichever it has.

**Data directory** (contract C4 fixes names; this is the proposal):
```
<data>/blobs/sha256/ab/cdef…             raw source files, immutable
<data>/sessions/<session_id>/session.json   metadata, laps, track visits, flags (replaces .idl0w)
<data>/sessions/<session_id>/data.parquet   canonical channels
<data>/sessions/<session_id>/derived/<hash>.parquet
<data>/workbooks/*.idl1wb
<data>/tracks/*.idl0t                       format unchanged; engine gains the writer
<data>/catalog.sqlite                       rebuildable index; never synced
```
`session_id` is the device's session id when the source is `.idl0`; otherwise a prefix of the blob hash.

**Catalog (SQLite)** tables: `sessions`, `blobs`, `workbooks`, `tracks`, `laps`, `lap_summary` (per lap × materialised channel: min/max/mean) so a season-wide search never opens Parquet. Rebuild = scan the tree.

**Workbook `.idl1wb`.** Observable-Framework-compatible Markdown:
````markdown
---
id: 9f3c…            # stable; conflict copies keep it
name: Fork tuning
constants: { g: 9.80665, rider_mass_kg: 82 }
---
# Fork tuning — Whistler, 2026-08-30

```math
fork_velocity = deriv(fork_travel, t)
fork_bottom_out = fork_travel > 195
```

```js
Plot.plot({ marks: [Plot.lineY(channel("fork_velocity"), { x: "t", y: "v" })] })
```

Bottom-outs this lap: ${count(fork_bottom_out)}
````
Math cells hold one or more `name = expression` definitions (the existing grammar plus constants). Table cells carry the existing table model. JS cells are Framework's. Prose is Markdown with `${…}` inline values. Parsing is `pulldown-cmark` in core; only fenced blocks are executable. **Migration:** `idl-rs migrate-workbook` converts `.idl0wb` v2 math channels → one math cell, constants → front matter, tables → table cells; chart slots are converted on first open in the app through the Properties-form generator (§6); overlay layouts are dropped (D9). `.idl0w` track visits and lap flags migrate into `session.json`; cursors, layouts and video links are dropped.

## 6. Notebook

**Cells** are the unit of everything: authoring, evaluation, error display, and later, merge. Kinds: prose, `math`, `table`, `js`.

**Sandbox.** JS cells execute inside an origin-isolated `<iframe sandbox="allow-scripts">` (no `allow-same-origin`) that cannot reach Tauri IPC. The Runtime, Inspector, Plot, D3 and Inputs are bundled into the iframe. Host ↔ iframe is `postMessage` with transferable `ArrayBuffer`s. The cell API is narrow and host-mediated: `channel(name, {lap?, session?})`, `laps`, `session`, `constants`, `Plot`, `d3`, `Inputs`, `html`. A watchdog pings the iframe; a stalled cell (runaway loop) gets the iframe torn down and rebuilt — state loss is the cost, and it is per-notebook, not per-app. This is defence against bugs and stray agent output, not adversaries.

**Editor — Properties + Code (D13).** Every chart cell's source of truth is its code. The *Properties* pane is a form (channels, lap/session scope, mark type, axes and domains, colours, y-scale, units) that **generates idiomatic Plot code** and **parses back the subset it generates** plus literal edits — bidirectional inside that subset. Code outside it (computed values, custom D3 marks) greys the pane to *custom code* with a *Reset to form* that regenerates from the last known props and warns that custom code will be discarded. The `plotForm` module (`parse(code) → props | null`, `generate(props) → code`) is a pure, heavily-tested TypeScript unit. Precedent: Observable's chart cell (form → Plot code, one-way); we are two-way where honest. The *Code* pane is CodeMirror 6 (Markdown mode for prose, JS mode for cells, our math mode). The *Agent* tab (L12) later.

**Interaction rules** (from the principle "no IPC on the interaction path"):
- **Hover** reads the per-pixel-column stats shipped with each tile. Cross-channel cursor readouts fire once on cursor settle (debounced), never per move.
- **Zoom** is quantised to tiers. During a pinch/scroll the existing picture scales via a canvas/CSS transform; tiles at the new tier are fetched on settle.
- **Pan** is translation. The picture slides; only newly exposed edge tiles are fetched. Playback prefetches ahead of the playhead.
- **Point budget.** Plot renders SVG; the host caps line marks at ~2 points per pixel column per series and lower on mobile. Density (spectrogram, g-g scatter, whole-session histograms) is a Rust raster under Plot axes.

**Mobile paper view.** Prose and outputs rendered, editors collapsed, live-updating against the active session. The Properties form is the touch editor; the Agent tab (later) is the "talk to it" editor.

## 7. Transport and sync

**Device transport (Rust).** Desktop BLE via `btleplug`; WiFi transfer against the device's HTTP protocol (SPEC §6) via `reqwest`; config push (SPEC §8). Mobile BLE and WiFi-network binding are Tauri mobile plugins (Kotlin/Swift) behind the same Rust traits — Isaac's lane, proven early (M2), not gated.

**LAN sync (D7).** Each app instance runs a small HTTP server (`axum`) advertised via mDNS (`_idl1._tcp`). **Pair once**: desktop shows a 6-digit code/QR, phone enters it, both keep a token. **Sync** is pull-based and idempotent: `GET /manifest` (blob hashes, workbook paths+hashes, session metadata) → diff → `GET /blob/<hash>` with range requests (resumable), push likewise → workbooks merge **per cell** by stable cell id: a cell changed on only one side takes that side; a cell changed on both since the last sync keeps the local version and appends the peer's as a conflict cell directly below it, marked `<!-- conflict from <peer> -->`, so the file stays valid and the human resolves it in place. Cells added on either side are unioned in document order; a cell deleted on one side and edited on the other is kept as a conflict cell. Whole-file conflict copies are never produced. A blob enters the catalog only after its hash verifies. Catalog never syncs. **Trigger**: automatically when a paired peer appears on the network while the app is open, plus a manual button and a status line. **Honest caveat**: iOS does not run this in the background; Android can with a foreground service. v1 is "open the app on home WiFi and it syncs." A cloud relay later is the same protocol over the internet.

**File watcher.** `notify` on `<data>/workbooks`; the app ignores its own writes (temp-file + rename, expected-hash set), debounces ~100 ms, re-parses, diffs cells, re-evaluates only changed math cells, and pushes into the Runtime. This is the agent-from-anywhere path at M1.

## 8. Export

Sidelined (D9). Tag idl-rs `idl0-video-export` at the last commit containing the painters; delete `video-export/`, `core/src/overlay`, `core/src/video`, the CLI `overlay` subcommand, and workbook v2 `overlay_layouts` handling on the idl1 line. The principle that survives: when reels return, they render from the workbook file — one vocabulary — and the Plot → SVG → `resvg` (tiny-skia) → ffmpeg path is the expected route.

## 9. Contracts (lead writes these before wave 1)

| | Contract | Fixes |
|---|---|---|
| C1 | **Session schema** | Arrow schema for `data.parquet`; the time model (int64 µs `t`, per-source `_t_recorded_us`, the burst-seam correction and its version); column metadata keys (`scale`, `offset`, `nominal_rate_hz`, `unit`, `source_kind`); file metadata (`session_id`, `timestamp_utc_ms`, `device_id?`, `config_checksum?`, `blob_sha256`, `importer_version`, `engine_version`); the `Channel ↔ Arrow` round-trip with mandatory per-sample time; `session.json` schema. |
| C2 | **Workbook v3** | `.idl1wb` grammar: front matter keys, fence kinds, math-cell definition syntax (multi-line `name = expr`), constants, inline `${}` semantics; **stable cell ids** (required — the unit of sync merge and of diffing; carried in the fence info string so Framework still treats the file as Markdown, assigned on first save when absent); the Properties-form generated Plot subset (what `plotForm` emits and parses). |
| C3 | **IPC surface** | Every `idl-rs-tauri` command: name, JSON arg/return shapes, which return binary and their byte layouts (tile: header + `f32` pairs + stats table; raster: width/height + RGBA), which stream progress; the single typed error shape that crosses IPC, mirroring core's and transport's error enums (CLAUDE.md §5 carries: no untyped failures). |
| C4 | **Data directory** | Paths above; `session_id` derivation; blob path sharding; atomic write rules; what the catalog indexes and how rebuild works; what sync moves. |

Contracts are short, live in `docs/superpowers/specs/`, and change only through the lead.

## 10. Lanes

Each lane: spec-first (its SPEC section in idl1-app), TDD, tests green (`cargo test` / `vitest`), CHANGELOG line, PR from a worktree branch, reviewer verdict before merge. Coverage targets carry from idl0: Rust > 90 % (`cargo tarpaulin`); pure TypeScript modules (`plotForm`, tile cache, cell diffing) > 80 %; UI rendering is not unit-tested. Lanes touch only their own crate/directory; cross-lane needs are contract changes.

| Lane | Scope | Needs | Wave | Done when |
|---|---|---|---|---|
| **L1** core `store/` | Arrow model ↔ Parquet r/w (C1); CAS blob store; SQLite catalog + rebuild; `session.json` (port of `.idl0w` semantics); track artifact writer; profile/settings persistence; session/lap-level ports from the inventory (gate synthesis, session-wide lap renumbering, lap-distance normalisation, filenames) | C1, C4 | 1 | Round-trip tests on real `.idl0` sessions with recorded timestamps preserved bit-exact; catalog rebuild from a scanned tree; CLI `idl-rs import`/`sessions` work |
| **L2** importers | FIT (`fitparser`), GPX (port of `gpx_parser.dart`), CSV; `Importer` trait producing the canonical model; post-import materialisation hook | C1 (stub L1 via trait) | 1 | Isaac's FIT/GPX archive imports; golden tests per format |
| **L3** core workbook v3 | Markdown parse (`pulldown-cmark`); math cells with constants, validator, builtin catalog and unit table (Dart-only today); resolver across cells; table cells; tile endpoints with column stats + tier cache; raster endpoints (spectrogram, 2-D histogram); `migrate-workbook` | C2 | 1 | Evaluates a migrated idl0 workbook byte-for-byte on math outputs; tile stats verified against decimation |
| **L4** `idl-transport` desktop | BLE (`btleplug`), WiFi transfer, config push; traits the mobile plugins implement | SPEC §6–8 | 1 | Download + config against the real device from Windows |
| **L5** Tauri scaffold | `app/`, `idl-rs-tauri` commands (C3), binary IPC proven on desktop, React/Vite skeleton, routing, state, file watcher plumbing | C3 | 1 | A tile fetched and rendered end-to-end; watcher fires on external edit |
| **L6** notebook UI | Sandboxed iframe + cell API; Runtime + Inspector; Plot/D3/Inputs bundle; CodeMirror (md/js/math); Properties ↔ Code editor + `plotForm`; `zoomable()`; interaction rules; raster layering; math↔js DAG bridge | L3, L5 | 2 | Pan/zoom/hover on a real session at 60 fps desktop; `plotForm` round-trips its subset |
| **L7** device/data/settings UI | Ports of the Device (all seven source-config views incl. HRM, which is a real input), Data (catalog browser, import), Settings tabs over L4/L5 | L4, L5 | 2 | Feature parity with idl0 for those tabs |
| **L9** mobile | Android/iOS builds; BLE + WiFi-binding plugins (Isaac); paper view; touch editor; IPC verified | L5, L4 traits | 2–3 | Download from the device on a phone; open a synced workbook |
| **L10** docs | idl1-app SPEC (copy Parts 1–2/3–10; rewrite app parts per lane); CLAUDE.md layer rules; README; CHANGELOG/TASKS discipline; fix idl0 CLAUDE.md §2 staleness | — | all | Every shipped lane has its SPEC section |
| **L11** LAN sync | `axum` server, mDNS, pairing, manifest/blob/workbook endpoints, per-cell merge with conflict cells (pure function over two parsed workbooks + last-synced base — tested on its own), auto-trigger, status UI | L1, L3 (parser), L4 crate | 2 | Phone → desktop blob sync and desktop → phone workbook sync on a home LAN; two-sided edits to different cells merge with no conflict |
| **L12** in-app agent | Rust API client, key in Settings, streaming, cell-scoped context, diff-accept UI; sub-spec follows the `claude-api` reference | L6 | 3, optional | Agent tab edits a cell and the file changes |

**Waves.** Wave 1 (day one, no shared files): L1, L2, L3, L4, L5 (+ L10 alongside). Wave 2: L6, L7, L9 scaffold, L11. Wave 3: L9 plugins, L12, polish. L8 (export) does not exist in v1.

## 11. Milestones

- **M0 — foundations.** Contracts C1–C4 written; idl1-app repo created (git init, docs copied, `rust/` submodule, Tauri template); idl-rs tagged `idl0-final` and `idl0-video-export`; deletions of D9 landed on idl-rs `main`; ecosystem verified by a Sonnet research task (Tauri v2 + mobile binary IPC, `btleplug`, `mdns-sd`, `arrow`/`parquet`, `fitparser`, `pulldown-cmark`, `@observablehq/runtime`/`plot`/`inputs`, CodeMirror 6, iframe sandbox + transferables on WKWebView/Android WebView).
- **M1 — desktop analysis parity.** Import `.idl0/.fit/.gpx` → Parquet; open a migrated workbook; Plot charts with real pan/zoom/hover; Properties + Code editing; file watcher live; CLI import/query. *idl1 beats idl0 for analysis here.*
- **M2 — device and sync.** Desktop BLE/WiFi download and config; LAN sync phone ↔ desktop; mobile BLE via Isaac's plugin.
- **M3 — mobile.** Paper view, touch editor, device management on the phone.
- **M4 — retire idl0-app.** Archive the repo; `bridge/` already gone from idl-rs `main`.

## 12. Agent-team operating model

Addresses the two 2026-09-02 pain points (human as message bus; failed cheap-model delegation).

- **Persistent lead** — one session, the model that wrote this doc. It writes contracts and lane briefs, adjudicates, and merges. It never implements.
- **Roles by `subagent_type`, model baked in**, enforced by the dispatch gate: `implementer` (Sonnet; one task, own worktree, TDD) → `reviewer` (Sonnet; findings file, verdict line) → `adjudicator` (Fable; cross-lane conflicts only) → `transcriber` (Haiku; mechanical: Dart tests → Rust tests, SPEC section moves). Bulk reading is `Explore` with an explicit model.
- **The repo is the bus.** Contracts and specs in `docs/superpowers/specs/`; lane briefs in `overnight/lanes/<lane>/BRIEF.md`; human rulings in `overnight/decisions.md`. No hand-written NEXT-PROMPTS.
- **Gates**: a lane task is done when its reviewer's verdict is clean and tests are green; a wave is done when every lane in it merges; contracts change only through the lead.
- **Commit hygiene**: no AI attribution trailers in these repos.

## 13. Keeping idl0-app alive

Submodules pin a commit. Tag idl-rs at the commit idl0-app uses (`idl0-final`); idl1 work proceeds on idl-rs `main`; idl0-app never bumps its pointer. Engine fixes idl0-app still needs are cherry-picked to an `idl0-maint` branch. Deleting `bridge/` and the export crates on `main` cannot affect a pinned build.

## 14. Risks, honestly held

- **Mobile BLE and WiFi binding through Tauri plugins.** Unproven in this project; Isaac has native Android BLE experience and owns it. Proven at M2, before anything depends on it.
- **SVG on mobile webviews.** The point budget and Rust rasters are the mitigation; the caps may need to be lower than desktop. Measured in L6/L9.
- **Determinism across engine versions and CPUs.** Materialised outputs are keyed by inputs; math cells recompute. Engine version is part of every derived hash.
- **Markdown as an executable container.** Only fenced blocks execute; front matter is strict YAML; parse errors are per-cell, never fatal. The grammar is C2's job to pin.
- **`plotForm` subset drift.** The generator and parser are one module with round-trip tests; Properties greys out rather than guesses.
- **Compile weight.** `arrow`/`parquet` are heavy. Feature-gate what the CLI does not need.
- **Sandbox iframe on mobile.** `postMessage` with transferables is standard on WKWebView/Android WebView; verified at M0.

## 15. Deferred / out of scope

Character-level CRDT co-editing and live cursors (`yrs` on cell text — replaces only L11's per-cell merge rule); cloud relay; ECharts/3-D; Framework run-sheet export (`idl-rs export-framework`); video/reels export; iOS background sync; CSV beyond a trivial importer.

## 16. Open items (assigned)

- C1: metadata for non-device sources; the burst-seam correction algorithm (validated against a session with a known ODR offset) and whether the firmware should stamp burst boundaries explicitly in a future `.idl0` schema so the correction becomes exact.
- C2: exact encoding of the cell id in the fence info string; math-mode syntax for CodeMirror.
- C4: exact `session_id` derivation for non-device sources.
- L4: crate name (`idl-transport` proposed) and whether the LAN sync server lives in it or beside it.
- D12: React stays unless L5 finds a reason at scaffold time.
