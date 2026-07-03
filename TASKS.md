# IDL0 Build Tasks

Read CLAUDE.md and IDL0_SPEC.md before starting any task.
Complete tasks in order — each layer depends on the one below it.
Mark tasks done only when `flutter test` passes and coverage targets are met.

---

## Active / awaiting hardware verification

- [ ] **Session-file `fsync` durability (2026-06-29)** — firmware now `fsync`s in
      `idl0_sd_flush`, so the FAT directory-entry size is committed at the ~1 Hz
      flush cadence — fixing the power-loss "file frozen at the GPS-rename size"
      corruption (see CHANGELOG; recovered the 2026-06-28 session via `idl-rs
      recover`). Code + SPEC §5.3/§10.2 landed. **Awaiting field power-cut
      verification:** log a session, pull power mid-ride, confirm the downloaded
      file spans the full ride (not frozen at ~48 KB) and the IMU `ovr` counters
      stay 0 across the run. Build/flash is on hardware (user-run).

- [ ] **Suspension-kinematics estimator (2026-06-23)** — offline, geometry-constrained
      IMU travel/velocity + steering estimator. **M0** (spec),
      **M1** (SO(3) primitives + traits + `MtbState`), and the **M2a engine** **done**:
      `estimate/{geometry,schema,detect,process,measurements,iekf,ledger,orient,run}`
      — the IEKF runs end-to-end via `run(input, geometry, config) -> StateEstimate`
      (+ `EstimatorInput::from_lookup` adapter), every process/measurement Jacobian
      FD-verified at 1e-6, validated on synthetic cases **and on real logs** (833 Hz/
      3 IMUs): static-flat log → velocity ≈ 0, attitude stable, biases recovered,
      travel at topout; **200 s jump session** → fitting the unsprung mounts (gravity
      →+Z via the coarse-pick + `refine_mount_tilt`) + airborne **topout zeroing**
      collapses between-jumps travel divergence from **169.8 mm → 0.3 mm**, travel
      physical (0–113 mm). Travel seeds at topout; sag is a loose coasting-only nudge;
      dynamic sag is a derived output. **App surface landed (2026-06-24):** the
      coarse-pick + auto-refine is now baked into `reference_bike()` + `run()`
      (`orient::refine_mount_from_window`, per-session static-window tilt fit — no
      longer test-only); a bridge fn `estimate_suspension_into_store(handle, config)`
      stores front/rear travel(mm)+velocity(mm/s) into the handle math store; and the
      Analyze tab has a **"Run estimator"** trigger + `suspensionEstimatorProvider`
      that runs it, surfaces the outputs in the channel picker, and refreshes charts
      on re-run for hot-reload **filter tuning**. Full `idl-rs` suite green (489).
      **Remaining for M2a:** (a) the **named-by-quantity math fns** — `wheel_velocity()`/
      `wheel_travel()`/`chassis_attitude()` + `quality()` in `math/eval.rs` (the
      interim app surface stores plain channels, not the virtual-sensor functions);
      (b) the per-session **`.idl0w` geometry context** (geometry is still the engine
      reference bike; the per-session geometry-store decision is **deferred per the
      user** — no `.idl0w` persistence yet); (c) **hot-loop optimization** — `run()` is
      ~9.4 s/run in release (200 k samples) on the naive `DMatrix` IEKF; the static-
      `SMatrix<24,24>` rewrite (~10× headroom) **regresses the DOF-generic
      `ProcessModel`/`ErrorState` trait surface the M5 batch smoother reuses**, so it
      needs an architectural decision (full static via const-generic DOF vs design-
      respecting scratch-buffer alloc-reduction); (d) the **off-axis diff-accel** +
      **unsprung-link gyro-rate** factors; (e) the **bottomout reference** + a more
      robust topout/bottomout event detector (airborne topout shipped); (f) per-bike
      **lever-arm** authoring (now grounded to the 4-bar axle X + Z≈−0.4 in
      `reference_bike`; correcting front X was only ~4 mm and rear Z is empirically
      irrelevant, low-priority); (g) the **IDL0_SPEC §-new contract section**.
      Then → M2b steering → M3 real-log tuning → M4 app surface → M5 batch smoother.
      Branch `worktree-suspension-estimator`.
      **M2c landed (2026-07-03, on main — see CHANGELOG):** flat-ground-**calibrated
      mounts** baked into `reference_bike()` (per-session refinement now opt-in
      `refine_mounts`, target fixed from chassis +Z → the mounted IMU0 window-mean up;
      both unsprung coarse picks were 180°-yawed — disambiguated on a riding log);
      **GPS-velocity aiding wired** (horizontal 2-DOF factor, per-fix event times,
      `gps_latency_s` + `gps_min_speed_mps`, closes audit F4); **wheel-chain RTS
      smoother** (`estimate/smooth.rs`, default on, replay-equivalence regression
      pins the 2-state ↔ 24-DOF decoupling). Follow-ups this raises: (h) re-tune
      the airborne/topout thresholds on real logs with the corrected mounts (the
      yaw fix changes the horizontal diff-accel the detector sees); (i) the M5
      full-state batch smoother still owns attitude/velocity/bias smoothing —
      the RTS pass covers only the wheel chains.

- [ ] **IMU FIFO drop fixes — field verify (2026-06-16)** — firmware drain
      rewrite landed (SPI DMA burst, SD decouple, IMU prio 6, cap 256, 20 ms
      poll, monotonic clamp) + on-SD drain instrumentation. **User to build +
      flash + record a field A/B (battery vs USB-monitor).** Verify: (a) drops
      gone in `tools/imu_drop_analysis.py` on a new log; (b) read `idl0_debug.log`
      per-IMU `read_us`/`tot_us`/`cycle_max_us` to confirm the cycle fell well
      under the FIFO margin and to attribute any residual overhead (SPI per-txn
      vs SD contention). Then decide on the structural items below.
      **Deferred / structural:** (a) move IMU1/IMU2 off the shared I²C onto SPI
      at the planned ±64 g IMU swap (removes the bus asymmetry; ~42 % I²C util is
      the only thing standing between here and a comfortable 1600 Hz); (b) optional
      "accel-only" (gyro BDR=0) mode — halves load if gyro isn't needed; (c) check
      whether the `accel_z`-off-on-IMU1/2 channel mask (`0x3BEFF`) is intentional.

