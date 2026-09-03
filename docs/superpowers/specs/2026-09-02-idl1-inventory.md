# idl1 rewrite — Dart data-layer carry-forward inventory

Produced 2026-09-02 by a read-only Sonnet survey of `app/lib/data/` against `rust/core/src/`.
Disposition counts (47 files): already-in-engine 9 · partial-port 9 · port 13 · UI-state-only 6 · drop-with-Flutter 10.

## 1. File-by-file

| Dart file | Responsibility | Engine equivalent | Disposition | Note |
|---|---|---|---|---|
| app_settings.dart | User prefs (rider name, units, sync) | none | port | shared_preferences; new backend must persist |
| bike_profile.dart | Bike config JSON + legacy migration | none | port | §8 config payload shaping, not engine concern |
| cached_session_laps.dart | Renumbers cached per-visit laps session-wide | laps/model.rs (Lap) | port | pure fn over Workspace; engine emits per-visit numbering only |
| channel_groups.dart | Buckets channel names by prefix for UI list | none | UI-state-only | used only by grouped_channel_list widget |
| channel_source.dart | Abstract device-config source, builds Flutter dialogs | none | drop-with-Flutter | Widget/Riverpod-coupled, device push config |
| cursor_lookup.dart | Binary-search epoch↔cursor mapping | none | UI-state-only | chart cursor helper |
| cursor_pair.dart | A/B cursor position pair per worksheet | none | UI-state-only | pure UI state |
| database_paths.dart | path_provider/sqflite DB dir + legacy migration | none | drop-with-Flutter | Tauri path/DB APIs differ |
| exceptions.dart | IDL0 exception hierarchy | session/mod.rs `ParseError` (subset) | partial-port | parse errors mirrored; profile/workspace/track/gpx exceptions not |
| fft_options.dart | FftXScale enum (chart axis display) | none | UI-state-only | display setting |
| fit_export.dart | FitLap bridge + export filename | export/fit/mod.rs | partial-port | lap bridge is glue; filename fn needs porting |
| gate_geometry.dart | Synthesizes start/finish gates from a polyline | none confirmed | port | laps/geometry.rs has crossing detection only, not gate synthesis |
| gpx_parser.dart | Parses .gpx XML into a Session | none | port | **largest importer port**; no XML/GPX parsing in engine |
| lap_context.dart | Bundles main/overlay lap state for math eval | math/eval.rs `MathLapContext`/`MathOverlay` | already-in-engine | thin bundle over ported types |
| lap_detection_bridge.dart | FFI bridge to `idl_rs::laps` | laps/detect.rs, laps/model.rs | already-in-engine | glue |
| lap_detector.dart | GpsFix/LapGate/SectorGate/NeutralZone classes | laps/model.rs, gps.rs | already-in-engine | Dart mirrors |
| lap_distance_accumulator.dart | Confidence-anchor lap-distance normalization | track_projection.rs `Projector` (related) | partial-port | still used by lap_provider.dart; algorithm differs from Projector |
| lap_timing.dart | LapTiming/Circuit/PointToPoint JSON model | laps/model.rs `LapTiming` | already-in-engine | (de)serialization mirror |
| math_channel.dart | MathChannel/MathConstant/Library/Validator/builtins | math/channel_def.rs (name+expression only) | partial-port | **constants, validator, builtin catalog have no engine equivalent** |
| math_eval_failure_mapper.dart | Maps MathEvalFailure → Dart exceptions | math/error.rs `MathEvalError` | already-in-engine | glue |
| math_quantity.dart | Unit-system default-unit lookup | none | port | pure lookup table |
| overlay_layout.dart | Mirror of engine `overlay::model` JSON | overlay/model.rs | already-in-engine | wire shape engine-defined |
| profile_store.dart | File-backed BikeProfile JSON store | none | port | atomic-write pattern |
| session_filename.dart | Session filename from timestamp | none | port | trivial |
| session_index.dart | SQLite cache of SessionMetadata | none | port | catalog |
| session_model.dart | Session/ChannelData/Lap/Sector/SessionMetadata | session/mod.rs, laps/model.rs | partial-port | channel fields mirror engine 1:1; `laps`/`bikeProfileSnapshot` are workspace-layer, not in engine `Session` |
| sessions_paths.dart | path_provider session folder resolution | none | drop-with-Flutter | Tauri path API differs |
| spectral_params.dart | FFT/spectrogram knob bundle | fft.rs (`FftWindow`/`Detrend`/`Scaling`) | already-in-engine | thin UI bundle |
| table_model.dart | TableColumn/RowContext/TableModel mirror | table/model.rs | already-in-engine | eval is engine-side |
| track.dart | Track entity (gates, sectors, neutral zones, polyline) | track_artifact/model.rs `Track` (read-only) | partial-port | engine has no serialize/write side |
| track_artifact_io.dart | Encode/decode `.idl0t` JSON | track_artifact/read.rs (read only) | partial-port | encode missing in engine |
| track_index.dart | SQLite cache of Track entities | none | port | catalog |
| track_matching_bridge.dart | FFI bridge to `idl_rs::tracks` | tracks/detect.rs | already-in-engine | glue |
| workbook.dart | Workbook entity (worksheets, math channels, constants, overlay layouts) | workbook/model.rs | partial-port | engine models math_channels/tables/overlay_layouts only |
| workbook_index.dart | SQLite cache of Workbook entities | none | port | catalog |
| workbook_migration.dart | One-shot legacy SharedPreferences→workbook migration | none | port? | unconfirmed relevance to a fresh rewrite — likely drop |
| worksheet.dart | ChartSlot/Worksheet chart-layout model (831 lines) | none (engine drops charts/layout) | UI-state-only | **replaced by workbook v3, not ported** |
| worksheet_block.dart | BlockContent (chart vs table) + placement | workbook/model.rs `BlockContentRaw` (table only) | partial-port | table blocks parseable engine-side |
| workspace.dart | `.idl0w` aggregate: track visits, videos, cursors, layout, lap flags (710 lines) | none | port | **2nd-largest port**; confirmed still Dart |
| y_scale.dart | Y-axis transform (linear/log/sqrt/square) | none | UI-state-only | display mapping |
| channel_sources/*.dart (7 files) | Device-config views, build Flutter dialogs | none | drop-with-Flutter | misfiled as data layer; pure UI. Reappears as L7 UI over SPEC §8 |

## 2. Engine canonical model (as of 2026-09-02)

- `session::Session { session_id, device_id, timestamp_utc_ms, config_checksum, channels: Vec<Channel> }` — flat list, no lap/workspace fields.
- `session::Channel { channel_id: String, sample_rate_hz: f64, column: RawColumn, sample_times_secs: Option<Vec<f64>>, gaps: Vec<GapSpan> }`.
  Fixed-rate channels have implicit time `i / sample_rate_hz`; event-driven channels (`sample_rate_hz == 0`) own a per-sample timestamp vector. **Genuinely multi-rate; no shared time axis.**
- `RawColumn`: `I16 | I32 | F32 { data, scale, offset }` (raw wire values, widened lazily as `raw*scale+offset`), `F64` verbatim (GPS/math/GPX), zero-storage `Ramp` (synthesized Time) and `Interp` (synthesized Distance).
- Sources (IMU0/1/2, GPS, wheel, analog, HRM) are a **naming convention** on `channel_id` (`IMU0_AccelX`, `GPS_Latitude`, per `parse::records::IMU_CHANNEL_NAMES`), not a typed grouping.
- `session::handle::SessionHandle` wraps `Session` + synthesized ids + interior-mutable derived-channel store (math outputs, lap slices).
- `workbook::model::Workbook` parses `workbook_id, name, math_channels: Vec<MathChannelDef{name, expression}>`, `workbook_version` (≤ v2), `overlay_layouts: Vec<OverlayLayout{id, name, canvas:"WxH", elements}>` with elements `Gauge | Attitude | TraceStrip | TrackMap | LapPanel` in normalized `[x,y,w,h]`. Worksheets parsed only to extract `WorkbookTable` blocks; chart/layout JSON silently dropped.

## 3. Surprises

1. **CLAUDE.md §2 is stale.** It says lap/track analysis and `.idl0w` are "still migrating." `laps/`, `tracks/`, `track_artifact/`, `workbook/`, `overlay/` all exist and are substantially complete with tests. Only `.idl0w` (workspace.dart) is genuinely still Dart.
2. **`MathConstant` has no engine support** — `MathChannelDef` is `{name, expression}` only. Constants, the validator, and the builtin catalog live only in Dart. Must land in the engine (L3).
3. `channel_sources/*` are UI (import flutter/material) filed under `data/`.
