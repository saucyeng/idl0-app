# Authoring IDL0 `.idl0wb` workbooks by hand

A `.idl0wb` file is a **portable analysis workbook**: an ordered set of
worksheets, each holding blocks (charts and tables), plus a library of math
channels and named constants — all as a single JSON object. It is
session-agnostic: charts name *channels*, never session IDs, and render against
whatever session the app binds at runtime. You can author and edit one entirely
by hand; the app reads it through `Workbook.fromJson`.

This document is the literal field-by-field contract. Field names, enum values,
channel ids, and function names below are exact — copy them verbatim.

> Ground-truth source files (verify here if anything is ambiguous):
> - `app/lib/data/workbook.dart` — top-level `Workbook` (`toJson`/`fromJson`)
> - `app/lib/data/worksheet.dart` — `Worksheet`, `ChartSlot`, the `ChartType` /
>   `WorksheetKind` / `XAxisMode` / `YScaleMode` / `ChartScope` / `VarianceMode` enums
> - `app/lib/data/worksheet_block.dart` — `WorksheetBlock` (chart|table envelope)
> - `app/lib/data/table_model.dart` — the `TableModel` a table block carries
> - `app/lib/data/spectral_params.dart` + `y_scale.dart` — the `spectral` object and `yScale`
> - `app/lib/data/math_channel.dart` — `MathChannel`, `MathConstant`, `kBuiltinMathChannels`
> - `app/dev/default_workbook.idl0wb` — a real, valid multi-sheet example
> - `app/test/data/default_workbook_test.dart` — the round-trip validation model
> - `rust/core/src/parse/records.rs` + `session/synthesis.rs` — the real channel ids
> - `rust/core/src/math/eval.rs` (`call_function`) + `math/parse.rs` (constants) —
>   the function set the engine actually evaluates
> - `docs/IDL0_SPEC.md` §19 (function set), §25/§26 (Maths/Analyze tabs)

---

## 1. Mental model (read this first)

```
Workbook                       ← the .idl0wb file (one JSON object)
├── math_channels[]            ← MathChannel library, shared by every worksheet
├── constants[]                ← MathConstant library (named scalars)
└── worksheets[]               ← ordered pages
    └── blocks[]               ← WorksheetBlock list (each holds a chart OR a table)
        └── content            ← {"kind":"chart","slot":{…}} or {"kind":"table","table":{…}}
                ├── channelIds[]      ← raw/session channel ids, e.g. "IMU1_AccelX"
                └── mathChannelIds[]  ← math channels, referenced by id (see §6)
```

Three hard rules that trip people up:

1. **Worksheets serialize as `blocks`, not `charts`.** A block wraps either a
   chart (`ChartSlot`) or a table (`TableModel`). The app *writes* `blocks`. A
   legacy flat `charts` array is still accepted on read (each entry becomes a
   chart block) and is simpler for hand-writing chart-only sheets — the worked
   example uses it. **Tables require `blocks`.** See §4.
2. **Charts reference math channels by the channel's `id`** (`mathChannelIds`),
   not its `name`. But a hand-authored math channel that **omits `id` gets
   `id = name`** — so if you leave `id` off every math channel, referencing by
   name "just works". Expressions reference channels by `[name]`. See §6.
3. **Colors are CSS hex ARGB strings** on `MathChannel` (`"#FF2196F3"`), but
   per-chart color *overrides* (`channelColors`) are **ARGB ints**. Two
   different encodings, two different fields. See §5 and §6.

---

## 2. Minimal complete skeleton

The smallest valid workbook the app will load — one standard worksheet with one
empty time-series chart, no math channels. This uses the legacy `charts`
shorthand (accepted on read; see §4 for the canonical `blocks` form). Copy and
grow it.

```json
{
  "workbook_id": "00000000-0000-4000-8000-000000000001",
  "name": "My Workbook",
  "workbook_version": 1,
  "created_at_ms": 1767225600000,
  "updated_at_ms": 1767225600000,
  "math_channels": [],
  "constants": [],
  "worksheets": [
    {
      "id": "ws-1",
      "name": "Sheet 1",
      "xAxisMode": "time",
      "charts": [
        {
          "slotId": "slot-1",
          "chartType": "timeSeries",
          "channelIds": [],
          "mathChannelIds": [],
          "yScaleMode": "auto",
          "heightFactor": 1.0,
          "channelColors": {},
          "scope": "auto"
        }
      ]
    }
  ]
}
```

`workbook_id`, `id` (worksheet), and `slotId` should be unique strings. The app
generates UUIDv4s for these, but any unique string round-trips fine — readable
slugs like `slot-bike-speed` are perfectly valid and easier to hand-edit.
Timestamps are **UTC milliseconds since the Unix epoch** (integers).