## Completed
- [x] **In-app FIT export (Strava) with native lap splits (2026-06-23)** —
      session detail card **Export .fit** (GPS-gated, beside Create track):
      `export_fit_to_vec` engine bridge → bytes → file-picker save, one FIT
      `lap` per detected lap (Strava shows them as splits — verified on Strava
      web). Exporter lap input slimmed to a 3-field `FitLap`; CLI maps detected
      laps to it. Desktop post-export drag-to-Strava grip + reveal-in-file-manager
      (reuses `revealInFileManager`). Filename `YYYY-MM-DD_<venue>.fit` (resolved
      venue, else local time). Rust + Dart helper tests pass; `flutter analyze`
      clean. SPEC §29.2 / §29.2.1.
      **Pending user check:** drag-into-Strava drop on Windows (`Formats.fileUri`
      of the saved file) — save/laps/reveal confirmed; if a browser rejects the
      drag, switch the drag payload to a virtual file (Save remains the fallback).
      **Follow-ups (deferred):**
      (a) **out-lap / pit-neutral lap classification** — `detect_laps` numbers the
      t=0→first-crossing segment as a normal flying lap and assumes sequential
      laps; reclassify the out lap and pit/neutral laps (engine + lap model;
      affects the in-app lap table *and* the FIT splits). Own brainstorm/design,
      spec-relevant (§12 / §14 / §17).
      (b) Strava **OAuth direct upload** + "Data and analysis from IDL0"
      description line (a `.fit` can't carry a Strava description) — needs the
      client-secret decision (embed for personal use vs. a tiny proxy for
      distribution).
      (c) **export hub** — `Export ▾` (CSV / LD) + Upload-to-Drive on a
      format-agnostic post-export affordance (the result-affordance shape is the
      growth point).
      (d) persisting the post-export affordance across restarts — considered
      (a `.idl0w` workspace field) and **declined**: not worth the schema churn.
- [x] **Shared Y-axis scale across chart types (2026-06-16)** — one
      `ChartSlot.yScale` (Linear / Log=signed symlog / Sqrt / Square) replaces
      per-chart `fftYScale` + `histogramLogCount` (auto-migrated), via a pure
      Dart transform (`y_scale.dart`) on the decimated display spots — no engine
      round-trip; inverse-formatted labels; cursors read real values. Applied to
      time-series / FFT / histogram-count / lap-progression; FFT + histogram keep
      their existing log rendering. One "Y scale" dropdown. 15 module tests +
      migration tests; `flutter analyze lib` clean. SPEC §26.12.
      **Follow-ups:** "nice" non-linear tick placement (decade ticks for Log);
      per-mode knobs (symlog linthresh, signed-power exponent) — both deferred.
      **(2026-06-24) Histogram count-axis scale control surfaced** — the chart
      already applied `yScale` but the properties dialog hid the Y-axis section
      for histograms (§26.10/§26.12 already specified it); the Lin/Log/Sqrt/Sq
      control is now rendered in the histogram section. **Deferred:** histogram
      **X-axis (value) scale.** The proper form is log/sqrt-spaced bin *edges*
      (re-bin in transformed space) computed in `idl-rs` — bar heights change —
      not a pure display warp; needs an engine change + a new `ChartSlot.xScale`
      field. Decided over a cheaper Dart display-warp because equal-width bins
      warped on a non-linear axis misrepresent density.
- [x] **Modular tables — formula half (2026-06-15)** — first-class
      `WorksheetBlock` (chart | table) + `placement` (only `inFlow` honoured;
      charts-before-tables invariant; legacy `charts`→blocks migration). Tables
      reuse the `idl-rs` math evaluator: `{cell}` namespace (`{A1}`/`{name}`/
      `{name[]}`) → `Ast::CellRef` resolved via `ChannelLookup::lookup_cell`
      (default none = firewall), `evaluate_scalar`, and arity-dispatched
      channel→scalar aggregates (`mean`/`max`/`min`/`sum`/`std`/`rms`/`median`/
      `p`/`first`/`last`/`count`). Engine `table::evaluate_table` (topo-sort +
      cycle detection + per-row lap-window slicing); serde-portable `TableModel`
      in the `.idl0wb`. Per-lap summary preset + `TableWidget` (inline cell
      errors, editable formulas/templates). Rust 4 table tests + math/aggregate
      tests; Dart model/preset/migration tests; `flutter analyze` clean. SPEC
      §26.11/§19.
      **Follow-ups (deferred):** (a) **Plan 2** — flexible layout rendering
      (honour `sideBySide` / `overlay` placement; "anything beside/over anything"
      per the design's §7); (b) other §8 deferred items — multi-session rows,
      subsume the bespoke `lapTable` chart into a table preset, more presets,
      range arithmetic in cells; (c) **CLI** (design §9a) — teach
      `idl-rs/workbook` to surface table blocks out of the worksheet tree, then
      an `idl-rs table <session>.idl0 <workbook>.idl0wb [--csv|--json]`
      subcommand beside `fit`/`export`/`math`, reusing `evaluate_table` and the
      engine's `detect_laps` for row windows.
- [x] **Vector & rotation math primitives (2026-06-15)** — `idl-rs`
      `math::vector`: internal `Vec3` value + `vec`/`vx`/`vy`/`vz`/`vadd`/`vsub`/
      `vscale`/`cross`/`dot`/`norm`/`normalize`/`angle` and inline `rotate_mat`/
      `rotate_axis`/`rotate_euler` (nalgebra-backed). Top-level vectors reduce
      to a scalar channel; reuses existing elemwise broadcasting; no FRB change.
      TDD, frame-at-axle worked example as integration test. SPEC §19.
      Dart-side function registry/help entries land with the maths-editor agent
      (out of this lane). Follow-ons: first-class matrix type, then the sci-rs
      `NotImplemented` backlog (`spectrogram`/`hilbert`/`correlate`/`convolve`/
      `resample`/`sosfilt`/`median`) — design each with the user first.
- [x] **Pipeline memory/perf remediation (2026-06-10)** — post-migration audit
      fixes: dev-build Rust at opt-level 3; deterministic `SessionHandle`
      dispose; path-based import/scan/WiFi parsing (no byte copies); raw-fold
      `decimate_tile` + tier ceiling 6 + 30 Hz hover throttle + coalesced tile
      repaints; `eval_math_into_store` / `slice_by_time_into_store`
      (metadata-only FFI, fingerprint-keyed re-eval, tile-based preview);
      overlay handle shared via Arc (no deep clone); lazy `Time` (ramp) /
      `Distance` (GPS-rate interp) columns; byte-budgeted handle residency
      (engine `session_resident_bytes`, 1 GiB warm default).
      SPEC §15.3/§19/§22. Follow-ups queued below (audit items out of scope).
- [x] **FIT export from the `idl-rs` CLI (`idl-rs fit`) (2026-06-09)** — GPS +
      speed + altitude + heart rate → Garmin FIT activity for Strava / Garmin
      Connect; optional `--track` lap splits; `--sport` (default cycling).
      Pure-core `export/fit` encoder + `fitparser` round-trip test. SPEC §29.2,
      §29.5. Follow-up: UI entry point (Data tab export action) reusing
      `export::write_fit`.
- [x] **Project scaffold** — create Flutter project structure, install Dart dependencies (pubspec.yaml), initialize Rust crate in `app/rust/` with flutter_rust_bridge, run `flutter_rust_bridge_codegen generate`, verify `flutter test` and `cargo test` both pass clean
- [x] **Filters** — `app/rust/src/filters.rs`: wrap sci-rs `butter_dyn` + `sosfiltfilt_dyn` for high-pass and low-pass. `cargo test filters` passes (2/2).
- [x] **Integration** — `app/rust/src/integration.rs`: trapezoidal integration (cumtrapz equivalent). `cargo test integration` passes (1/1).
- [x] **FFT** — `app/rust/src/fft.rs`: rustfft with Hann, Hamming, rectangular windows, one-sided magnitude spectrum. `cargo test fft` passes (1/1).
- [x] **Calibration math** — `app/rust/src/calibration.rs`: bias capture (mean of N samples), rotation matrix from gravity via nalgebra Rotation3. `cargo test calibration` passes (3/3).
- [x] **Rotation** — `app/rust/src/rotation.rs`: nalgebra Matrix3 × Vector3 multiply. `cargo test rotation` passes (3/3). Full crate: 10/10.
- [x] **flutter_rust_bridge bindings** — all functions callable from Dart. `flutter test` passes 9/9 (8 bridge integration tests + 1 widget smoke test).
- [x] **Data tab lap cache (2026-06-02)** — cache detected laps on `TrackVisit`
      (`.idl0w` schema v7); import/rescan compute laps via the shared
      `detectLapsForVisit` helper; the Data tab aggregates, lap-time facet, and
      "compare with" picker read the cache so opening the tab never parses a
      session. Pre-v7 workspaces repopulate on "Rescan visits". SPEC §15, §17, §24.

---

## Current

- [ ] **Dogfooding push (2026-06-12)** — the app is finally usable; the user is
      starting to actually ride with it. Big spec-first infra
      (**active-config mirror**, **WiFi link lifecycle P3+**) is **deprioritised**
      in favour of making analysis features they'll use day-to-day. Priorities,
      in order:
      - [x] **Workbook permanence fix (2026-06-12)** — the default "Workbook 1"
            was an in-memory phantom that never persisted, so it reset on every
            restart. `WorkbookNotifier.build()` now **seeds + persists the
            default eagerly at load** (offline immediately; signed-in deferred to
            post-sync so it can't race a Drive download), so persistence no
            longer depends on an edit completing before restart;
            `WorkspaceNotifier._persistActiveWorkbook` materializes-on-first-edit
            as a fallback. New-workbook is now a **blank single sheet**
            (`Workbook.createBlank`) per the user's call; the default
            (`Workbook.createDefault` = Session + Charts) is the seed/duplicate
            source. Regression tests at both layers. CHANGELOG.
      - [~] **Build a strong default workbook** (own fresh-context effort) — curate
            what a fresh install opens to, editing the **`.idl0wb` file directly**
            in a loop (then bake into `Workbook.createDefault`). Order: lap times
            (+ deltas) → bike → suspension → ride frequencies (FFT) → rider inputs.
            See [[project_default_workbook_curation]]. Progress:
            - [x] **First-cut artifact (2026-06-12)** — `app/dev/default_workbook.idl0wb`
                  (5 sheets: Session/Bike/Suspension/Frequencies/Rider inputs, baked
                  Fork/Shock velocity math) + parse/round-trip test (8/8). Channel
                  ids verified against the Rust parser.
            - [x] **Authoring skill (2026-06-12)** — `skills/idl0-workbook-authoring/SKILL.md`:
                  teaches an agent to hand-author `.idl0wb` (workbooks + math
                  channels) with no API — the "skill, not an API" plan. Documents
                  the math-by-name + hex-vs-ARGB gotchas.
            - [x] **Reload-from-file button (2026-06-12)** — workbook menu "Reload
                  from file" re-imports the last-used `.idl0wb` (replace policy) +
                  activates it; one tap after the first pick (path remembered,
                  shared with Import…). The edit-file → reload loop, pairs with the
                  authoring skill. **User to verify live.**
            - [ ] **Iterate the layout** (fresh session, interactive) → then bake the
                  dialled-in version into `Workbook.createDefault`.
      - [~] **Chip-driven math editor (2026-06-12)** — Maths tab gains a
            **Build / Text** toggle; Build is a chip editor: drag/tap colour-coded
            chips (channels / functions-by-category / operators / values) into
            labelled function argument slots, with a **live inferred output unit**
            and IDE-style hover/tap definition cards (signature + More docs).
            Serialises to the same engine text as Text mode (lossless toggle).
            The Dart-side unit inference is a prototype — real dimensional
            propagation belongs in `idl-rs` (follow-up). **User to verify live.**
      - [~] **Math-channel store consolidation (2026-06-12)** — the **workbook is
            the single source of truth** for math channels + constants; the global
            SQLite store (`idl0_math.db`) is retired; channel **identity is the
            name** (charts/expressions/`idl-rs` all reference by name). Recursive
            dependency resolution stays Rust-side (`resolve.rs`), unchanged — only
            the `defs` source moves to the active workbook.
            - [x] **Rename-everywhere (IDE-style) (2026-06-15)** — renaming a
                  math channel (metadata Name field, committed on Enter/blur)
                  rewrites every other workbook expression that references
                  `[OldName]` → `[NewName]` via `MathChannelNotifier.renameChannel`.
                  Chart slots reference channels by their **stable id**, so they
                  survive a rename with no propagation needed. Provider test +
                  analyze clean.
            - [x] **Universal constants in `idl-rs` (2026-06-15)** — `pi`, `tau`,
                  `e`, and `g` (9.80665 m/s²) are recognised as bare identifiers
                  in any expression, resolved to a literal at parse time
                  (`idl-rs` `math::parse`) — no store, always available, portable.
                  Channel refs are bracketed (`[g]`) so there's no collision.
                  `cargo test parse` green; SPEC §19 documents them.
      - [x] **IMU drop reconciliation (idl-rs parser) — blocks cross-IMU math.**
            (Landed 2026-06-15.) Cross-IMU elemwise (`[Fork accel] - [Frame accel]`) errors today
            ("different sample rates", 816 vs 791 Hz) because `compute_imu_rates`
            turns dropped samples into a fake per-IMU average. Firmware
            back-counts per-sample `timestamp_us` from each FIFO drain at the
            nominal ODR period (SPEC §5.5), so all IMUs share one true rate and
            the timestamps' only real signal is *where samples dropped*. Fix:
            assign the single nominal rate, reconcile each IMU onto a shared grid
            (detect drops from the timestamp jumps, linear-fill the holes,
            pad-align the ~0.1 s starts), record a sparse gap list. Lean +
            drop-rate-proportional (no-drop logs are a no-op). Non-goals:
            per-sample time arrays, drift correction, FFT gap-exclusion / UI
            shading (record gaps, ship no consumers yet). Empirically validated
            on a real 7.7 MB log (2–5% drops, pervasive interior, zero clock
            drift).
            SPEC §15 (spec-during on landing). Unblocks the suspension velocity/
            travel channels in the default workbook.
      - [ ] **Analysis math — frame/axle kinematics (idl-rs).** Matrix math to
            synthesise the frame's location at the two axle paths from the single
            central IMU (rigid-body transform: IMU pose + lever arms → axle
            positions). Pure `idl-rs` (nalgebra), per the thin-Dart rule. Feeds:
            - [ ] **Front/rear suspension velocity + position** (integrate axle-
                  relative motion; the existing `Fork/Shock velocity` +
                  `Suspension travel` templates are the 1-D seed).
            - [ ] **Steering angle → understeer/oversteer angle** — synthesise
                  with GPS speed + wheelbase (yaw-rate vs. speed/wheelbase gives
                  the slip/understeer angle).
      - [x] **Chart-creation UI redesign (2026-06-15)** — precursor to the new
            chart types. A single chart-type catalog (`chart_type_catalog.dart`:
            glyph + label + blurb per type). Mobile: Add-Chart picker rows gain
            the type glyph + blurb. Desktop (`> 700` dp): the picker merges into
            `ChartPropertiesDialog` as a left **type rail** — selecting a type
            converts the slot in place (channels preserved), and "Add chart"
            opens the merged panel directly (`isNew`; Cancel discards). Chart
            type is now editable after creation on desktop. SPEC §26.9; analyze
            clean. **User to verify live.**
      - [~] **New analysis widget types** — each a new `ChartType` + renderer
            behind the existing workbook/chart engine (one
            `chart_type_catalog.dart` entry + renderer + property section).
            - [x] **Histogram (2026-06-15)** — `ChartType.histogram`: value
                  distribution as equal-width bars. New `idl-rs`
                  `channel_histogram` engine fn (samples never cross FFI); slot
                  options bin count / symmetric range / log count axis; Y = each
                  series' % of samples. **Overlays** every (session × channel)
                  series over a shared range (front/rear across main + N overlay
                  sessions), staircase outlines, colour-coded legend; optional
                  `Smooth` fitted polyline through bin centres. SPEC §26.10.
                  **User to verify live.**
                  - [ ] **Numeric summary readout** — compute distribution stats
                        in `idl-rs` from the samples (mean, median, std/RMS,
                        p5/p50/p95, % compression vs rebound, peak/mode) and show
                        a compact per-series readout. The fitted polyline is not
                        needed for these — they come straight from the samples.
                  - [ ] **Window by zoom / lap** — shared follow-up with the FFT
                        chart (both compute over the whole session in v1).
                  - [ ] **Per-series labels disambiguate session** — overlaid
                        series currently label by channel id only (like the FFT
                        chart); when the same channel spans main + overlay, add a
                        session marker to the legend.
            - [ ] **GPS colour-channel overlay** — colour the GPS map track by a
                  channel value (speed, travel…) with a legend. Reuses the GPS
                  map renderer; likely a `gpsMap` option, not a new type.
            - [ ] **Spectrogram** — rolling short-FFT heatmap (time × frequency ×
                  magnitude). Needs the `idl-rs` STFT port (in progress) + a
                  custom heatmap painter. New `ChartType.spectrogram`.

- [ ] **Mobile UI redesign (2026-06-11)** — design approved. Take the
      big ideas from the phone prototype, do the final design ourselves, lose
      nothing. Tight hot-reload loop, not a rigid spec→plan→execute cycle.
      Phases:
      - [ ] **P1 — brand tokens + `plexSans()`** (`brandFgFaint`,
            `brandControlRadiusSoft=7`). Additive; screens unchanged.
      - [ ] **P2 — `QuietButton` filled/large variants + theme radius split;
            deliver the CTA re-triage table.**
      - [ ] **P3 — new brand primitives** (BrandSheet, SetupStepper, DenseRow,
            Chip, SegmentedControl, StatusDropdownTrigger, IconBtn/ToolGroup,
            tristate CheckBox, pulsing StatusDot).
      - [ ] **P4 — global header + nav restyle + OTA pending-verify banner.**
      - [x] **P5 — Settings re-skin (2026-06-11)** brand layer + **desktop
            two-pane** (≥720 dp section-list + detail; narrow single-scroll);
            firmware buttons → QuietButton CTA; Drive toggles brand-tinted.
            All 28 controls preserved; analyze clean, firmware test 8/8.
      - [x] **P6 — Maths re-skin (2026-06-11)** brand chrome; narrow Insert
            palette → BrandSegmented + IndexedStack (swipe dropped);
            ColorGridPicker kept; existing controls only. All 27 controls
            preserved; analyze clean.
      - [x] **P7 — Device A (2026-06-11)** hero card (No-device/Ready/Recording)
            + live RX/TX activity chips + pulsing recording timer. **Sensor
            health (HR/GPS/SD/IMU/battery) is now a non-blocking warning, not a
            recording gate** — HR-up gate removed; recording starts immediately
            (SPEC §23.9/§23.10). Refusals preserved via the always-mounted Mode
            picker; `ConnectionPanel` is now display-only in a collapsible.
            All mode suites green (24/24). Follow-up **done (2026-06-12)**:
            removed the unused `AwaitHr` / HR-wait-pill machinery — see the
            Cleanup entry below.
      - [x] **P8 — Device B (2026-06-12)** Channels table brand pass — mono
            kicker header + `plexMono` name→rate/unit→scale/offset hierarchy over
            the shared column grid, **responsive** below 560 dp (compact
            two-liner: name owns line 1, calibration formula on a dim line 2 —
            fixes the phone-width name clip), green `brandGood` On checkbox.
            Per-source dialogs (IMU/GPS/wheel/HRM/analog/digital) + HRM scan +
            Add-channel sheet hand-finished via a shared `dialog_chrome.dart`
            (mono kicker titles/sections, `QuietButton` actions, green enable
            toggles). Presentation only; channels_table 6/6. (Read-only IMU/HRM
            row info stubs left theme-branded — they live in the data layer.)
      - [~] **P9 — Device C (device picker + auto-connect, 2026-06-11)** hero
            device dropdown (`StatusDropdownTrigger`) → picker sheet:
            scan→connect-nearest, disconnect, "This phone" (soon). **Nearest
            IDL0 auto-connects once on app open** (headphones model;
            `autoConnectControllerProvider`, watched in the shell). Replaces the
            old connect/disconnect buttons. Still deferred: known-only
            auto-connect + listing every nearby unit in the dropdown (needs a
            live scan-list + paired-list persistence, §23.8), multi-unit switch,
            phone-GPS mode, Transfer card.
      - [ ] **P10 — shared selection store** (XOR, cross-session laps, adapter).
      - [x] **P11 — Data tab (2026-06-12)** full brand pass: Sessions table +
            field/direction sort (day-groups follow the sort); venue heading
            derived from matched tracks; **rescan handle-pin fix** (pin
            `keepAlive` before the parse await) + per-row scan spinner +
            coalesced refresh; session detail card + **GPS map preview**;
            **create-track-in-editor** flow (name/venue inline, responsive on
            mobile); filter rail; Tracks table + detail panel. SPEC §24.
            Follow-up **done (2026-06-12)**: the Tracks table is now **grouped
            by venue** — collapsible `brandSurface2` venue sections (name + `·
            count`, expanded by default), mirroring the Sessions Date›Venue tree;
            grouping preserves the active sort via first-appearance order. SPEC
            §24 updated (spec-during). Presentation only; `dart analyze` clean.
      - [x] **P12 — Analyze (2026-06-12)** full brand pass — pure presentation
            behind the existing `selectionProvider` / workspace / chart engine
            (shared selection store already in place; N-lap variance still
            deferred). Lap-table `DataTable` re-themed (mono headers + tabular
            data, `brandGood` best-lap row, `brandGood`/`brandAccent` deltas,
            brand M/O checkboxes, `brandHivis` star, `brandInfo` reference flag);
            a shared `brandChartPalette` across time-series / FFT / GPS-map /
            lap-progression with mono axis labels + `brandRule` gridlines, brand
            cursors, and brand GPS-map gates/discs/controls; workbook bar +
            dropdown, chart-workspace chrome, and every Analyze dialog/modal
            re-skinned (`QuietButton` actions, brand inputs/checkboxes/switches).
            Tests updated for the new copy + uppercased labels; `dart analyze`
            clean. No spec change needed (presentation only within §26).
      - [x] **Cleanup — dead redesign scaffolding removed (2026-06-12).**
            Deleted the now-unused HR-gate machinery left over from P7 (the
            `AwaitHr` step + `_hrOk`, the `StepContext` skip half, the
            `waitingForHr` phase, `ModeTransition.hrWaitElapsed`,
            `TimedOutWaitingForHr`, `ModeController.skipHrWait`, and the
            `_HrWaitPill` substate + its tests) — recording hasn't gated on HR
            since P7. Also removed the debug **Brand Gallery** tab (the
            `kDebugMode` 6th nav destination + `brand_gallery.dart`). Mode suites
            green (mode_step/mode_picker/mode_controller); no spec change needed.

- [x] **Maths built-in channels — code↔spec divergence resolved (2026-06-12).**
      User chose **editable built-ins**, so this was a spec fix only (no code
      change): §25 now describes the 5 tutorial channels as a one-shot per-install
      seed of ordinary editable/duplicatable/deletable user channels (the
      `builtin:` id prefix only namespaces ids, it does not lock them), matching
      the shipped behaviour. The old "not user-deletable, not editable" language
      is gone.

- [ ] **N-lap variance analysis (idl-rs) — multi-lap comparison (2026-06-11,
      deferred by user)** — replace today's **2-lap Main/Overlay** model
      (`variance_time`/`variance_dist` vs a main/overlay reference, §25) with a
      **N-lap** comparison. User goal: "see any/all conditions that make my
      lap-time deltas increase/decrease, mostly **relative to the fastest
      lap**" (e.g. 6 laps of a GNCC). Shape: the shared selection store already
      holds a cross-session lap *set* (the N laps); the engine aligns them to a
      common **track distance axis** and computes per-position statistics
      (mean / std / min-max envelope) and/or each-lap **delta vs a
      reference/fastest** lap. **Compute lives in `idl-rs`** (sci-rs stats), per
      the thin-Dart/portable-core rule. Constraint: only aligns laps of the
      **same track**. Rationalises the M/O/★/reference role layer (design doc §7).
      User tried 1:N before and found it complicated — parked as a TODO; UI
      decisions are being made forward-compatible now.

- [ ] **Active-config mirror — device-loaded config + BLE config transport
      (2026-06-11, design resolved, NOT started)** — spec-first. Turn the Device
      screen into a live mirror of the logger's loaded config: view current
      settings, see outdated/foreign at a glance, pull→inspect→tweak→push back,
      swap profiles — all on the always-on BLE control plane.
      Resolved design (this session):
      - **Config identity.** The pushed config carries the profile **name** + an
        app-managed **`uuid`** (random v4, regenerated on any *logger-setting*
        change, **not** on rename; sibling of read-only `device_id`/
        `config_version`). Library `BikeProfile` already has `profileId`/
        `profileName`; the push (which today strips app metadata) must now
        include name + uuid so the firmware can broadcast them.
      - **Status broadcast (BLE).** Firmware emits two §7.3 status lines — config
        name (capped ~31 chars) + uuid. App classification precedence: uuid
        matches a library profile's current uuid → **Current ✓**; else name
        matches a library profile → **Outdated ⚠** (Push to update); else
        **Foreign**; empty → **No config**. uuid-before-name keeps rename safe.
      - **Transport = BLE, not WiFi.** Config push **and** pull move to a new
        chunked GATT config characteristic (write=upload, read=pull; framing:
        begin-with-total-length → offset writes over Write-With-Response → end →
        validate JSON → write `idl0_config.json` → reboot-to-apply). Kills the
        BLE↔WiFi↔BLE mode-switch overhead for the most common write op; WiFi
        keeps only bulk session downloads + OTA. Push reboots
        (`reconnectAfterReboot`, existing); pull is read-only. Reverses the old
        "config via WiFi, not BLE" (§8) — that was convenience, not necessity;
        precedent: §7.6 ships calibration results over BLE.
      - **UI.** Device hero gains a loaded-config status row + Pull /
        Push-to-update actions; a pulled config lands in an editable working copy
        → push back and/or Save to library.
      **Firmware TODOs (user-owned):** (1) chunked config characteristic
      (upload + readback + reassembly + JSON write + reboot); (2) retain +
      broadcast name + uuid in §7.3 status.
      **App work:** re-point `BleService.pushConfig` to the BLE chunked write;
      add `pullConfig`; `DeviceState.loadedConfigName/Uuid` + pure reconciliation
      (degrades to "No config" while null); hero status row + actions;
      pulled-config working-copy flow.
      **Spec (do before code):** §6.1 retire `/config`; §7 new config
      characteristic + chunk protocol; §7.5 + §10.4 drop config from the
      WiFi-mode activity list; §8 + §23.6 push transport → BLE; §8 add `uuid` +
      name carriage + uuid lifecycle + classification; §23 hero status row + Pull.

- [ ] **WiFi link lifecycle redesign (2026-06-10)** — spec approved;
      SPEC §6/§7/§10.4/§23.9 revised. Implementation phases:
      - [x] **P1 — firmware control plane (2026-06-10):** `GET /ping`
            (identity + status, no SD access), `POST /handoff` (drop BLE),
            `POST /wifi_off` (exit WiFi mode, resume advertising), 5-min
            no-activity failsafe (streaming transfers count as activity).
            Hardware-verified except the failsafe timer itself (code-reviewed;
            self-announces on serial in normal use — confirm opportunistically).
      - [x] **P2 — Android platform layer (2026-06-10):** plugin → commands
            (`request`/`release`) + event stream (`available`/`lost`/
            `unavailable`), SSID-keyed; loopback proxy over
            `Network.socketFactory` replaces `bindProcessToNetwork`.
            Hardware-verified: proxied transfers + internet alive during
            transfer. Field fixes: IPv4 loopback pin, singleton binder
            (`wifiBinderProvider`), sync-list link gate (P4 stopgap).
      - [ ] **P3 — link reconciler + staleness model:** single-flight
            transition-table state machine (verify → handoff → heartbeat →
            relink/backoff), `DeviceState` last-known + provenance, mode
            transitions re-plumbed (HTTP exit + BLE-reconnect leg). Deletes
            `WifiBindController`, the `getFileList` warmup retry, TEMP debug
            prints. Old-firmware compatibility window (no `/ping` →
            reachability-only verify, no handoff). Rider: redesign the Device
            tab connection presentation — handoff must read as one continuous
            connection changing transport (BLE → WiFi), not as a disconnect;
            user wants a broader pass on this UI (brainstorm at P3 planning).
      - [ ] **P4 — ops gate + resume:** serialized link-gated `DeviceOps`
            facade (wait ≤15 s while converging, typed fail-fast otherwise);
            `bind`/`release` removed from the `WifiService` surface;
            `Range`-resume downloads with one auto-retry after relink.
      - [ ] **P5 — polish:** link-journal debug view, transition coverage
            meta-test hardening, remove the P3 compatibility window, final
            cleanup sweep.

- [ ] **Parser hot-loop perf fix — route by channel id, not name (2026-06-02)**
      — `ChannelAccumulator.push(name)` does a `HashMap<String>` (SipHash) lookup
      per sample, and the IMU path re-derives `(imu,axis)→name` to look up
      scale/offset by name — ~40M string-hashes for a 20M-sample session.
      Violates §5.2's "read the registry once, route by id" intent (the Dart
      original was masked by cached `String.hashCode`). Fix: resolve id→slot and
      id→scale/offset once, push by integer slot, intern names only at output.
      Byte-identical Session/Channel parity required. Root-caused via systematic
      debugging; see the design spec.

- [ ] **Efficient-pipeline master design — phase roadmap (2026-06-02)**
      — supersedes the H1–H5 handle-only roadmap.
      Seam-first, then parallel forks:
      - [x] **Phase 0 — freeze the `SessionHandle` API seam** (`channel_min_max`,
            `materialize_f64`, `slice_by_time` new; `decimated_tile` exists;
            `welch_tile`/`gps_track_tile` reserved). Real impls against current
            `f64` storage; no app-behavior change; FRB-bridged. Core 271/271 green
            (13 new). Done 2026-06-02.
      - [x] **Phase E — eviction (2026-06-02).** `sessionHandleProvider` →
            autoDispose + `HandleResidencyController` LRU (selected ∪ 8 warm);
            six handle-watching providers → autoDispose. Fixes season-scale OOM.
      - [x] **Phase D-drain (2026-06-03).** Analyze charts self-source every view
            from the handle by id; `SessionChannelData` → metadata (no samples);
            `channelDataProvider` deleted. `ChannelData` kept (GPX/`Session.channels`
            model). Subsumes H2–H4. Y-bounds → `channel_min_max`
            (`channelBoundsProvider`), event-driven X → `channel_sample_times`,
            FFT → new engine **`welch_channel`** (`fftSpectrumProvider`; spectrum
            computed Rust-side, samples never cross FFI), GPS map → `gps_track`
            (`gpsTrackProvider`; no `gps_track_tile` — full fix list suffices),
            lap-window slicing → `slice_by_time` + `add_channel`
            (`lapSlicedChannelProvider`), session-start → one-sample
            `materialize_f64` (`sessionStartMsProvider`). **Fixed a post-3c
            regression:** displayed math channels + lap slices were never written
            to the handle store, so they rendered empty in the Analyze viewport —
            the evaluator now `add_channel`s its result, and lap slices are
            materialized into the store, so both decimate by id like any channel.
            `welch_channel` wrapper lives in `session.rs` (shares the canonical
            `SessionHandle`). Core 283/283; `flutter analyze lib` clean (0 err/warn);
            touched tests analyze-clean (pre-existing DriveService-fake errors
            unrelated). Spec §15/§15.3/§26.
            **User runtime verification pending.**
      - [ ] **Compact-storage confidence follow-ups (Phase C).** (a) Golden-file
            parity harness: parse a real `.idl0` fixture and diff materialized
            output bit-for-bit pre/post compaction (current gate is synthetic
            buffers). (b) Formal coverage number for `column.rs` via a working
            `cargo tarpaulin` run (Windows-flaky; needs Linux/CI). Both optional —
            belt-and-suspenders.
      - [ ] **Phase D-tab.** Data-tab laziness — list/duration/lapcount from SQLite
            catalog meta; no handle for unselected sessions.
      - [x] **Phase C — compact storage (2026-06-03).** `RawColumn` typed columns
            (I16/I32/F32 + scale/offset, or verbatim F64) behind the frozen seam;
            byte-identical, invisible to consumers. IMU + i16/i32/f32 registry
            channels compacted (8→2 B/sample for IMU); lazy f64 materialization.
            Core 283/283.

- [ ] **POST-REFACTOR: thorough data-pipeline efficiency + latent-bug audit**
      — after the idl-rs Rust-engine migration + handle-only cluster (H1–H5)
      complete, sweep the whole data path (parse → handle → decimation → math →
      laps → chart) for inefficiency and latent bugs. Triggered by the parser
      hot-loop find: there are likely other ported-from-Dart patterns that are
      cheap in Dart but costly in Rust, plus no throughput guards anywhere.

- [x] **Handle-only analyze layer — H1: engine lap recording-seconds (2026-06-02)**
      — `SessionHandle::epoch_ms_to_time_secs` (Rust); `Lap`/`Sector` carry
      `startTimeSecs`/`endTimeSecs` stamped by `detect_laps`; math lap-context +
      `availableChannelNamesProvider` cut off `channelDataProvider`
      (`sessionChannelMetaProvider` for meta). Deleted the Dart epoch→Time
      converters. Origin → back-filled `timestamp_utc_ms`; sectors now
      interpolate. `cargo test` 275+6 green; math/channel provider tests green
      (pre-existing bridge-dll lap_provider failures unchanged). Next: **H2**
      (chart lap windowing reads the new lap seconds; retires `_sliceChannel` /
      `_sessionStartMs` / `_fullDataRange`).

- [x] **Rust engine migration — Phase 0: workspace restructure + rebrand (2026-05-30)**
      — extracted Rust into the repo-root `/rust` cargo workspace: pure `idl-rs`
      engine (core), `idl-rs-bridge` FRB shim, `idl-rs-cli` (`idl-rs` binary).
      FRB codegen + Gradle `cargoBuildRust` repointed at `/rust/bridge`; old
      `app/rust` removed; product rebranded IDL0 → idl-rs (file format + magic
      unchanged). `cargo test` 58/58 green; `flutter analyze` clean for the
      migration. **Pending:** device smoke build (chart + FFT render) and the
      branch merge. Later phases (1: parser/model → Rust, 2: CLI export, …).

- [x] **Rust engine migration — Phase 1: parser cut-over (2026-05-31)** — app
      parses `.idl0` via the `idl-rs` engine through a `RustOpaque<SessionHandle>`
      (`channelDataProvider` + import/download/rescan drain the handle);
      `Time`/`Distance` synthesis moved into core; canonical `duration_ms`;
      Dart `BinaryParser` (+ its tests + `tool/dump_idl0.dart`) deleted after a
      Rust-suite + FFI golden parity gate. `cargo test` 118/0; app `flutter
      analyze` clean (8 pre-existing DriveService-fake errors, unrelated); manual
      Windows run on a real file OK.
      **Follow-ups:** (a) confirm the math-channel-rename lag is pre-existing —
      the chart re-ingest/decimate path is unchanged by this cut-over; (b)
      chart-path bridge-shrink + `ingest_channel` retirement deferred to Phase 3
      (clean once math-channel results are Rust-owned); (c) web build unsupported
      until WASM bindings (Phase 6).

- [x] **Rust engine migration — Phase 2: CLI export (2026-06-01)** — `idl-rs
      export <file.idl0> [-o OUT] [--format csv|json] [--channel NAME]...` writes
      the engine's channel set (raw + synthesized `Time`/`Distance`). CSV is
      long/tidy (`channel,time_s,value`); JSON is nested + lossless. Serialization
      lives in the `idl-rs` core (`export` module — pure, streaming) so CLI/app/
      future-bindings share it; `info`/`channels` now read via `SessionHandle`.
      `cargo test` green (16 new export tests + 4 CLI tests). Parquet deferred.
      **Follow-up:** Parquet export (`--format parquet`) — revisit alongside
      Phase 6 Python/WASM when a concrete columnar consumer exists.

- [x] **Rust engine migration — Phase 4a: lap detection (2026-06-01)** —
      moved the lap-detection algorithm into a pure `idl_rs::laps` module
      (`detect_laps` reads `GPS_*` from the retained handle, takes the bound
      Track's gates/sector-gates/neutral-zones as input, optional `TrackVisit`
      window; circuit + point-to-point + sectors + neutral-zone subtraction
      port verbatim). The app's sole detection caller `visitLapsProvider` cut
      over via `lap_detection_bridge` mappers; deleted the Dart `LapDetector`
      and its test suite (cases ported to `laps::detect`). Track config models +
      `buildGpsTrack` stay Dart for the matcher (4b). `cargo test -p idl-rs`
      (246) green; bridge builds; `flutter analyze` clean (save pre-existing
      DriveService-mock errors). Spec §17.5/§17.6, roadmap, design_rationale
      updated.
      **Remaining Phase 4:** 4b track matching + visit detection. No CLI yet
      (headless gate source = Phase 5; GUI authors tracks, CLI consumes).

- [x] **Rust engine migration — Phase 4b: track matching (2026-06-01)** —
      moved multi-track visit detection into a pure `idl_rs::tracks` module
      (`detect_visits` reads session GPS from the handle, matches each Track's
      reference polyline in a flat-earth metric frame, returns deterministic
      `VisitWindow`s; tuning defaults live in `VisitParams::default()`). Promoted
      `GpsFix` + `build_gps_track` to a shared `idl_rs::gps` module; exposed
      `gps_track` for Track authoring + the ghost-lap accumulator. App cut over
      via `track_matching_bridge` (mints `visitId`); deleted the Dart
      `TrackMatcher`, `PolylineGeometry`, and `buildGpsTrack` (parity-gated —
      cases ported to `tracks::{detect,geometry}`) — **no Dart GPS-fix builder
      survives**. `track_projection::Projector` left untouched. `cargo test -p
      idl-rs` (262) green; bridge + CLI build; `flutter analyze` clean save the
      pre-existing DriveService-mock errors; `flutter test` 683 pass (13
      failures all pre-existing `chart_workspace_test` bridge-dll timeouts).
      SPEC §17.1/§17.3 + roadmap §8 updated. **Phase 4 complete.**

- [x] **Rust engine migration — Phase 5b: track artifact + CLI (2026-06-02)** —
      new `.idl0t` portable Track file (one Track per file = `Track.toJson` + a
      version wrapper); engine `track_artifact` module reads it into a domain
      `Track` via a new shared `config` versioned-JSON reader, which also
      retrofits `workbook` (deleted its bespoke `WorkbookError`). CLI gains
      `laps` + `visits` (text / `--format json`) over a `.idl0t`; lap-aware CLI
      `math` stays deferred. App exports/imports `.idl0t` (import prompts on a
      `trackId` collision: update-in-place vs new copy). No bridge —
      `detect_laps`/`detect_visits` already bridged. `cargo test -p idl-rs` (270)
      green; CLI builds; `flutter analyze` clean save the pre-existing
      DriveService-mock errors; new `track_artifact_io` round-trip test passes.
      **`.idl0w` reclassified as app state (stays Dart).** SPEC §17b + §29.6 +
      roadmap §8 updated. **Remaining Phase 5:** 5a GPX import. The drop-the-`0`
      extension rename is its own later spec-first cycle.

- [x] **Rust engine migration — Phase 3c: chart-path `ingest_channel` retirement (2026-06-01)** —
      chart tiles decimate directly from the retained `SessionHandle`
      (`SessionHandle::decimate_tile` backed by a shared `with_channel_samples`
      find path that `lookup` was refactored onto). Deleted the process-global
      `chart_decimation` sample registry and `ingest_channel`/`release_channel`/
      `release_session`/`sample_at` (+ their bridge wrappers); kept the pure
      `decimate_tile_pure`/`decimate_channel`/`empty_tile`. The chart passes the
      handle to `decimateTile` and no longer ingests; `selection_provider` drops
      `releaseSession` (keeps the tile-cache `invalidateSession`). A session's
      samples now live in exactly one place — the engine. `SessionHandle`'s
      generated Dart decl relocated to `chart_decimation.dart` (codegen gotcha);
      consumers' `rust` imports adjusted. `cargo test -p idl-rs` green; bridge +
      CLI build; `flutter analyze` clean (save pre-existing DriveService-mock
      errors). Spec §15.3/§26.8, roadmap §8, tile-decimation design updated.
      **Phase 3 complete** (3a + 3b + 3c).

- [x] **Rust engine migration — Phase 3b: headless workbooks (2026-06-01)** —
      `idl-rs math <file>.idl0 --workbook <wb>.idl0wb` evaluates a portable
      workbook's math channels against a session and exports the derived channels
      (CSV/JSON; `--include-base`, `--channel`). Engine gained the `workbook`
      module (`.idl0wb` reader — `math_channels` only — + `apply_workbook`), the
      math **dependency resolver** (`math::resolve`, ported from Dart), and
      `export::write_channels` (explicit channel slice, so derived channels
      behind the math-store lock can be emitted). App cut over to the
      `resolve_math_dependencies` bridge fn; Dart `_resolveDependenciesIntoHandle`
      deleted (no two live implementations). Lap-aware functions reported skipped
      until lap detection (Phase 4). App file-picker I/O + Drive sync were already
      shipped (portable-workbooks), so no app UX change. `cargo test -p idl-rs`
      (233) + `-p idl-rs-cli` (6) green; bridge builds; `flutter analyze` clean
      (save pre-existing DriveService-mock errors). Spec §19/§29, roadmap §8,
      design_rationale updated.
      **Resolves Phase 3a follow-ups (a)** resolver→core **and (c)** exporter
      includes derived channels. **Remaining:** (b) the 7 NotImplemented stubs.
      (3c shipped — see the Phase 3c entry above; Phase 3 is complete.)

- [x] **Rust engine migration — Phase 3a: math evaluator port (2026-06-01)** —
      moved the math-channel expression engine (tokenizer, parser, evaluator,
      value types, full live function set incl. `variance_time`/`variance_dist`)
      into the `idl-rs` core `math` module; app evaluates via `eval_math`. The
      `SessionHandle` is now retained for the session lifetime with an
      interior-mutable math-channel store written via `add_channel`; the Dart
      resolver writes resolved dependencies back without re-marshalling samples;
      cross-session variance crosses the overlay as a second handle. Deleted the
      1,840-line Dart `MathChannelEvaluator` + `DspAdapter` + its test (eval
      parity ported to the Rust suite — `idl_rs::math` units + `math::tests_parity`).
      `cargo test -p idl-rs` 213+ green; `flutter analyze` clean (save pre-existing
      DriveService-mock errors); the eval-provider test group is skipped (bridge
      dll not loaded under `flutter test`). Spec §15/§19/§25, CLAUDE.md, roadmap §8
      updated.
      Manual `flutter run` confirmed math channels render identically (2026-06-01).
      **Follow-ups:** (a) ✓ done in Phase 3b — dependency resolver moved into
      `idl-rs` (`math::resolve`); (b) implement the 7 NotImplemented stubs
      (`spectrogram`, `hilbert`, `correlate`, `convolve`, `resample`, `sosfilt`,
      `median`) when needed; (c) ✓ done in Phase 3b — derived channels export via
      `write_channels`; (d) ✓ 3b portable workbook done; 3c chart-path
      `ingest_channel` retirement remains.

- [x] **Data tab sync/download redesign (2026-05-30)** — replaced the
      fixed-height download panel with a compact "Sync · N new" button opening
      a full-screen `SyncScreen` (`syncControllerProvider`). Diffs device
      files against the library by `session_id` (NEW / IN LIBRARY /
      identity-unknown), newest-first. Default is an unchecked **file picker**
      (check a few → "Download (N)"); the `autoSyncOnOpen` setting (default
      **OFF**) enables **connect-and-forget** (`syncAllNew`, downloads all new
      automatically). Strictly sequential queue with `MB / MB · %` + queue
      banner, per-file error isolation + Stop. Progress derives from the known
      file size (device streams chunked, no `Content-Length`). Firmware
      `wifi_server.c` `/files` now emits `session_id` per file.
      `download_panel.dart` retired. `flutter test` green on `transport/`,
      `sync_controller*`, `settings_provider`, `sync_screen` (97 tests);
      analyzer clean on touched files.
      Spec §6.1, §24.17, §27; design_rationale; CHANGELOG.
      **Firmware build/flash + on-hardware verify pending (user runs builds).**

- [x] **Fix: HR_RR / event-driven channel time-axis dilation (2026-05-30)** —
      event-driven channels (`sample_rate_hz == 0`) were plotted at a fallback
      1 Hz, stretching the axis by the channel's mean event rate (HR_RR at
      ~120 bpm → 2× span). Parser now keeps per-sample `timestamp_us` for these
      channels in `ChannelData.sampleTimesSecs` (relative to earliest record
      ts); the Analyze chart plots against them via `sampleXSeconds` /
      `sampleIndexAtTime`. Fixes wheel-pulse and marker channels too. Spec
      §15.2 + §21.2; CHANGELOG. v3 parser only (v2 deprecated). `flutter test`
      green on `binary_parser_test` + `time_series_chart_test`.
- [x] **Analyze: bar refinements + chart reorder + sheet right-click + overlay
      cleanup (2026-05-29)** — workbook bar shrunk to 40 dp; X-axis mode moved
      into the bar as a dropdown; `WorkbookBindingChips` deleted; chart slots
      reorder via drag handle (ReorderableListView + custom proxyDecorator);
      worksheet tabs gain right-click Rename/Duplicate; per-chart title
      centred and hidden when blank; time-series charts gain a coloured-dot
      legend in the top-left. `ChartSlot.slotId` UUID added for stable
      reorder identity. `flutter test` passes on touched suites; analyzer
      clean on touched files.
- [x] **Android Rust build automation** — `cargoBuildRust` Gradle task in
      `app/android/app/build.gradle.kts` cross-compiles `app/rust` via
      `cargo-ndk` on every Android build (incremental: skipped when the Rust
      source is unchanged); output to gitignored `app/build/app/rustJniLibs/`.
      Committed `.so` files and `tools/build_android_rust.bat` removed;
      CLAUDE.md §7 rewritten. Fixes the recurring flutter_rust_bridge
      content-hash `StateError` caused by a stale committed `.so`.
- [x] **First on-device run** — `flutter run` launched on Pixel 8 Pro (Android 16, API 36) without crashing. All 4 tabs navigable. `flutter test` 158/158, `cargo build --release` clean. Impeller/Vulkan backend active.
- [x] **Android Rust library** — cross-compiled `libidl0_processing.so` for `arm64-v8a` (1.6 MB) and `armeabi-v7a` (1.0 MB) using `cargo-ndk` + NDK 28.2. Output in `app/android/app/src/main/jniLibs/`. Build script at `tools/build_android_rust.bat`. CLAUDE.md §7 documents the required rebuild step. Resolves dlopen crash at `RustLib.init()`.
- [x] **Analyze tab — Session Sheet worksheet kind** — `Worksheet.kind: WorksheetKind { standard, sessionSheet }` in `lib/providers/workspace_provider.dart` (no `_kSupportedWorkspaceVersion` bump — that's the `.idl0w` file, not the prefs-backed runtime workbook). `Worksheet.sessionSheet(name:)` ctor pre-populates pinned `lapTable + lapProgression` slots; `_defaultState` + `addWorkbook` ship `[Session, Charts]`; load-time `_ensureSessionSheet` migration prepends a Session Sheet to any pre-existing workbook missing one. New `ChartType.lapTable` (formalised — was a hardcoded child) + `ChartType.lapProgression`. `WorkspaceNotifier.removeChart` refuses pinned slots with `debugPrint`; new `removeWorksheet(int)` clamps active index and refuses last sheet. New `lib/ui/tabs/analyze/lap_progression_chart.dart` — fl_chart line per session in `effectiveSessionIdsProvider` scope, X = lap index, Y = lap time s, fastest-lap dot enlarged. New `lib/ui/widgets/mode_aware_checkbox.dart` shared widget; lap-table section + per-row checkboxes call `selectionProvider.toggleSession`/`toggleLap`, mute by mode. `_ChartHeader` shows pin badge + hides controls for pinned slots, gains close button for non-pinned. Workbook bar: Session Sheet tabs render `Icons.list_alt`; "+" is now a `PopupMenuButton<WorksheetKind>` with Standard / Session Sheet. 13 new tests, several existing tests updated for new default workbook shape. `flutter test` passes 409/409; `flutter analyze` clean.
- [x] **Saucy Eng Field Manual brand system** — eight reusable brand widgets in `app/lib/ui/brand/` (`SectionHead`, `SpecRow`, `TickBlock`, `BracketedCta`, `StatusBadge`, `HairlineDivider`, `LiveryStripe`, plus tokens). Field Manual `ThemeData` in `app/lib/ui/app.dart` — Tourney for display, IBM Plex Mono for body / UI / numerics, tabular figures on by default, structural surfaces 0 px, controls capped at 2 px. All five tabs visually re-grounded; structural radii ≥ 4 px audited and removed. Single `LiveryStripe` mounted by `AdaptiveShell`. `flutter test` 384/385 (one pre-existing failure in untracked `runs_hierarchy_provider_test`), `flutter analyze` clean.

---

## Queue — Processing Layer (Rust + sci-rs)

Follow-ups from the 2026-06-10 pipeline audit (out of remediation scope):

- [ ] **Evaluator borrow/view redesign** — `ChannelLookup::lookup` materializes
      a full f64 copy per `[Name]` reference and `require_channel` re-clones
      per channel-typed argument; a `butter(...)` eval peaks at ~4-5× channel
      size in transients. Needs a view/borrow redesign in `idl-rs::math`.
- [ ] **Lap-distance accumulation in the engine** — `gps_track` drains the full
      fix list per lap in `lapDistanceAccumulatorProvider`; window the fixes
      engine-side (or move the accumulator into `idl-rs` entirely).
- [x] **Prune vestigial `#[frb(sync)]` DSP wrappers (2026-06-11)** — removed
      the filters / integration / clip_reconstruct / variance / calibration /
      rotation bridge modules and fft's sync fns (mirrored Welch types kept);
      orphaned generated Dart files deleted. Same sweep removed the
      unreachable `drive_sync_indicator.dart` / `gpx_import_dialog.dart`
      widgets and `importGpxAsSession`. Note: drive-sync status currently has
      NO UI surface (the indicator was already unreachable before deletion) —
      restore one from `driveSyncProvider.syncStatus` if wanted.
- [ ] **Parser column `shrink_to_fit`** — parse columns grow by doubling and
      keep up to ~2× slack resident for the handle lifetime; shrink (or
      size-hint) at `into_entries`.
- [ ] **GPX import via the engine** — the GPX path still builds the legacy
      Dart `Session` then copies into the handle (boxed `List<double>` →
      `Float64List` → FFI); fold into the Phase 5 GPX migration.

---

## Queue — Data Layer

- [x] **Session model** — `app/lib/data/session_model.dart`: SessionMetadata, Session, Lap, Sector, ChannelData, BikeProfile. `flutter test app/test/data/session_model_test.dart` passes (12/12).
- [x] **Lap detection** — `app/lib/data/lap_detector.dart`: GPS gate crossing (flat-earth segment intersection), circuit and point-to-point modes, sector timing. `flutter test app/test/data/lap_detector_test.dart` passes (8/8).
- [x] **Workspace file serializer** — `app/lib/data/workspace.dart`: read/write `.idl0w` JSON with version guard, atomic save. `flutter test app/test/data/workspace_test.dart` passes (5/5).
- [x] **Binary parser** — `app/lib/data/binary_parser.dart`: v1 + v2 format parsers, GPS time reconstruction, variable-stride IMU records. `flutter test app/test/data/binary_parser_test.dart` passes (15/15).
- [x] **SQLite session index** — `app/lib/data/session_index.dart`: upsert, getById, delete, getAll, rebuildFromSessions. `flutter test app/test/data/session_index_test.dart` passes (9/9).

---

## Queue — Transport Layer

- [x] **WiFi transfer** — `app/lib/transport/wifi_transfer.dart`: listFiles, downloadFile, downloadFileTo (streaming + progress), deleteFile. `flutter test app/test/transport/wifi_transfer_test.dart` passes (17/17). Android network binding (TODO #11) stubbed — requires platform channel before on-device use.
- [x] **Config push** — `pushConfig` added to `WifiTransfer`: POST /config with JSON body. `flutter test app/test/transport/wifi_transfer_test.dart` passes (20/20).
- [x] **BLE connection** — `app/lib/transport/ble_connection.dart`: scan, connect/disconnect, 5 control commands, DeviceStatus parsing. `flutter test app/test/transport/ble_connection_test.dart` passes (13/13). connect/disconnect/command paths require manual on-device verification.

---

## Queue — UI Layer

- [x] **App shell + Analyze tab skeleton** — `AdaptiveScaffold` shell (NavigationBar mobile / NavigationRail desktop, breakpoint 600 dp); `SessionNotifier`, `WorkspaceNotifier`, `CursorNotifier` (per-worksheet) providers; `AnalyzeTab` with `WorkbookBar` (workbook dropdown + worksheet TabBar) and `ChartWorkspace` (scrollable column, drag-resize TODO); `TimeSeriesChart` skeleton (fl_chart `LineChart`, synchronized cursor via `cursorProvider.family`, empty-state prompt). `flutter test` passes: 2 shell breakpoint tests, 5 session provider tests, 5 workspace provider tests, 1 chart empty-state test, 1 smoke test.
- [x] **Tab 1: Device** — connection panel, battery, recording controls, config editor (all §8 fields, groups: Bike Profile / IMU / GPS / Analog / Wheel Speed), calibration flow per §15.2. BLE mocked via `MockBleService`. `flutter test` passes 7 new tests (5 provider unit, 2 widget). Shell wiring deferred to integration pass once all 4 tabs are done.
- [x] **Tab 2: Runs** — session library, download panel, metadata editor, session selector per §15.3. `runs_provider.dart` filter state + `filteredSessionsProvider`; WiFi and Drive mocked at boundary. `flutter test` passes 108/108 Dart (4 new: 2 provider unit, 1 widget, 1 widget+spy). `rust_bridge_test` DLL failure is pre-existing environment issue.
- [x] **Tab 3: Maths** — expression editor, channel/function/constants panels, preview plot per §15.4. `MathChannel`, `MathConstant`, `MathChannelLibrary` (6 shipped templates), `MathChannelValidator` (syntax + channel-ref validation), `MathChannelRepository` (SQLite). `MathChannelNotifier` with `NotifierProvider`. UI: metadata bar, operator toolbar, 300 ms validation debounce, 500 ms preview debounce, context-sensitive `FunctionHelpPanel`, `InsertPanels` (Channels / Functions / Constants, desktop columns / mobile TabBar), `ExpressionPreview` placeholder. `flutter test` passes 35/35 new tests (21 data, 14 provider); 154/155 total (pre-existing DLL failure unchanged).
- [x] **Math channel evaluator** — `MathChannelEvaluator` recursive-descent interpreter; `DspAdapter` seam for test isolation; `mathChannelEvalProvider` wired with auto-invalidation; `ExpressionPreview` upgraded to live fl_chart preview. 18 new tests (15 evaluator unit, 3 provider).
- [x] **Maths tab — Quantity & Units selectors** — `MathQuantity` class + `kMathQuantities` (25 entries, primary unit first). `ChannelMetadataBar` Quantity and Units free-text fields replaced with `DropdownButton`/`InputDecorator` dropdowns; selecting a quantity auto-sets the primary unit; switching quantity resets units. Persisted via `updateChannel`. 10 new tests.
- [x] **Tab 4: Analyze** — `WorkbookBar` (dropdown + TabBar + "+" button), `ChartWorkspace` (XAxisSelector, ChartCursor, Add Chart), `TimeSeriesChart` (wheel/GPS fallback warnings), `XAxisMode` per-worksheet in `WorkspaceNotifier`, `cursorProvider.family` synchronized cursors. `flutter test` passes 118/119 (pre-existing DLL failure). FFT chart, histogram, GPS map, lap table, drag-resize deferred to next pass.
- [x] **Shell wiring** — replaced `_DevicePlaceholder` and `_MathsPlaceholder` in `adaptive_shell.dart` with real `DeviceTab` / `MathsTab`; added `sqflite_ffi` init to `adaptive_shell_test.dart` and `widget_test.dart` (real tabs spin up database providers). `flutter test` passes 154/155 (pre-existing DLL failure unchanged).
- [x] **Analyze tab — deferred chart types** — `FftChart` (Rust FFT bridge, Hann/Hamming/Rect window picker, event-driven guard), `GpsMapChart` (GPS_Latitude/GPS_Longitude polylines on google_maps_flutter, bounding-box camera fit), `LapTable` (lap × sector DataTable, fastest-lap highlight, automatic display below charts). `lapDataProvider` FutureProvider.family. `ChartType` enum + `ChartSlot.chartType`; `addChart([ChartType])`; "Add Chart" dialog with type picker. Google Maps API key placeholder in AndroidManifest.xml. 9 new tests.
- [x] **Cross-tab provider wiring** — (1) `sessionIndexLoaderProvider` in `session_provider.dart` loads all sessions from SQLite into `sessionProvider` on `RunsTab` first build; (2) `ChartWorkspace` shows "0 sessions selected" empty state from `sessionProvider.selectedSessionIds`; (3) `channel_provider.dart` adds `channelDataProvider` (FutureProvider.family keyed by UUID, parses `.idl0` via `BinaryParser`) and `availableChannelNamesProvider` (union of selected-session channel names); `ExpressionEditor` passes live channel names to `validate()`; (4) `RunsTab` reads `deviceProvider.isConnected` and passes to `DownloadPanel`; (5) `BleService` abstract + `StubBleService` in `lib/transport/ble_service.dart`; `WifiService` abstract + `StubWifiService` in `lib/transport/wifi_service.dart`; `bleServiceProvider` in `device_provider.dart`, `wifiServiceProvider` in `runs_provider.dart`; `DownloadPanel` refactored to `ConsumerStatefulWidget` reading `wifiServiceProvider`; mock files removed from `lib/`, `MockBleService` moved to `test/helpers/`. 4 new `channel_provider_test.dart` tests; all existing tests green. `flutter test` passes 158/159 (pre-existing DLL failure unchanged).
- [x] **App entry point, Android permissions, bridge test location** — `lib/ui/app.dart`: dark theme (`ThemeData.dark`), cyan accent, renamed `IdlApp` → `IDL0App`; `lib/main.dart` and `test/widget_test.dart` references updated. `android/app/src/main/AndroidManifest.xml`: BLE (legacy + API 31 granular), WiFi, and storage permissions added. `android/app/build.gradle.kts`: `minSdk = 21` (BLE floor) hardcoded; `compileSdk`/`targetSdk` remain delegated to Flutter. `test/rust_bridge_test.dart` moved to `integration_test/bridge_integration_test.dart` with `IntegrationTestWidgetsFlutterBinding.ensureInitialized()`; `integration_test` SDK package added to `pubspec.yaml` dev_dependencies. `flutter test` passes 158/158 (bridge tests now excluded from host run).
- [x] **Binary dump tool** — `tools/idl0_dump.dart`: standalone Dart CLI (dart:io/typed_data/convert only) for inspecting v1 (ESPL) and v2 (IDL0) log files. Flags: `--all`, `--records N`, `--type imu|gps|channel|end`, `--summary`. Forward-compatible: unknown types skipped via `payload_len`. Truncation exits 1 with partial summary. Validated against `reference/sensor_16.bin` (v1, 17,916 IMU records, no GPS).
- [x] **Analyze tab — math channels in charts + chart properties** — `ChartSlot` extended with `mathChannelIds`, `yScaleMode`, `yMin`, `yMax`, `heightFactor`, `channelColors`; `YScaleMode` enum added. `WorkspaceNotifier` gains `addMathChannelToChart`, `removeMathChannelFromChart`, `updateChartProperties`. `_ChannelPickerDialog` shows "Math Channels" section (watches `mathChannelProvider`). `_ChartSlotView` evaluates math channels via `mathChannelEvalProvider` per session, combines with raw channels, shows error overlay on eval failure. `_ChartHeader` with `Icons.tune` opens `_ChartPropertiesDialog`: per-channel colour swatches + `_ColorPickerDialog` (8 presets), Y axis Auto/Manual toggle with Min/Max fields, height `Slider` (0.5–3.0×). `TimeSeriesChart` and `FftChart` accept `yMin`/`yMax`/`channelColors`. GPS map: colour section keyed by session, no Y axis section. 8 new tests (4 provider, 4 widget). `flutter test` passes 217/217.
- [x] **Analyze tab — bug fixes + UX pass** — (1) v1 IMU `sampleRateHz` inferred from timestamps in `_parseV1()`; FFT no longer shows "requires fixed-rate" on ESPL files; test at `binary_parser_test.dart:303` confirms ±5% accuracy. (2) "Add Channel" shortcut hidden once channels are assigned; properties dialog is the only management path. (3) `WorkspaceState` JSON-serialized and persisted via `shared_preferences` (`workspace_state` key); backwards-compatible `fromJson` with safe defaults. (4) Workbook and worksheet names editable via double-tap inline `TextField`; `renameWorkbook`/`renameWorksheet` methods added to `WorkspaceNotifier`. (5) `_ChartPropertiesDialog` channels section uses `ReorderableListView`; reorder commits via `updateChartProperties`; "+ Add Channel" opens `_ChannelPickerDialog` on top; math channel rows gain edit button that sets `activeChannelId` and navigates to Maths tab (`shellIndexProvider` = 2). (6) Per-chart drag-resize handle (12 px strip, `SystemMouseCursors.resizeUpDown`); height committed on drag end; Size slider removed. (7) `XAxisRange` class in `workspace_provider.dart`; `setXAxisRange`/`resetXAxisRange` on notifier; `TimeSeriesChart` applies `minX`/`maxX` from range; `onScaleStart`/`onScaleUpdate` scale gesture handles pinch-zoom (multi-finger) and cursor (single-finger); double-tap resets zoom; zoom-active banner with "Reset zoom" above charts. `flutter test` passes 240/240.
- [x] **Tab 5: Settings** — `AppSettings` model + `UnitSystem` enum (`app/lib/data/app_settings.dart`); `SettingsNotifier` backed by `shared_preferences` (`app/lib/providers/settings_provider.dart`); `shellIndexProvider` (`StateProvider<int>`) replaces local shell index so any widget can navigate tabs; `SettingsTab` with 5 sections: Profile (debounced rider name), Units (`SegmentedButton<UnitSystem>` + summary), Drive Sync (sign in/out from settings, auto-sync + WiFi-only toggles), How-Tos (4 markdown articles via `flutter_markdown`, Full Reference link via `url_launcher`), About (version, licenses, report issue). `defaultUnit(MathQuantity, UnitSystem)` helper in `math_quantity.dart`; `ChannelMetadataBar._onQuantityChanged` applies `defaultUnit` instead of always taking `q.units.first`. `_DriveSection` in `runs_tab.dart` navigates to Settings (index 4) + shows SnackBar when not signed in. `flutter test` passes (7 new tests: 4 defaults, 2 persistence round-trips, 1 unit-system restore; 6 `defaultUnit` tests added to `math_quantity_test.dart`).
- [x] **GPX import (Garmin/Strava)** — `app/lib/data/gpx_parser.dart` (`xml: ^6.5.0`) parses `<trkpt lat lon>` + `<ele>` + `<time>` and Garmin `gpxtpx:hr`/`gpxtpx:cad` + Strava `<power>` extensions into `GPS_Latitude`/`GPS_Longitude`/`GPS_Altitude`/`GPS_EpochMs`/`HR_BPM`/`Cadence_RPM`/`Power_W` channels; sample rate inferred from median timestamp delta, falls back to 1 Hz with warning when timestamps absent. `GpxParseException` added to `exceptions.dart` (extends `ParseException`). `SessionSourceType { idl0, gpx }` enum + `SessionMetadata.sourceType` field (defaults to `idl0`); `SessionIndex` schema bumped to v2 with `source_type TEXT NOT NULL DEFAULT 'idl0'` column + `onUpgrade` ALTER. `RunsNotifier.importFiles` dispatches by extension — `.gpx` files copied verbatim to `<docs>/sessions/<uuid>.gpx`, `.idl0` unchanged. `channelDataProvider` dispatches by extension. `DriveSyncNotifier.queueUpload` uploads `gpx` instead of `idl0` for imported sessions; `GoogleDriveService.uploadSessionFile` accepts `'gpx'`. `SessionListItem` shows secondary-coloured `GPX` badge; `_SyncRow` substitutes `.gpx` for `.idl0` slot when `sourceType == gpx`. `flutter test` passes 249/249 (9 new in `gpx_parser_test.dart`). Spec §12 updated.
- [x] **Analyze tab — ghost chart in worksheet + synchronized cursor** — new `ChartType.ghostDelta` + `ChartSlot.sourceSessionId`/`targetLapNumber` (nullable, `_unset` sentinel in copyWith, JSON keys omitted when null, old layouts load with nulls). `WorkspaceNotifier.addGhostChart`/`removeChart`. `GhostChart` widget resolves reference lap at render time via shared `resolveGhostReferenceLapNumber` (lifted from `lap_table.dart` to `lap_provider.dart`); fl_chart with zero-line; title shows "Ghost — Lap N vs Lap M (best[, target ignored])" + remove button. `LapTable` ghost button now calls `addGhostChart`; `ghost_delta_page.dart` deleted. Cursor sync: `cursorProvider` keeps existing `String → double?` (session-relative seconds) contract; ghost chart converts to lap-relative via `lapStartSeconds = (lap.startTimestampMs − GPS_EpochMs[0]) / 1000` and writes back on tap/drag; `GpsMapChart` gains optional `worksheetId`, renders one cursor marker per selected session via `cursorEpochMs` + `nearestEpochIndex`, and tap-to-set-cursor (non-edit-mode, no gate selected) finds the closest GPS sample by squared flat-earth distance and writes `cursorSecondsFromEpoch`. New `lib/data/cursor_lookup.dart` (pure helpers). 16 new tests; `flutter test` passes 304/304.
- [x] **Analyze tab — ignore laps** — workspace v3: `Workspace.ignoredLapNumbers: Set<int>` (1-based, matches `Lap.lapNumber`), JSON key `ignored_lap_numbers` (sorted list, omitted when empty), v1/v2 files load with empty default. `SessionWorkspaceNotifier` gains `ignoreLap`/`unignoreLap`/`clearIgnoredLaps` (synchronous save). `LapTable` converted to `ConsumerStatefulWidget` with local `_showIgnored` (default ON); per-row `Icons.block`/`Icons.visibility_off` toggle, ignored rows render `surfaceContainerHighest` background + `TextDecoration.lineThrough` at 60% opacity, best-lap highlight and Δ columns suppressed. `Icons.star` marks best non-ignored; `Icons.flag` marks pinned reference (only when explicitly pinned). Best-lap + per-sector best computed across non-ignored only and stay stable when toggle flips. Ghost button disabled on active reference, when no eligible reference exists, or when fewer than two non-ignored laps remain. `_resolveReferenceLapNumber` layers `pinned-when-not-ignored ?? fastest-non-ignored`; `GhostDeltaPage` unchanged. 12 new tests; `flutter test` passes 283/283.
- [x] **Analyze tab — GPS map zoom + edit-mode + endpoint editing** — bottom-right `FloatingActionButton.small` zoom +/- buttons (`MapController.move(center, zoom ± 1)`, clamped to `MapOptions.minZoom = 1` / `maxZoom = 19`); replaced ambiguous `Icons.location_searching` edit FAB with `FloatingActionButton.extended` (`Icons.add_location_alt` + "Place Gate" idle, `Icons.close` + "Cancel" active, `colorScheme.error` background when active). Gate endpoint drag: per-gate `Icons.drag_indicator` markers (visible only when the gate is selected OR edit mode is active) wrap a `GestureDetector` whose `onPanStart` captures `latLngToScreenPoint`, `onPanUpdate` accumulates pixel delta + back-projects via `pointToLatLng` for live `Polyline` preview, `onPanEnd` commits via new `SessionWorkspaceNotifier.updateLapGate(int, LapGate)` / `updateSectorGate(int, SectorGate)`. New `swapLapGates()` exchanges `lapGates[0..1]`; surfaced as `Icons.swap_horiz` button in `_SelectedGatePanel` when the selected gate is a lap gate and `lapGates.length >= 2`. 5 new tests; `flutter test` passes 275/275.
- [x] **Analyze tab — map provider switch + reorderable sectors** — `google_maps_flutter` replaced with `flutter_map` + `latlong2`; `GpsMapChart` rewritten on `FlutterMap` with `PolylineLayer`/`MarkerLayer` and `MapOptions.initialCameraFit`. `lib/ui/tabs/analyze/map_tile_source.dart` adds `MapTileSource { osmStandard, esriSatellite, esriHybrid }` + `tileSpecsFor()` (hybrid stacks satellite + boundaries/labels via two `TileLayer`s); top-right `SegmentedButton<MapTileSource>` toggles basemap with attribution badge bottom-right. `SessionWorkspaceNotifier.reorderSectorGates(int oldIndex, int newIndex)` adjusts for `ReorderableListView`'s newIndex convention; new top-right `Icons.reorder` button opens a bottom-sheet `ReorderableListView` of sector gates. Maps API key meta-data + setup comment removed from `AndroidManifest.xml`. 7 new tests (3 reorder, 4 tile-source); `flutter test` passes 270/270.
- [x] **Gate placement, sector timing, ghost lap delta** — workspace v2 schema: `LapGate.name` (default `''`, v1 files load with empty default) and `Workspace.referenceLapNumber: int?` for ghost-timing reference; both round-trip through `.idl0w`. `WorkspaceSaver` lifted from `metadata_editor.dart` to `data/workspace.dart` so the new provider can share it. `app/lib/providers/session_workspace_provider.dart`: `SessionWorkspaceNotifier` (`AsyncNotifierProvider.family` keyed by sessionId) with synchronous-save mutation methods (`addLapGate`, `removeLapGate`, `renameLapGate`, `addSectorGate`, `insertSectorGate`, `removeSectorGate`, `renameSectorGate`, `setReferenceLapNumber`); each `await`s `WorkspaceSaver.save` before returning — no debounce, no flush-on-dispose, no first-write special case. `workspaceSaverFactoryProvider` injects `FileWorkspaceSaver` in production and a no-op in tests. `lap_provider.dart` rewritten: `sessionLapsProvider` (`Provider.family<AsyncValue<List<Lap>>, String>`) composes `sessionWorkspaceProvider` and `channelDataProvider` and feeds the resulting GPS track + gates to `LapDetector` (1 gate → circuit, ≥2 → point-to-point); old stub `lapDataProvider` deleted, all callers migrated. `GpsMapChart` rewritten with gate-placement UI: edit-mode FAB (Icons.location_searching), two-tap dialog (`SegmentedButton<GateKind>` + name + optional sector insert position), existing gates render as orange (lap, 8 px) / yellow (sector, 5 px) polylines with midpoint markers; tap marker → selection panel with Rename/Delete; gate coordinates stored at × 1e7 to match firmware encoding. **GPS scaling fix:** `GpxParser` now multiplies lat/lon by 1e7 — reconciles a unit mismatch from the prior task that placed GPX-derived sessions ~1e-6 ° from their real location on the map and prevented gate detection on imported runs. `LapTable` extended: per-sector time + delta-to-best-sector cells (theoretical-best-lap colouring), Δ Best column, reference-lap flag (`Icons.flag`) when `Workspace.referenceLapNumber` matches the row, long-press → bottom-sheet "Set as reference" / "Clear reference", `Icons.compare_arrows` ghost button per row (disabled on the active reference); multi-session view collapses each session into an `ExpansionTile` keyed by date. `app/lib/data/ghost_lap.dart`: pure-Dart closest-point-on-polyline delta (skipped Rust per CLAUDE.md §1 — geometry, not bike physics). `ghostDeltaProvider` slices GPS channels by lap timestamp window, hands them to `GhostLap.ghostLapDelta`, infers target sample rate from median delta. `GhostDeltaPage` is a transient `MaterialPageRoute` (not a chart slot) — `fl_chart` line plot, X = lap-relative seconds, Y = delta seconds, zero line drawn. `flutter test` passes 274/274 (12 new tests across workspace v2 round-trip, sessionLapsProvider/SessionWorkspaceNotifier integration, ghost geometry, ghost provider wiring, lap-table reference-flag widget). Spec §12.1 already had the i32 × 1e7 contract; §14.3 extended with the gate model, ghost-lap, and `referenceLapNumber` semantics.

---

## Queue — Track Entity (cross-session lap comparison, §12.3)

- [x] **Track entity — Phase 1: foundation (model, cache, sync, no UI)** — `app/lib/data/track.dart` (`Track` with UUID, name, venueName, lapGates, sectorGates, referencePolyline, createdAtMs, updatedAtMs; `Track.create` / `copyWith` / JSON round-trip), `GpsFix.toJson` / `fromJson`. `app/lib/data/track_index.dart` (separate `tracks.db`, schema v1, `full_json` column, upsert/getById/getAll/delete). `SessionIndex` v3 migration adds nullable `track_id` column; `SessionMetadata.trackId` + `clearTrackId()`. `DriveService` extended with `listTracks` / `downloadTrack` / `uploadTrack` + `DriveTrackFile`; `GoogleDriveService` implements them against `IDL0/tracks/<trackId>.idl0t` (UUID-validated filename filter, lazy folder creation, Files.update on subsequent edits). `TrackNotifier` (`AsyncNotifierProvider`) returns local cache immediately + fire-and-forget `_syncWithDrive` (last-write-wins by `updatedAtMs`); supports createTrack / updateTrack / deleteTrack (cascades session detach) / assignSessionToTrack / unassignSession / pushSessionGatesToTrack; `debugSyncCompletion` testing seam. 19 new tests across `track_test.dart`, `track_index_test.dart`, expanded `session_index_test.dart`, `track_provider_test.dart`. `flutter test` passes 327/327; `flutter analyze` clean. Spec §12.3 added.
- [x] **Track entity — Phase 2: auto-detection + manual binding UI** — `app/lib/data/polyline_geometry.dart` (shared `closestPointOnPolyline`; ghost_lap keeps its windowed optimisation); `buildGpsTrack(channels)` lifted to public in `lap_detector.dart`. `app/lib/data/track_matcher.dart` (`TrackMatcher.findMatchingTrack`: bounding-box pre-filter → ~50-sample sub-sampling → mean closest-point distance in local east/north metres via flat-earth at session centroid → 50 m default threshold). `metadata_editor.dart` converted to `ConsumerStatefulWidget`; new `_TrackRow` renders bound / auto-detected / unbound states with Confirm / Choose other / Change / Detach / Assign / Create actions. `_TrackPicker` bottom sheet (auto-matched first, currently bound ticked, Create-new + Detach-current footer actions). `_CreateTrackDialog` takes name (default = venue or "Unnamed Track") and copies workspace gates + session GPS into the new Track. 11 new tests (8 matcher + 3 editor widget); the pre-existing save test wrapped in `ProviderScope` with the new overrides. `flutter test` 338/338, `flutter analyze` clean.
- [x] **Ghost chart direction-aware matching + hover cursor** — `GhostLap.ghostLapDelta` extended with a `forwardWindow` parameter (default 100 segments ≈ 10 s of reference look-ahead at typical 10 Hz GPS) so the search window is bounded on both sides; an additional direction-of-travel filter rejects candidate segments whose dot-product with the target's local direction (`tgt[i-1] → tgt[i+1]`) is non-positive. The combination eliminates the spike-then-linear-recovery artifact on out-and-back / fold-on-itself courses where the polyline crosses itself in opposite directions. Falls back to spatial-closest when every candidate fails the direction test (target reversing mid-lap), so output never has holes. New `hoverCursorProvider` (`StateProvider.family<double?, String>`) holds transient hover state per worksheet, distinct from the pinned `cursorProvider`. `TimeSeriesChart`, `GhostChart`, and `GpsMapChart` wrap their interactive area in `MouseRegion`; `onHover` writes the hover provider, `onExit` clears it. Charts display `hover ?? pinned` so hovering over any chart previews the cursor on every other chart and the GPS map without clicking. Touch devices never fire hover events, so tap-to-pin behaviour is preserved unchanged. `GpsMapChart`'s hover handler is throttled to ~30 Hz (per-pixel mouse motion would otherwise rebuild every cursor-subscribing chart on every frame); chart hovers are unthrottled because fl_chart already gates events. 2 new ghost_lap tests (out-and-back at half speed verifies smooth ramp at the fold; forward-window cap verifies the matcher cannot snap 200+ segments forward to a same-direction spatially-coincident segment); `flutter test` passes 340/340.
- [x] **Multi-track sessions — Phase 1: data model rework (replace `trackId` with `trackVisits`)** — Workspace v3→v4: new `TrackVisit` class (stable UUID `visitId`, `trackId`, `startTimestampMs`, `endTimestampMs`); `Workspace.trackVisits: List<TrackVisit>` and `Workspace.trackVisitsLibraryHash: String?` with copyWith / toJson / fromJson and `clearTrackVisits()`; v1/v2/v3 files load with empty defaults. `SessionMetadata.trackId` and `clearTrackId()` removed; `tag: String` (default `''`) added. SessionIndex v3→v4 migration: `track_id` column dropped via recreate-and-copy (DROP COLUMN requires SQLite ≥ 3.35, not guaranteed on older Android), `tag TEXT NOT NULL DEFAULT ''` added. `TrackNotifier.assignSessionToTrack` / `unassignSession` / `pushSessionGatesToTrack` deleted; `deleteTrack` no longer touches sessions (skip-on-resolve in hierarchy view per §12.3). `TrackMatcher.findMatchingTrack` renamed to `findBestMatchOverall`; `findVisits` stub added (Phase 3). MetadataEditor's track-binding UI replaced with read-only `_TracksVisitedRow` (visit count per Track, e.g. "A-Line (3 visits), Top of the World (1 visit)") + new `tag` field. Existing tests for binding/clearTrackId/findMatchingTrack/pushSessionGatesToTrack deleted; new tests for v4 round-trip, tag round-trip, tracks-visited row added.
- [x] **Multi-track sessions — Phase 2: GPX-as-track import + Tracks library** — new `lib/data/gate_geometry.dart` (`GateGeometry.endpointGates` synthesises Start + Finish 20 m perpendicular `LapGate`s from a polyline's endpoints; flat-earth metric projection at the polyline midpoint; degenerate identical-points input collapses to a zero-length gate without crashing). `GpxParser.parse` augmented to surface `<metadata><name>` as `GpxParseResult.metadataName`. `RunsNotifier.importGpxAsSession({bytes, filename})` and `TrackNotifier.importTrackFromGpx({bytes, name, venueName})` accept already-picked bytes so the unified dialog picks once and dispatches by mode. New `lib/ui/tabs/runs/gpx_import_dialog.dart`: file picker → `GpxParser.parse` preview → `SegmentedButton` mode toggle (Session / Track) preselected by entry button → editable name + venue → confirm dispatches to the matching provider method, returns `(success, message)` for the snackbar. New `lib/ui/tabs/runs/track_library.dart`: list of Tracks (sorted updatedAt desc) with rename / venue-edit / delete (with stale-visits warning) and a header "Import GPX as track" entry. Runs tab toolbar gains a `Icons.terrain` button that pushes `TrackLibrary` as a route; existing `_ImportButton` (bulk `.idl0` + `.gpx`) preserved alongside it as `_LibraryActions`. New tests: `gate_geometry_test.dart` (5 tests covering width, endpoint centring, degenerate input, empty/single-point input), `track_provider_test.dart` `importTrackFromGpx` (parses + auto-gates + uploads) + bad-GPX guard. `flutter test` passes 347/347; `flutter analyze` clean.
- [x] **Multi-track sessions — Phase 3: visit detection** — `TrackMatcher.findVisits` implemented (bbox pre-filter → flat-earth metric projection at session centroid → per-sample winner with `thresholdMeters = 30.0` → coalesce contiguous same-track samples with `gapToleranceSeconds = 5.0` tolerance → drop visits < `minVisitSeconds = 30.0`). Stable `visitId` UUID minted per visit (per Q10). `trackLibraryHash(List<Track>)` in `track_provider.dart` returns `'sha1:<hex>'` over sorted `(trackId, updatedAtMs)` — used as `Workspace.trackVisitsLibraryHash` for staleness detection. `RunsNotifier.importFiles` and `importGpxAsSession` run findVisits + persist a fresh Workspace with visits + hash on import. New `RunsNotifier.rescanTrackVisits(sessionId)` re-reads current Track list, re-runs detection, and merges back into the existing Workspace (preserves user gates / math channels / etc.); hooked to a Rescan icon button in `MetadataEditor._TracksVisitedRow` that also surfaces a `rescan available` chip when the live hash differs from the cached one. `sliceGpsByWindow(gps, startMs, endMs)` and `visitLapsProvider` (`FutureProvider.family<List<Lap>, ({String sessionId, String visitId})>`) added in `lap_provider.dart`; gate fall-through is `Workspace.lapGates` ?? `Track.lapGates`. Track skip-on-resolve when a visit's trackId no longer maps to a Track. 7 new findVisits tests in `track_matcher_test.dart`.
- [x] **Multi-track sessions — Phase 4: hierarchical Runs UI + lap-granular selection** — `runsHierarchyProvider` (`FutureProvider<List<RunsDayGroup>>`) aggregates `sessionProvider.sessions` → per-session `Workspace.trackVisits` → per-visit laps via `visitLapsProvider`, groups by local-time day (per Q15), then by Track, ordered chronologically; computes day-best ★ excluding ignored laps (per Q16) and a `hasStaleVisits` flag from per-workspace hash mismatches. New `HierarchicalRunsView` widget (`lib/ui/tabs/runs/hierarchical_runs_view.dart`): expandable Day → Track → Laps tree, per-lap checkbox (writes `selectedLaps`), inline `Icons.compare_arrows` (Compare with…) and `Icons.block`/`Icons.visibility_off` (ignore toggle) per row, lap-time + tag chip + ★ glyph. `ChoiceChip` tag filter row at the top (single-select with implicit "All" per Q13). `SessionState` extended with `Set<LapKey> selectedLaps` + `toggleLapSelection`/`selectLap`/`clearLapsForSession`; `deselectSession` and `clearSelection` cascade through. `RunsViewMode { tracks, sessions }` + `RunsViewModeNotifier` persist via `shared_preferences` key `idl0.runs.view_mode` (per Q17); `runsTagFilterProvider` (in-memory `StateProvider<String?>`). RunsTab body replaced with `_LibraryBody` carrying the SegmentedButton + view dispatch — Tracks (default) vs. legacy `SessionList`. 5 new lap-selection tests + 3 hierarchy aggregation tests (day-best, hash-mismatch flag, skip-on-resolve).
- [x] **Multi-track sessions — Phase 5: cross-day Compare with…** — `ChartSlot` extended with `referenceSessionId: String?` and cross-session `referenceLapNumber: int?` (additive, _unset sentinel in copyWith, JSON keys omitted when null, pre-Phase-5 ghost layouts load with nulls). `WorkspaceNotifier.addGhostChart` accepts the new fields. `crossSessionGhostDeltaProvider` mirrors `ghostDeltaProvider` but pulls reference + target slices from independent sessions via two separate `channelDataProvider` reads. `GhostChart` build-method gains a top-of-build cross-session branch: when `slot.referenceSessionId` and `slot.referenceLapNumber` are set and differ from the source, renders via `crossSessionGhostDeltaProvider`; otherwise falls through to the existing same-session resolution chain (pinned → fastest-non-ignored). New `CompareWithPicker` (`lib/ui/tabs/runs/compare_with_picker.dart`): scoped to one Track, scans `runsHierarchyProvider` for non-ignored laps (excluding the source), sorts by lap time ascending, shows date + Δ vs. picked lap (green when faster, red when slower) + tag chip; returns `ComparePickerEntry` on tap. `_LapRow._onCompare` opens the picker, on pick selects both sessions + the source lap, calls `addGhostChart(...)` with the cross-session reference fields, and switches to the Analyze tab via `shellIndexProvider = 3`. 4 new tests covering the cross-session ChartSlot fields (addGhostChart, JSON round-trip, forward-compat for pre-Phase-5 layouts, copyWith null-clear). Spec §12.3 rewritten end-to-end around `TrackVisit`s.

- [x] **FFT chart: Welch spectral estimation** — new Rust `welch()` (`app/rust/src/fft.rs`, on `rustfft`; detrend None/Mean/Linear, Mean/Median averaging, Magnitude/Density scaling) drives the FFT chart. Per-chart properties added: segment length (auto = pow2 ≤ n/8, clamped 256–8192), overlap %, detrend, averaging, scaling, and a log-magnitude Y axis beside log-X. `ChartSlot` extended (additive, `_unset` sentinel, FFT-only JSON, defaults for old workbooks). `fft()` retained for the math-channel `fft(ch, window)`. Rust 57/57, `chart_slot_test.dart` 6/6, `fft_chart_test.dart` 3/3. Docs: new `docs/signal_pipeline.md`, SPEC §10/§21.1, `design_rationale.md`.

---

## Queue — Spec 1 follow-ups (config refactor)

- [ ] **Frequency-aware FFT zoom/pan** — FFT charts currently disable the
      worksheet zoom/pan context-menu items (X axis is Hz, not worksheet time).
      A frequency-domain zoom is a v2 follow-up flagged in `fft_chart.dart`.
- [ ] **Time-series x-axis does not rescale / re-tick when zoomed in.** On the
      Analyze time-series chart, zooming to fine detail does not rescale the x
      axis ticks/labels, so it is impossible to tell how many raw samples are
      actually on screen (e.g. whether a saturation event is one point or
      several at 866 Hz). Needs the x-axis ticks + label density to follow the
      active zoom range, and ideally a point/marker render at high zoom so
      individual samples are visible. Blocks visual diagnosis of declip output
      (TODO(idl0): see clip_reconstruct short-clip overshoot tuning).
- [ ] **Marker rendering in Analyze tab** — vertical lines on every chart
      at marker (CHANNEL_SAMPLE channel kind=`digital/marker_*`) timestamps,
      labelled with the marker name; tap a line to seek the cursor; one row
      in the lap table summarising marker count per lap. Data-layer plumbing
      already lands the records in the session via the standard registry-
      driven parser path; this task is purely Analyze-tab presentation.
- [ ] **Status auto-refresh / refresh button on Device tab** — pull the
      §7.3 status proactively so battery / SD / GPS / IMU / HR_Battery
      do not sit stale during long sessions. Either a refresh button or a
      periodic poll (~ every 30 s) is acceptable. Annotation "(read on
      connect)" on stale rows is the temporary marker for the status pane
      pieces this would retire.
- [ ] **Per-channel analog rate overrides** — the firmware ADC scheduler
      currently shares one rate across all analog channels. Adding a
      per-channel `rate_hz` field to `analog.channels[i]` that overrides
      the group rate via firmware-side decimation would let a 1 kHz
      strain gauge coexist with a 100 Hz fork potentiometer. Schema
      slot is forward-compatible; needs firmware decimation + UI
      affordance.
- [ ] **DigitalKind.level + DigitalKind.pwm in the `+ Add channel…` picker**
      — schema-supported, no firmware reader yet. Add the picker entries +
      firmware GPIO ISR (level: low-rate sample at edge OR poll at 50 Hz;
      PWM: pulse-counting on edge interrupt over a fixed window) when a
      sensor that needs them lands.

---

## Queue — Data tab follow-ups

- [ ] **Filesystem rescan: walk <docs>/sessions/ for sideloaded .idl0 files
      not in the SQLite index. New method RunsNotifier.rescanSessionsFolder.
      Tied to Drive sync's downstream flow.**
- [ ] **Per-day collapse-state persistence in SharedPreferences (current
      behaviour: all days expanded; remember collapsed days across launches).**
- [ ] **MetadataForm dirty-state tracking + unsaved-changes prompt on dismiss.**
- [ ] **Venue → first-class entity upgrade (see docs/design_rationale.md).**
- [ ] **GoogleDriveService: shared http.Client lifecycle / pagination on list
      queries. Pre-existing class-level cleanup; flagged during data tab
      redesign code review.**
- [ ] **Lap-cache staleness affordance (deferred from 2026-06-02 lap cache).**
      Cached laps drift when a Track's gates are edited in Analyze (live laps
      change; the `.idl0w` cache does not until a rescan). `trackVisitsLibraryHash`
      already records the library version the cache was computed against, but no
      UI surfaces staleness. Surface a "rescan available" affordance on the Data
      tab when a session's cached hash ≠ the current `trackLibraryHash`, or
      auto-rescan affected sessions on Track-library change. Matters most for the
      headline "find my best lap on Track X" use case, which goes stale silently.
- [ ] **Lap-cache migration for pre-v7 workspaces (deferred from 2026-06-02 lap
      cache).** Workspaces written before schema v7 carry visits but no cached
      laps, so the Data tab shows them with no laps until the user runs "Rescan
      visits". Acceptable for pre-release dev data (chosen to avoid an on-open
      parse-storm). If real session libraries predate v7, add a one-shot
      background pass that rescans only the lap-cache-missing workspaces (off the
      Data-tab-open path) so laps populate without a manual rescan.

---

## Queue — Portable Workbooks follow-ups (2026-05-27)

Shipped at commits `a1f0509` … `f2f479c`. SPEC §17a.

- [x] **Resolve layer-inversion** (commit `d339763`): `Worksheet`, `ChartSlot`, and chart-related enums (`ChartType`, `XAxisMode`, `YScaleMode`, `ChartScope`, `WorksheetKind`, `XAxisRange`) moved to `app/lib/data/worksheet.dart`. `workspace_provider.dart` re-exports them so existing UI imports continue working without churn. `data/workbook.dart` now imports `Worksheet` directly from `data/`.
- [ ] **Per-row Export/Delete in `BrowseWorkbooksModal`**: row trailing menu currently wires Duplicate; Rename / Export / Delete show "Coming soon". The dropdown menu on the active workbook already covers these actions, so this is a usability follow-up only.
- [ ] **Per-(workbook, session) cursor + zoom restore**: spec §7 specifies a clean reset on primary-session switch (implemented). Restore would carry users back to their last view of a given `(workbook, session)` pair.
- [ ] **Tombstone GC after 30 days for deleted workbooks** (spec §4.5). Delete propagates via Drive immediately today; a tombstone table is not yet implemented. Required only if a delete-while-offline race appears.
- [ ] **Flush pending Drive uploads on app pause/close** (spec §4.7). `WorkbookNotifier.flushPendingUploads()` exists; it needs wiring to `WidgetsBindingObserver.didChangeAppLifecycleState` so suspending the app doesn't lose pending edits.
- [ ] **Drop dead `_kWorkspaceState` constant** from `workspace_provider.dart` (legacy SharedPreferences key, replaced by `workspace_ui_state`). The Task 5 migration removes the entry on first launch; the constant itself can be deleted once the parallel-agent branch is merged.

---

## Queue — WiFi/Logging Mutex follow-ups (2026-05-27)

Shipped in T1–T16 of the WiFi/Logging Mode Mutex plan. See SPEC §7.2, §10.4, §23.9.

- [x] **IMU (+ GPS) sampling pause during WiFi mode (2026-06-03).**
  `imu_task` and `gps_task` poll `IDL0_MODE_BIT_WIFI_UP` via
  `idl0_mode_get_bits()` (mirroring `hrm_task`'s edge handling) and
  suspend bus reads while the bit is set. IMU0 shares the SPI2 bus with
  the SD card, so its per-cycle drains were stealing bus-lock time and CPU
  from the `/download` `fread` loop; GPS freed the NMEA-parsing CPU and
  `uart_flush_input`s on resume. Self-contained; no edits to
  `wifi_server.c` / `session.c`. **Measured ~5× download throughput.**
  Root-caused via systematic debugging. See spec §10.4.
- [ ] **WiFi/BLE coexistence throughput tax during transfers.** With the
  sensor-suspend landed, `/download` still pulses (speed-up/slow-down)
  because BLE stays connected and notifies at ~1 Hz while WiFi shares the
  single 2.4 GHz radio under `WIFI_PS_NONE` (the coexistence arbiter slices
  radio time). Candidate levers: slow the BLE status cadence during an
  active transfer (e.g. drop to a heartbeat while `WIFI_UP` + a download is
  in flight), widen the BLE connection interval, and/or revisit the
  single-threaded 8 KB httpd send loop. Measure each in isolation; the goal
  is the ~1 MB/s the C6 AP is capable of. See spec §10.4.
- [ ] **Active config name/version in status.**
  `Firmware: <semver>` shipped (2026-06-29, OTA auto-update) — parsed
  into `DeviceState.firmwareVersion`. Still TODO: add the
  `Config: <name> v<n>` line and render the config name/version on the
  Device-tab connection row + Settings tab.
- [ ] **mode_state lazy-init contract.** `idl0_mode_event_group()`
  uses lazy `xEventGroupCreate` — safe today because `app_main`
  ordering ensures the first call comes before any concurrent
  caller, but the safety property is implicit. Either add a
  one-shot `idl0_mode_init()` called from `app_main` before any
  task that may touch the group, or document the ordering
  invariant inline.
- [ ] **Cross-task atomic reads of `s_running` / `s_state`.**
  `idl0_session_is_running()` is called from `gps_task` (and
  potentially other tasks); writers are on the NimBLE host task.
  Today the bare `bool` / enum reads are technically a data race;
  the event-group framework introduced in T3 should replace these
  bare reads as the canonical truth.
- [x] **Skip-as-Cancel resolved (2026-06-04).** `StepContext.skip()` +
  `AwaitHr.onSkip` resolve the HR wait as `StepOk` (continuing into
  `StartLogging`), distinct from Cancel (`StepCancelled`).
  `ModeController.skipHrWait()` signals the active step; the `_HrWaitPill`
  Skip button calls it. Lets the user record with a strap enabled in config
  but not worn. Test: `mode_step_test` "skip mid-wait → StepOk". Spec §4.1.
- [ ] **MaterialBanner Reconnect action.** The `TimedOutAwaitingConfirm`
  banner's Reconnect button currently only dismisses. Wire it to
  actually re-establish the BLE link (`deviceProvider.connect()`).
- [ ] **Device-tab hint-line spec literals.** Spec §5.1 calls for
  Idle = "session count on SD", WiFi = AP SSID, Recording =
  "mm:ss + free SD MB". v1 ships with the available `DeviceState`
  fields (HR / SD / battery / `deviceName`-as-SSID). Track the
  remaining fields (session-file count, recording elapsed time,
  free SD MB) and add them to `DeviceState` + status parser when
  they land in the §7.3 status string.
- [x] **Transport-level WiFi wrap cleanup — pushConfig done in S2; pushFirmware still pending.** Stability pass S2 (`5c572c5`) stripped the `wifiOn()` / `bind` / `release` wrap from `BleConnection.pushConfig`; it is now pure HTTP and requires the caller to be in `Mode.wifi`. `RealWifiService.pushFirmware` and any other internal WiFi wraps still need the same audit — verify no binding leaks remain after the OTA upload path.
- [ ] **Relocate `wifiServiceProvider` out of `runs_provider.dart`.** Stability pass S3 imports `wifiServiceProvider` from `runs_provider.dart` into `providers/mode_step.dart` so the `WifiOn` / `WifiOff` steps can call `bind()` / `release()`. That's a layer smell — `runs_provider` is a sessions concept; wifi is transport-adjacent. Move the provider definition to `transport/wifi_service.dart` (or a dedicated `providers/wifi_provider.dart`) and update the two import sites. ~5 lines, zero behavior change.

---

## Queue — Connection stability pass (2026-05-28)

Six commits (`3b0217e`..`235a77c`) addressing connection regressions surfaced after the WiFi/Logging Mutex shipped. See commit messages for per-fix detail. App-only; no firmware changes.

- [x] **S1 — Tighten `_extractAttCode` to the known IDL0_ACK_* set.** Both the structured `e.code` path and the regex fallback now restrict to `{0x00, 0x03, 0x80, 0x81, 0x82}`; non-IDL0 GATT errors (e.g. `0x05` auth-fail, `0x08` authz-fail, `0x16` remote-user-term) fall through to `DeviceUnreachableException` instead of being mis-rendered as "Device refused command (0xNN)".
- [x] **S2 — Strip WiFi/bind/release wrap from `BleConnection.pushConfig`.** Pure HTTP now; caller must be in `Mode.wifi`. Closes the cascading "pushed config then couldn't record" bug (the wrap left WiFi ON after push → firmware mutex blocked the next START_LOGGING → exception was silently swallowed).
- [x] **S3 — `WifiOn` / `WifiOff` steps own Android process `bind` / `release`.** New `StepFailed(reason)` + `TransitionFailed(reason)` sealed variants for non-firmware transport errors; ModePicker SnackBars them like firmware refusals. Closes the "Mode.wifi up but downloads still fail" symptom from T14 (panel deleted its own bind without naming an owner).
- [x] **S4 — ConnectionPanel routes Start/Stop via `ModeController.switchTo`; SnackBars on Connect/Disconnect errors.** HR-up gate honored; refusals surface via the picker's existing TransitionResult stream; no more silent record failures.
- [x] **S5 — Link-loss observer.** `BleService.connectionLost` stream emits on unexpected BLE drops; `DeviceNotifier` resets `DeviceState` automatically. No more stale "Connected" UI after the link dies.
- [x] **S6 — Bluetooth-off precheck.** `BleConnection.connect()` checks `FlutterBluePlus.adapterStateNow` before scanning; throws `DeviceUnreachableException("Bluetooth is off. Enable it and try again.")`, which S4's handler renders as a SnackBar.

---

## Queue — Selection refactor + Data tab (replaces hierarchical Runs view)

- [x] **Selection refactor + Data tab — Phase 1: global XOR selection model** — new `lib/providers/selection_provider.dart` exposing `SelectionMode { session, lap }`, `LapKey` (value-class with `==`/`hashCode`), `Selection { mode, sessionIds, lapKeys }`, `SelectionNotifier` (toggleSession / toggleLap auto-flip mode and clear the inactive set; selectMany / setMode / clear / removeSessionFromSelection helpers), and the derived `effectiveSessionIdsProvider` / `effectiveLapKeysProvider`. Legacy `SessionState.selectedSessionIds` / `selectedLaps` and the `selectSession` / `deselectSession` / `toggleLapSelection` / `selectLap` / `clearLapsForSession` / `clearSelection` methods deleted from `session_provider.dart`; `SessionNotifier.removeSession` now drops references via `selectionProvider`. Every consumer migrated to `effectiveSessionIdsProvider` / `selectionProvider.notifier` (channel_provider, runs_provider, chart_workspace, lap_table, expression_preview, session_list_item, hierarchical_runs_view). New `selection_provider_test.dart` (20 tests covering XOR semantics, mode flip on toggle, selectMany, setMode, clear, removeSessionFromSelection, derived providers, LapKey value semantics). Old `session_provider_lap_selection_test.dart` deleted; `session_provider_test.dart` slimmed to addSession / removeSession / loadSessions; channel_provider_test, chart_workspace_test, lap_table_test, runs_provider_test migrated to the new API. `flutter analyze` clean; `flutter test` 393/394 (single failure pre-existing in `runs_hierarchy_provider_test`, deleted in Phase 2).
- [x] **Selection refactor + Data tab — Phase 2: rename Runs → Data, faceted search** — Shell renamed (`Icons.travel_explore` / "DATA"); directory move `lib/ui/tabs/runs/` → `lib/ui/tabs/data/`; legacy widgets removed (`hierarchical_runs_view.dart`, `session_list.dart`, `session_list_item.dart`, `track_library.dart`, `runs_tab.dart`); legacy provider `runs_hierarchy_provider.dart` and its test deleted; `runs_provider.dart` slimmed to import + rescan only (RunsState filter / RunsViewMode / runsTagFilterProvider / filteredSessionsProvider all deleted). New `data_filters_provider.dart` (`DataFilters`, `DataFiltersNotifier`, facet mutators with `(none)` empty-string sentinel for Bike / Rider / Tag; `DataView { sessions, tracks }` and `DataSort` enums; `clearAll` preserves view + sort). New `data_results_provider.dart` (`SessionRow`, `SessionRowLap`, `TrackRow`, `FacetCounts`; `_sessionAggregatesProvider` fans out per-session workspace + visit-laps via `Future.wait`; `filteredSessionRowsProvider` / `filteredTrackRowsProvider` apply filters + sort; `facetCountsProvider` computes "(N)" badges by simulating each candidate value as the active filter; `lapTimeDomainProvider` returns `(60 000 ms, ceilTo5Min(maxKnownLapTime).clamp(60_000, 10_800_000))`). New UI: `data_tab.dart` (Drive section + DownloadPanel + filter rail / bottom-sheet + results panel + floating "ANALYZE N selected" launcher), `filter_rail.dart` (Date chips with single-select preset matching, multi-select facets with inline search ≥ 8 entries, RangeSlider + mm:ss text inputs for Lap time, Source checkboxes, Has gates / Has GPS booleans, Clear all action), `session_results.dart` (date headings + collapsible session rows with mode-aware checkboxes + Track-name lap rows with Compare / Ignore inline buttons), `track_results.dart` (sortable DataTable + `Import .gpx tracks…` multi-select button + side detail panel with rename / delete / stale-visits warning). `CompareWithPicker` rewritten against direct providers (`compareEntriesProvider` walks sessionProvider + sessionWorkspaceProvider + visitLapsProvider scoped to one Track). New `data_filters_provider_test.dart` (7 tests). `adaptive_shell_test.dart` overrides Drive / Track / sessionIndexLoader providers so `pumpAndSettle` settles. `flutter analyze` clean; `flutter test` 396/396. Spec §15.3 rewritten end-to-end; §17 documents `selectionProvider` + new providers list.

---

## Queue — Lap delta rewrite (2026-05-09)

- [x] **Lap delta rewrite — full system rebuild.** Replaced the 2026-05-08 variance architecture (Dart `polyline_averager.dart` + Dart `variance.dart` + canonical-polyline `Track` fields + `WorkspaceState.baselineLapKey` + auto-derived `LapDelta` math channel) with: Rust `track_projection.rs` (`Projector` — directional position matching with ±90° heading filter and ±10-segment local search) + Rust `variance.rs` (`variance_time`, `variance_dist`, `current_lap_at`, `lap_start_time`, `sector_number_at`); `flutter_rust_bridge` adapters in `app/rust/src/api/lap_delta.rs`; Dart dispatch in `math_channel_evaluator.dart` via a new `LapContext`; per-session `Workspace.mainLapNumber: int?`, `Workspace.overlayLapKey: ({String sessionId, int lapNumber})?`, `Workspace.starredLapNumber: int?` (workspace schema bumped); synthesised `Time` base channel; five hardcoded built-in math channels (`LapNumber`, `LapTime`, `LapDistance`, `Lap Delta T`, `Lap Delta D` in `kBuiltinMathChannels`); lap-table main/overlay radio columns + star toggle + cross-session overlay picker. The four `Track` polyline fields (`canonicalPolyline`, `polylineSourceSessionId`, `polylineSourceLapCount`, `polylineDerivedAtMs`), the Track editor's Polyline section, and the cyan-dashed / faded source-lap overlays are removed; legacy `.idl0t` and `.idl0w` files load with the extra keys silently ignored. Spec updates: §16 (canonical polyline rolled back), §19 (function table + variance paragraph + Time base channel), §21.3 (main/overlay/starred designation replaces baselineLapKey), §25 (tutorial channels). Supersedes the 2026-05-08 variance architecture work logged under the "Gate placement, sector timing, ghost lap delta" entry above.

---

## Blocked (open spec TODOs — resolve before implementing)

- [ ] **Analog front-end** — TODO #2: voltage range and ADC resolution not defined; analog parsing unimplementable
- [ ] **1600 Hz validation** — TODO #3: LSM6DSO32 throughput at 1600 Hz over SPI not yet validated on hardware
- [ ] **Firmware JSON endpoint** — TODO #10: `/files` must return JSON before WiFi transfer can be implemented

---

## Queue — Track Gates Redesign (Track-first lap timing + editor modal)

- [ ] **Session Gates: ad-hoc analysis overlay using the dormant
      `Workspace.lapGates` / `Workspace.sectorGates` fields. Brainstorm
      first; covers per-session sectors that don't pollute the canonical
      Track sectors.**
- [ ] **Smart auto-detect off-Track segments for Track creation (Q8 Option 4
      from the design — hover an unrecognized polyline section and accept
      the auto-detected bounds in one click).**
- [ ] **Drop `Workspace.lapGates` / `Workspace.sectorGates` fields entirely
      once Session Gates is decided.**

---

## Migrated from spec §2 Open Items (2026-05-04 overhaul)

These items were previously tracked in `docs/IDL0_SPEC.md §2 Open Items`. The spec is now strictly specification; project work lives here per `CLAUDE.md §10`. The original TODO numbering (TODO #N) is preserved so existing inline references in the spec body resolve to the entries below.

- [ ] **TODO #9: Pricing decision** — $300–350 recommendation pending (Isaac, High)
- [ ] **TODO #11: Android WiFi socket binding** — Flutter platform channel binding HTTP socket to specific `Network` object (Android 10+ routes HTTP to cellular when WiFi has no internet) (Dev, High)
- [ ] **TODO #12: Firmware HTTP Range request support** — for resumable downloads on `/download` (Isaac, Medium)
- [ ] **TODO #13: Firmware unique device ID** — derive SSID/BLE name from `esp_efuse_mac_get_default()` last 4 bytes (Isaac, High)
- [ ] **TODO #14: Firmware SD-full threshold check + BLE notification** — stop logging at 200 MB free, notify over BLE (Isaac, Medium)
- [ ] **TODO #15: Firmware soft battery cutoff** — write SESSION_END, flush SD, BLE notify "Battery critical", power off at minimum LiPo voltage (Isaac, High)
- [ ] **TODO #16: Firmware per-device WiFi password** — derive from device ID, replace shared `datalogger123` default (Isaac, Medium)
- [ ] **TODO #17: SD overwrite-oldest-session when full** — config option, default off (Isaac, Low)
- [x] **TODO #19: Firmware partition table migration to OTA layout** — `firmware/partitions.csv` is the §4.6 dual-OTA layout (ota_0 / ota_1 at 1500 KB each); `sdkconfig.defaults` sets 4 MB flash and points at the custom table. Shipped during P8 build-fixing; verified by P9 OTA.
- [ ] **TODO #21: Validate ESP32-C6 simultaneous BLE central+peripheral roles** — required for HRM (BLE central) support; configure in ESP-IDF before BLE stack is built to avoid architectural rework (Isaac, High)
- [ ] **TODO #24: "Verify calibration" check** — compare live gravity vector to stored rotation matrix, warn if misaligned beyond tolerance (Isaac, Low)
- [ ] **TODO #25: tools/config_generator utility** — produce valid `idl0_config.json` from CLI args for rapid multi-device setup at races (Dev, Low)

---

## Queue — Release / Ops

- [ ] **Production keystore for Play Store** — when this app is ever
      published, the shared dev keystore at `~/.android/idl0-dev.jks`
      (used by `app/android/app/build.gradle.kts` for both debug and
      release builds) is unsuitable: passwords are in source, alias is
      generic, and the cert is committed-friendly. Generate a fresh
      release keystore, store it outside the repo, gate the signing
      config in Gradle on `release.signingConfig` overrides (e.g.
      `key.properties` loaded from env or a CI secret store), back it
      up to a password manager — **losing the release key means you can
      never update the published app.** Until then the shared
      dev keystore keeps cert stable across `flutter install` so the
      on-device session library survives reinstalls.

---

## Queue — Firmware Bring-up

- [x] **P1 — v2 spec lock + parser update** — IMU_SAMPLE / GPS_FIX
      timestamp fields, §3.6 device ID, §5.1 CRC32, §5.3 SESSION_END
      semantics, §10.2 SD layout. Dart parser updated to read new
      layout (timestamps read-and-discarded for now; model change to
      consume them is a follow-up).
- [x] **P2 — Firmware ESP-IDF scaffold** — `Firmware/` directory with
      CMakeLists, sdkconfig.defaults, partitions, vendored
      `lsm6dso32x_STdC` component, empty module stubs. Builds clean
      via `idf.py build`. Pin-dependent work blocked on netlist export.
- [x] **P3 — pinout lock + LED hello-world** — `firmware/main/pins.h`
      filled from KiCad netlist (13 named signals); LED on GPIO9
      (BOOT strap, active-high through R1/D1) wrapped by new
      `led_status` module; `app_main` runs the 1 Hz idle blink.
      `idf.py build` deferred — toolchain not on this session's PATH
      and esp-idf-eim MCP not responding.
- [x] **P4 — BLE control plane** — NimBLE peripheral, GATT service FF
      (FF03 control / FF04 status), `IDL0-XXXX` advertising, command
      dispatch wired to app_main. Verified with nRF Connect.
- [x] **P5 — SD-card session logger** — firmware mounts the SD card over
      SPI and reports its presence in the §7.3 BLE status string; v2
      binary-format encoders for the file header, `IMU_SAMPLE`, `GPS_FIX`,
      `CHANNEL_SAMPLE`, `SESSION_END`, and the CRC-32/ISO-HDLC trailer;
      `idl0_config.json` loader; session start/stop writes a complete
      `header + SESSION_END` `.idl0` file. App side: Device tab SD/GPS/IMU
      peripheral status display; v2 parser reads the 6-byte (12-char hex)
      device ID per the §3.6 correction. New `app/tool/dump_idl0.dart`
      header-dump CLI for P5-P7 verification.
- [x] **P6 — GPS UART + writer ring buffer** — `writer_task` lock-free ring
      buffer for SD writes (sensor tasks append and return immediately); new
      `gps_parser` module (NMEA RMC/GGA, host-testable C99) + `gps_task`
      emitting `GPS_FIX` records into writer; centralised `status` module for
      §7.3 BLE status publishing; session file rename to
      `/sessions/YYYY-MM-DD_HH-MM-SS.idl0` on first fix; `GPS: FIX|NOFIX|ABSENT`
      state in BLE status; 5-second lost-lock watchdog. Hardware: ESP→MAX-M10S
      TX trace open (9600 baud / 1 Hz / portable defaults); `gps_sample_rate_hz`
      pinned to `IDL0_GPS_ACTUAL_RATE_HZ = 1`; UBX-CFG burst deferred for next
      board revision.
- [x] **P7 — IMU SPI sampling** — LSM6DSO32 on CS=GPIO2 via SPI with vendored
      ST register-access driver (`lsm6dso32x_STdC`, upstream tag v2.3.0,
      under `firmware/components/`); WHO_AM_I check, ODR/full-scale/power-mode
      config, continuous FIFO+BDR; `imu_task` polls FIFO every 50 ms, pairs
      gyro+accel into `IMU_SAMPLE` records with per-sample `timestamp_us` walking
      back from the read instant at the configured ODR, submits one record per
      pair to the writer pipeline. `IMU: OK|PARTIAL|ERROR|ABSENT` in §7.3 BLE
      status (PARTIAL reserved for multi-IMU). On-chip FIFO overrun sticky bit
      logged but not written to file (drops visible app-side as timestamp gaps).
      Multi-IMU (IMU1 on CS=GPIO21, IMU2 on CS=GPIO22) deferred until 3-IMU
      harness is available; driver singleton ready for multi-IMU path as
      structural change only.
- [x] **P8 — WiFi server** — on-demand AP via `CMD_WIFI_ON`/`CMD_WIFI_OFF`
      (§7.2), SSID `IDL0-XXXX` (§3.6), password `datalogger123` (§6 shared
      default), IP 192.168.4.1. Four endpoints: `GET /files` (JSON session
      list), `GET /download?file=…` (chunked 8 KB with HTTP 206 + Content-Range),
      `GET /delete?file=…` (path-guarded), `POST /config` (JSON validation +
      persist to `/sdcard/idl0_config.json`). Throughput tuning: lwIP 16 KB
      buffers, WiFi RX 16 / TX 32, httpd stack 8 KB → ~500+ KB/s on C6 AP.
      `WiFi: ON|OFF` in §7.3 BLE status. App-side `WifiTransfer` already targets
      these endpoints. OTA (`/ota`) + `partitions.csv` migration deferred to P9.
- [x] **P8 follow-up — panel-scoped WiFi bind lifecycle (app).** Per-op
      `WifiNetworkBinder.bind`/`release` on Android 10+ raced the
      `requestNetwork`/`unregisterNetworkCallback` cycle: first call
      succeeded, second silently timed out at 10 s. `WifiService` now
      exposes `bind()` / `release()` and `BleService` exposes
      `wifiOn()` / `wifiOff()`; `DownloadPanel` owns the lifecycle —
      bind + `CMD_WIFI_ON` on the connected transition, release +
      `CMD_WIFI_OFF` on disconnect or dispose. `flutter test
      test/transport/real_wifi_service_test.dart test/ui/data/download_panel_test.dart`
      passes 13/13; full transport + UI/data suite 57/57.
- [x] **P9 — OTA endpoint + manual rollback** — `POST /ota` on the WiFi AP
      streams the raw `.bin` through `esp_ota_*` (SHA-256 verified by
      `esp_ota_end`); device reboots ~500 ms after the 200 response. New
      `CMD_OTA_CONFIRM = 0x06` (§7.2) commits the running image; §7.3 status
      gains an `OTA: PENDING_VERIFY` line until the app confirms — without
      confirmation, the bootloader rolls back on next reboot. `app_main`
      latches pending-verify via `esp_ota_get_state_partition`; never
      auto-marks. Partition migration (TODO #19) closed; signed images,
      anti-rollback, auto-update-from-web, and OTA UI deferred.
- [x] **Firmware auto-update from the web (2026-06-29)** — the deferred P9
      auto-update layer. `FirmwareCatalog`/`GitHubReleasesCatalog` reads the
      GitHub Releases API (stable = `/releases/latest`, beta lists; channels
      via the prerelease flag), `firmwareUpdateProvider` compares against the
      device's `Firmware:` §7.3 line (now emitted by `status.c`), and the
      Settings card + Device-hero banner download the `.bin` and reuse the
      existing OTA push. `.github/workflows/firmware-release.yml` builds +
      publishes on a `v*` tag. SPEC §7.3/§27.1/§27.4/§27.7. Design +
      plan. Remaining: efuse anti-rollback; the
      first durable release is cut after the saucyeng repo split.
- [x] **Schema v3 — per-channel scale/offset in registry** — IDL0 binary
      file format gains a 40-byte channel registry entry with `scale: f32`
      and `offset: f32`; parser produces already-scaled physical values
      (g, dps, bar) instead of raw int16 LSB. Per-IMU `accel_range_g[3]` /
      `gyro_range_dps[3]` in config supports mixed-range IMUs. Schema bumped
      2 → 3; v2 parser path scheduled for cleanup on 2026-06-03.
- [ ] **2026-06-03: Remove v2 binary parser path** — schema v3 launched
      2026-05-20. Two weeks later, delete `parseV2`, `_parseV2*Record`,
      `_readRegistryEntryV2`, the v2 test group in `binary_parser_test.dart`,
      and the v2 dispatcher branch in `BinaryParser.parse()`. Stage 5 / Task 15
      for the full checklist. Automated reminder
      scheduled via CronCreate.
- [ ] **Multi-IMU bring-up** — IMU1 on CS=GPIO21, IMU2 on CS=GPIO22; each with
      its own SPI + driver instance; tagged FIFO reads distinguish per-IMU samples.
      Deferred until a 3-IMU harness is available for hardware validation.
- [ ] **TX trace rework + UBX-CFG init burst** — restore ESP→MAX-M10S TX on
      next board revision; implement UBX-CFG command for configurable GPS sample
      rate (unpins `gps_sample_rate_hz` from firmware constant).
- [ ] **Extract NMEA parser from `gps_driver.c` into `gps_nmea.c`** so the host
      test under `firmware/test/test_gps_nmea.c` actually links and runs.
      Pure-C99 parser; UART + state machine stay in `gps_driver.c`. Move the
      NOFIX→FIX transition out of `idl0_gps_feed_line` into `gps_task`.
- [ ] **Channel-registry population** — wheel-speed and analog channels in
      the v2 file-header channel registry; deferred with the ADC work
      (blocked on TODO #2).
- [ ] **Vendored ST driver tag pin** — document the upstream `lsm6dso32x_STdC`
      tag (currently v2.3.0) in `firmware/components/lsm6dso32x_STdC/UPSTREAM.md`
      or a README if tracking master SHA instead of tagged release.
- [ ] **Battery driver (§10.1)** — measure LiPo state-of-charge and expose
      via `idl0_battery_soc()` accessor called by the status module.
- [ ] **Composite sessionId** — replace the firmware-generated 16-byte UUID
      with `${deviceId}-${sessionStartMs}` (12 hex MAC + 13-digit ms).
      Eliminates cross-device collision by construction (different MACs),
      saves 16 bytes per file header, and makes sessionIds debuggable at
      a glance (`grep aabbccddeeff /sessions/` → all sessions from that
      device). Drop the UUID field from the binary header; bump
      `schema_version` to 3; `BinaryParser.parseV3` synthesizes
      `sessionId = "$deviceId-$sessionStartMs"` from the already-present
      fields. v2 parser stays for legacy files. App-side
      `SessionNotifier.addSession` currently logs a `WARN` on UUID
      collision and lets latest-import overwrite the previous entry —
      that warning can be removed once collisions are structurally
      impossible. Bundle with the next firmware schema bump (e.g.
      multi-IMU, per-device password) so users see one migration, not
      two.

---

## Queue — Analyze tab + chart enhancements (2026-05-26)

Brainstorm each item before implementation per CLAUDE.md §2. Dispositions
inline. Order is not implementation order — pick the next one to ship
based on impact + brainstorm-readiness.

- [x] **Analyze tab vertical shrink** *(spec-during, §26)* — replaced
      the persistent `ChartCursor` strip beneath every time-series
      chart with a brand-styled fl_chart tooltip pinned to cursor A
      and a small `A → B  Δ <t>` chip above the chart when both
      cursors are pinned. New pure-Dart `formatChannelValue` (3 sig
      figs, magnitude-aware decimals, ±∞/NaN handling) drives both
      the tooltip and the chip; tooltip indicators are suppressed
      during multi-finger pinch. Per-channel B values dropped from
      inline UI — `Copy Cursor Values` (chart context menu) remains
      the export path. Reclaims ~28 dp per chart on mobile. 15 tests
      (8 formatter + 7 chart) pass; `flutter analyze` count unchanged
      from pre-work baseline (pre-existing test-file errors in
      unrelated tabs). Spec §26 + design_rationale.md updated.
- [x] **Analyze tile-based chart decimation** *(spec-during, §26.8 + §15.3)* —
      tile-based lazy min/max decimation in Rust, with raw samples
      handed off to Rust at first chart render. Pinch/pan stay smooth
      at 60fps on Pixel 8 Pro for sessions up to 2hr × 800Hz. Coarsest
      tier eagerly built per worksheet; finer tiers stream async with
      next-coarser upscaling as fallback. Cursor readouts bypass tiles
      via exact `sample_at`.
- [ ] **Wire `sample_at` into cursor readouts** *(spec-during, §26.8)* —
      the Rust `sample_at` function is exported and tested but no Dart
      call site exists. The in-chart tooltip can't use it (sync constraint),
      so wire it into either the `Copy Cursor Values` chart-context-menu
      action or a dedicated cursor-value chip below the chart. See the
      §26.8 footnote.
- [ ] **Rust core / Dart shell architecture** *(spec-first, §1)* —
      migrate bulk sample-array ownership from Dart to Rust. Parser
      sample payload, math channel evaluator, GPX import, calibration
      math move; session metadata, workspace, SQLite, UI, transport,
      file I/O entry points stay Dart. Positions for cross-platform
      UI future (WASM, uniffi, jni) and makes the chart layer's
      `ingest_channel` handoff redundant. Brainstorm in parallel
      session 2026-05-27.
- [ ] **UI density pass** *(no-spec-change)* — second pass on the
      quiet-field-manual brand to tighten spacing / type / row
      heights throughout. No new entities, no API change.
      Brainstorm: which screens are too sparse / too dense today,
      and what's the measurable reduction (rows per screen, dp
      per panel).
- [ ] **FFT cursor window** *(spec-during, §26.4 FFT chart)* — FFT
      input window becomes ±N seconds around the worksheet cursor
      instead of the full lap / full session. Default N = 2 s.
      Touches Rust DSP (range-bounded FFT) + Analyze UI (window
      slider in FFT chart properties). Brainstorm: window math
      (centred / leading / trailing), interaction with the cursor
      pair (A/B → fixed window between cursors?), what happens
      when cursor is outside any sample range.
- [ ] **Spectrogram chart type** *(spec-first, §26 — new chart type)*
      — STFT-derived 2-D spectrogram (time × frequency × magnitude
      heatmap). New `ChartType.spectrogram` slot + Rust spectrogram
      function (already partially in `MathChannelEvaluator`).
      Architectural: colour-map choice, hop size policy, render
      backend (custom painter vs. fl_chart limitation).
- [ ] **Histogram chart type** *(spec-first, §26 — new chart type)*
      — single-channel value distribution across the selected
      lap/window. New `ChartType.histogram`. Architectural: bin
      count strategy, log/linear Y, multi-channel overlay (or one
      channel per slot).
- [ ] **Scatter plot chart type** *(spec-first, §26 — new chart type)*
      — two-channel X-vs-Y, coloured by time / lap / a third channel.
      New `ChartType.scatter`. Architectural: density rendering
      (point vs. heatmap), down-sampling rules, when to switch from
      points to hexbin.
- [ ] **Synchronized video channel** *(spec-first — new architectural
      surface; biggest scope)* — video file linked to a session,
      synced to the worksheet cursor for play/pause/scrub. Touches
      data layer (new entity, file storage, sync offset metadata),
      UI (player widget, scrub bar, time-base reconciliation),
      transport (import + maybe Drive sync of the video file). Needs
      its own design doc before queue
      decomposition.

---

*When all queue items are complete and blocked items are resolved, this document is done.*