---

## 3. `Workbook` — top-level fields

From `workbook.dart` `toJson`/`fromJson`. JSON keys are `snake_case` at this
level (note: worksheet/chart keys are `camelCase` — see §4/§5).

| JSON key          | Type               | Required | Meaning |
|-------------------|--------------------|----------|---------|
| `workbook_id`     | string             | yes      | Stable id (UUIDv4 in the app); preserved across rename/sync. |
| `name`            | string             | yes      | Display name. |
| `worksheets`      | array<Worksheet>   | yes\*    | Ordered pages. A zero-worksheet workbook is invalid — always ≥ 1. |
| `math_channels`   | array<MathChannel> | no       | Math-channel library (default `[]`). |
| `constants`       | array<MathConstant>| no       | Named scalar constants (default `[]`). See §6.1. |
| `created_at_ms`   | int                | yes      | Creation time, UTC ms. |
| `updated_at_ms`   | int                | yes      | Last-modified time, UTC ms. Drives last-write-wins on sync — bump it when you edit. |
| `workbook_version`| int                | no       | Schema version. Current max is **1**. Omitting it defaults to 1. A value **> 1** throws `UnsupportedWorkbookVersionException` — never invent a higher number. |

\* `worksheets` may be absent in JSON (defaults to `[]` on read), but a workbook
with no worksheets has nothing to display. Always ship at least one.

App constructors worth knowing (so you can match their output):
- `Workbook.createDefault()` → a `Session` session-sheet + a blank `Charts`
  sheet, seeded with the built-in lap tutorial math channels (`LapNumber`,
  `LapTime`, `LapDistance`, `Lap Delta T`, `Lap Delta D` — see §6.2).
- `Workbook.createBlank()` → one standard `Sheet 1` with a single empty chart.

---

## 4. `Worksheet` — a page of blocks

From `worksheet.dart`. Keys are `camelCase`.

| JSON key     | Type                  | Required | Meaning |
|--------------|-----------------------|----------|---------|
| `id`         | string                | yes      | Stable worksheet id. |
| `name`       | string                | yes      | Tab label, e.g. `Suspension`. |
| `xAxisMode`  | enum string           | no       | `XAxisMode`; default `time`. See below. |
| `blocks`     | array<WorksheetBlock> | no       | Charts and tables in document order (canonical). |
| `charts`     | array<ChartSlot>      | no       | **Legacy** flat chart list; accepted on read, migrated to chart blocks. |
| `kind`       | enum string           | no       | `WorksheetKind`; **omit for a normal sheet** (default `standard`). |

**`blocks` vs `charts`.** The app writes `blocks`; on read it prefers `blocks`,
falls back to migrating `charts`, and if both are absent defaults to one empty
chart block. For hand-authoring a chart-only sheet, the `charts` shorthand is
simpler and fully supported (the example file uses it). To include a **table**,
or to match app output exactly, use `blocks`. Charts always precede tables in v1.

**The `blocks` (canonical) form** — each block has an `id`, a `placement`, and a
`content` discriminated by `kind`:

```json
"blocks": [
  {
    "id": "block-speed",
    "placement": "inFlow",
    "content": { "kind": "chart", "slot": { /* a ChartSlot — see §5 */ } }
  },
  {
    "id": "block-laptable",
    "placement": "inFlow",
    "content": { "kind": "table", "table": { /* a TableModel — see §5.4 */ } }
  }
]
```

`WorksheetBlock` fields: `id` (string, stable), `placement` (`BlockPlacement`:
`inFlow` default — `sideBySide`/`overlay` are stored but not yet rendered),
`overlayTargetId`/`overlayOpacity` (only for `overlay`, omit otherwise), and
`content`. A table block's content may also carry `rowSource`
(`authored` default, or `lapSelection` for a live N-lap comparison table) —
omit it for the normal authored case.

**`xAxisMode`** (`XAxisMode` enum) — one of:
- `time` — elapsed seconds from session start (default).
- `wheelDistance` — metres from front/rear wheel-speed integration. Requires a
  `WheelFront` or `WheelRear` channel in the session.
- `gpsDistance` — metres from cumulative GPS track. Requires `GPS_SpeedKmh`
  (drives the synthesized `Distance` base channel; see §7).

**`kind`** (`WorksheetKind` enum):
- `standard` — blank sheet you fill yourself. This is the default; **omit the
  `kind` key entirely** for standard sheets (the app omits it on write).
- `sessionSheet` — a session-overview sheet. It pins three charts at indices
  0/1/2: `gpsMap`, `lapTable`, `lapProgression` (in that order). When
  hand-authoring a session sheet, **include all three pinned charts yourself**
  in that order (see §8.4). On read, if a `sessionSheet` has no `gpsMap` chart
  in any position, the app auto-prepends one — but author it explicitly to be safe.

---

## 5. `ChartSlot` — one chart

From `worksheet.dart`. Keys are `camelCase`. **Which fields apply depends on
`chartType`** — see the matrix below. The slot is the object inside a chart
block's `content.slot` (or an entry of a legacy `charts` array).

### Always-applicable fields

| JSON key        | Type              | Default       | Meaning |
|-----------------|-------------------|---------------|---------|
| `slotId`        | string            | (auto UUID)   | Stable slot id; unique within the sheet. |
| `chartType`     | enum string       | `timeSeries`  | See `ChartType` below. |
| `channelIds`    | array<string>     | `[]`          | Raw/session channel ids (e.g. `"IMU1_AccelX"`). See the catalog in §7. |
| `mathChannelIds`| array<string>     | `[]`          | Math channels **by id** (§6). |
| `yScaleMode`    | enum string       | `auto`        | `auto` or `manual`. |
| `yMin`          | number            | (omit)        | Only when `yScaleMode` is `manual`. Omit otherwise. |
| `yMax`          | number            | (omit)        | Only when `yScaleMode` is `manual`. Omit otherwise. |
| `heightFactor`  | number            | `1.0`         | Height multiplier, clamped 0.5–3.0 (×300 dp base). |
| `channelColors` | map<string,int>   | `{}`          | Per-channel color **overrides, ARGB int** (e.g. `4280391411` = `0xFF2196F3`). Keyed by channel id (or by session id for `gpsMap`). Channels absent here use the auto palette. |
| `scope`         | enum string       | `auto`        | `ChartScope`: `auto` (follow lap-table main/overlay) or `session` (always full-session). |
| `yScale`        | enum string       | `linear`      | `YScale` display transform — `linear`, `log` (symlog), `sqrtSigned`, `squareSigned`. Any continuous-Y chart. The app **emits it only when non-`linear`**. |
| `showZeroLine`  | bool              | `false`       | Draw a Y=0 reference line. The app **omits this key when false**; only emit it when `true`. Ignored for `gpsMap`/`lapTable`. |
| `title`         | string            | (omit)        | Title overlay. Omit to fall back to the channel-name default. |

### `ChartType` enum

| Value            | What it plots | Channel fields used |
|------------------|---------------|---------------------|
| `timeSeries`     | Multi-channel line chart vs the sheet's X axis. | `channelIds` + `mathChannelIds`. |
| `fft`            | Multi-channel Welch FFT magnitude spectrum (one line per channel). | `channelIds` + `mathChannelIds`. Plus `spectral` + `fftAveraging` (below). |
| `spectrogram`    | Time × frequency heatmap (STFT). Keeps every frame. | `channelIds` + `mathChannelIds` (typically one). Plus `spectral` (no `fftAveraging`). |
| `histogram`      | Value-distribution bars (fraction of samples per bin) over the rendered session. | `channelIds` + `mathChannelIds` (one typical; extras overlay). Plus `histogram*` fields. |
| `varianceTrace`  | N-lap variance — per-sample delta lines vs the Main (fastest) lap. | **`varianceChannelIds`** (not `channelIds`). Plus `varianceMode`. |
| `gpsMap`         | GPS track polyline on a map. | **None** — GPS auto-resolves; leave both id arrays `[]`. |
| `lapTable`       | Per-session lap × sector table. Pinned slot 1 of a session sheet. | **None** — auto-resolves; leave both `[]`. |
| `lapProgression` | Lap-time progression (X = lap index, Y = lap time s). Pinned slot 2 of a session sheet. | **None** — auto-resolves; leave both `[]`. |

> Unknown `chartType` strings fall back to `timeSeries` on read (so an old build
> won't crash on a future type) — but author the exact spelling.

### `spectral` — FFT / spectrogram DSP params (emit **only** for `fft` and `spectrogram`)

The app nests these under a single `spectral` object (replacing the old flat
`fftWindow`/`fftXScale`/… keys — those still migrate on read but are no longer
written). Defaults match the app.

| `spectral` key   | Type        | Default     | Values |
|------------------|-------------|-------------|--------|
| `window`         | enum string | `hann`      | `FftWindow` — `rectangular`, `hann`, `hamming`. |
| `segmentLength`  | int         | (omit=auto) | Welch/STFT segment length in samples. Omit for auto. |
| `overlapPercent` | number      | `50.0`      | Segment overlap %, 0–99. |
| `detrend`        | enum string | `mean`      | `Detrend` — `none`, `mean`, `linear`. |
| `scaling`        | enum string | `magnitude` (FFT) / `density` (spectrogram) | `Scaling` — `magnitude` (RMS, input units) or `density` (PSD). |
| `freqScale`      | enum string | `log`       | `FftXScale` — `linear` or `log`. (Frequency axis: X for FFT, Y for spectrogram.) |

Plus, **FFT only** (not spectrogram), a sibling key on the slot:

| Slot key       | Type        | Default | Values |
|----------------|-------------|---------|--------|
| `fftAveraging` | enum string | `mean`  | `Averaging` — `mean` or `median` (cross-segment). |

### Histogram fields (emit **only** when `chartType` is `histogram`)

| JSON key             | Type | Default | Meaning |
|----------------------|------|---------|---------|
| `histogramBinCount`  | int  | `40`    | Number of equal-width bins. Always emitted for histogram slots. |
| `histogramSymmetric` | bool | `false` | Bin over a zero-centred range `[-m, m]` (natural for signed suspension-velocity). Emitted only when `true`. |
| `histogramSmooth`    | bool | `false` | Draw a smooth polyline through bin centres instead of bars. Emitted only when `true`. |

(The count axis uses the shared `yScale` — set `"yScale": "log"` for a log count axis.)

### Variance-trace fields (emit **only** when `chartType` is `varianceTrace`)

| JSON key             | Type          | Default    | Meaning |
|----------------------|---------------|------------|---------|
| `varianceChannelIds` | array<string> | `[]`       | Channels to compare across laps (this chart ignores `channelIds`). |
| `varianceMode`       | enum string   | `distance` | `VarianceMode` — `time` (lap-relative time) or `distance` (track distance; needs a Track-bound session). |

---

## 6. `MathChannel` — the workbook's derived channels

From `app/lib/data/math_channel.dart`. (There is no longer a separate "portable
vs runtime" split — math channels live on the owning `Workbook` and travel with
the `.idl0wb`.) Keys are `snake_case`:

| JSON key         | Type   | Required | Default        | Meaning |
|------------------|--------|----------|----------------|---------|
| `id`             | string | no       | falls back to `name` | Stable identity. **Charts reference this** (`mathChannelIds`). App uses UUIDs / `builtin:…`; **omit it when hand-authoring** so `id == name`. |
| `name`           | string | yes      | —              | Display name; how *expressions* reference it (`[Name]`). |
| `expression`     | string | yes      | —              | Expression text (see §9). Stored verbatim, evaluated lazily. |
| `quantity`       | string | no       | `""`           | Physical quantity, e.g. `Velocity`, `Position` — used for axis grouping. |
| `units`          | string | no       | `""`           | Display units, e.g. `m/s`, `m`, `bar`. |
| `sample_rate_hz` | number | no       | `0`            | Output rate in Hz. **`0` = inherit** from the expression's primary source channel (the usual choice). |
| `decimal_places` | int    | no       | `2`            | Decimals in gauges/tables. |
| `color`          | string | no       | `"#FFFFFFFF"`  | **CSS hex ARGB string**, e.g. `"#FF2196F3"` (`#AARRGGBB`, or `#RRGGBB` = opaque). |

Example (hand-authored — `id` omitted, so it equals `name`):

```json
{
  "name": "Fork velocity",
  "expression": "integrate([IMU1_AccelX])",
  "quantity": "Velocity",
  "units": "m/s",
  "sample_rate_hz": 0.0,
  "decimal_places": 3,
  "color": "#FF2196F3"
}
```

### How charts find a math channel

- `ChartSlot.mathChannelIds` holds math-channel **ids**. An app-created channel
  has a UUID id, so its chart entry is that UUID (a rename keeps the chart linked).
- A hand-authored channel that **omits `id` defaults `id` to `name`** — so
  `"mathChannelIds": ["Fork velocity"]` resolves to the channel named (and
  thus id'd) `Fork velocity`. **Recommended for hand-authoring: omit every
  `id`, reference by name.** Keep it consistent — don't mix named refs with a
  channel that sets an explicit UUID id.
- A `mathChannelIds` entry with no matching channel id silently renders nothing
  for that entry (the chart skips it) — it does not error.
- Matching is exact, case- and space-sensitive: `"Fork velocity"` ≠
  `"fork velocity"` ≠ `"Fork Velocity"`.

### 6.1 `MathConstant` — named scalars (`constants[]`)

Each entry: `{"id": "...", "name": "g", "value": 9.81}`. `id` defaults to
`name` for hand-authored files. They travel with the workbook and are usable by
name in expressions. Note the engine **already** provides `g`, `pi`, `tau`, `e`
as built-ins (§9) — `constants` is for your *own* named values.

### 6.2 Built-in tutorial channels (`kBuiltinMathChannels`)

`Workbook.createDefault()` seeds five editable lap channels (ids namespaced
`builtin:…`): `LapNumber` = `current_lap()`, `LapTime` =
`[Time] - lap_start_time(current_lap())`, `LapDistance` =
`[Distance] - lap_start_distance(current_lap())`, `Lap Delta T` =
`variance_time([LapTime])`, `Lap Delta D` = `variance_dist([LapTime])`. Reuse
these expressions when you want the same channels.

---

## 7. Channel catalog — the real ids charts must use

These are the channel ids the parser and engine actually produce. `channelIds`
entries must be drawn from this set (plus any user/registry channels present in
the specific session). Math expressions reference the same ids via `[Id]`.

### IMU channels — `IMU{0,1,2}_{Accel,Gyro}{X,Y,Z}`

Source: `IMU_CHANNEL_NAMES` in `rust/core/src/parse/records.rs`. Axis order per
IMU is AccelX, AccelY, AccelZ, GyroX, GyroY, GyroZ.

```
IMU0_AccelX IMU0_AccelY IMU0_AccelZ IMU0_GyroX IMU0_GyroY IMU0_GyroZ
IMU1_AccelX IMU1_AccelY IMU1_AccelZ IMU1_GyroX IMU1_GyroY IMU1_GyroZ
IMU2_AccelX IMU2_AccelY IMU2_AccelZ IMU2_GyroX IMU2_GyroY IMU2_GyroZ
```

**Body mapping (fixed by firmware/install convention):**
- **IMU0 = sprung mass / frame** (the bike body)
- **IMU1 = front fork** (unsprung, front)
- **IMU2 = rear shock** (unsprung, rear)

**Which axis is "vertical" depends on the physical mounting — do not assume Z.**
On the reference rig each sensor is mounted with a *different* axis pointing
along gravity: fork **X**-up (`IMU1_AccelX`), shock **Y**-up (`IMU2_AccelY`),
frame **Z**-up (`IMU0_AccelZ`). The worked example uses exactly those. If you
don't know a given bike's mounting, ask rather than guess the axis. Accel units
are g; gyro units are dps.

### GPS channels

Source: `parse_gps_record` in `rust/core/src/parse/records.rs`.

```
GPS_EpochMs       GPS epoch milliseconds (wall clock)
GPS_Latitude      raw latitude (i32, coordinate-scaled)
GPS_Longitude     raw longitude (i32, coordinate-scaled)
GPS_Altitude      altitude
GPS_SpeedKmh      ground speed in km/h
GPS_Heading       heading
GPS_FixQuality    fix quality code
GPS_Satellites    satellite count
```

### Synthesized base channels (added on session load, not stored on disk)

Source: `rust/core/src/session/synthesis.rs` + SPEC §19.
- `Time` — `samples[i] = i / rate`, at the highest fixed-rate channel's rate.
  Always present when the session has any fixed-rate channel. Reference as `[Time]`.
- `Distance` — cumulative metres from integrating `GPS_SpeedKmh / 3.6`. Present
  only when `GPS_SpeedKmh` exists. Reference as `[Distance]`.

### Other ids you may see in sessions / templates

`WheelFront`, `WheelRear` (wheel speed → enable `wheelDistance` X axis),
`HR_BPM` (heart rate), `HR_RR` (R-R interval). These exist only if the session
logged them.

---

## 8. Recipes

Each recipe is the `ChartSlot` object. Drop it into a worksheet's legacy
`charts` array, **or** wrap it as a block:
`{"id":"…","placement":"inFlow","content":{"kind":"chart","slot":{ …recipe… }}}`.

### 8.1 Add a time-series chart of channels X and Y

```json
{
  "slotId": "slot-fork-shock-accel",
  "chartType": "timeSeries",
  "channelIds": ["IMU1_AccelX", "IMU2_AccelY"],
  "mathChannelIds": [],
  "yScaleMode": "auto",
  "heightFactor": 1.0,
  "channelColors": {},
  "scope": "auto",
  "showZeroLine": true,
  "title": "Fork + shock vertical accel"
}
```

### 8.2 Add an FFT chart of one channel

```json
{
  "slotId": "slot-fork-fft",
  "chartType": "fft",
  "channelIds": ["IMU1_AccelX"],
  "mathChannelIds": [],
  "yScaleMode": "auto",
  "heightFactor": 1.0,
  "channelColors": {},
  "scope": "auto",
  "spectral": {
    "window": "hann",
    "overlapPercent": 50.0,
    "detrend": "mean",
    "scaling": "magnitude",
    "freqScale": "log"
  },
  "fftAveraging": "mean",
  "title": "Fork resonance (FFT)"
}
```

Omit `segmentLength` for auto. Add `"yScale": "log"` for a log magnitude axis.
For a **spectrogram**, set `"chartType": "spectrogram"`, keep the `spectral`
object (use `"scaling": "density"`), and drop `fftAveraging`.

### 8.3 Add a histogram (e.g. suspension-velocity distribution)

```json
{
  "slotId": "slot-susp-velocity-hist",
  "chartType": "histogram",
  "channelIds": [],
  "mathChannelIds": ["Fork velocity", "Shock velocity"],
  "yScaleMode": "auto",
  "heightFactor": 1.0,
  "channelColors": {},
  "scope": "auto",
  "histogramBinCount": 40,
  "histogramSymmetric": true,
  "title": "Suspension velocity distribution"
}
```

### 8.4 Add a math channel and chart it

Two steps. **First**, add the channel to the top-level `math_channels` array
(omit `id` so it equals `name`):

```json
{
  "name": "Fork velocity",
  "expression": "integrate([IMU1_AccelX])",
  "quantity": "Velocity",
  "units": "m/s",
  "sample_rate_hz": 0.0,
  "decimal_places": 3,
  "color": "#FF2196F3"
}
```

**Then** reference it from a chart by its `name` (which is its `id`); leave
`channelIds` empty if the chart only plots math channels:

```json
{
  "slotId": "slot-fork-velocity",
  "chartType": "timeSeries",
  "channelIds": [],
  "mathChannelIds": ["Fork velocity"],
  "yScaleMode": "auto",
  "heightFactor": 1.0,
  "channelColors": {},
  "scope": "auto",
  "showZeroLine": true,
  "title": "Fork velocity"
}
```

A chart can mix raw and math channels — populate both arrays.

### 8.5 Make a Session overview sheet

Set `kind: "sessionSheet"` and include the three pinned charts in order. These
auto-resolve their data, so `channelIds`/`mathChannelIds` stay empty:

```json
{
  "id": "ws-session",
  "name": "Session",
  "xAxisMode": "time",
  "kind": "sessionSheet",
  "charts": [
    { "slotId": "slot-session-gpsmap", "chartType": "gpsMap",
      "channelIds": [], "mathChannelIds": [], "yScaleMode": "auto",
      "heightFactor": 1.5, "channelColors": {}, "scope": "auto",
      "title": "Track map" },
    { "slotId": "slot-session-laptable", "chartType": "lapTable",
      "channelIds": [], "mathChannelIds": [], "yScaleMode": "auto",
      "heightFactor": 1.0, "channelColors": {}, "scope": "auto",
      "title": "Lap times" },
    { "slotId": "slot-session-lapprogression", "chartType": "lapProgression",
      "channelIds": [], "mathChannelIds": [], "yScaleMode": "auto",
      "heightFactor": 1.0, "channelColors": {}, "scope": "auto",
      "title": "Lap progression" }
  ]
}
```

### 8.6 Pick an X-axis mode

Set `xAxisMode` on the worksheet:
- `"time"` — always works.
- `"gpsDistance"` — needs `GPS_SpeedKmh` in the session.
- `"wheelDistance"` — needs `WheelFront` or `WheelRear`.

### 8.7 Manual Y-axis range

```json
"yScaleMode": "manual",
"yMin": -2.0,
"yMax": 2.0
```

Only include `yMin`/`yMax` when `yScaleMode` is `"manual"`.

---

## 9. Expression language quick reference

Source of truth for what **renders** is the engine — `call_function` in
`rust/core/src/math/eval.rs` and the constant table in `math/parse.rs`. (The
Maths-tab inline validator in `math_channel.dart` is a *separate*, sometimes
incomplete allowlist used only for live editing feedback — it can flag valid
engine functions, e.g. the vector primitives, or trip on channel names
containing parentheses. The engine, not that validator, decides what evaluates.)

### Channel references

- `[ChannelName]` — references a session, synthesized, or other math channel by
  its id/name. Examples: `[IMU1_AccelX]`, `[GPS_SpeedKmh]`, `[Time]`,
  `[Distance]`, `[Fork velocity]`. Channel refs are **always bracketed**.
- Range / lap indexing: `[Channel][t_start:t_end]` (time slice) and
  `[Channel][lap_n]` (one lap). (Per SPEC §19 "Range".)

### Constants

Bare (unbracketed) identifiers resolve to built-in scalars at parse time:
`g` = **9.80665** (standard gravity, m/s²), `pi`, `tau`, `e`. So
`[IMU0_AccelZ] * g` converts g → m/s². You may also define your own named
scalars in the workbook `constants[]` array (§6.1). (Because channel refs are
bracketed, a bare `g` is unambiguously the constant.)

### Operators

`+ - * /`, comparisons `< > <= >= == !=`, and the **keywords** `and` `or` `not`
(infix/prefix — not call syntax: `x > 0 and y < 10` is valid; `and(x, y)` is not).

### Functions (engine `call_function`)

| Category       | Functions |
|----------------|-----------|
| Filters        | `butter(order, cutoff_Hz, "low"\|"high", ch)` (aliases `"lowpass"`/`"highpass"`; `"band"` is rejected) |
| Time-domain    | `integrate(ch)`, `differentiate(ch)`, `rms(ch, w)`, `mean(ch, w)`, `std(ch, w)`, `detrend(ch)` / `detrend(ch, mode)` — remove mean + linear trend (least-squares, global, NaN-aware, phase-transparent); `mode` = `linear` (default) \| `constant` \| `none` |
| Reconstruction | `declip(ch)` — rebuilds accel peaks clipped at the ±g rail |
| Scalar aggregates | `sum(ch)`, `count(ch)`, `first(ch)`, `last(ch)`, `median(ch)`, `p(ch, quantile)` (quantile 0–100) |
| Elementwise    | `abs`, `sqrt`, `sign`, `floor`, `ceil`, `round`, `pow(x, y)`, `min(a, b)`, `max(a, b)`, `clamp(ch, lo, hi)` |
| Trig           | `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2(y, x)`, `sinh`, `cosh`, `tanh`, `deg2rad`, `rad2deg` |
| Logic          | `if(cond, t, f)` (call syntax); `and`, `or`, `not` (keywords) |
| Frequency      | `fft(ch, window)` (window `"hann"`/`"hamming"`/`"rect"`) |
| Vectors (3-vec)| `vec(x, y, z)`, `vx(v)`, `vy(v)`, `vz(v)`, `vadd(a, b)`, `vsub(a, b)`, `vscale(v, s)`, `cross(a, b)`, `dot(a, b)`, `norm(v)`, `normalize(v)`, `angle(a, b)` |
| Rotations      | `rotate_mat(v, m00,m01,m02,m10,m11,m12,m20,m21,m22)` (row-major, scalar entries), `rotate_axis(v, ax, ay, az, angle)` (scalars), `rotate_euler(v, roll, pitch, yaw)` (angles may be channels) |
| Lap            | `current_lap()`, `lap_start_time(n)`, `lap_start_distance(n)`, `sector_number()` |
| Variance       | `variance_time(ch)`, `variance_dist(ch)` — Main lap vs overlay laps |

**Deferred functions** parse and validate but throw "not yet implemented" at
eval time: `spectrogram`, `hilbert`, `correlate`, `convolve`, `resample`,
`sosfilt`. (Note: `median(ch)` is **implemented** as a scalar aggregate; only a
2-arg rolling `median(ch, w)` is still deferred.) Don't ship a workbook that
depends on a deferred function expecting data.

### Worked expressions

| Goal | Expression |
|------|-----------|
| Fork velocity (∫ fork accel) | `integrate([IMU1_AccelX])` |
| Declipped fork accel | `declip([IMU1_AccelX])` |
| Suspension travel (double ∫) | `integrate(integrate([IMU1_AccelX]))` |
| High-pass before integrating (drift control) | `integrate(butter(2, 0.8, "high", [IMU1_AccelX]))` |
| Drift-controlled velocity | `detrend(integrate(butter(2, 0.2, "high", [Fork rel accel])))` |
| Accel in m/s² | `[IMU0_AccelZ] * g` |
| Wheel distance | `integrate([WheelFront])` |
| GPS distance (km/h → m/s first) | `integrate([GPS_SpeedKmh] / 3.6)` |
| Lap time | `[Time] - lap_start_time(current_lap())` |

---

## 5.4 / TableModel — table blocks (advanced)

A table block's `content` is `{"kind":"table","table":{…},"rowSource":"…"?}`.
The `TableModel` (mirrors `idl_rs::table::TableModel`; **camelCase** keys, engine-
compatible) is a grid:

- `columns`: array of `{"id", "name"?, "template"?}` — `name` is the `{name}`
  (same-row) / `{name[]}` (whole-column) reference target; `template` is a
  formula applied to every cell in the column that has no own formula.
- `rows`: array of `{"id", "context"?}` — `context` `{"sessionId","lapIndex"}`
  binds the row to a lap window so its `[Channel]` refs resolve to that lap.
- `cells`: `cells[r][c]` = `{"formula"?, "literal"?, "name"?}` — `literal`
  short-circuits evaluation; else `formula` (or the column `template`) is
  evaluated in the row's context; `name` makes a single cell a `{name}` target.

Cell formulas use the same expression language (§9) plus `{cellName}` /
`{colName[]}` references. For non-trivial tables, read `table_model.dart` and
`rust/core/src/table/eval.rs`. Note `lapTable` (§5) is a *chart type*, not a
TableModel — don't confuse the two.

---

## 10. The worked example (`app/dev/default_workbook.idl0wb`)

A real, valid multi-sheet workbook ordered to the suspension-analysis flow. It
uses the legacy `charts` form and omits math-channel `id`s (so each `id` equals
its `name`). Sheet order:

1. **Session** (`kind: sessionSheet`) — pinned `gpsMap` + `lapTable` + `lapProgression`.
2. **Bike** — `timeSeries` of `GPS_SpeedKmh`; frame vertical accel
   (`IMU0_AccelZ` + declipped); frame-at-axle accel math channels.
3. **Suspension** — fork+shock accel (`IMU1_AccelX` + `IMU2_AccelY`, raw +
   declipped), velocity and travel math channels, and a `histogram` of the
   velocity channels.
4. **Frequencies** — `fft` of `IMU1_AccelX` and `IMU2_AccelY`.
5. **Rider inputs** — `IMU0_GyroZ` (frame yaw rate) placeholder.

Its math channels include `declip(...)` axes, integrated velocity/travel, and
pitch-corrected frame-at-axle references. **Treat the exact expressions there as
illustrative and evolving** — open the file for the current definitions; this
reference defines the *format*, not a frozen suspension recipe.

---

## 11. Common mistakes & validation

**Mistakes to avoid**

- **Referencing a math channel by a `name` while also giving it an explicit
  `id`.** `mathChannelIds` matches on `id`. For hand-authoring, omit `id`
  everywhere so `id == name`, then reference by name. A mismatch renders nothing
  (no error).
- **Writing flat `fft*` keys.** FFT/spectrogram params now live in the nested
  `spectral` object (`window`, `freqScale`, …); `fftAveraging` is a separate
  FFT-only sibling key. Old flat keys still load but aren't the current shape.
- **Putting type-specific fields on the wrong chart.** Emit `spectral` only for
  `fft`/`spectrogram`; `histogram*` only for `histogram`; `variance*` only for
  `varianceTrace`.
- **Giving `channelIds` to an auto-resolving chart.** `gpsMap`, `lapTable`, and
  `lapProgression` resolve their own data — keep both id arrays `[]`. (And
  `varianceTrace` uses `varianceChannelIds`, not `channelIds`.)
- **Wrong color encoding.** `MathChannel.color` is a **hex string**
  (`"#FF2196F3"`). `ChartSlot.channelColors` values are **ARGB ints**
  (`4280391411`). Don't swap them.
- **`workbook_version` > 1.** Throws `UnsupportedWorkbookVersionException`.
  Keep it `1` (or omit).
- **`snake_case` vs `camelCase` mixups.** Top-level `Workbook` and `MathChannel`
  keys are `snake_case` (`workbook_id`, `sample_rate_hz`). `Worksheet`,
  `WorksheetBlock`, `ChartSlot`, and `TableModel` keys are `camelCase`
  (`xAxisMode`, `chartType`, `mathChannelIds`, `freqScale`).
- **Assuming the vertical IMU axis is Z.** It depends on mounting (fork X-up,
  shock Y-up, frame Z-up on the reference rig). Use the right axis (§7).
- **Channel id typos.** Use the exact catalog ids (§7): `IMU1_AccelX`,
  `GPS_SpeedKmh` — not `imu1_accelx` or `GPSSpeed`.
- **Depending on a deferred function** (§9) for rendered data.

**Validate by round-tripping**

The authoritative check is: does it parse through `Workbook.fromJson` and
re-serialize cleanly? The model is `app/test/data/default_workbook_test.dart`,
which loads the example, asserts its structure, and round-trips
`Workbook.fromJson(workbook.toJson())`. Note that a `charts`-form sheet
re-serializes as `blocks` — structurally identical, not byte-identical.

To validate your hand-edited file the same way, from `app/`:

1. Point a copy of that test at your path, or
2. Write a throwaway test doing
   `Workbook.fromJson(jsonDecode(File(path).readAsStringSync()))` and assert on
   `workbook.name`, the worksheet names/kinds, `worksheet.charts` (the chart
   blocks), and `mathChannels.map((c) => c.name)`.

Then `flutter test test/data/<your_test>.dart`.

If `Workbook.fromJson` throws `WorkbookParseException`, your JSON is malformed
or a required key (`workbook_id`, `name`, `created_at_ms`, `updated_at_ms`) is
missing or the wrong type. A `sessionSheet` missing its `gpsMap` is auto-repaired
on read (a map is prepended), so don't rely on its absence.
