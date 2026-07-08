# Changelog

All notable changes to IDL0 will be documented here.

Format: [Semantic Versioning](https://semver.org) — `MAJOR.MINOR.PATCH`

Log file schema versions and app versions are independent. Both are noted where relevant.

---

## [Unreleased]

### Fixed

- **Device firmware version with a leading `v` broke the update check and doubled in the hero (2026-07-08).** A local git-describe build reports the tag name verbatim (`v0.1.0`), but the app only stripped the leading `v` from *release tags* (`firmware_catalog.dart`), not from the *device-reported* version — so `Version.parse('v0.1.0')` threw and Settings showed "Couldn't check: device version unparseable," while the Device-hero readout rendered `vv0.1.0` (the row prepends its own `v`). `DeviceStatus.fromString` now strips a single leading `v` when parsing the §7.3 `Firmware:` line, normalising storage so the check parses, the hero shows one `v`, and the auto-confirm version match stays consistent with the release side (which is already `v`-stripped). Surfaced during v0.1.0 hardware bring-up. **Spec disposition:** no spec change needed — this makes the implementation match §27.7's existing "version of record = tag with `v` stripped" contract.

### Added

- **OTA release enablement — rollback, release CI fix, §27.7 auto-confirm + ahead-of-channel, across both repos (2026-07-06).** The finishing sprint the firmware repo split unblocked:
  - **Firmware: OTA rollback is now real.** `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=y` landed in `sdkconfig.defaults` — OTA images boot `PENDING_VERIFY` and the bootloader rolls back on reboot unless confirmed via `CMD_OTA_CONFIRM` (§4.6/§7.2). The state machine `ota.c`/`status.c` were written against was previously compiled out. Bootloader option: previously-flashed devices need one USB reflash. App image fits the 1600K slot with 4% free (headroom watch in TASKS).
  - **Firmware release CI could publish the wrong `.bin` — fixed.** `firmware-release.yml` picked the asset via `find build -maxdepth 1 -name '*.bin' | head -1`, and `build/` contains both `idl0_firmware.bin` and the 8-byte `ota_data_initial.bin` seed — filesystem-order dependent. Now an explicit `Stage release assets` step hardcodes `build/idl0_firmware.bin` (existence-guarded), publishing exactly one `.bin` per release as `idl0-firmware-v<ver>.bin` + `idl0-firmware-v<ver>.bin.sha256` (`sha256sum` format — app parses the first token; humans get `sha256sum -c`). **Spec disposition:** spec-during — §27.7 sha-asset wording updated.
  - **App: §27.7 completed — OTA auto-confirm + ahead-of-channel note.** After a catalog OTA push + reboot, the app auto-sends `CMD_OTA_CONFIRM` once the reconnected device reports the pushed version with `OTA: PENDING_VERIFY` (one-shot `armOtaAutoConfirm` on `DeviceNotifier`, consumed only on version-bearing frames received **while connected** — the initial handshake frame arrives before `connect()` resolves and must not spend the arm; review-caught). A rolled-back device's first connected frame mismatches → disarm without confirm; manual `.bin` pushes never arm and disarm any pending expectation; the manual pending-verify card stays as fallback. The update check now distinguishes a device *ahead* of its channel (`FirmwareAheadOfChannel`): neutral informational note, never a downgrade prompt, hero banner stays absent. Tests model real BLE ordering via a `statusDuringConnect` hook on the shared mock. **Spec disposition:** spec-during — §27.7 auto-confirm paragraph.
  - **App: Device hero shows firmware version.** Neutral `FW v<version>` entry in the peripheral readout when the device reports §7.3 `Firmware:` (§23.10 updated — no longer "planned").
  - **App: pushFirmware WiFi-binding audit closed.** No leak by design (binder untouched by `pushFirmware`; bind lifecycle owned by `WifiBindController`); regression tests pin the OTA-reboot release path and no-binder/cancel paths. Found in passing (queued in TASKS): early `cancel()` before the OTA connection establishes leaves `PushFirmwareHandle.done` unsettled.
  - **Repo hygiene post-split:** firmware repo gained `docs/README.md` (canonical-spec pointer + §-map + release process) and its own `CLAUDE.md`; stale `docs/IDL0_SPEC.md` path references repointed (§ numbers untouched); `managed_components/` gitignored; app's `kFirmwareRepoSlug` comment now documents the release asset contract with a versioned-asset parsing test.

- **Suspension estimator — calibrated mounts, GPS-velocity aiding, and the offline RTS wheel smoother (2026-07-03).** Three linked upgrades to the M2a engine:
  - **Calibrated unsprung mounts (a real bug fixed).** Per-session mount auto-refinement aligned each unsprung IMU's static gravity to chassis **+Z**, silently absorbing the parked attitude — a leaning bike or flopped bars at the trailhead became a permanent mount-tilt error, i.e. a DC gravity leak into the wheel-drive signal (a velocity ramp between anchors). The refinement target is now a caller-supplied up-reference (the mounted IMU0's window-mean gravity), and the reference geometry now carries mounts **baked from the flat-ground calibration recording** (`2026-06-20_18-10-32.idl0` — which itself leaned 13.2°, proving the point). Baking also exposed that both unsprung coarse picks carried a **180° yaw error** inherited from the pre-fix identity-IMU0 frame (gravity can't see yaw; the travel axis is ~90 % vertical, so every prior validation passed): the yaw datum was disambiguated on a riding log by horizontal diff-accel RMS (shared braking/cornering accelerations cancel under the correct yaw — 23.4→17.8 m/s² front, 18.7→15.5 m/s² rear). Per-session refinement remains as opt-in `refine_mounts` (default **off**), now with the corrected target.
  - **GPS velocity wired in** (audit F4 closed). `EstimatorInput::from_lookup` now builds fixes from `GPS_SpeedKmh` + `GPS_Heading` at their per-fix event times (new `ChannelLookup::sample_times`), and the runner applies them latency-corrected (`gps_latency_s`, default 0.2 s — the module's internal filter delays its solution) with a min-speed gate (`gps_min_speed_mps`, 0.5 m/s — course is noise below walking pace) and a fix-quality gate. The `GpsVelocity` factor is now **horizontal 2-DOF** (speed + course carry no vertical information); `gps_sigma` default loosened to 0.5 m/s to model the GPS's own smoothed, correlated output. Anchors chassis-velocity DC + observes heading while moving; `v_chassis` is now pinned on moving logs, not just at stops.
  - **Fixed-interval RTS smoother over the wheel chains** (`estimate/smooth.rs`, `smooth` config flag, default **on**). The wheel `{w, ẇ}` block is exactly decoupled inside the 24-DOF filter (block-diagonal F/Q/P₀; no other factor touches its columns), so a standalone 2-state pass over the run's captured drives + factor schedule reproduces the forward marginals — locked in by a replay-equivalence regression (`run_smooth_off_forward_wheel_outputs_match_standalone_replay`, agreement < 1e-9 over a stationary/riding/airborne profile) — and the backward sweep then distributes each topout/ZUPT anchor over the interval *before* it: two-sided boundary conditions on the travel integral instead of the causal drift-then-yank. O(n) at 40 B/sample/wheel, transient.
  - Plumbing: `run_trace` now returns the loop's own captured drives + the final airborne flag (exact by construction; ~55 lines of re-derivation deleted); `SuspensionConfig` gains `gps_latency_s` / `gps_min_speed_mps` / `refine_mounts` / `smooth` (FRB regenerated; app defaults updated). Full `idl-rs` suite green (547; the one `parse::v3` failure is pre-existing on the snapshot commit, unrelated). **Spec disposition:** spec-during — design doc §5/§7/staged-plan updated; the estimator's IDL0_SPEC.md section remains owed (tracked in TASKS).

- **Firmware auto-update from GitHub Releases (2026-06-29).** The app now pulls published firmware from a GitHub repo (`kFirmwareRepoSlug`) over the public Releases API, compares the running version against the channel's latest (semver, via `pub_semver`), and surfaces an "update available vX → vY" card (Settings → Firmware) plus a Device-hero banner. Accepting downloads the `.bin` — optionally verifying a published `firmware.bin.sha256` — and reuses the existing OTA push (`/ota` → reboot → `CMD_OTA_CONFIRM`). Stable/beta channels map onto the GitHub prerelease flag; channel picker + auto-check toggle persist in settings. Firmware gains a `Firmware: <semver>` line in the §7.3 BLE status string so the check works in idle/BLE mode, and a `.github/workflows/firmware-release.yml` builds + publishes on a `v*` tag (version of record = the tag). **Spec disposition:** spec-during — SPEC §7.3, §27.1, §27.4, and new §27.7.

### Changed

- **Analyze + Maths chart-UX polish for release (2026-06-26).** Five tweaks across the chart stack:
  - **Mouse-wheel zoom consolidated; the Windows "stuck — every wheel zooms" bug fixed.** Two competing `onPointerSignal` handlers (one in `ChartContextMenu`, one in `TimeSeriesChart`) had contradictory modifiers — Shift meant *pan* in one and *zoom* in the other, Alt meant *zoom* in both with different magnitudes — so a single notch double-fired. Wheel handling now lives only in the chart, on one scheme: **Ctrl + wheel = zoom at cursor, Shift + wheel = pan, plain wheel = scroll the worksheet** (pure `wheelModeFor(ctrl, shift)` in `chart_action.dart`, shared with the Settings reference). Root cause of the "stuck" mode: a stale `HardwareKeyboard` modifier after an Alt+Tab focus change (the missed key-up leaves Alt "pressed"); since Alt is no longer a wheel trigger, that desync can no longer hijack a plain wheel. The two SDK reset APIs were unusable (`clearState()` is `@visibleForTesting` and tears down keyboard handlers; `syncKeyboardState()` only *adds* engine-pressed keys), so the fix is the scheme itself.
  - **Context menu layered into cascading submenus.** The flat ~21-item `showMenu` list became a `MenuAnchor` with hover-out **Cursor / Zoom / Pan** `SubmenuButton`s, Reset View / Copy Cursor Values / Properties at the top level, and the disabled v2 placeholders tucked under **More** — ~6 top-level rows. Dropped the `ChartMenuKey` round-trip (items dispatch `ChartAction` directly).
  - **Maths preview is now the real interactive chart.** `ExpressionPreview` renders the active math channel through the same Analyze `TimeSeriesChart` (Ctrl/Shift-wheel zoom/pan, cursors, right-click menu, per-viewport re-decimation via the shared tile cache) instead of a static min/max envelope — so a filter's effect is visible at any zoom while its parameters change, in real time. Enabled by making the action dispatcher slot-agnostic: vertical-zoom/Reset Y writes now route through an `onApplyYScale` callback (worksheet slot, or the preview's local ephemeral state) and the chart hosts outside a worksheet via a synthetic `worksheetId`. Deleted the bespoke `_previewSpotsFromTile` rendering and the one-off `mathPreviewTileProvider` (net code reduction).
  - **Settings → Controls.** New read-only reference of the chart keyboard / mouse / wheel shortcuts (grouped Mouse wheel / Mouse / Keyboard as leader-dot `SpecRow`s, mirroring `kDefaultChartBindings` + `wheelModeFor`). Editable rebinding stays a v2 follow-up.
  - **Desktop nav rail slimmed** from the stock 192 dp extended width to 160 dp (`extendedNavigationRailWidth`), reclaiming the dead space between the short rail labels and the body for the Analyze charts.

  Tests: dispatcher rewritten to assert the `onApplyYScale` seam (27 cases), context-menu widget tests updated to navigate the new submenus, new `wheelModeFor` unit suite — 37 chart tests green; `flutter analyze` clean across the touched files. **Spec disposition:** spec-during — SPEC §26.7 (menu + wheel scheme + Y seam), §25 (interactive preview), and §27.4 (Controls section) updated.

- **Suspension estimator — bounds-only by default; sag prior is now opt-in (2026-06-26).** The `SagPrior` (a soft continuous pull of riding travel toward static sag) no longer fires by default. New `EstimatorConfig::use_sag_prior` flag (default **false**) gates it; travel DC is now anchored only by the airborne **topout reference** and the `[0, travel_max]` **barrier**. Rationale: the sag prior's recapture corner (τ < ~0.4 s) lands *inside* the suspension band and attenuates the recovered **velocity** — the deliverable (FFT / spectrogram / histogram) — for the sake of a tighter absolute-travel DC that the user has deprioritized. Measured A/B on a real jump session (169 466 samples, `2026-06-16_18-28-42.idl0`): bounds-only front travel spans the full stroke (sd 58 mm, median 37 mm, dynamic sag 54 mm, full travel only on the top ~1%) and **does not rail** — correcting the prior code's "turning sag off rails travel" assumption; front velocity widens (σ 655 vs 530 mm/s) and de-skews (+0.20 vs +1.39) versus sag-on, i.e. more real motion passes. The app/CLI/GUI all run bounds-only (the bridge hardcodes `use_sag_prior = false`, so the FFI mirror is unchanged → no codegen); the engine default can be flipped to A/B from a test or the CLI (`examples/compare_sag.rs`). The app's `sagSigma` knob is consequently inert. Caveat: a **no-airtime** ride has no continuous travel-DC anchor under bounds-only, so absolute travel DC may drift (accepted — velocity is the deliverable; enable sag if absolute travel matters). New regression `sag_prior_gate_off_by_default_keeps_rigid_riding_travel_at_topout`. **Spec disposition:** spec-during — design §5 updated. **Also:** the default analysis workbook's Suspension sheet gains two overlaid histograms (front + rear) comparing the DSP-filtered velocity (`Fork/Shock velocity`, converted to mm/s) against the estimator velocity, so the estimator output can be sanity-checked against the simple filter.

### Fixed

- **Session files no longer freeze at the GPS-rename size on power loss — the writer now `fsync`s, committing the file size at the ~1 Hz cadence (2026-06-29).** The firmware logs via stdio over FATFS and flushed data every ~1 s (`idl0_sd_flush`) but never `fsync`'d, so FATFS only wrote the directory-entry **size** at `f_close` — i.e. the first-GPS-fix rename and session close. A hard power cut between those froze the on-disk size at the rename point (a few seconds in) while the rest of the ride's samples kept landing in clusters the FAT never accounted for: the file read as ~48 KB and looked truncated, though the data was physically present (recoverable only via `idl-rs recover`, which walks the raw record stream independent of FAT size). `idl0_sd_flush` now does `fflush` **then** `fsync(fileno)` under the existing file mutex, so the committed size never lags the data by more than the ~1 Hz flush interval; a power-interrupted session reads complete up to ≤1 s before the cut. The fsync runs only on the writer task (never the IMU drain, which hands off lock-free via the ring buffer) and adds ~2 metadata sectors on top of the cluster write the writer already did each second — no new SD cadence, negligible hot-loop cost (single-core C6, 1 ms tick; SD I/O blocks the writer on DMA and yields the core to the drain; the only shared resource is the SPI2 bus, serialized one ~512 B transaction at a time; the IMU FIFO keeps ~300 ms headroom at `ovr=0`). **Verification:** field power-cut test (log → pull power mid-ride → confirm the downloaded file spans the full ride and `ovr` stays 0) — pending build/flash on hardware. **Spec disposition:** spec-during — §5.3 (SESSION_END durability) and §10.2 (SD durability) updated.

- **GPS speed read 100× high and `Distance` ran 100× long — `GPS_SpeedKmh` now engine-scaled to physical km/h (2026-06-26).** The firmware logs GPS speed as km/h × 100 (`speed_x100`, §5.6), but the engine pushed it to the `GPS_SpeedKmh` channel **raw** while every consumer assumed plain km/h — so the colour-by / time-series axis read ~3373 instead of ~33.7 km/h, `Distance` synthesis (`speed/3.6`) integrated a 100×-too-fast speed, and the lap-distance anchor threshold (`> 5 km/h`) never tripped. Fixed at the core parser: `GPS_SpeedKmh` is now stored as a compact `i32` with a `0.01` column scale, so `materialize()` yields physical km/h — `Distance`, math expressions, the colour scale, and lap anchoring are all correct with no per-consumer division (the same `physical = stored × scale` path the IMU and registry channels use). The FIT exporter drops its compensating `/100`. Firmware and the `.idl0` on-wire format are unchanged (still km/h × 100) — existing logs reparse correctly, no re-record. New parse regression (raw 1000 → 10.0 km/h, `RawColumn::I32`); FIT speed tests updated to physical km/h. **Spec disposition:** spec-first — §5.7 marks `GPS_SpeedKmh` as the engine-scaled GPS-fix channel.

- **Suspension estimator — gravity-leveling no longer runs in free fall (NaN-poison + bogus-tilt fix) (2026-06-25).** `GravityLeveling` fired on *every* sample with no airborne gate and an unguarded `normalize()` of the measured up-vector. In free fall the chassis specific force collapses toward 0, so it normalized a ~0 vector → **NaN**, which the IEKF's singular-`S` guard did *not* catch (`try_inverse` of a NaN matrix returns `Some(NaN)`), poisoning the entire run; short of NaN it inflated the Jacobian ~9× and injected **bogus attitude tilt on every jump**, which then corrupts the lever term → travel. Three-part fix: (1) `GravityLeveling` is **gated off when `airborne[i]`** — in free fall there is no gravity direction to level against, so attitude propagates open-loop on the gyro through the short float and re-levels on landing; (2) the factor is now numerically **NaN-safe** (`try_normalize` / zero-Jacobian when `|specific force| ≈ 0` ⇒ K=0 no-op); (3) the IEKF **rejects a non-finite innovation** rather than applying it (closing the gap where a NaN `S` slipped past the singular-`S` guard). New behavioral regressions: `sustained_free_fall_does_not_nan_or_inject_tilt` (run-level — finite output + level attitude through a 0.4 s float) and `residual_and_jacobian_are_finite_in_free_fall`. Surfaced by the overnight adversarial audit (finding **F1**; report at `docs/estimator_filter_audit.md`). Full `idl-rs` suite 524 passed, 1 ignored (the one red is the pre-existing `parse::v3` session-start off-by-1s). **Spec disposition:** spec-during — design §5 notes gravity-leveling is gated in free fall.

- **Suspension estimator — corrected IMU0 mount frame; front travel no longer rails to the barrier (2026-06-24).** IMU0 (sprung/chassis reference) is physically mounted **X-rear, Y-right** (Z up), but its mount was identity (X-forward, Y-left) — a 180° yaw error. That inverted ωₓ/ω_y and the horizontal specific force, so the lever-arm rotational transport `ω̇×L + ω×(ω×L)` was *added* into wheel travel instead of cancelled — doubling it on hard pitch (landings) and railing front travel into the `[0, travel_max]` barrier. Validated on a real jump log: front-travel peak **182.1 → 138.9 mm** (now inside the 170 mm max), samples pinned at the barrier **1306 → 0**, and the clean ground-truth check (rear travels ~vertically) — rear **longitudinal** residual diff-accel **25.4 → 10.0 m/s² RMS**. Fix: IMU0 mount = 180° about Z, applied **once up front** to its accel/gyro so the orientation/bias fit and the lever-term ω̇ run in the chassis frame too — they were on **raw** IMU0 data, invisible under identity but wrong with a real mount (`fit_from_window`'s own contract says inputs are already mounted). IMU1/IMU2 mounts unchanged (already correct). New ground-truth test `reference_bike_imu0_mount_maps_x_rear_y_right_into_iso_frame`; corrected `run_refines_a_tilted_unsprung_mount` (it had silently assumed an identity IMU0 mount when building its synthetic rigid bike). No bridge/FFI change. **Spec disposition:** spec-during — design §7 (orientation/mounts) updated.

- **Suspension estimator — rough ground no longer snaps travel to topout (false free-fall) (2026-06-24).** The airborne/free-fall detector keyed only on the chassis specific force collapsing toward 0 (`airborne_accel_thresh`), so a rough-but-grounded light-chassis moment (rebound crest, terrain unweighting) that held `|accel₀|` below threshold long enough to pass the sustained-run gate was mislabeled as free fall and the topout reference snapped travel to 0 (the visible drop at e.g. 1:32.4 on a rough-but-not-airborne section). Free fall now requires a **second, relative** criterion: every present unsprung IMU's lever-compensated diff-accel must also be small (`airborne_diff_thresh`, default 5.0 m/s², hot-reload tunable in `suspension_estimator_provider.dart`). In real rigid-body free fall the topped-out wheel tracks the chassis so diff-accel ≈ 0; a terrain-driven wheel has a large diff-accel even when the chassis is momentarily light, so the relative test vetoes the false topout. New regression `rough_low_g_ground_with_large_diff_accel_is_not_flagged_airborne`; the prior airborne tests stay green (full `idl-rs` suite 522 passed, 1 ignored — the one unrelated red is the pre-existing `parse::v3` session-start off-by-1s). New field threaded through the `SuspensionConfig` bridge mirror + FRB bindings. **Spec disposition:** spec-during — design doc §5 (topout/free-fall) updated.

- **App: histogram count-axis scale control is now reachable — Lin/Log/Sqrt/Sq (2026-06-24).** SPEC §26.10/§26.12 specify the histogram count axis (per-bin percentage) shares the chart `yScale` control, and the chart already *applied* all four transforms — but the properties dialog hid the whole Y-axis section for histograms (the histogram owns its value axis), so the scale control was unreachable and every histogram was stuck on `linear`. The shared Lin/Log/Sqrt/Sq segmented control (extracted to a `_buildScaleControl` helper, shared with the generic Y-axis section) is now rendered in the histogram properties section as **"Count axis scale"**, and the chart's title-bar tag reflects the active non-linear scale (`log` / `sqrt` / `sq`) instead of only tagging `log`. No model or serialization change — `yScale` was already persisted and round-tripped for every chart type; only the widget was missing. **Spec disposition:** no spec change needed (brings the UI in line with the already-written §26.10/§26.12). The histogram **X-axis** (value) scale remains deferred — the proper form is log/sqrt-spaced re-binning in `idl-rs`, logged in TASKS.

- **App: GPS map now renders every selected session (2026-06-24).** Analyze chart tiles were fed the bound primary/overlay session pair (`workbookViewContextProvider`), so the GPS map only ever drew one track even with several sessions selected — and the per-session colour rows were labelled with raw session UUIDs. The GPS map (a spatial overlay, not a Main/Overlay lap comparison) now sources its session set from `effectiveSessionIdsProvider`, so every selected session's track renders; the `GpsMapChart` widget already iterated N sessions, it was simply starved of them. Per-session colour rows are labelled by session date via a shared `sessionDisplayLabel` helper (lifted from the lap-progression legend). Other chart types keep the bound pair. **Spec disposition:** spec-during — SPEC §26.0.a.

- **App: chart-type rail labels no longer break mid-word (2026-06-24).** The desktop chart-type rail buttons were a fixed 66 px — too narrow for "Spectrogram"/"Histogram" at the label font size, so they wrapped mid-word. Cards widened to 88 px with more padding (and the properties-dialog content-width ceiling raised) so labels fit. Visual only, no model change. **Spec disposition:** no spec change needed (cosmetic; §26.9 notes the rail is sized to fit labels).

### Added

- **App: Scatter / G-G chart in Analyze (2026-06-26).** A new `ChartType.scatter` plots one channel against another, tuned for the **G-G diagram** (lateral g vs longitudinal g — the friction circle). Two render modes: a uniform-stride-decimated **point cloud** (optionally coloured by a third channel through the Turbo colormap) and a 2D **density heatmap** (time-at-state). Equal-aspect with concentric reference g-circles by default, so the traction envelope reads round. Pairing, decimation, binning, and bound computation live in `idl-rs` (`scatter::{scatter_points, scatter_density}`); each render is a single one-way FRB call (`handle in → reduced result out`) — the engine returns the extent it used, so no axis bound round-trips the boundary. A single `CustomPainter` draws the cloud/heatmap and the reference rings through one coordinate transform (the spectrogram-chart pattern; `fl_chart` is not used). Slot fields `scatter*` (X/Y channel, mode, colour-by + scale, equal-aspect, reference-circles, bin count) persist per slot, gps-style gated in JSON. **Spec disposition:** spec-during — SPEC §26.14.

- **Dev tool: interactive travel-tuning GUI on real sessions (`tools/estimator_sim/gui.py`) + `run_trace` engine export (2026-06-25).** A new `idl-rs` `estimate::run::run_trace` returns an `EstimatorTrace` of the per-sample inputs the wheel integrators saw (the exact front/rear wheel-drive accelerations, plus the airborne-detector inputs and the stationary gate), and a `cargo run --example estimate_trace -- <session.idl0>` dumps it to CSV. A Python matplotlib GUI then replays the linear 2-state `{w, ẇ}` travel sub-filter over that **real** drive with live sliders (sag/topout/barrier/ZUPT σ, wheel pos/vel process noise, airborne thresholds, init), overlaying the full engine's actual travel as ground truth. Because the travel sub-filter is effectively decoupled from the rest of the 24-DOF state, the replay matches the engine to **~0.0 mm front / 0.04 mm rear** at default config — so the sliders show exactly what the engine would do, instantly, on a real log. Tuning/diagnostic only, not wired into the build. **Spec disposition:** no spec change needed (dev tooling; `run_trace` is additive debug API with no effect on `run`).

- **App: colour the GPS trace by a channel value — Turbo heatmap (2026-06-24).** A GPS chart can now colour its trace by one channel (chart properties → *Colour by*; `None` = solid per-session colours). The engine resamples the chosen channel onto each GPS fix nearest-sample (`gps_channel_values` in `idl-rs`, beside `build_gps_track` — one f64 per fix in fix order, `NaN` outside the channel span; only the small per-fix vector crosses FFI, the column stays in the handle), exposed via a thin `tracks.rs` FRB wrapper (`gpsChannelValues`) + `gpsChannelValuesProvider`. The app maps values through a Turbo colormap LUT (`turbo_colormap.dart`) into flutter_map's per-vertex `gradientColors`, on one min/max scale shared across all visible traces (auto, or a manual range), with a bottom-left colorbar legend showing the scale + channel. The choice persists on the chart slot (`gpsColorChannelId` / `gpsColorMin` / `gpsColorMax`, gps-gated in JSON). v1 covers raw/synthesized channels and the Turbo map only. **Spec disposition:** spec-during — SPEC §26.0.a / §26.9 / §15.3 (`gps_channel_values` seam).

- **App: in-app FIT export (Strava) with native lap splits (2026-06-23).** The session detail card exports a GPS session to a Garmin `.fit` (`export_fit_to_vec` engine bridge → bytes → file-picker save), emitting one FIT `lap` per detected lap so Strava shows per-lap splits. Laps come from the session's cached track-visit laps; the exporter's lap input was slimmed to a 3-field `FitLap` (`start_ms`/`end_ms`/`elapsed_ms`) to keep the full lap model off the FFI boundary. Desktop adds a post-export drag-to-Strava grip + reveal-in-file-manager (reusing `revealInFileManager`). Filename `YYYY-MM-DD_<venue>.fit` (resolved venue, else local time). SPEC §29.2.1.

- **Selectable / copyable file path + reveal-in-file-manager in the session detail card (2026-06-23).** The "File info" panel's field values are now selectable text (highlight/copy). The Path row gains two quick actions: a **Copy path** button (all platforms, with a confirmation snackbar) and, on desktop only, a **reveal-in-file-manager** button — `explorer /select` (Windows), `open -R` (macOS), or `xdg-open` of the containing folder (Linux). Failures surface a snackbar rather than throwing. SPEC §24.10.

- **`detrend(ch)` math function — global least-squares trend removal (2026-06-19).** New time-domain math-channel function (`idl-rs` `statistics::detrend`, dispatched in the `math` evaluator). Fits against the **sample index** `i = 0..N-1` (matching `scipy.signal.detrend`, no `[Time]` dependency) and removes the trend whole-series: `detrend(ch)` defaults to `linear` (removes constant offset + linear drift), `detrend(ch, mode)` takes `"linear"` / `"constant"` (alias `"mean"`) / `"none"`; an unknown mode is rejected at eval time like `butter`'s bad direction arg. The fit is computed **centered** (numerically stable on season-length runs) and is **NaN-aware** — it fits over finite samples only and leaves dropouts in place, intentionally unlike scipy so one gap can't blank a channel. Output inherits the input's length / units / quantity / sample rate. Worked use: `detrend(integrate(butter(2, 0.2, "high", [Fork rel accel])))` for drift-controlled velocity. SPEC §19.

- **Suspension estimator — stream outputs instead of retaining the full trajectory (long-session memory) (2026-06-24).** `run()` no longer holds a `Vec<MtbState>` for every sample (~200 B/sample → ~600 MB on a 1-hour 833 Hz log, on top of the input arrays — the likely OOM on long sessions). It now streams the four wheel outputs (front/rear travel + velocity, `Vec<f64>`) plus the per-sample stationary flag and a single `final_state`; `StateEstimate`'s memory is O(outputs), not O(samples × full state). Behaviour is identical (the full `idl-rs` suite, incl. every estimator run-level test, stays green at 492) — the regression guard for a pure memory refactor. The `chassis_velocity()`/`chassis_attitude()` accessors (unused; the future virtual-sensor surface will stream them when it lands) were dropped with the trajectory. No FFI/bridge-signature change (internal `StateEstimate` + the bridge's own extraction only). **Speed note:** profiling shows the per-sample cost is dense 24×24 matrix-multiply FLOPs (Joseph-form covariance update + `F·P·Fᵀ`), not allocation. (A fixed-size `SMatrix<24,24>` rewrite was benchmarked and is ~30% *slower* at this size — nalgebra's `DMatrix` gemm beats the unrolled static loop past ~6×6 — so it is ruled out, not deferred. The remaining headroom is allocation reduction and exploiting the near-scalar measurement Jacobians, O(n³) Joseph → ~O(n²); both modest and deferred.) **Spec disposition:** no spec change (internal engine memory optimization; the derived-channel contract is unchanged).

- **Suspension estimator — sag re-tuned to a moderate drift anchor + airborne hysteresis + velocity pin (2026-06-24).** Tuning/fix pass driven by the jump artifact where recovered travel "snaps back to the sag point before landing," plus the histogram that railed at both `0` and full travel. A 2-state `{w, ẇ}` Riccati + drift sweep settled the sag question with numbers: (1) the snap is the **sag prior at full strength** (at `sag_sigma=0.15`, steady-state recapture τ≈23 ms — a near-hard pin), and no finite per-sample position prior can ever be a gentle long-horizon DC corrector (τ < ~0.4 s across the whole sane `(sag_sigma, wheel_vel_rw)` plane); (2) but the sag prior is a **load-bearing continuous drift anchor** — travel DC is double-integrated diff-accel, a slow diff-accel bias ramps it into the barrier, and topout events are too sparse to bound it between jumps (a diff-accel-bias state converges far too slowly — the bias is only observable through those sparse topouts), so **turning sag off rails travel at the barrier** (the bimodal `0`/`170 mm` histogram). The fix is a *moderate* sag: **`sag_sigma` 0.15 → 0.5** — weak enough to let real travel motion pass (sim max 65→85 mm) while still bounding the drift (rails only above ~3–4× the default). The recovered mean near sag is correct (sag is the operating point); the σ trades spread for stability. Two supporting fixes: (a) the free-fall flag now **bridges brief mid-air interruptions** (`close_short_gaps`, gaps ≤ ~100 ms) before the sustained-run gate, so one jump is a single continuous topout instead of flickering open a coasting window where the sag prior re-captures travel before landing; (b) the topped-out wheel's rate is pinned **`ẇ = 0`** during the float (`ZeroWheelVelocity` is now runner-gated like the topout/sag/barrier factors, applied on stationary **and** airborne samples) — a topped-out wheel in free-fall isn't articulating, so its in-air velocity reads ~0 instead of integrator noise. TDD: `close_short_gaps` unit test, the runner-gated `ZeroWheelVelocity` gate, and an integration regression (`brief_midair_gap_does_not_snap_travel_to_sag_before_landing` — verified to fail without the bridge). Full `idl-rs` suite green (492). No FFI/bridge change (reuses existing config fields + a const). **Spec disposition:** the estimator design doc's §5 anchor section updated to describe sag as the load-bearing moderate drift anchor (with the observability-wall rationale for why topout-only can't replace it); no `IDL0_SPEC.md` change (estimator contract section still lands with M4).

- **Suspension-kinematics estimator — app surface: auto-refined mounts + in-app run/plot/tune (2026-06-24).** The estimator is now drivable from the app so its outputs can be **seen and the filter loops tuned by hot reload**. (a) *Engine — per-session mount auto-fit:* `run()` now auto-refines each unsprung IMU's coarse mount against the session's own static window (the same `[ws, we]` window the attitude/bias fit uses) via the new `orient::refine_mount_from_window` — gravity over the window snaps each link's static tilt onto chassis +Z while the coarse pick supplies the discrete orientation gravity can't see (design §7 "coarse pick + offline auto-fit"). `reference_bike()` now carries the **validated coarse unsprung-mount picks** (IMU1 +X up, IMU2 +Y up, both +Z bike-left) instead of identity placeholders, so an out-of-box run is correct on the reference bike without external calibration; the refine is a no-op on aligned/level data, so the synthetic tests are unchanged. (b) *Bridge:* `estimate_suspension_into_store(handle, config)` runs the engine over the retained session handle and stores the four outputs — **front/rear wheel travel (mm) + velocity (mm/s)** — into the handle's math store by id (metadata-only FFI crossing, like `eval_math_into_store`; the chart decimates them by id). `SuspensionConfig` is the flat, FFI-friendly mirror of the full `EstimatorConfig` tuning surface; `suspension_config_default()` exposes the reference defaults. (c) *App — the outputs are auto-evaluating math channels:* the four outputs surface as builtin math channels ("Front/Rear travel (mm)", "…velocity (mm/s)") whose expressions are the spec's `wheel_travel("front")` / `wheel_velocity("rear")` forms. `mathChannelEvalProvider` recognises them and routes to `suspensionEstimatorProvider` — an autoDispose `FutureProvider.family` that runs the estimator **once per session** (Riverpod-memoised, so all four outputs share one ~9 s run) via the existing `flutter_rust_bridge` async call (off the UI isolate). So they ride the **normal math-channel chart path**: lazy auto-evaluation on first reference, the standard per-chart loading spinner while the run is in flight, and zero UI blocking — no manual trigger. Geometry stays the engine reference bike for now (the per-session `.idl0w` geometry store is still deferred); the filter tuning lives in a Dart default config. The default workbook's **Suspension** sheet gains two charts plotting the estimator's front/rear wheel travel + velocity, sitting alongside the workbook's own declip→integrate fork/shock estimates for direct comparison. (d) *First real-data tuning pass:* the topout (airborne) reference now requires a **sustained** free-fall — the raw `|accel0| < threshold` flag is gated to runs of ≥50 ms (`sustained_runs`) so an instantaneous low-g dip (rebound crest, sharp unweight, accel noise) no longer re-zeros travel; the airborne threshold is lowered (4.0→2.5 m/s²) so only deeper unweighting counts; and the coasting sag prior is loosened (`sag_sigma` 0.08→0.15) so it stops piling travel around the static-sag point. Full `idl-rs` suite green (490), default-workbook test extended, Dart analysis clean.

- **Suspension-kinematics estimator — M2a engine "wheels first" (IEKF + factors + run pipeline) (2026-06-23).** The offline geometry-constrained estimator now **runs end-to-end** in the pure core. New `estimate/` modules: `geometry` (`BikeGeometry` — fork tangent, sampled rear axle-path tangent, steer axis, per-IMU pose/lever, topology; reference-bike default), `schema` (the geometry-derived, inspectable state schema — active vs frozen per component; hardtail drops rear states, M2a freezes steering), `detect` (the stationary gate over `zupt_flags`), `process` (the IMU0-strapdown + diff-accel wheel-drive kinematic `ProcessModel` with analytic `F`/`Q` **verified against finite-difference at 1e-6** — the shared-Jacobian exit check), `measurements/` (ZUPT, ZARU, wheel-velocity ZUPT, accel-compensated 2-DOF gravity-leveling, GPS velocity, sag prior, travel barrier, and the **topout reference** — the airborne/free-fall travel-DC anchor — every analytic Jacobian FD-verified), `iekf` (the hand-rolled iterated EKF in Gauss-Newton/information form, the same residuals the M5 batch smoother will reuse), `ledger` (per-component confidence + DC-source: Pinned / RelativeOnly / Frozen), `orient` (tilt + per-IMU gyro-bias fit from a stationary window — gravity gives tilt, not yaw — plus `refine_mount_tilt`, the §7 coarse-pick + auto-refine that snaps an unsprung IMU's mount tilt to the static-log gravity), and `run` (`run(input, geometry, config) -> StateEstimate` over typed sample arrays, plus a reusable `EstimatorInput::from_lookup` adapter that pulls the standard `IMU{0,1,2}_*` channels from any `ChannelLookup` — `g`→m/s², `dps`→rad/s, axis-tolerant (an absent axis is zero-filled, safe when it is the travel-orthogonal lateral axis some loggers omit on the unsprung IMUs), and **declipping each accel axis** via `clip_reconstruct::declip` — hard landings rail the ±32 g accelerometer on the travel axis, and clipped compression peaks would otherwise underestimate travel). `rotation` gains `right_jacobian_so3` (the gyro-bias→attitude coupling). Travel is seeded at **topout (0)**, the physical floor an unweighted bike rests at, and the sag prior is a loose **coasting-only** DC nudge (a parked bike is not at sag) — real travel DC comes from compression events + the M3 topout/bottomout references. Validated on synthetic data (static first-light reads ~0 and stays level, constant gyro bias absorbed, GPS anchors velocity, oscillating travel recovered) **and on real logs** (833 Hz, 3 IMUs): on the 10 s static-flat log, velocity ≈ 0.0002 m/s, attitude stable, biases recovered, travel rests at topout; on a 200 s **jump session**, fitting the unsprung mounts (gravity → +Z) and applying the airborne topout zeroing collapses the between-jumps travel divergence from **169.8 mm (open-loop drift) to 0.3 mm** — each jump re-zeros the integrator — with travel staying physical (peaking ~134 mm of the 170 mm fork once the railed accel is declipped; ~113 mm without) rather than drifting past the limits. +59 tests across the engine, full `idl-rs` suite green (486). **Remaining for M2a:** the user-facing bridge/math surface (`wheel_velocity()`/`chassis_attitude()` + `quality()` in `math/eval.rs`, per-session `.idl0w` geometry context, FRB regen), the off-axis diff-accel + unsprung-link-gyro factors, and the IDL0_SPEC contract section — these land with the app surface (M4-adjacent, gated on the UI-workflow design).

- **Suspension-kinematics estimator — M1 foundations (manifold + traits + noise) (2026-06-23).** First code for the offline, geometry-constrained IMU suspension/steering estimator. Pure-core `rotation` gains nalgebra-native SO(3) primitives — `skew`/`vee`, `exp_so3`/`log_so3` (the pinned right-perturbation convention), `rotation_between` (with an antiparallel fallback), `adjoint`, `swing_twist` (the steer-scalar extractor), and `lever_arm_accel` (`a + ω̇×L + ω×(ω×L)`); `calibration::rotation_from_gravity` is refactored onto `rotation_between` (behavior preserved). `statistics::zupt_flags` adds a dual-indicator (accel-σ + gyro-mean) stationary detector. A new pure `estimate/` module hosts the estimator-agnostic model traits (`ErrorState`/`ProcessModel`/`MeasurementModel` — the navlie/factor blueprint shared verbatim by the IEKF and the future batch smoother), the 24-DOF `MtbState` error-state with `oplus`/`ominus` on SO(3)⊕ℝⁿ, and the Allan→Q process-noise builder. Foundations only — no user-facing surface yet (the `wheel_velocity()` virtual sensors, the per-session geometry block, and the IEKF land in M2/M4, where the IDL0_SPEC contract section follows). +19 tests, full `idl-rs` suite green (425).

- **Shared `stft()` engine core + `spectrogram()` time-frequency matrix (2026-06-18).** `welch()` is rebuilt on a new `stft()` primitive (segment → window → detrend → real FFT per frame via `realfft`; returns complex frames). `spectrogram()` re-uses the same `stft()` core and keeps the per-frame power as a time×frequency matrix instead of averaging — peaks read identically to `welch()` by construction. Windowed variants (`welch_channel_windowed`, `spectrogram_channel`) accept `[t0_secs, t1_secs]` for lap/zoom slicing without copying samples. `spectrogramChannel` FRB accessor added to the session handle; bridge exposes `SpectrogramResult` (`freqs_hz`, `times_secs`, `power`, `n_times`, `n_freqs`). `realfft` replaces `rustfft` (drops the always-zero imaginary input and redundant negative-freq half; ~2× faster / half memory; welch tests relaxed to 1e-9 numeric equivalence). SPEC §19.

- **Spectrogram heatmap chart widget + `ChartType.spectrogram` (2026-06-18).** New `SpectrogramChart` widget renders the time×frequency power matrix as a GPU-painted heatmap (custom `CustomPainter`, log-frequency Y axis option, per-chart power-range clip). `SpectralParams` (shared `ChartSlot` field) holds window/overlap/detrend/scaling/log-freq common to both FFT and spectrogram. `ChartType.spectrogram` added to the workbook schema (auto-migrates from `ChartType.fft` where applicable). SPEC §26.

- **Spectrogram — repaint isolation, gridlines, denser axes, shared cursor (2026-06-19).** Three fixes to the spectrogram chart. (1) Performance: the painter drew one `drawRect` per time×frequency cell (~1 M ops for an 8192-pt segment's 4097 bins × ~240 columns) on a layer shared with the rest of the worksheet, so any unrelated repaint re-rasterized the whole heatmap — making the app unusable while a spectrogram was shown. The heatmap now renders on its own `RepaintBoundary` layer with frequency bins aggregated to ~one band per vertical pixel (max over each band's bins, preserving peaks), and the colour-max is computed once per result instead of every paint. (2) Axes: 7 frequency ticks (was 5) and 5 absolute-time labels (was start / duration / end), with frequency + time gridlines aligned to the ticks to make the log scale legible. (3) Cursor: the spectrogram now carries the worksheet's shared A/B/hover cursor on a separate overlay layer (cursor motion no longer repaints the heatmap) and a tap pins cursor A, so a spectral peak can be read against track position. SPEC §26.10.a.

- **Spectrogram time resolution — fill the time axis instead of ~26 columns (2026-06-18).** The spectrogram was borrowing the FFT chart's Welch segmentation (≈8 segments at 50 % overlap), which produced only ~15–26 time columns — coarse for a heatmap. Segment length still sets the frequency resolution, but the hop is now auto-sized (`ChartSlot.autoSpectrogramOverlap`) to fill the time axis with ~240 frames (`kSpectrogramTargetColumns`), the short-hop/high-overlap regime a spectrogram needs — independent of frequency resolution, bounded so short windows pack the max frames (hop ≥ 1) and very long windows stay non-overlapping. The spectrogram no longer honours `overlapPercent` (that drives the FFT chart's Welch hop). SPEC §26.10.a.

- **FFT chart auto-windows to zoom / lap (2026-06-18).** The FFT and spectrogram charts now resolve their time window from the active selection (zoom range in session-mode, primary-lap `startTimeSecs`/`endTimeSecs` in lap-mode) rather than always using the full session. Session-mode falls back to full channel if no zoom is set. Lap-mode uses the engine-computed `startTimeSecs`/`endTimeSecs` (GPS-grid interpolated) so the spectral window aligns exactly with the time-series and FFT charts. SPEC §26.

- **`idl-rs fft` + `idl-rs spectrogram` subcommands — headless frequency analysis (2026-06-18).** Two new structured CLI commands expose the engine's Welch spectrum and spectrogram to scripts and agents. `fft` computes a one-sided averaged spectrum (`welch_channel` / `welch_channel_windowed`) of any channel, with configurable window function (`hann`/`hamming`/`rect`), segment length, overlap, detrend (`none`/`mean`/`linear`), averaging (`mean`/`median`), and scaling (`magnitude`/`density`); `spectrogram` computes the time×frequency power matrix (`spectrogram_channel`). Both use the JSON envelope (§29.7): text mode prints bins or dims; `--format json` emits `data.freqs_hz`/`data.values` (fft) or `data.freqs_hz`/`data.times_secs`/`data.power`/`data.n_times`/`data.n_freqs` (spectrogram). Unknown `--channel` returns a `not_found` envelope with the available channel list. Pure `fft_json_data` / `spectrogram_json_data` cores are unit-tested in-process (no file I/O). SPEC §29.9.
- **N-lap variance — compare up to nine laps against the fastest, across sessions (2026-06-18).** The engine gained a multi-session table substrate, `table::evaluate_table_multi` (each row resolves `[Channel]` against its own `SessionHandle`; cross-row `{col[]}` preserved in one pass), a `main({col[]})` reference aggregate, and `variance::variance_traces` (N overlay-vs-Main delta series, time or distance, reusing the `variance_geom` GPS projection). The app's selection model gained `Selection.mainLapKey` + `setMainLap` (Main = fastest selected lap, overridable; overlays derived, capped at nine) and `comparisonLapsProvider`; a table block can derive its rows live from the selection (`TableContent.rowSource = lapSelection`) and a new `ChartType.varianceTrace` plots the per-lap deltas. The substrate also unblocks cross-session tables in the CLI. SPEC §13, §26.11, §26.13. *(Engine + state + models landed; comparison-table and variance-chart widgets follow.)*

- **`idl-rs table` command group — headless table evaluation (2026-06-18).** New `table eval` / `table list` / `table check` sub-actions evaluate, enumerate, or validate a workbook's tables against a session through the JSON envelope (§29.7). The engine gained `Workbook::tables` (surfaces `.idl0wb` table blocks with their layout metadata), `table::lap_windows` (resolves each row's lap window), and `table::validate` (structure / formula-parse / reference / cycle checks); the CLI's `table eval` emits a self-describing payload — columns with their formulas, rows with their resolved windows + per-cell value/error — or a `text`/`csv` grid, with `session_mismatch` / `lap_out_of_range` warnings. Single-session scope (cross-session deferred to N-lap variance, which needs a per-row-handle evaluator). Authoring stays direct `.idl0wb` JSON edit, validated by `table check`. SPEC §29.8.

- **`idl-rs` CLI JSON output envelope (2026-06-18).** Every CLI command now speaks one versioned JSON envelope (`schema`/`ok`/`command`/`engine` + exactly one of `data` or `error`) so a script or agent parses a single shape and branches on one error path. The structured inspect commands (`info`, `channels`, `laps`, `visits`) emit a success envelope under `--format json` — and `info`/`channels` gain the `--format` flag they lacked — with a truncated-log caveat carried in a machine-readable `warnings` array; **text stays the default**. `laps`/`visits` `--format json` is now the enveloped object form rather than a bare array. The bulk commands (`export`, `math`, `fit`, `recover`, `scan`) write their raw CSV/FIT/`.idl0` artifact unchanged on success and a JSON **error envelope to stderr** on failure (exit non-zero). Errors carry a closed seven-kind taxonomy (`io`, `invalid_input`, `not_found`, `eval`, `unsupported`, `usage`, `internal`) plus an open `details` object — `not_found` lists the available channels for one-retry self-correction, `eval` echoes the engine's `eval_kind`. New `rust/cli/src/envelope.rs` holds `CliError`/`ErrorKind`/`Warning` + the engine-error mappings, unit-tested per variant; clap's pre-dispatch usage errors stay native (exit 2). SPEC §29.7.

- **`central_imu_workbook.idl0wb` — curated workbook for a central-IMU-only unit (2026-06-17).** A ready-to-import analysis workbook for a logger with only the central 6-axis IMU (`IMU0`), GPS, and a heart-rate strap — no unsprung fork/shock IMUs. The accel/gyro channels are declipped and de-rotated for a ~30° nose-up mount tilt to vehicle frame via `rotate_axis(…, 0, 1, 0, deg2rad(30))` (lateral/pitch unaffected; X↔Z corrected). Six worksheets: Session (map + laps), Speed & line, Cornering & braking g (long/lat + combined-g + lateral-g histogram), Ride roughness + FFT, Attitude rates (roll/pitch/yaw), and Heart rate / effort. Guarded by `test/data/central_imu_workbook_test.dart` (channel restriction + math-reference integrity + round-trip).

### Changed

- **Engine-owned typed derived-channel store (2026-06-22).** The handle's flat string-keyed math-store overlay is replaced by a typed `DerivedKey` store: math outputs keyed by name, lap-windowed slices keyed by their `(source, role, lap)` identity. A lap slice can no longer collide with a base or math channel (the bug that rendered declipped/derived channels as short, misplaced fragments is structurally impossible), and editing a math channel no longer leaks stale lap-slice generations in the engine store or the tile cache — lap slices use a stable engine-generated token and replace in place, with the recompute generation moved to a Riverpod trigger (`MathChannelState.generations`) instead of being baked into the storage key. `add_channel`→`store_math`; `slice_by_time_into_store`→`slice_lap_into_store` (returns `{token, length}`); new `retain_derived(live_sources)` reclaims a deleted/renamed channel's entries declaratively on the eval path. FRB bindings regenerated. SPEC §15.3.

- **Math evaluator no longer makes redundant full-channel copies (2026-06-22).** Evaluator sample buffers are now `Arc<[f64]>`, so a `[Name]` reference and every operand share one widened buffer instead of cloning; a per-pass `MemoLookup` widens a channel referenced N times exactly once; the DSP functions (`integrate` / `butter` / `fft` / `declip`) borrow `&[f64]`; and the zero-storage `Time` ramp resolves to a closed-form `(len, rate)` (new `ChannelLookup::channel_dims`) instead of materializing. Internal `idl-rs` change — numerical output is byte-identical (parity-tested), no FFI or SPEC change. Cuts transient memory on season-scale math chains (a multi-reference expression no longer holds N copies of the channel). Store-residency / typed-keyspace and chunked evaluation are deferred to follow-on specs.

- **Dev Rust builds trim debuginfo to line tables (2026-06-24).** `[profile.dev]` now sets `debug = "line-tables-only"` — the cargokit `flutter run` build (Flutter debug → cargo dev profile) no longer emits the full variable/type debuginfo, only the line tables, so every incremental relink of the `idl-rs`/`idl_rs_bridge` cdylib is lighter while panic backtraces keep their `file:line`. Zero runtime cost (the cdylib Flutter loads needs no Rust symbol info); the per-package `opt-level = 3` that keeps the engine release-grade in debug builds is unchanged.

- **Device tab consolidated into two cards (2026-06-16).** Everything about a connected device now lives on the Device tab as a **Device card** (live status, recording, push/pull config, file access) and a **Config card** (profile bar + channel table), with calibration tucked below. Peripheral status is a color-coded `StatusIcon` strip (battery/SD/GPS/IMU/HR) with an optional numeric slot ready for the firmware §7.3 numerics follow-on. **Mode is now automatic** — the manual mode picker is gone; WiFi is driven on demand by file sync and OTA, recording by the hero's primary button, and the current mode shows as an info-only line. Mutex-refusal UX moved from the picker to an always-mounted `ModeResultListener`. **Device file sync moved off the Data tab onto the Device card** (Files entry, auto-driving WiFi); the Data tab is now a pure library browser. New **Pull from device** reads the device's live config over BLE and saves it as a new library profile. OTA push (Settings) now drives WiFi itself instead of requiring the removed picker. SPEC §22/§23/§24.

### Fixed

- **Opening a multi-series time-series chart could crash with a `LateInitializationError` in fl_chart (2026-06-23).** Opening a worksheet whose active sheet held a chart with two or more overlaid series (e.g. fork + shock travel, or any sheet sitting next to two FFTs) intermittently threw `LateInitializationError: Field 'mostRightSpot' has not been initialized` from deep inside fl_chart (`LineChartHelper.calculateMaxAxisValues` → `LineChartBarData.mostRightSpot`), during the implicit-animation tween that fires as data updates. Root cause: the time-series chart emits `FlSpot.nullSpot` for any span whose decimation tiles are still loading (first open) or whose window is entirely NaN (a lap-aware math channel outside its lap), so a series could become a **non-empty bar of only `(NaN, NaN)` spots**. fl_chart's auto axis-scaler skips *empty* bars and early-returns on an all-null *first* bar, but reads the `late final mostRightSpot` — left uninitialized when a bar has no non-null spot — on every later non-empty bar; a second, valid series therefore tripped it. The crash needed ≥2 series in one chart, which is why it surfaced on busier sheets while the tiles were still in flight. Fix: new pure `TimeSeriesChart.renderableSpots` collapses an all-null spot list to `const []` before it becomes a `LineChartBarData`, keeping fl_chart on its guarded empty-bar path (the bar draws nothing either way) while preserving bar order for palette/tween stability. Covered by `test/ui/time_series_chart_test.dart` (guard unit tests plus a regression test asserting `mostRightSpot` throws on a non-empty all-null bar and that the guard prevents it). FFT charts are unaffected (they render a spinner while loading and only ever emit finite-x spots). No spec change needed (rendering-path robustness bug against a third-party chart invariant; the §26 chart contracts are unchanged).

- **Session timestamps showed device boot time; files named by UUID (2026-06-22).** Two related Data-tab fixes. (1) **Recording timestamp.** The engine back-filled a `.idl0`'s session start (`Session.timestampUtcMs`, SPEC §5.6) as `gps_epoch − device_ts/1000` — the wall clock at device-timestamp 0, i.e. **boot**. Because the device timestamp is monotonic across recordings in one power cycle, every recording in that boot collapsed to the same boot instant in the browser. Now anchored at the recording's **first sample**: `gps_epoch − (device_ts − first_sample_device_ts)/1000` (`rust/core/src/parse/v3.rs`, regression test `backfill_session_start_is_recording_start_not_boot`). This also corrects absolute wall-clock times in FIT/GPS export. (2) **File naming.** Session `.idl0`/`.gpx` logs + their `.idl0w` workspaces are now named by recording start in local time (`YYYY-MM-DD_HH-MM-SS`, `-2`/`-3` on a same-second collision, falling back to the `sessionId` when the time is unknown) via new `app/lib/data/session_filename.dart`, instead of the opaque `<sessionId>.idl0` — bringing the code in line with the §15.1 / §10 naming convention. `sessionId` stays the internal identity. The rescan-from-disk dedup, which assumed `filename == sessionId`, now dedups by stored path + parsed `sessionId`. (3) **Migration.** A Data-tab overflow action **"Repair timestamps & names"** re-parses every indexed session to correct its (boot-time) timestamp and rename its files to the new scheme — idempotent and fault-isolated (renames roll back on partial failure). SPEC §5.6 / §15.1 updated (and §15.1 corrected: `createdTimestampMs` is the recording start, not the download time it previously claimed).

- **Maths tab crashed when editing an expression — Riverpod `_didChangeDependency` assertion (2026-06-22).** Changing a numeric value in a math expression (or any back-to-back channel CRUD) threw `_AssertionError … '!_didChangeDependency': Cannot use ref functions after the dependency of a provider changed but before the provider rebuilt`. Root cause: `MathChannelNotifier.build()` does `ref.watch(workbookProvider)`, and every CRUD method writes through `workbookProvider.notifier.updateWorkbook`, which **synchronously** re-dirties the notifier's own element. The code that ran straight after the write then called `ref` on that now-dirty element — `ref.read(chartTileCacheProvider)` to drop the channel's stale tiles, and `_activeWorkbook`'s `ref.read(workbookProvider/workspaceProvider)` on a chained edit — before the deferred rebuild flushed, tripping the assertion. In the app the single-edit cache read crashed every expression edit; the chained-edit reads were also latent (and made the provider's unit tests fail deterministically). Fix: capture the stable collaborators once in `build()` (the only window where `ref` is guaranteed usable) — the tile cache, `workbookProvider.notifier`, and `workspaceProvider.notifier` — and read **those**, never `ref`, from the mutation path. Two public read accessors back this: `WorkbookNotifier.currentWorkbooks` (latest list via the notifier's own state) and `WorkspaceNotifier.activeWorkbookIndex` (the instance-field index, valid even mid-rebuild), so the active workbook resolves without `ref.read`. Covered by `test/providers/math_channel_provider_test.dart` (single-edit + back-to-back CRUD no longer throw, tiles still invalidated). No spec change needed (Riverpod-lifecycle correctness bug; the workbook-as-source-of-truth and lazy-eval contracts are unchanged).

- **Lap "main only" view silently destroyed every math channel (2026-06-19).** Viewing a single main lap (a non-session-scope chart with a designated/selected Main lap) corrupted all math channels across the whole worksheet: they rendered as a short, time-shifted fragment (data ending early, "tiles in the wrong place") while raw channels stayed correct. Root cause traced end-to-end against a real session — the engine eval is provably correct (every math channel evaluates to full length at the source rate via the CLI's `apply_workbook`, the same `resolve_dependencies`→`evaluate`→`add_channel` path the app uses). The corruption was in the chart's lap-view path: `_resolveLapPairChannels` "Mode 2 (main only)" sliced each channel with an **empty suffix**, so `lapSlicedChannelProvider` built the store id as `channelId + "" == channelId` and the engine's `slice_by_time_into_store` (an upsert by id) **overwrote the full-session channel in the math store with the rebased lap slice**. Base channels were immune — `with_channel` resolves `session.channels` before the math store, so the base data shadowed the corrupt entry — but math channels live only in the store, so they were destroyed, and because the store is shared the damage leaked into session-scope charts too. Fix: Mode 2 now uses the ` (main)` suffix (consistent with main+overlay mode), so the lap slice is stored under a distinct id and never overwrites its source. Guarded against regression by an `assert` in `lapSlicedChannelProvider` that rejects an empty suffix (it fires before the FFI call, so it's covered by a bridge-free test in `test/providers/channel_provider_test.dart`). No spec change needed (rendering-path data-corruption bug; the §15.3 self-sourcing seam and lap-window contract are unchanged).

- **Math channel charts showed stale values until you zoomed in — tile cache never invalidated (2026-06-19).** Editing a math channel's expression (e.g. fixing the fork-travel drift) left the chart rendering the *previous* expression's data at any already-cached zoom tier — full-zoom showed the old blown-up curve, while zooming in (hitting an uncached tier) revealed the corrected data, making the math look zoom-dependent when it wasn't. Root cause: decimated chart tiles are keyed by the channel's **stored name** (the engine stores a math result under `MathChannel.name`, and the chart self-sources tiles by that name), but `MathChannelNotifier.update/rename/deleteChannel` invalidated the cache by the channel's **UUID** (`channel.id`) — which never matched any tile key, so the invalidation was a silent no-op and stale tiles survived every edit. Invalidation now uses the name. A second gap is closed in the same fix: editing an *upstream* channel (e.g. `Fork velocity`) now also drops the tiles of every channel that transitively depends on it (e.g. `Fork travel = detrend(integrate([Fork velocity]))`) — previously a dependent's tiles stayed stale because only the edited channel was touched. The transitive dependent set is computed by a pure `mathTileInvalidationNames` (bracket-delimited `[name]` matching, so a shorter name is never a substring of a longer one); `renameChannel` additionally frees the orphaned old-name tiles. Covered by `test/providers/math_channel_provider_test.dart` (closure unit tests + update/delete/rename invalidation). No spec change needed (cache-invalidation correctness bug; the lazy-evaluation and tile-decimation contracts are unchanged).

- **Stuck function-definition card after switching tabs (2026-06-19).** In the chip math editor, opening a function chip's definition card and clicking "More ▾" pins it; the card renders into the root `Overlay` via `OverlayPortal`. Because tabs are kept alive in the shell's `IndexedStack`, a pinned card survived a tab switch and floated — undismissable — over the next tab (its only dismiss affordance, the chip, was now off-screen). The popover was extracted to `definition_popover.dart` as `DefinitionPopover` and now watches `shellIndexProvider`, force-dismissing (unpin + hide) whenever the active tab changes. Tap-to-toggle and hover behaviour are unchanged. Covered by `test/ui/definition_popover_test.dart`. No spec change needed (chip editor is a prototype; popover behaviour isn't a spec contract).

- **App launcher name + application id (2026-06-19).** The Android home-screen label was `idl-rs` — the *engine* crate name had leaked into `AndroidManifest.xml`'s `android:label`, mislabelling the *product* (the app is **IDL0**; `idl-rs` is the Rust engine + CLI). Set `android:label` to `IDL0` and aligned iOS `CFBundleDisplayName` (was `Idl0`) to match. Separately, the placeholder `applicationId` `com.example.idl0` was set to the publishable **`com.saucyeng.idl0`** (the internal Gradle `namespace` and Kotlin package stay on the generated `com.example.idl0` — they may differ from the application id, and no FileProvider/authority references the id). Note: changing the application id makes Android treat this as a new package, so it installs alongside any prior `idl-rs` build with a fresh app-private session library; uninstall the old one. The Drive **OAuth Android client must be registered against `com.saucyeng.idl0`** + the signing SHA-1 (see Drive setup).

- **Data tab — mobile toolbar height, toggle wrap, venue pre-fill, and detail-sheet keyboard overflow (2026-06-18).** Four Data-tab fixes. (1) **Toolbar no longer stacks five button rows on a phone.** On narrow widths the results toolbar compacts to two rows — search (filling the row) + a compact Drive-status icon + a `⋮` overflow menu on top, then the Sessions/Tracks toggle, sort, and an icon-only Import below; the infrequent **Rescan visits** / **Rescan disk** and **Drive sign-in/out** moved into the overflow menu. The dedicated full-width Drive row (`_DriveSection`) was **removed entirely** — Drive is now a compact status icon + overflow sign-in/out in the toolbar on both layouts (on wide the rescans remain visible buttons, so the overflow there carries only Drive sign-in/out). **Drive sign-in/out is wired to the real interactive flow** (`DriveSyncNotifier.signIn`/`signOut`) — the Data-tab control previously only redirected to the Settings tab; now the signed-out cloud icon is itself a tap-to-sign-in affordance (spinner while in flight) and the overflow "Sign in/out of Drive" runs the real flow. (2) **Sessions/Tracks toggle no longer wraps** — `SegmentedButton.showSelectedIcon: false` drops the M3 selected-state check that widened the active segment and pushed the trailing "s" of "Sessions" onto a second line; labels are `maxLines: 1`. (3) **Venue metadata field is pre-filled** — when a session has no explicit `venueName` but resolves a venue from a matched Track, the editable Venue field in `MetadataForm` is seeded with that resolved venue (new shared `resolveSessionVenue`, also used by `SessionDetailCard`) so saving persists it into the session's own metadata instead of leaving it blank (SPEC §24.10). (4) **Editing a track/venue in the mobile detail sheet no longer hides the field behind the keyboard** — the detail bottom sheet now sizes to ~92 % of screen height (was a fixed 560 px half-screen) and lifts above the soft keyboard via `viewInsets.bottom` padding with a matching height reduction; `TrackDetailPanel` was made scroll-safe (fields + stats in an `Expanded`+`SingleChildScrollView`, action buttons pinned). No spec change for (1)/(2)/(4) — UI fixes within the §24.2 narrow detail-sheet / §24.3 toggle surface.

- **Workbook Import / Reload looked dead on mobile — file-picker MIME filter (2026-06-17).** The workbook dropdown's **Import…** and **Reload from file** actions used `FilePicker` with `FileType.custom` + `allowedExtensions: ['idl0wb']`. Android has no MIME mapping for the `idl0wb` extension, so the system picker showed nothing selectable (the same failure the `.idl0` log import already worked around in `runs_provider.dart`). Both pickers now use `FileType.any` — the system file picker opens so a `.idl0wb` in Downloads is selectable, and content is validated on import (`importFromFile` → `Workbook.fromJson` surfaces `WorkbookParseException` / `UnsupportedWorkbookVersionException` on a bad pick).

- **Pinch-zoom crash on mobile — chart vs. scroll-list gesture arena (2026-06-16).** Pinching a time-series chart on Android threw `'package:flutter/src/gestures/scale.dart': Failed assertion: line 847 ... 'false': is not true`. Root cause (confirmed from the stack trace): the chart's `ScaleGestureRecognizer` and the enclosing `ReorderableListView`'s vertical drag recognizer both entered the gesture arena; the drag won and *rejected* the scale gesture after it had already `started`, an illegal `started → rejected` transition the framework asserts on (release builds don't crash but the pinch is silently cancelled by the scroll, so zoom was unreliable either way). Fix: a new `ChartGestureArea` (in `chart_gestures.dart`) drives the chart through a custom `ChartZoomScrubGestureRecognizer` that claims the arena only for a 2-finger pinch or a horizontally-dominant 1-finger drag; a vertically-dominant 1-finger drag is left unclaimed so the worksheet scrolls. The recognizer reaches `started` only after winning outright, so it can never be rejected mid-gesture. New touch model: vertical 1-finger = scroll, horizontal 1-finger = cursor A, 2-finger = zoom, double-tap = reset. Covered by `test/ui/chart_gestures_test.dart` (vertical-yields-to-scroll, horizontal-scrubs, pinch-zooms, double-tap-resets). SPEC §26.8 mobile-gesture table updated.

- **IMU drain — startup drops + config/priority follow-up (2026-06-16, hardware round).** First-flash testing (IMU0-only) showed clean draining (`ovr=0`, ~811 Hz) but `writer: buffer full` drops for the first ~5 s of each session. Root cause was *not* the FIFO: the 16 KB writer ring overflowed during fresh-file FAT-allocation latency, amplified by a per-dropped-batch `ESP_LOGW` storm (two blocking UART lines/drop on the IMU task) and a priority inversion. Fixes: (1) **removed the per-drop logging** — counted instead and surfaced as `writer_drops=N` in the 5 s diag line + session summary; (2) **reverted the IMU task to priority 5** (equal to the writer) — with the burst drain the FIFO has ~300 ms headroom, so the writer keeping the ring drained is the real constraint and must not be starved; (3) **writer ring 16 KB → 64 KB** to absorb the startup SD transient; (4) **removed the all-IMUs-on DIAG override** in `imu_task` so `imu_enabled` from the config is respected (IMU1/IMU2 disabled → not initialised, not polled). Pending re-flash + field verification.

- **IMU FIFO drop reduction — firmware drain rewrite (2026-06-16).** Field logs dropped 2–5 % of IMU samples (unsprung I²C IMUs ~2.4× worse than the SPI frame IMU). Root cause was throughput/contention, not bandwidth: the poll loop ran at ~152 ms/cycle (not the intended 50 ms) — ≈ the FIFO's ~150 ms capacity — because IMU0's per-word SPI drain spent ~480 blocking `spi_device_transmit` calls/cycle and the per-batch `fflush` held the shared SPI bus; a handful of all-three coincident stalls came from SD-write latency starving the single-core C6. Changes, all firmware: (1) **IMU0 SPI drain is now a single DMA burst** (`idl0_imu_drain`, mirrors the I²C burst — ~480 transactions → 1); (2) **SD writes decoupled** — `setvbuf` 16 KB cluster buffer + ~1 Hz `idl0_sd_flush` from the writer, replacing the per-append `fflush` that back-pressured the bus; (3) **IMU task priority 5→6** so a due drain preempts an in-progress SD write; (4) **drain cap 128→256 pairs** (full FIFO; static buffers) so one drain recovers a stall; (5) **poll 50→20 ms** (FIFO occupancy ~127→~17 pairs); (6) **per-IMU monotonic timestamp clamp** removing the IMU0 drain-boundary backsteps at source. No SPEC change — §5.5's back-count contract is unchanged (timestamps are now strictly monotonic, which the app reconciliation already assumed). **Pending hardware build/flash + field A/B verification** (per-IMU drain timing lands in `idl0_debug.log`; re-run `tools/imu_drop_analysis.py`).
- **On-SD drain instrumentation via `diag_log` (2026-06-16).** The IMU task accumulates per-drain timing (bus-read vs total µs, pairs, overruns, slowest cycle, writer drops) in RAM during a session and emits a per-IMU summary to `idl0_debug.log` at session stop — after the session file closes, so it never contends with session SD writes (§1). Attributes the drain cost on real hardware where no serial monitor is attached.

### Added

- **Shared Y-axis scale across chart types (2026-06-16).** One `ChartSlot.yScale`
  — Linear / Log / Sqrt / Square — replaces the per-chart `fftYScale` and
  `histogramLogCount` (both auto-migrate to `yScale: log`), chosen from a single
  "Y scale" control. `Log` is signed log (symlog: linear near zero, log in the
  tails) so it works on zero-crossing time-series data and reduces to plain
  log₁₀ on positive data; `Sqrt`/`Square` are signed power transforms. A pure
  Dart module (`y_scale.dart`) maps the already-decimated display spots and
  inverse-formats axis labels — no engine round-trip; cursors/tooltips read real
  values. FFT and histogram keep their existing `log` rendering. Time-series,
  FFT, histogram, and lap-progression honour it; GPS map / lap table ignore it.
  Follow-up: "nice" non-linear tick placement. SPEC §26.12.
- **IMU drop reconciliation in `idl-rs` (2026-06-15).** All IMU channels now share one nominal rate (`1e6 / (1_000_000 / ODR)`, matching the firmware back-count) and are reconciled onto a single grid at parse finalization. Each sample is placed at its **absolute** grid slot `round((ts − t0) / period)` — not by accumulating per-step advances — so the time→slot mapping is identical across IMUs and a sensor's own drops never drift its later samples; forward jumps are linear-filled in raw `i16` space, leading/trailing offsets held, and out-of-order drain-boundary samples (sub-period backsteps / duplicates) dropped. Every IMU channel ends equal-length and time-aligned, so cross-IMU element-wise math (`[Fork accel] − [Frame accel]`) no longer errors with "different sample rates" and co-temporal events stay aligned to ½ period across the whole session (a real field log drifted ~0.1 s with per-step accumulation; absolute placement holds it to <1 sample). Each synthesized run is recorded in a per-channel `gaps` list (`{start, len}`, shared across an IMU's six axes); no consumers yet. Hot-loop fast path is one `i64` compare per IMU record — a clean log is a no-op. Replaces the drop-skewed `(n−1)/span` per-IMU rate. SPEC §15.2/§5.5.

- **Modular tables — formula half (2026-06-15).** Tables are now first-class
  worksheet content. A worksheet holds ordered `WorksheetBlock`s (chart | table)
  with a `placement` field (only `inFlow` honoured in v1; charts precede tables);
  the legacy flat `charts` array migrates to chart blocks on load. Tables reuse
  the `idl-rs` math evaluator — no second engine: a new `{cell}` sigil
  (`{A1}` / `{name}` / `{name[]}`) tokenizes/parses to `Ast::CellRef` and
  resolves through `ChannelLookup::lookup_cell` (defaulting to "none", so channel
  math is firewalled from cells), `evaluate_scalar` requires a single scalar
  result, and channel→scalar aggregates (`mean`/`max`/`min`/`sum`/`std`/`rms`/
  `median`/`p`/`first`/`last`/`count`) dispatch by arity so the one-argument
  forms coexist with the existing windowed/elementwise ones. The engine
  `table::evaluate_table` topo-sorts cells (cycle detection), slices each row's
  `[Channel]` refs to its lap window, and returns a `CellResult` grid across FFI.
  A per-lap summary preset (Add table) seeds one row per lap with max-per-channel
  metrics and a delta-to-best column; the `TableWidget` edits cell formulas and
  column templates inline with per-cell errors. Plan 2 (flexible side-by-side /
  overlay layout) and the CLI `idl-rs table` subcommand are deferred. SPEC
  §26.11, §19.
- **Vector & rotation math primitives (2026-06-15).** New `idl-rs`
  `math::vector` module adds an internal `Vec3` evaluator value plus the
  vector/rotation function set to the math-channel language: `vec`, `vx`/`vy`/
  `vz`, `vadd`, `vsub`, `vscale`, `cross`, `dot`, `norm`, `normalize`, `angle`,
  and inline rotations `rotate_mat` (row-major 3×3), `rotate_axis` (axis-angle),
  `rotate_euler` (intrinsic roll/pitch/yaw; angle args may be channels for a
  per-sample rotation). Vectors are intermediate-only — a top-level result must
  reduce to a scalar channel via a component or `norm`. Backed by `nalgebra`;
  reuses the evaluator's existing broadcasting rules. Motivating consumer: the
  frame-at-axle rigid-body lever-arm transfer. No bridge/FRB change (Vec3 is
  evaluator-internal). SPEC §19.
- **Universal math constants `pi` / `tau` / `e` / `g` (2026-06-15).** Recognised
  as bare identifiers in any math expression (`[IMU1_AccelZ] * g`,
  `2 * pi * [Freq]`), resolved to a literal at parse time in the `idl-rs`
  engine — no store, always available, and portable with the `.idl0wb`. `g` is
  standard gravity (9.80665 m/s²). Channel references stay bracketed (`[g]`) so
  there is no collision. SPEC §19.

### Changed

- **Math-channel rename propagates references (IDE-style, 2026-06-15).**
  Renaming a math channel (committed on Enter / focus-loss, not per keystroke)
  rewrites every *other* workbook expression that references the old name
  (`[OldName]` → `[NewName]`) via `MathChannelNotifier.renameChannel`. Chart
  slots reference channels by their stable `id`, so chart membership survives a
  rename untouched.

- **Math channels consolidated onto the workbook — single source of truth
  (2026-06-12).** The Maths editor, the evaluator, and charts now read and
  write the **active workbook's** math channels and constants; the global
  SQLite math store (`idl0_math.db` / `MathChannelRepository`) and its
  first-launch seed are removed. The two `MathChannel` model classes are
  unified into one (`data/math_channel.dart`): a stable `id` (defaults to
  `name` for hand-authored `.idl0wb`), hex `color`, `sampleRateHz`. Charts
  reference channels by `id` (rename-safe); expressions and the `idl-rs`
  resolver reference by `name`. Named constants fold into the `.idl0wb`
  (`Workbook.constants`). Recursive cross-channel dependencies still resolve in
  a single Rust-side pass (`idl-rs` `math::resolve`) — only the source of the
  definition list moved to the active workbook. Fixes imported / default-
  workbook math channels not appearing in the editor and never evaluating.

- **Chart-creation UI: type icons + desktop merged editor (2026-06-15).** Each
  addable chart type now carries a glyph, one-line blurb, and a signature
  accent colour in a single catalog (`chart_type_catalog.dart`). On mobile the
  Add-Chart picker shows the colour-coded glyph and blurb per row. On desktop
  (viewport `> 700` dp) the type picker merges into the properties panel as a
  left **type rail** (each type colour-coded; selected lights its accent):
  selecting a type converts the chart in place (channels preserved), and
  "Add chart" opens the merged panel directly (Cancel discards the
  placeholder). Chart type is now editable after creation on desktop.
  SPEC §26.9.

### Added

- **Histogram chart type (2026-06-15).** New `ChartType.histogram` — the
  value distribution of a channel over the session, as equal-width bars (the
  staple suspension tool: velocity histogram for damper balance, travel
  histogram for sag / bottom-out). Binning is a new `idl-rs` engine fn
  (`channel_histogram` → `histogram::histogram`); only the small
  `HistogramResult` crosses FFI, never the samples (the §15.3 seam, like
  `welch_channel`). Options on the slot: bin count (default 40), **symmetric**
  zero-centred range (for signed velocity channels), and a **log** count axis
  (exposes the high-velocity tails). Y is each series' % of samples; X is
  channel value. **Overlays** every assigned (session × channel) series as a
  staircase outline sharing one value axis — the chart unions each channel's
  `channel_min_max` into a common range and bins every series onto identical
  edges (explicit-range `channel_histogram` param), so front + rear across
  main + N overlay sessions lie on top of each other, colour-coded in the
  legend. A `Smooth` slot toggle renders each distribution as a fitted polyline
  through the bin centres instead of stepped bars. `cargo test` (5) + slot JSON
  round-trip tests. SPEC §26.10, §15.3.

- **Chip-driven math expression editor (Maths tab, 2026-06-12).** A
  **Build / Text** toggle adds a drag-and-drop chip editor beside the raw-text
  one (lose-nothing). Colour-coded chips — channels (green), functions by
  category (signal/time-domain/math/logic), operators, values — drag or tap
  into labelled function argument **slots**, with a **live inferred output
  unit** (`integrate([accel])` → `m/s`) and IDE-style hover/tap definition
  cards (signature + an expandable "More" docs section). Serialises to the same
  engine text as Text mode, so the two round-trip. The Dart-side unit inference
  is a prototype; real dimensional propagation is a future `idl-rs` job.
- **Claude skill: author `.idl0wb` workbooks by hand
  (`skills/idl0-workbook-authoring/SKILL.md`, 2026-06-12).** A self-contained,
  example-dense skill teaching any agent to read/build/edit `.idl0wb` workbook
  JSON and math channels with no app or API — field-by-field reference for
  `Workbook` / `Worksheet` / `ChartSlot` / `MathChannel`, the IMU/GPS channel
  catalog (IMU0=frame, IMU1=fork, IMU2=shock), the expression-language quick
  reference, recipes, and a common-mistakes/round-trip-validation section.
  Calls out the math-channel-by-name gotcha and the hex-vs-ARGB-int color split.
- **Dev artifact: first-cut default analysis workbook
  (`app/dev/default_workbook.idl0wb`, 2026-06-12).** A hand-editable `.idl0wb`
  JSON template ordered to the suspension-analysis flow — Session (pinned GPS
  map + lap table + lap progression) → Bike (GPS speed, sprung-mass accel) →
  Suspension (fork/shock accel + baked-in `integrate(...)` velocity math
  channels) → Frequencies (fork/shock FFT) → Rider inputs (placeholder until
  steering/understeer math lands). Round-trips through `Workbook.fromJson`
  (test at `app/test/data/default_workbook_test.dart`). This is a starting
  template to iterate on by hand; **not yet** baked into
  `Workbook.createDefault()`.
- **Analyze — "Reload from file" workbook action (2026-06-12).** The workbook
  menu gains a **Reload from file** entry that re-imports a `.idl0wb` (replace
  policy) and makes it active — one tap after the first pick, since the last
  path is remembered (shared with `Import…`). Turns "edit a workbook file
  externally → see it" into a tight loop: pairs with the
  `idl0-workbook-authoring` skill (a user's agent edits the JSON, they tap
  Reload) and with iterating `app/dev/default_workbook.idl0wb`. No spec change
  needed (additive menu action within §24).

### Fixed

- **Chart properties: dead channel buttons + remove-chart crash (2026-06-15).**
  The properties dialog's channel list runs in a `ReorderableListView` whose
  default per-row drag recognizer was eating taps on the colour / edit / remove
  buttons on desktop (the buttons looked dead) — default drag handles are now
  off and each row carries its own explicit drag handle. Removing a channel no
  longer closes the whole dialog (a stray `Navigator.pop` is gone). And
  "Remove chart" no longer throws `Bad state: Cannot use "ref" after the widget
  was disposed`: `confirmRemoveChart` captures the notifier before its dialog
  await, and the properties dialog confirms before closing itself. The
  histogram's legend/tags no longer sit under the per-chart drag + properties
  overlay (the title bar reserves the top-right corner).

- **Workbook permanence — the default workbook no longer resets on restart
  (2026-06-12).** On a fresh install the workbook library (SQLite `workbooks.db`)
  is empty, so the Analyze tab showed an in-memory **default "Workbook 1"
  phantom** that was never persisted — edits to it (charts, worksheets, renames,
  X-axis modes) vanished on every relaunch, while sessions and tracks persisted
  fine because they're always written to their own indexes on import.
  `WorkbookNotifier.build()` now **seeds the default workbook into an empty
  library and persists it** so the tab always opens to a real workbook, not a
  phantom — done **eagerly at load** (offline immediately; when signed into
  Drive, deferred to the post-sync check so it never races a download of the
  user's real workbooks), so persistence no longer depends on an edit completing
  before the app is restarted. `WorkspaceNotifier._persistActiveWorkbook` also
  no longer early-returns on an empty library — it materializes the default on
  first edit (single-flight) as a belt-and-suspenders fallback. Regression tests
  added at both layers. No spec change needed — this restores the intended
  §15.5 / §24 persistent-workbook behaviour.

### Changed

- **Analyze — "New workbook" is a blank slate (2026-06-12).** The workbook-bar
  "New workbook" action now creates a workbook with a single empty sheet
  (`Workbook.createBlank`) instead of an empty, worksheet-less one (which would
  display blank / could throw). A prefilled start comes from a template or by
  duplicating the **default** workbook (Session + Charts), which is what the
  first-run seed and `Workbook.createDefault` provide.

- **Mobile UI redesign — brand layer + Device hero (2026-06-11).** First
  increments of the phased UI redesign:
  - Brand layer: IBM Plex Sans body type; a filled, **category-coloured**
    primary-button hierarchy (warm-white primary, blue connect/BLE, green go,
    amber live, red destructive — red is no longer the primary colour); a 7 px
    soft control radius; a raised interactive-surface contrast ladder
    (`brandControlFill` / `brandControlActive`); and new primitives
    (`BrandSheet`, `BrandSegmented`, `DenseRow`/`TableHeader`, `BrandChip`,
    `ToolGroup`/`IconBtn`, `PulsingDot`). Additive — existing screens render
    unchanged apart from the global radius/contrast.
  - **Device tab now leads with a hero status/action card** (No-device / Ready /
    Recording): live **RX/TX** activity chips, a pulsing recording timer, the
    colour-coded peripheral readout folded inline, and a **device dropdown →
    picker** (`StatusDropdownTrigger` → scan-connect-nearest / disconnect /
    "This phone" soon) that replaces the old connect/disconnect buttons. The
    standalone `ConnectionPanel` was removed.
  - **Sensor health no longer gates recording.** The HR-up gate is removed —
    HR/GPS/SD/IMU/battery surface as non-blocking warnings and recording starts
    immediately (SPEC §23.9/§23.10). Mode suites green (24/24). Follow-up:
    remove the now-unused `AwaitHr` / HR-wait-pill machinery.
  - **Settings + Maths tabs re-skinned (2026-06-11).** Settings gains a
    **desktop two-pane** layout (≥720 dp section-list + detail; narrow stays a
    single scroll, §27), firmware controls move to category-coloured
    `QuietButton`s, and Drive toggles are brand-tinted. Maths adopts the brand
    chrome throughout (operator chips, a `BrandSegmented` narrow insert-palette,
    destructive-red delete, `ColorGridPicker` kept, §25). Both are pure restyles
    behind unchanged providers — every existing control preserved (28 + 27
    verified); analyze clean, firmware widget test green.
  - **Data tab — Sessions tree re-skinned (2026-06-11, P11 slice 1).** The
    Date·Venue → Session → Laps tree adopts the brand system: mono tracked date
    headers on `brandSurface2`, hairline `brandRule` dividers, and a shared
    brand selection checkbox that reads as recessed on the inactive axis of the
    XOR selection (the session box dims in lap-mode and vice versa). Best-lap
    metrics and the session-best star use the saturated `brandGood`; ignored
    laps recede to `brandFgFaint` with a strikethrough. Pure restyle behind the
    existing `selectionProvider` — expand/collapse, venue/session detail
    routing, Compare-with, and Ignore/Restore all preserved. The tree now also
    derives a session's venue heading from a matched Track's venue when the
    session itself carries no `venueName` (mirroring the venue-filter facet), so
    track-matched sessions no longer group under "(no venue)". The **session
    detail card** is re-skinned to the brand system (mono header/file-info,
    `QuietButton` Save/Delete) and applies the same venue derivation in its
    header. The **filter rail** is re-skinned too: mono kicker section heads,
    `BrandChip` date presets, a brand check-row across every facet (Track /
    Venue / Bike / Rider / Tag / Source / requirements) with `brandGood` ticks
    and dim count badges, brand-filled search + lap-time inputs, and a
    `QuietButton` Clear-all — every facet and the McMaster-style faceted search
    preserved (SPEC §15.3).
  - **Session GPS preview + name-in-editor track creation (2026-06-12,
    SPEC §24).** The session detail card now shows a non-interactive GPS map
    thumbnail (`SessionMapPreview` over `sessionGpsPreviewProvider` → engine
    `gpsTrack`, on the app `tileSpecsFor` basemap) so you can recognise *where*
    a session was before any track work; a "Create track from this session"
    button appears when the session has GPS. Track creation no longer asks for
    name/venue in a pre-editor dialog: the Track Editor gains a **create mode**
    (`isNew` + `sourceSessionId`) with a **TRACK** sidebar section (Name +
    Venue), creating the Track on Save (single extended `createTrack`, then a
    source-session rescan) and discarding on Cancel. `TrackCreationDialog`
    removed.
  - **Track editor is responsive (2026-06-12).** The editor previously dropped
    its entire sidebar on narrow widths, so track creation / gate editing only
    worked on desktop. Narrow now stacks the map over a scrollable controls
    panel, and the map fills the area while a gate is being placed (precise two-
    tap), restoring the controls on commit/cancel. The sidebar build is shared
    between the wide and narrow layouts (SPEC §24.12).
  - **Tracks table re-skinned (2026-06-12).** The Tracks view moves off the
    Material `DataTable` to the brand `TableHeader` + `DenseRow` table (aligned
    `NAME · SESSIONS · LAPS · BEST · LAST RIDDEN`, `brandGood` best-lap, the
    `brandGood` inset selection bar), toolbar actions become `QuietButton`s
    (Import = filled primary), and the Track detail panel adopts brand chrome
    (mono header/stats, brand inputs, `QuietButton` Edit-gates / Save / Delete).
    Pure restyle — import / create-from-session / rename / delete all preserved.
    This completes the Data-tab (P11) brand pass.
  - **Analyze tab re-skinned (2026-06-12, P12).** The whole Analyze surface
    adopts the field-manual brand system — a pure presentation pass behind the
    existing `selectionProvider`, workspace, and chart engine (no behaviour,
    schema, or selection change; N-lap variance stays deferred). **Lap table:**
    the Material `DataTable` is re-themed to mono tracked headers + mono tabular
    data over hairline `brandRule` dividers, best-lap rows tinted `brandGood`,
    ignored rows recessed to `brandSurface2`; lap/sector deltas read
    `brandGood` / `brandAccent` (faster/slower), the M/O designation boxes share
    a `brandGood`-tick control, the star is `brandHivis`, the reference flag
    `brandInfo`. **Charts:** a shared `brandChartPalette` (8 luminous hues tuned
    for the near-black canvas) replaces the washed-out Material trace palette
    across time-series / FFT / GPS-map / lap-progression; axis labels, gridlines,
    and borders move to mono `brandFgDim` + `brandRule`; time-series cursors are
    `brandFg` (A) / `brandHivis` (B); GPS-map gate polylines, cursor discs, flags,
    layer toggle, tracks button, zoom buttons, and attribution all move to brand
    tokens/controls. **Chrome & dialogs:** the workbook bar + dropdown, the
    chart-workspace chrome (Add-chart/-channel `QuietButton`s, zoom banner, math
    error overlay, pinned/title/drag overlays), and every Analyze dialog/modal
    (add-chart, channel-picker, chart-properties, workbook import/delete/rename,
    sync-settings, browse-workbooks, tracks-popup, lap-overlay pickers) adopt
    mono labels, brand inputs/checkboxes/switches, and `QuietButton` actions.
    Tests updated for the new copy + uppercased button labels; `dart analyze`
    clean across the tab. No spec change needed (presentation only within
    SPEC §26).
  - **FFT chart — true log-axis gridlines (2026-06-12).** On a log frequency
    (or magnitude) axis the chart now draws decade **major** gridlines aligned
    with the 0.1 / 1 / 10 / 100 labels plus dim **2…9 intra-decade minor**
    lines, giving the characteristic "log paper" bunching instead of the
    previous evenly spaced (linear-looking) grid. Linear axes unchanged.
  - **Device config — channel table aligned (2026-06-12).** The Channels list
    in the Device config editor now lays the header, source rows, and expanded
    channel rows on one shared column grid
    (NAME · RATE HZ · UNIT · SCALE · OFFSET · ON) so values line up vertically:
    the per-source enabled/total count moves into the name cell and the
    per-source gear sits in a reserved trailing gutter that no longer pushes the
    source columns out of line with the header. The per-channel calibration —
    previously crammed and truncated as `unit · scale / offset` in one cell —
    splits into its own **Unit / Scale / Offset** columns; those headers (and
    the Unit/Scale/Offset values) show only when a source is expanded. A fixed
    gap separates the right-aligned rate from the value block (no more
    "Rate Hz"/"Unit" or "800g" collisions), the gear is constrained to its
    column, and the On column shows a saturated `brandGood` checkbox (dim
    hollow box when off) in place of the faint ✓/· glyphs. Layout-only —
    expand/collapse, source and per-channel dialogs, and + Add channel… all
    preserved (channels_table tests 5/5). The full Device-tab brand pass
    remains P8.
  - **Device tab — P8 channel table chrome (2026-06-12, slice 1).** The Channels
    table moves off the residual Material styling onto the brand system: the
    header row becomes uppercase mono kickers (`SOURCE · RATE HZ · UNIT · SCALE ·
    OFFSET · ON`) over a hairline `brandRule` rule, and the rows adopt a
    deliberate `plexMono` hierarchy — the source/channel name reads bright
    `brandFg`, the rate and unit dim to `brandFgDim`, and the scale/offset
    calibration detail recedes to `brandFgFaint` so a row scans name-first. The
    expand chevron and per-source gear move to `brandFgDim` chrome, and
    + Add channel… gains a `brandGood` add glyph. Presentation only — behaviour,
    column geometry, and dialogs unchanged (channels_table tests 5/5). Source
    dialogs (already theme-branded) get their hand-finished pass in slice 2.
  - **Device tab — channel table is responsive (2026-06-12).** The single-row
    column grid needs ~400 px of fixed RATE/UNIT/SCALE/OFFSET width, which a
    phone can't spare, so the channel name clipped to nothing on mobile. Below a
    560 px breakpoint the table now reflows (via `LayoutBuilder`) into a compact
    two-liner — the source/channel name owns the first line, and the calibration
    detail drops to a dim second line rendered as the calibration formula
    (`104 Hz · g · ×4.88e-4`, with a signed offset only when non-zero). Nothing
    is dropped (scale/offset survive for analog channels), and tablet/desktop
    keep the scannable wide grid unchanged. New widget test covers the compact
    path (channels_table 6/6).
  - **Device tab — P8 source dialogs (2026-06-12, slice 2).** The six per-source
    config dialogs (IMU / GPS / wheel / HRM / analog / digital) plus the HRM
    scan-pair dialog and the + Add channel… sheet get a hand-finished pass on
    top of the theme branding they already inherit. A shared `dialog_chrome.dart`
    gives every one an uppercase mono kicker title, mono section headings
    (`AXES`, `NMEA SENTENCES`), and a `QuietButton` action row (Cancel outline +
    a filled Save, with Delete/Forget as a red `alert` outline). Enable toggles
    and per-axis/NMEA checkboxes now read the same saturated `brandGood` as the
    channel table's On column instead of the theme's reserved amber/red; the HRM
    "Search nearby HRMs…" button becomes a blue `info` `QuietButton` and its
    helper prose moves to `plexSans`. Presentation only — every field, default,
    and save path is unchanged. The two read-only IMU/HRM row info stubs stay as
    theme-branded `AlertDialog`s (they live in the data layer). Touched files
    analyze clean; channels_table 6/6 (covers the picker).
  - **Device tab — P7 cleanup: dead AwaitHr machinery + Brand Gallery tab
    removed (2026-06-12).** Removed scaffolding the redesign left behind.
    Recording stopped waiting on the HR strap at P7 (sensor health is a
    non-blocking warning), so the now-dead HR-gate machinery is gone: the
    `AwaitHr` step + `_hrOk`, the `StepContext` skip half, the `waitingForHr`
    transition phase, `ModeTransition.hrWaitElapsed`, the `TimedOutWaitingForHr`
    result, `ModeController.skipHrWait`, and the `_HrWaitPill` substate (plus
    their isolated tests). The mode picker keeps its segmented control, refusal
    SnackBars, and the informational HR readiness dot. Also removed the debug
    **Brand Gallery** tab (the `kDebugMode` 6th nav destination and
    `brand_gallery.dart`). No behaviour change; mode suites green
    (mode_step / mode_picker / mode_controller). No spec change needed.
  - **Data tab — Tracks grouped by venue (2026-06-12, P11 follow-up).** The
    Tracks view is no longer a flat table — Tracks now collect into collapsible
    **venue sections** (a `brandSurface2` header strip with the uppercase venue
    name and a `· count`, expanded by default), mirroring the Sessions
    Date·Venue tree. Grouping preserves the provider's active sort via
    first-appearance order, so the venue holding the top-ranked track leads and
    rows keep their order within a venue; tracks with no venue collect under a
    single "(no venue)" section. The pinned column header
    (`NAME · SESSIONS · LAPS · BEST · LAST RIDDEN`), row layout, selection, and
    the right-pane `TrackDetailPanel` are unchanged. SPEC §24 updated
    (spec-during: "flat sortable table" → grouped-by-venue).
  - **Data tab — Sessions table layout + sortable columns (2026-06-12, P11
    slice 2).** The Sessions view is now an aligned, expandable table: a pinned
    column header (`TIME · SESSION · LAPS · DUR · BEST`) over `DenseRow` session
    rows whose values sit in fixed right-aligned columns, with lap sub-rows
    sharing the grid so each lap time stacks under the session's best lap
    (folds to `TIME · SESSION · BEST` below 620 dp, laps/duration kept as a dim
    tail — no data lost). Sorting moves from a direction-baked dropdown to a
    compact field-chooser + independent **ascending/descending toggle**: the
    `DataSort` enum is replaced by `DataSortField` + a `sortAscending` flag, so
    any column can be sorted either way (each field keeps a sensible default
    direction). `DenseRow` vertical padding tightened to 6 px. Provider tests
    11/11.
  - **Data tab fixes (2026-06-12).** (1) The Sessions tree's day-group order now
    follows the active sort instead of a hardcoded date-descending — group keys
    take their order from the already-sorted rows, so the Date direction toggle
    and the best-lap/duration/lap-count fields actually reorder the list. (2)
    The library-wide "Rescan visits" failed on every un-watched session with
    `StateError: Cannot call onDispose after a provider was disposed`. Root
    cause: `sessionHandleProvider` (autoDispose) called `ref.keepAlive()` only
    *after* its parse `await`, so a listener-less read (the bulk rescan uses
    `ref.read(...future)`) let it dispose mid-build, crashing at the subsequent
    `ref.onDispose`. Fix: pin with `keepAlive()` *before* the first await
    (closing the link on any build failure so an errored provider still frees).
    The bulk rescan also no longer collapses per-session failures into an opaque
    count — it surfaces the first real error (type + message) in the snackbar
    instead of a broad `catch (_) { return null; }`, per SPEC §16 / CLAUDE.md §5.
    (3) The bulk rescan no longer flashes the whole list once per session: each
    row shows its own spinner while it is being scanned (a tiny
    `rescanProgressProvider` watched per-row via `.select`, so only the active
    row rebuilds), and the workspace invalidations are deferred to a single
    batch refresh at the end.

- **Pipeline memory/perf remediation (2026-06-10).** Post-migration audit fixes
  spanning engine, bridge, and app — a 100M-sample session now loads without
  exhausting memory and the interactive paths stop copying full channels:
  - Dev (`flutter run`) builds compile the Rust engine and its dependencies at
    opt-level 3 (cargokit maps Flutter debug → cargo dev profile, which ran the
    parser/DSP unoptimized — the dominant "app got slower" factor).
  - `SessionHandle`s are disposed deterministically (residency eviction,
    import/scan/WiFi probe handles) instead of waiting on GC finalizers that
    feel no pressure from Rust-held bytes.
  - Import, rescan, and WiFi registration parse from the file path
    (`parse_session_from_path`); no whole-file Dart buffers or FFI byte copies
    (~3× file size peak eliminated); rescan stats sizes instead of reading.
  - `decimate_tile` folds min/max per bucket over the raw column — no f64
    span materialization at any tier (was 33 MB/tile at tier 4, and blocked
    higher tiers); chart tier ceiling raised 4 → 6 accordingly (≤ ~6k spots at
    any zoom vs ~49k); hover cursor writes throttled to 30 Hz; tile-arrival
    repaints coalesced.
  - `eval_math_into_store` evaluates and stores math channels engine-side,
    returning only `(length, rate)` — the result vector no longer crosses FFI
    twice and is no longer retained in Dart (~3×800 MB per channel at 100M
    samples); eval invalidation keys on the channels' name+expression
    fingerprint, so editor churn no longer re-evaluates every math channel;
    the Maths preview reads one decimated tile.
  - `slice_by_time` widens only the lap window (`materialize_range`), and
    `slice_by_time_into_store` keeps lap slices engine-side (no round trip).
  - Overlay (variance) evaluations share the retained handle via Arc instead
    of deep-cloning the whole session twice per eval.
  - Synthesized `Time` is a zero-storage ramp column and `Distance` stores
    GPS-rate metres lazily interpolated — removes 16 B/sample of resident
    overhead per handle (~1.6 GB at 100M samples), bit-identical output.
  - Handle residency is byte-budgeted (1 GiB warm default) from
    engine-reported `session_resident_bytes`, replacing the count-based
    8-handle policy. SPEC §15.3, §19, §22 updated.

### Removed

- **Dead-code sweep after the Rust migration (2026-06-11).** Pruned the
  vestigial sync DSP bridge wrappers (`filters` / `integration` /
  `clip_reconstruct` / `variance` / `calibration` / `rotation` modules and
  `fft`'s sync `fft`/`welch` fns — the app consumes that math through the
  engine via `eval_math_into_store` / `welch_channel`; the `fft` module
  survives for the mirrored Welch types) plus their orphaned generated Dart
  files; deleted two unreachable widgets left behind by the Data-tab redesign
  (`drive_sync_indicator.dart`, `gpx_import_dialog.dart`) and the dialog-only
  `importGpxAsSession` (GPX session import remains via the file picker; track
  import via "Import .gpx tracks…").

### Added

- **WiFi link P2 — Android plugin rewrite + loopback proxy (2026-06-10).**
  The platform layer is now a pure sensor/actuator: `request`/`release`
  commands plus an `available`/`lost`/`unavailable` event stream. No
  process-wide `bindProcessToNetwork` — device traffic flows through a
  loopback TCP proxy over `Network.socketFactory` sockets (pinned to the
  IPv4 loopback; Android's `getLoopbackAddress()` is `::1`), so internet
  (Drive sync) keeps working during transfers — verified on hardware. No
  platform-side timers: the 10 s bind timeout that could dismiss the
  system approval dialog is gone; Dart owns a 45 s request budget.
  `onUnavailable` now unregisters the network request (fixes a
  registration leak) and requests are SSID-keyed (no stale-network reuse
  across devices). Field-found fixes in the same pass: the binder is an
  app-session singleton behind `wifiBinderProvider` (the service provider
  previously rebuilt per status frame, discarding the proxy port), and
  the sync list waits for the link to finish converging instead of racing
  the bind (stopgap until the P4 ops gate). SPEC §6.2.

- **WiFi link lifecycle redesign (spec-first; design + SPEC revision, code to
  follow).** Root-cause rework of the WiFi connection lifecycle: firmware HTTP
  control plane (`/ping` identity/status, `/handoff`, `/wifi_off`, 5-min
  no-activity failsafe) with BLE fully off in WiFi mode (exits the documented
  C1-unstable SoftAP+BLE coexistence regime and stops ceding ~50% of radio
  time to BLE); app-side single-flight link reconciler (desired/actual,
  identity-verified `linked`, 10 s heartbeat, bounded backoff, transition
  journal); Android plugin reduced to commands + event stream with a loopback
  proxy replacing `bindProcessToNetwork` (Drive sync unaffected by transfers);
  staleness-aware `DeviceState` (BLE loss no longer reads as mode=idle);
  serialized link-gated ops facade; `Range`-resume downloads.
  SPEC §6.1/§6.2/§7.2/§7.3/§10.4/§23.9 revised; `design_rationale.md` entry.

- **FIT (Garmin) export from the `idl-rs` CLI (`idl-rs fit`).** Converts a
  session to a Garmin FIT activity (GPS track, speed, altitude, and heart rate)
  for Strava / Garmin Connect upload. Heart rate is carry-forward merged onto the
  GPS record stream; `--track <t.idl0t>` emits per-lap FIT lap messages; `--sport`
  sets the activity type (default cycling). The encoder is a pure-core
  `export/fit` module (hand-rolled FIT framing + CRC-16), validated by a
  `fitparser` round-trip test. SPEC §29.2, §29.5.
- **Compact raw sample storage with lazy f64 materialization (Phase C).** The
  engine's `Channel` now stores a typed `RawColumn` (I16/I32/F32 with
  `scale`/`offset`, or verbatim F64) instead of an eager `Vec<f64>`. IMU axes and
  i16/i32/f32 registry channels keep their raw wire values; physical f64 is
  materialized on demand as `(raw as f64) × scale + offset` — bit-identical to the
  old eager conversion — and never resident. Resident IMU storage drops 8 →
  2 bytes/sample (4×; ~160 MB → ~40 MB for a 20 M-sample session), and the
  per-sample scale multiply leaves the parser's IMU hot loop. GPS, synthesized
  `Time`/`Distance`, and math channels stay verbatim f64. Consumers materialize
  through the handle (`channel_samples` / `materialize_f64` / `slice_by_time`) or
  the narrow column ops (`decimate_tile` materializes only the tile window;
  `channel_min_max` folds over raw and scales the pair). No bridged-signature or
  Dart-binding change. SPEC §15.3.

- **Data tab — zero parse on open.** Detected laps are now cached per
  `TrackVisit` in `.idl0w` (schema v6 → v7) at import / WiFi download / GPX
  import / rescan, when the session is parsed anyway. The Data tab's session and
  track aggregates, lap-time facet domain, and the "compare with" picker read
  these cached laps instead of parsing each session — opening the tab no longer
  triggers a multi-second-per-session parse. The Analyze tab still detects laps
  live. Pre-v7 workspaces show laps after the next "Rescan visits". SPEC §15,
  §17.2, §17.4, §24.7.
  - Cached laps are renumbered **session-wide** on read (shared
    `cachedSessionLaps` helper) so the Data tab's lap numbers and ignored-lap
    matching agree with the Analyze lap table and §24.7 on multi-visit
    sessions — the engine emits per-visit numbering, which previously made
    ignore/display inconsistent across tracks within one session.

- **Bounded `SessionHandle` lifetime (Phase E) — fixes season-scale OOM.**
  `sessionHandleProvider` is now `autoDispose` + `keepAlive`, governed by a
  `HandleResidencyController` that keeps `selected ∪ 8-most-recent-deselected`
  handles resident and evicts the rest (closing the keep-alive link frees the
  Rust `Vec<f64>`; the session's chart tiles are dropped too). The six
  per-session providers that read the handle became `autoDispose` so deselect
  releases them. Previously handles freed only on library delete, so opening a
  season accumulated ~288 MB/session → OOM. Resident memory is now bounded by the
  selection, not the library size. SPEC §15.3.

- **`SessionHandle` Phase-0 API seam** (`channel_min_max`, `materialize_f64`,
  `slice_by_time`) — bounded views onto handle-owned samples: a finite (min,max)
  scalar pair for Y-axis auto-scale, a half-open index-range materialization, and
  an inclusive time-window slice (fixed-rate via nominal rate, event-driven via
  per-sample times; the seconds↔index conversion now lives in the engine, not
  scattered across Dart widgets). FRB-bridged (`ChannelBounds`). These let
  Analyze/lap consumers stop draining whole channels across FFI — the `f64` form
  crosses only as the bounded result. No app-behavior change yet: `channelDataProvider`
  still feeds today's consumers; the rewire is Phase D-drain. Master design §4/§7.

### Documentation

- **Efficient-pipeline master design**.
  Supersedes the handle-only cleanup roadmap (H1–H5). Defines the target pipeline:
  compact typed raw columns (native wire width + scale/offset) with lazy `f64`
  materialization, `SessionHandle` as the single sample owner behind a fixed API
  seam (`decimated_tile` / `channel_min_max` / `materialize_f64` / `slice_by_time`
  / `welch_tile` / `gps_track_tile`), and a seam-first roadmap (Phase 0 freeze →
  Eviction, Drain-retirement, Data-tab laziness, Compact storage). Diagnoses the
  three lazy-port artifacts behind the season-scale OOM (eager `f64` core column,
  duplicate Dart `ChannelData` copy, no handle eviction).

### Changed

- **Analyze charts self-source every view from the session handle; the second
  full Dart sample copy is gone (Phase D-drain).** `SessionChannelData` is now
  channel *metadata* (`sessionId`, `channelId`, `sampleRateHz`, `length`,
  `isEventDriven`) — no samples. Each chart pulls the bounded view it needs from
  the retained `SessionHandle` by id: the time-series line reads Y-bounds from
  `channel_min_max` and event-driven X from `channel_sample_times` (decimation
  already came from `decimate_tile`); the FFT reads its spectrum from a new
  engine `welch_channel` (computed Rust-side — only the `WelchResult` crosses
  FFI, never the samples); the GPS map reads the fix list from `gps_track`; the
  lap-compare overlay slices via `slice_by_time`. New focused `autoDispose`
  providers (`channelBoundsProvider`, `channelSampleTimesProvider`,
  `fftSpectrumProvider`, `gpsTrackProvider`, `lapSlicedChannelProvider`,
  `sessionStartMsProvider`) back these. A session's samples now live in exactly
  one place — the engine, in compact form. The `welch_channel` bridge wrapper
  lives in `session.rs` (beside the other handle accessors) so it shares the
  canonical `SessionHandle` opaque type. SPEC §15, §15.3, §26.

- **Parser hot loop routes by integer channel id/slot instead of hashing the
  channel name per sample** (SPEC §5.2). The v3 IMU and generic-channel paths
  resolved `(scale, offset)` and the accumulator bucket via `HashMap<String>`
  (SipHash) lookups on every sample — ~40M hashes for a 20M-sample session, a
  verbatim port of the Dart accumulator that Dart's cached `String.hashCode` had
  masked. Now resolved once per channel and routed by integer index; the
  per-sample channel-name clone on the fixed-rate path is gone too. Byte-identical
  output (full v3 parser test suite green). Release A/B on a 20M-sample synthetic
  log: parse 1.53 s → 0.37 s (4.2× faster, 13 → 55 M samples/s). GPS routing left
  name-based intentionally (low-rate, shared code).

- **Laps and sectors now carry engine-computed recording-time seconds**
  (`startTimeSecs` / `endTimeSecs`), stamped by the lap detector via the new
  `SessionHandle::epoch_ms_to_time_secs`. Math lap-context and channel-name
  listing no longer read the eager Dart sample copy (`channelDataProvider`) —
  the engine owns epoch→Time conversion, and the session-start anchor moves to
  the back-filled `timestamp_utc_ms` (fixes a pre-GPS-lock `GPS_EpochMs[0] == 0`
  edge case; sectors now GPS-interpolate consistently with lap bounds).
  Handle-only analyze-layer cleanup, step H1.

### Removed

- **`channelDataProvider` — the eager per-session `List<ChannelData>` drain.**
  Its only remaining consumers were the Analyze charts, which now self-source
  metadata + bounded views from the handle (see Changed). `ChannelData` itself
  stays — it is the GPX parser / `Session.channels` data model, not a chart type.

- **Retired the v1 (`ESPL`) and v2 (`IDL0` schema 2) log formats.** Only schema
  3 is parsed now: `ESPL` files report invalid-magic and schema-2 files report
  unsupported-schema. Deleted `parse/v1.rs`, `parse/v2.rs`, `parse/nmea.rs`, and
  `read_registry_entry_v2`; SPEC §5.0 (the v1 wire format) removed accordingly.
  New firmware writes schema 3; no v1/v2 files were worth retaining.

### Fixed

- **Math channels and lap-compare slices render in the Analyze viewport again.**
  Phase 3c retired the old Dart→Rust chart sample-ingest path, after which the
  time-series chart decimates strictly from the handle by id — but a *displayed*
  math channel was never written to the handle's math store (`resolve_math_
  dependencies` writes only a channel's referenced dependencies, not the channel
  itself), and lap-window slices lived only in Dart. Both rendered empty in the
  viewport (math still showed in the Maths-tab preview, which reads eval samples
  directly). The math evaluator now upserts its result via `add_channel` after
  `eval_math`, and lap slices are materialized into the store via `slice_by_time`
  + `add_channel`, so both decimate by id like any base channel.

- **Workbook dropdown actions no longer crash when no workbook is persisted.**
  Export, Duplicate, Sync settings, and Delete resolved the active workbook by
  name-matching against `workbookProvider` with `orElse: () => wbs.first`, which
  threw `Bad state: No element` whenever that list was empty (a fresh user, or a
  load race, viewing the synthetic default "Workbook 1"). All four now route
  through a guarded `_resolveActiveWorkbook` helper and surface a SnackBar
  instead of throwing. (`app/lib/ui/tabs/analyze/workbook_bar.dart`)

### Architecture

- **Rust engine extracted to a `/rust` cargo workspace; product rebranded
  IDL0 → idl-rs.** All DSP moved from `app/rust` into a pure `idl-rs` core crate
  (no flutter_rust_bridge dependency); a thin `idl-rs-bridge` shim holds the
  `#[frb]` wrappers (plus `#[frb(mirror)]` for the fft types) and is the only
  crate Flutter sees; a new `idl-rs-cli` crate builds the `idl-rs` binary. FRB
  codegen and the Gradle `cargoBuildRust` task now target `/rust/bridge`. The
  `.idl0`/`.idl0w` file format and `IDL0` magic header are unchanged, as is the
  Android `applicationId`. Phase 0 of the engine-migration roadmap.

- **`idl-rs` can now parse `.idl0` files (Phase 1, engine-side only).** A pure
  Rust parser for v1/v2/v3 logs plus the `Session`/`Channel` model lives in
  `idl-rs` (`parse`/`session` modules), with ~52 parity tests mirroring the Dart
  `BinaryParser` suite byte-for-byte. Additive only — the app still uses the Dart
  parser; the FRB cut-over is a separate reviewed step.

- **App cut over to the `idl-rs` parser; Dart `BinaryParser` removed (Phase 1
  cut-over).** Parsing now flows through a `RustOpaque<SessionHandle>`:
  `channelDataProvider` and the import/download/rescan paths call the engine and
  drain the handle into the existing `List<ChannelData>` shape. `Time`/`Distance`
  synthesis moved into the engine (`session::synthesis`); `session_metadata` is
  now the single session-summary extractor (duration = longest channel span).
  Parity gated by the Rust suite + an FFI golden before deleting the 1,214-line
  Dart parser, its tests, and the superseded `tool/dump_idl0.dart`. The chart
  decimation path (`ingest_channel`) is unchanged this phase — its shrink and
  retirement are a Phase-3 co-delivery. Web build is unsupported until WASM
  bindings (Phase 6).

- **Desktop + Android Rust build migrated to cargokit.** Replaced the
  hand-rolled Windows CMake/`build_rust_release.bat` hook and the custom Android
  `cargoBuildRust` Gradle task with the standard `flutter_rust_bridge` cargokit
  `rust_builder` plugin (`app/rust_builder`, `rust_lib_idl0`), pointed at
  `/rust/bridge`. Fixes the `flutter run -d windows` breakage after the Phase 0
  workspace move (`could not find Cargo.toml in app/rust`). The bridge package
  was renamed `idl-rs-bridge` → `idl_rs_bridge` to match the cdylib filename
  cargokit expects. `flutter build windows` green.

- **`idl-rs` CLI exports sessions to CSV and JSON (Phase 2).** New `idl-rs
  export <file.idl0> [-o OUT] [--format csv|json] [--channel NAME]...` writes the
  engine's channel set — raw channels plus synthesized `Time`/`Distance`.
  CSV is long/tidy (`channel,time_s,value`); JSON is a nested, lossless
  per-channel dump. The serialization lives in the `idl-rs` **core** (new
  `export` module — pure, streaming to any `io::Write`), so the CLI, the app,
  and future Python/WASM bindings share one implementation; format follows the
  `-o` extension unless `--format` overrides, and no `-o` writes to stdout.
  `info`/`channels` now read through `SessionHandle` (showing synthesized
  channels). Parquet deferred until a concrete columnar consumer.

- **Math-channel evaluator moved into `idl-rs` (Phase 3a).** The expression
  engine — tokenizer, recursive-descent parser, evaluator, value types, and the
  full live function set (`integrate`/`butter`/`fft`/`declip`, `differentiate`/
  rolling `rms`/`mean`/`std`, elementwise + trig, `clamp`/`if`, the four
  lap-aware functions, and `variance_time`/`variance_dist`) — now lives in the
  `idl-rs` core `math` module and is consumed by the app through `eval_math`.
  The `SessionHandle` is **retained** for the session lifetime (no longer
  drained-and-dropped) and gains an interior-mutable math-channel store written
  via `add_channel`, so the Dart cross-channel resolver writes resolved
  dependencies back without re-marshalling samples; the evaluator reads them
  Rust-side via a `ChannelLookup`. Cross-session `variance_*` crosses the
  overlay as a **second handle**, never as samples. The 1,840-line Dart
  `MathChannelEvaluator` and its `DspAdapter` seam are deleted; the seven
  deferred stubs (`spectrogram`, `hilbert`, `correlate`, `convolve`, `resample`,
  `sosfilt`, `median`) port as the same "not yet implemented" error. The
  cross-channel dependency resolver stays Dart for now (built against the
  `ChannelLookup`/`add_channel` seams so it can move later). Parity gated by
  Rust tests ported from the former Dart evaluator suite.
- **Headless workbooks: `idl-rs math --workbook` (Phase 3b).** The CLI gains
  `idl-rs math <file>.idl0 --workbook <wb>.idl0wb [-o OUT]`, which evaluates a
  portable workbook's math channels against a session and exports the derived
  channels (CSV/JSON; `--include-base` adds base + synthesized, `--channel`
  filters). The engine gained a `.idl0wb` reader (`workbook` module — reads
  `math_channels` only) and `apply_workbook`. The cross-channel **dependency
  resolver moved from Dart into the `idl-rs` core** (`math::resolve`); the app
  now resolves through the `resolve_math_dependencies` bridge fn and the Dart
  `_resolveDependenciesIntoHandle` was removed. Export gained `write_channels`
  (an explicit channel slice) so derived channels held behind the math-store
  lock can be emitted. Lap-aware functions require a lap context the CLI does
  not yet build (lap detection is a later phase) and are reported as skipped.
- **Chart decimation reads from the session handle (Phase 3c).** Chart tiles
  decimate directly from the retained `SessionHandle`
  (`decimate_tile(handle, channel_id, tier, tile_index)`, backed by a shared
  `with_channel_samples` find path that `lookup` also uses); the process-global
  `chart_decimation` sample registry and the `ingest_channel`/`release_channel`/
  `release_session`/`sample_at` functions (and their bridge wrappers) are
  deleted. A session's samples now live in exactly one place — the engine. The
  Dart tile cache and its invalidations (session removal, math re-eval) are
  unchanged. Completes the Phase 3 engine migration (3a evaluator + 3b workbooks
  + 3c decimation).
- **Lap detection moved into `idl-rs` (Phase 4a).** `idl_rs::laps::detect_laps`
  reads the session's GPS from the retained handle, takes the bound Track's
  gates/sector-gates/neutral-zones as input, and returns the lap table (with an
  optional `TrackVisit` window); circuit + point-to-point timing, sectors, and
  neutral-zone subtraction all port verbatim. The app's `visitLapsProvider` cut
  over via the `detect_laps` bridge fn and the Dart `LapDetector` was deleted.
  The Track config models and `buildGpsTrack` stay Dart for track matching
  (Phase 4b). No CLI yet (headless gate source lands in Phase 5).
- **Portable Track artifact + headless lap/track CLI (Phase 5b).** New `.idl0t`
  file (one Track per file = the Track JSON + a version wrapper) lets the GUI
  export/import tracks and the `idl-rs` CLI analyze them headlessly:
  `idl-rs laps run.idl0 --track t.idl0t` prints the lap table; `idl-rs visits …`
  reports track visits (text or `--format json`). The engine reads `.idl0t` via
  a new shared `config` versioned-JSON reader, which `workbook` reading now also
  uses (its bespoke error type was removed). App import prompts on a `trackId`
  collision (update in place vs new copy). `.idl0w` stays an app concern (not
  migrated). No FFI changes — lap/visit detection was already bridged.
- **Track matching moved into `idl-rs` (Phase 4b).** Multi-track visit
  detection is now `idl_rs::tracks::detect_visits`: it reads the session GPS
  from the handle, matches against each Track's reference polyline, and returns
  deterministic visit windows (the app mints the `visitId` when mapping them).
  `GpsFix` + `build_gps_track` were promoted to a shared `idl_rs::gps` module
  (used by both `laps` and `tracks`), and `gps_track` is exposed so Track
  authoring and the ghost-lap distance accumulator build their GPS from the
  engine. The Dart `TrackMatcher`, `PolylineGeometry`, and `buildGpsTrack` are
  deleted — no Dart copy of the GPS-fix builder survives. Detection tuning
  defaults live once in `VisitParams::default()`. Completes the Phase 4 engine
  migration (4a lap detection + 4b track matching).

### Firmware

- **Config push moved to BLE (2026-06-16).** `idl0_config.json` now pushes
  over BLE instead of WiFi — more reliable than the SoftAP and no WiFi
  changeover overhead. New Config-RX characteristic FF05 (`0000FF05-…`) plus
  two Control commands: `CMD_CONFIG_BEGIN` (0x07) opens an 8 KB reassembly
  buffer, the app streams the JSON to FF05 in MTU-sized chunks, and
  `CMD_CONFIG_COMMIT` (0x08) validates + atomically writes the file and reboots
  ~500 ms later to apply (config is read at boot only). BEGIN/chunk/COMMIT all
  carry the §7.2 ACK protocol — overflow, empty/duplicate commit, malformed
  JSON, or an SD write error are refused (`0x80`/`0x81`) with no partial config
  persisted; a disconnect mid-transfer discards the buffer. The validate +
  temp-file-and-rename logic is now a shared `idl0_config_write_json()` used by
  both this path and the WiFi `POST /config` handler (kept as a fallback).
  App: `BleConnection.pushConfigBle()`; Push Config now requires idle mode and
  reconnects after the reboot. SPEC §7.1/§7.2/§8/§23.6.

- **Config read-back over BLE — round-trip verify (2026-06-16).** New
  Config-TX characteristic FF06 (`0000FF06-…`, read) plus `CMD_CONFIG_READ_BEGIN`
  (0x09): snapshots the live `idl0_config.json` and serves it back in ≤200-byte
  chunks via a device-side cursor (read until an empty chunk = EOF); the
  snapshot is freed on disconnect. App: `BleConnection.pullConfigBle()` →
  decoded `Map`. Push Config now pulls the config back after the reboot and
  confirms it matches what was sent ("applied and verified" / "didn't match");
  the check is best-effort, so older firmware without FF06 still reports a plain
  "applied". SPEC §7.1/§7.2.

- **On-SD diagnostic log (2026-06-16).** New `diag_log.{c,h}` writes
  `/sdcard/idl0_debug.log`: a `BOOT reason=…` marker per power-up (a
  `BROWNOUT` trail = battery sag), a 15 s heap sample (`heap/min/frag`) so a
  slow leak shows as a declining trend, and `wifi up/down` + `ble
  suspend/resume` event lines to correlate heap drops with radio cycles.
  Skips itself during a logging session (§1, no SD contention),
  mutex-serialised, size-capped (rotates at 512 KB), no-op without an SD card.
  Diagnostic aid for the long-session WiFi degradation.

- **WiFi-mode HTTP control plane (link lifecycle P1, 2026-06-10).** New
  endpoints: `GET /ping` (identity + status JSON — the WiFi-mode status feed
  and the app's liveness/identity probe), `POST /handoff` (drops BLE so WiFi
  owns the radio outright — exits the C1-unstable SoftAP+BLE coexistence
  regime), `POST /wifi_off` (HTTP exit path; deferred teardown, BLE
  advertising resumes). A no-activity failsafe exits WiFi mode after
  5 minutes with no associated station or no HTTP request — streaming
  transfers count as activity — so the device can never be stranded in AP
  mode. `idl0_wifi_stop()` resumes BLE on every exit path. Verified on
  hardware (ping/handoff/wifi_off round trip, post-handoff transfers,
  pre-handoff BLE abort); the 5-minute failsafe is code-reviewed and
  self-announces on serial in normal use. SPEC §6.1, §10.4.

- **`POST /config` reboots to apply (2026-06-04).** After persisting
  `idl0_config.json`, `config_post_handler` flushes the `200` then
  `esp_restart()`s (config is read at boot only). The GPS module is UART-only
  with no power-enable GPIO, so the u-blox keeps its fix across the SoC reset.
  Spec §6.1.

- **IMU + GPS sampling suspends while the SoftAP is up.** `imu_task` and
  `gps_task` now poll `IDL0_MODE_BIT_WIFI_UP` (mirroring `hrm_task`) and stop
  their sensor bus reads while WiFi is active. The WiFi/logging mutex guarantees
  no session is logging then, so no data is lost; IMU FIFOs are drained-and-
  discarded and the GPS UART flushed on resume. Because IMU0 shares the SPI2 bus
  with the SD card, suspending hands the bus and CPU to the `/download` `fread`
  loop — **measured ~5× download throughput**. Spec §10.4.

- **`/files` reports `session_id`.** The `GET /files` JSON now includes a
  `session_id` per file — the 16-byte header UUID (file offset 5) rendered as
  32 lowercase hex chars — read from each file's header in `wifi_server.c`.
  Lets the app diff device files against its library without downloading them.
  Omitted when a header is unreadable. Spec §6.1.

- **Mode event group framework.** New `mode_state.{h,c}` exposes a
  single `EventGroupHandle_t` with `WIFI_UP` / `LOGGING_ACTIVE`
  bits. `wifi_server.c` and `session.c` set/clear bits;
  mode-aware subsystems subscribe via `xEventGroupWaitBits` /
  `xEventGroupGetBits` instead of being called via per-subsystem
  hooks. Removes the legacy `hrm_task_on_wifi_on/off()` API in
  favour of `hrm_task`-side bit-edge detection.
- **Command ACK protocol.** Control writes (FF03) now return an ATT
  result code: `0x00` accepted, `0x03 WRITE_NOT_PERMITTED` for
  mutex / precondition refusals, `0x80–0x82` reserved.
- **WiFi/Logging mutex enforced.** `CMD_WIFI_ON` returns `0x03`
  while a session is running; `CMD_START_LOGGING` returns `0x03`
  while SoftAP is up.
- **1 Hz status publisher.** Periodic `esp_timer` re-publishes FF04
  so centrals see live state without per-subsystem on-change
  hooks.
- **On-change HRM publishes.** `hrm_task` triggers
  `idl0_status_publish()` at STREAMING entry, DISCONNECT, first
  battery read, and SUSPENDED ↔ SCANNING transitions.
- **Live status notifications.** `status.c` now runs a 1 Hz `esp_timer`
  that republishes the FF04 status string so the connected central sees
  live BPM, NO_CONTACT, SD/GPS/IMU/WiFi state without disconnecting and
  reconnecting. `hrm_task` additionally publishes on STREAMING entry,
  DISCONNECT, first battery read, and SUSPENDED ↔ SCANNING transitions
  so HR-line changes feel immediate. No GATT contract change.
- **HRM resume diagnostics.** Added one-line logs at `idl0_wifi_stop`
  entry, `hrm_task` EV_WIFI_ON / EV_WIFI_OFF dequeue (with state), and
  `start_scan`'s `ble_gap_disc` return code, to isolate why the HRM
  central sometimes does not resume after `CMD_WIFI_OFF`.

### App

- **WiFi connection lifecycle — bind follows mode state (2026-06-04).** Fixed
  the recurring "connects once, must restart to reconnect" failures on Android.
  Root causes, found via systematic debugging: (1) the Android
  `WifiNetworkSpecifier` request omitted `removeCapability(NET_CAPABILITY_INTERNET)`,
  so the no-internet device AP could never satisfy it — a silent 10 s bind
  timeout; (2) the process bind was a side-effect of the `WifiOn` *transition*,
  so relaunching with the AP already up (no transition) never bound. Now: the
  native bind is **idempotent + self-healing** (fast-reuse a live network, clear
  on `onLost` and re-request); a new **`WifiBindController`** makes the bind
  **follow `Mode` state** — bound whenever the device is in `Mode.wifi`, however
  it got there — owned/activated by the Device tab; `WifiOn`/`WifiOff` are now
  pure firmware-AP commands. `switchTo` also requires a live BLE link (clean
  "Connect first" instead of raw "not connected" exceptions), and `pushConfig` /
  `deleteFile` gained request timeouts so a stuck call can't hang forever. The
  Device-tab WiFi hint shows live bind status (`linked` / `linking…` /
  `not reachable`). Spec §6.2, §10.4.
- **HR-wait Skip continues instead of cancelling.** Tapping Skip during the HR
  strap wait now resolves `AwaitHr` as success and proceeds into `StartLogging`
  (via `ModeController.skipHrWait()` / `StepContext.skip()`), distinct from
  Cancel which aborts — so a strap enabled in config but not worn no longer
  hard-blocks recording. Spec §4.1.
- **Config push auto-applies via reboot + reconnect.** A successful Push Config
  now restarts the device (firmware `POST /config` → `esp_restart`) so the new
  config applies in full — config is read at boot only (HRM enable/address, IMU
  ODR/ranges), so this avoids partial application. The app then re-establishes
  the BLE link automatically (`DeviceNotifier.reconnectAfterReboot`, with retry)
  and the device boots back into idle mode ready to log — no manual reconnect,
  no button. The GPS module keeps power across the SoC reset, so its fix
  survives. Spec §6.1.
- **Data tab sync/download redesign.** Replaced the cramped fixed-height
  download panel with a compact "Sync · N new" entry button that opens a
  full-screen Sync screen (`SyncScreen` / `syncControllerProvider`). The
  screen diffs device files against the library by `session_id` (now reported
  in `/files`), marking each NEW / IN LIBRARY / identity-unknown, sorted
  newest-first. Two behaviours switch on one setting: by default the list is an
  unchecked **file picker** (check a few, tap "Download (N)") so connecting to a
  new device never pulls everything at once; with the `autoSyncOnOpen` setting
  ON it's **connect-and-forget** — opening downloads all new files
  automatically. Either way files download through a strictly sequential queue
  (the device serves one request at a time) with per-file `MB / MB · %`
  progress — derived from the known file size, since the device streams chunked
  without a `Content-Length` — and an overall "N of M done · K queued" banner.
  Per-file failures are isolated; a Stop control halts the queue. Retires
  `download_panel.dart`. Spec §6.1, §24.17, §27; design_rationale.

- **Fixed: event-driven channels (HR_RR) plotted on a dilated time axis.**
  Channels with `sample_rate_hz == 0` were placed at a fallback 1 Hz —
  one sample per integer second — so a channel that emits faster than 1 Hz
  was stretched by its mean event rate (HR_RR at ~120 bpm spanned 2× the
  real session duration; a 30-min ride showed 60 min of beats). The parser
  was reading each `CHANNEL_SAMPLE`'s `timestamp_us` and discarding it. It
  now keeps per-sample times for event-driven channels in
  `ChannelData.sampleTimesSecs` (seconds relative to the earliest record
  timestamp), and the Analyze chart plots them against those times instead
  of `index / rate`. Also corrects wheel-pulse and digital-marker channels.
  Decimation is unchanged (index-bucketed min/max); only the bucket→X and
  viewport→sample-range mappings became timestamp-aware. Spec §15.2, §21.2;
  v3 parser only (the v2 path is deprecated, removed 2026-06-03).
- **Channel pickers group by sensor.** The Maths Channels insert panel and the
  Analyze Add Channel dialog now group session channels into collapsible
  sections by name prefix (`GPS`, `IMU0`, `IMU1`, `IMU2`, `HR`) instead of one
  long flat list; ungrouped channels render flat beneath, and a search query
  flattens to a filtered list. Pure `groupChannelNames` resolver + reusable
  `GroupedChannelList` widget; presentation-only (custom groups deferred).
- **HRM BPM channel renamed `HeartRate` → `HR_BPM`.** So it shares the `HR_`
  prefix with `HR_RR` for grouping and matches the GPX importer (already
  `HR_BPM`). Renamed in firmware (`session.c` registry stamp), the app
  (`HrmSource`), and spec §5.2; channel id stays 22. Legacy `.idl0` logs are
  aliased on read so they group consistently without re-recording.
- **Duplicate math channels.** Each math channel row has a duplicate action
  (`duplicateChannel`) that copies the channel with a fresh id and a unique
  `" copy"` name and selects it.
- **Office-style colour grid.** A shared `ColorGridPicker` (hue × shade grid +
  greyscale, no new dependency) replaces the two smaller divergent palettes in
  the math channel metadata chip and the chart channel colour row.
- **Analyze: bar refinements + chart reorder + sheet right-click + overlay
  cleanup.** Workbook bar shrunk 48 → 40 dp with the X-axis mode
  (Time / Wheel / GPS) moved into the bar as a compact dropdown; the
  `WorkbookBindingChips` row is removed (lap-table M/O selection now drives
  overlay session). Chart slots reorder via a drag handle paired with the
  properties cog — `ReorderableListView` with a custom `proxyDecorator`
  gives large tiles a lifted shadow + 0.98 scale during drag; pinned
  Session Sheet slots can't be reordered. Worksheet tabs gain a
  Rename / Duplicate right-click context menu (new
  `workspaceProvider.duplicateWorksheet`). Per-chart title overlay moves to
  top-centre and renders nothing when blank, eliminating overlap with the
  Y-axis tick labels. Time-series charts gain a coloured-dot legend in the
  top-left corner (mirrors the FFT chart's legend), positioned clear of
  the Y axis. `ChartSlot` now carries a `slotId` UUID for stable identity
  through `ReorderableListView`, JSON round-tripped.

- **FFT chart: Welch spectral estimation.** The FFT chart now computes spectra
  via Welch's method (new Rust `welch()` on `rustfft`) instead of a single
  periodogram. New per-chart properties: segment length (blank = auto), overlap %,
  detrend (None/Mean/Linear), averaging (Mean/Median), scaling (Magnitude/PSD
  Density), and a log-magnitude (Y) axis beside the existing log-frequency (X).
  Defaults (auto segment, 50 % overlap, Mean detrend, Mean averaging, Magnitude)
  produce a smoothed, DC-suppressed spectrum out of the box — fixing the dominant
  0 Hz spike and noisy haze of the raw periodogram — while a single full-record
  segment with no detrend reproduces the old raw view. `fft(ch, window)` remains
  the math-channel primitive, unchanged. See `docs/signal_pipeline.md`.

- **Maths tab Channels picker shows session + math channels.** The
  Channels insert panel was fed only the math channel names and never the
  recorded session channels, so it appeared empty of `[IMU1_AccelX]`-style
  references. Both the picker and expression validation now read a single
  `mathExpressionChannelNamesProvider` — the union of the selected sessions'
  channel names and every math channel name — so a math channel can reference
  another (the evaluator already resolved such cross-references). A typed
  channel name now also carries over to the left list and the picker live as
  you type (the Name field persisted on submit only, which never fired on
  focus loss). Spec §25 updated.
- **Maths: channel names with spaces/digits now evaluate.** The expression
  evaluator's tokenizer split the text inside `[...]` into separate
  identifier/number tokens, so a reference like `[New channel]` or
  `[Declipped 1_AccelX]` validated but threw `Expected rbracket but got …`
  at evaluation. The lexer now captures the whole bracketed name verbatim
  (matching the validator's `[^\[\]]+` rule), so any channel name — including
  the default "New channel" — resolves.
- **`declip(ch)` math channel.** Reconstructs IMU acceleration peaks
  clipped at the ±32 g sensor rail by fitting a smooth asymmetric pulse
  (sech² template) to each clipped segment's unclipped shoulders, with
  widths constrained by the clip span so the recovered peak — and the
  jerk/jounce derived from it — are physical. Negative-rail clips are
  reconstructed in a sign-normalised domain (rebuilt downward, not as an
  upward spike). The peak overshoot is bounded by how long the signal stayed
  clipped (it grows quadratically with clip width, scaled by the shoulder
  slopes), so a brief one- or two-sample graze of the rail is reconstructed
  conservatively instead of as a tall spike; the policy deliberately
  under-recovers genuinely wide clips rather than risk a misleading peak.
  Returns the channel unchanged where nothing is clipped. Backed by a pure-Rust
  reconstructor (`app/rust/src/clip_reconstruct.rs`); the template shape is
  tuned offline by a dev-only Rust harness against real sub-limit waveforms.
- **WiFi/Logging mode picker.** New three-segment `ModePicker` in
  the Device tab makes WiFi state explicit and mutually exclusive
  with recording. Record segment carries an HR-readiness dot
  (green/amber). Transitions to Recording wait for HR (10 s,
  Skip override). Driven by a table-based `ModeController` walking
  composable `Step` primitives; typed `TransitionResult`s map to
  distinct UI per failure mode (firmware refusal SnackBar,
  disconnect, timeout MaterialBanner). Removes the panel-scoped
  WiFi lifecycle from `DownloadPanel`; the panel now shows an
  inline "Switch to WiFi mode" button when not in WiFi mode.
  Config push / OTA flows require `Mode.wifi`. Spec §7.2, §10.4,
  §23 updated.
- **Analyze tile-based chart decimation.** Time-series charts now render
  via min/max-decimated tiles fetched lazily from Rust, with raw
  samples handed off to a Rust-owned per-(session, channel) cache.
  Pinch-zoom and pan stay smooth at 60 fps on a Pixel 8 Pro for
  sessions up to 2 hr × 800 Hz. Tile cache (30 MB cap, LRU) lives at
  `ChartTileCache`; tier selection picks `log8(samples_per_pixel × 2)`
  clamped to [0, 4]. Y-zoom anchors at the gesture focal point (was:
  range center). `setXAxisRange` writes coalesce to ~60 Hz during a
  gesture. Spec §26.8 and §15.3 updated.
- **Portable Workbooks.** Workbooks are now first-class entities synced to
  Google Drive (`IDL0/workbooks/<uuid>.idl0wb`), can be exported and imported
  as `.idl0wb` files, and carry their own math channels. Chart rendering is
  session-agnostic — new primary/overlay binding chips (24 dp strip below the
  workbook bar) bind sessions at view time without altering the workbook
  definition. Per-workbook sync settings dialog controls debounce cadence and
  Drive opt-out. `.idl0w` schema bumped to v6: `math_channels` and
  `workbook_layout` removed (math channels live on the owning Workbook;
  `workbook_layout` was never read). v5 files migrate cleanly on first launch.
  Legacy SharedPreferences `workspace_state` blob migrates to per-workbook files
  on first launch and is then deleted. Spec §17a added; §11.4, §25, §26, §28
  updated.
- **Analyze tab — vertical shrink via cursor tooltip.** Replaced the
  persistent `ChartCursor` strip beneath every time-series chart with
  fl_chart's built-in tooltip, brand-styled (mono Plex, hairline
  border, `brandSurface` fill) and formatted with a new universal
  smart sig-fig formatter (`formatChannelValue`): 3 significant
  figures with magnitude-aware decimal places. Tooltip indicators
  are pinned to cursor A so values stay visible after the touch
  lifts; suppressed during multi-finger pinch to avoid focal-point
  thrash. A small `A → B  Δ <t>` chip renders above the chart only
  when both cursors are pinned, replacing the old strip's B and Δ
  columns. Per-channel B values are no longer surfaced inline — use
  the chart context menu's `Copy Cursor Values` to export both
  cursors. Reclaims ~28 dp per time-series chart on mobile. FFT,
  GPS map, lap table, and lap progression charts are unchanged
  (none used `ChartCursor`). Spec §26 updated.
- **Analyze tab — multi-channel FFT + auto-open properties on new chart.**
  FFT slots now render every assigned channel as its own line on a shared
  frequency axis (was: only the first channel). Event-driven channels are
  silently skipped; renderable channels' IDs appear as colored-dot chips in
  the title bar legend. Per-channel colour overrides from
  `ChartSlot.channelColors` work the same as in `TimeSeriesChart`. Adding a
  `timeSeries` or `fft` chart now auto-opens the chart properties dialog
  so channels can be assigned without a second click; `gpsMap` and
  `lapProgression` (which auto-resolve channels) are unchanged. Spec §21.1
  updated.
- **Device tab — channel-table editor + bike-profile library.** Replaces
  the per-section form in `config_editor.dart` with a `ProfileBar`
  (dropdown + add/kebab actions) above a `ChannelsTable` that mirrors
  the §5.2 binary registry: one expandable parent row per `ChannelSource`
  (IMU0/1/2, GPS, Wheel Speed, Analog, Digital). Profile library lives at
  `<docs>/profiles/<uuid>.idl0p` (one JSON file per profile, atomic save).
  Active profile id persists to `SharedPreferences` (`idl0.profiles.active_id`).
  New abstraction in `data/channel_source.dart` + `data/channel_sources/`
  decouples the UI from individual sensor kinds — new kinds (Spec 2's HRM,
  future cadence/power) plug in via `kChannelSourceFactories` with zero
  table-UI changes. Schema cleanup: `bike_profile.type` and `imu_count`
  dropped (presence derived from `imu.imuN.enabled`); `analog.scaling` map
  replaced by ordered `analog.channels[]` array; new `digital.channels[]`
  block; wheel speed defaults to disabled. Legacy configs migrate on load
  via `BikeProfile.migrateLegacyConfig`. Spec §8 + §23 updated.
- **Firmware — debounced marker (handlebar) button support.** New
  `digital_task` reads `digital.channels[]` (kind `marker`), installs a
  GPIO ISR with software debounce, writes one CHANNEL_SAMPLE (u8,
  event-driven, value = monotonic press counter) per accepted press via
  the existing writer queue. Analog reader generalised to iterate
  `analog.channels[]` instead of hardcoded pressure-front/rear.
- **Fix: re-downloading a session no longer crashes the widget tree.**
  `SessionNotifier.addSession` now upserts by `sessionId` (replaces an
  existing entry in place, otherwise appends) instead of always
  appending. Hardware symptom: re-downloading a session you already had
  put two `SessionMetadata` with the same `sessionId` into Riverpod
  state, downstream widgets used the sessionId as a `Key`, and the
  rendering layer threw on duplicate keys (debugger paused on a
  rendering/widgets-library exception; UI hung). Mirrors
  `ConflictAlgorithm.replace` already used by `SessionIndex.upsert`, so
  both layers agree on duplicate handling. On a true cross-device UUID
  collision (different `deviceId`, same `sessionId` — astronomically
  unlikely with 128-bit UUIDs but logged for audit), the latest import
  wins and a `debugPrint` warning is emitted. Composite-sessionId
  migration logged in `TASKS.md` as the proper long-term fix.
- **Per-request HTTP timeouts on `WifiTransfer`.** `listFiles` and
  `downloadFileTo` (initial response + per-chunk gap) now cap each HTTP
  call at 8 s (configurable via `requestTimeout`). Hangs surface as
  `TransferTimeoutException` instead of freezing the UI. Together with
  the existing single retry in `RealWifiService.getFileList`, a stalled
  first request now retries automatically — previously the retry only
  triggered on thrown errors and a hang slipped through. Diagnostic
  hook: the timeout's exception message names the endpoint and elapsed
  seconds, so the next hardware test can pinpoint which leg stalled.
- **Sessions land on external storage.** WiFi-downloaded `.idl0` files now
  write to `getExternalStorageDirectory()/sessions/` (falls back to app
  documents on platforms without external storage), so they're browseable
  from the Android Files app. The session index, GPX import, and download
  panel registration all read from the same root. Existing files left in
  the old internal path are treated as lost — no migration.
- **Fix: post-bind warmup race on first `/files` request.** Hardware
  symptom that survived the panel-scope bind: opening the Data tab on
  a connected device, then tapping "Load files" the first time, threw
  a "Could not reach device" snackbar; the second tap a second later
  succeeded. Root cause is Android-side — `bindProcessToNetwork`
  returns success when `onAvailable` fires, but DHCP / ARP / the
  device-side `esp_http_server` haven't all fully settled. The very
  first GET to `192.168.4.1` throws `SocketException`. `RealWifiService.getFileList`
  now retries once after a 500 ms delay; subsequent calls hit a warm
  path and don't retry. Genuine unreachability still surfaces — both
  attempts fail, the second exception propagates.
- **P9: OTA — app side.** Settings → Update Firmware section: pick a
  `.bin`, push to the device over WiFi (`WifiTransfer.pushFirmware`
  streams chunked to `POST /ota`), watch progress, cancel mid-upload
  (closes the HTTP client → device times out and discards). On
  success the panel grays out for 5 s and auto-reconnects over BLE;
  if the device boots into `PENDING_VERIFY` (parsed from the §7.3
  status string), a commit card offers `Confirm` (sends
  `CMD_OTA_CONFIRM` 0x06) or instructs the user to power-cycle to
  roll back. New: `FirmwarePushException(statusCode)` for the
  device-emitted 400 (image validation) and 500 (device error) so
  the UI can surface "Firmware file corrupted" vs "Device error"
  separately from generic `DeviceUnreachableException`.
  `BleService.confirmOta`, `DeviceState.otaPendingVerify`, and
  `DeviceNotifier.confirmOta` plumb the state through Riverpod. Wire
  contract — `POST /ota` body is raw `.bin` octet-stream returning
  `ok\n`, then a ~500 ms reboot delay — matches the firmware-side P9
  handler (separate session).
- **Fix: panel-scoped WiFi bind lifecycle.** `RealWifiService` no longer
  binds/releases the Android process network on every `getFileList` /
  `downloadFile` call. `WifiService` gains explicit `bind()` / `release()`
  methods and `BleService` gains `wifiOn()` / `wifiOff()`; `DownloadPanel`
  owns the lifecycle — `bind` + `CMD_WIFI_ON` on the `deviceConnected:true`
  transition, `release` + `CMD_WIFI_OFF` on the transition back or on
  dispose. Hardware symptom this fixes: after the first `releaseWifi`
  tears down the network callback, the next `requestNetwork` sometimes
  fired no callback at all and timed out at 10 s — so "Load files" worked
  but "Download" timed out until retapped. As a side effect, the AP is
  also commanded on as part of opening the panel, so file listing works
  without the user having to push a config first.
- **P5: Device tab peripheral status + v2 device ID.** The Device tab now
  shows SD / GPS / IMU peripheral status parsed from the §7.3 BLE status
  string. The v2 binary parser reads the device ID as 6 MAC bytes
  (12-char hex) per the §3.6 correction. New `app/tool/dump_idl0.dart` —
  a standalone Dart CLI that parses a `.idl0` file with the production
  `BinaryParser` and prints its header (magic, schema, session/device IDs,
  start time, config CRC, channel/sample counts); a verification aid for
  P5-P7 firmware bring-up.
- **Fix: BLE connect no longer triggers WiFi bind.** `DownloadPanel` was
  auto-loading the file list on `deviceConnected` becoming true, which called
  `WifiNetworkBinder.bind()` immediately after every BLE connect — popping the
  Android WiFi dialog and crashing with `DeviceUnreachableException`. Removed
  the auto-load; the file list now loads only when the user taps "Load files"
  (spec §6: WiFi AP is on-demand only). `TransportException` is now caught at
  the `DownloadPanel` and `ConfigEditor` UI boundaries and shown as a SnackBar
  instead of propagating as an unhandled crash.
- **BLE integration pass.** Live `BleService` wired — the Device tab now
  connects to a real `IDL0-XXXX` device over `flutter_blue_plus`
  (`BleConnection` now implements `BleService`), replacing `StubBleService`.
  Completes P4.
- **Android build: automatic Rust cross-compile.** The `idl0_processing`
  Rust library now cross-compiles as part of the Android Gradle build
  (`cargoBuildRust` task → `cargo-ndk`), keeping the bundled `.so` always in
  sync with the Rust source. Gradle skips the task when the Rust source is
  unchanged. The committed `jniLibs/*.so` binaries and the manual
  `tools/build_android_rust.bat` script are removed; CLAUDE.md §7 updated.
- lap delta: full rewrite — Rust track_projection (directional
  matching) + variance_time/variance_dist/current_lap/lap_start_time/
  sector_number. Per-session main/overlay/starred lap designation
  replaces baselineLapKey. Time as synthesised base channel. Five
  hardcoded tutorial math channels. Supersedes 2026-05-08 variance
  architecture.
- variance: variance_time / variance_dist / lapDelta math expression
  functions backed by per-Track canonical polyline (consensus-scored
  seed + perpendicular-median refinement) and per-lap distance
  accumulator with confidence-anchored drift redistribution. Track
  editor Polyline section + cyan-dashed candidate overlay.
  _Superseded by the lap-delta rewrite above._
- ghost-lap: confidence-weighted Gaussian filter with per-slot smoothing /
  spike-rejection / drift-sensitivity sliders in chart properties.
- **Track gates redesign.** `Track.lapGates` replaced by `Track.lapTiming`
  (sealed union: Circuit | PointToPoint); new `NeutralZone` entity for
  timing pauses; `Lap.rawElapsedMs` exposes uncorrected duration alongside
  `lapTimeMs`. The §17 workspace-over-track fall-through is removed; lap
  detection reads only Track. New Track editor modal (map + sectioned
  sidebar) launches from the Track detail card or the Analyze map's
  Tracks… popup. Track creation from a session segment supported via
  tap-A/tap-B + range slider with auto-perpendicular preview gates.
  Analyze tab gate-edit UI removed.

### App
- **Schema v3 binary parser path.** `BinaryParser.parse()` dispatches on
  the schema byte: `IDL0 + schema = 2 → parseV2`,
  `IDL0 + schema = 3 → parseV3`, all others throw
  `UnsupportedSchemaVersionException`. `ChannelRegistryEntry` gains `scale`
  and `offset` fields (defaulted to 1.0 / 0.0 so v2 files decode unchanged
  through the unified `physical = raw × scale + offset` formula).

  `_parseV3ImuRecord` looks up each enabled axis by name in the registry
  and applies scaling. A missing-entry fallback stores the raw value with a
  `dev.log` warning so a malformed file does not crash the parser.
  `_parseV3ChannelRecord` does the same for `CHANNEL_SAMPLE` records.

  The test suite gains a `parseV3 — …` group of 13 tests:
  header round-trip with registry scaling, mixed-range IMUs (IMU0 at ±32 g
  vs. IMU1 at ±16 g — same raw int16 value yields different physical
  outputs), disabled-axis registry absence, CHANNEL_SAMPLE scaling,
  FIFO-overrun computed-rate carryover, dispatcher routing, schema-mismatch
  errors, and defensive missing-entry fallbacks.

  The v2 parser path is preserved and tagged at each entry point with
  `// TODO(idl0): remove after 2026-06-03` cleanup comments. A scheduled
  task on that date will delete `parseV2`, `_parseV2*Record`,
  `_readRegistryEntryV2`, the v2 test group, and the v2 dispatcher branch.

- **Analyze tab — chart context menu (v1)** — right-click (desktop) and
  long-press (mobile) on any time-axis chart (TimeSeries, Ghost, FFT,
  LapProgression) opens a Cursor / Zoom / Pan menu, plus Reset View, Copy
  Cursor Values, and Properties. Dual A/B cursors per worksheet (`CursorPair`)
  render as solid-white A and dashed-amber B vertical lines across all charts
  in the worksheet; the readout below each chart shows A time + values, B
  time, and |A↔B| delta. Worksheet X range and cursor pair now persist in
  SharedPreferences so zoom and cursors restore on app reopen. Manual Y range
  reuses the existing `ChartSlot.yScaleMode + yMin + yMax`.
  - **Default keybindings:** Shift+arrows / Shift+scroll = pan; Alt+arrows /
    Alt+scroll = zoom; F2 / Alt+F2 = horizontal/vertical full-out; Z = zoom
    to cursors; Ctrl+Shift+C = copy cursor values; F5 = Properties...
    Settings-backed editable bindings is a v2 follow-up; the const
    `kDefaultChartBindings` map is the source of truth for v1.
  - **Mobile gestures:** 1-finger drag = move cursor A; 2-finger pinch = free-
    form X+Y zoom (Y only acts when slot is in `YScaleMode.manual`); 2-finger
    drag = pan; long-press = menu; long-press-drag = Zoom Window
    (drag-rectangle); double-tap = Reset View.
  - **Zoom Window:** secondary-button-drag (desktop) or long-press-drag
    (mobile) paints a translucent rectangle and on release applies its X
    range and slot manual Y range. Drags below 8 px in either dimension
    fall through to a normal click.
  - **Reset View:** clears X range, both cursors, and slot Y mode in one
    operation. Triggered by menu, double-tap, or by the F2/Alt+F2 keys
    (which clear individual axes).
  - New files: `app/lib/data/cursor_pair.dart`, `app/lib/ui/widgets/chart_action.dart`,
    `app/lib/ui/widgets/chart_context_menu.dart`. Modified: cursor provider
    (CursorPair state), workspace provider (persistent worksheetRanges +
    new worksheetCursors map), all four time-axis chart widgets,
    chart_workspace.dart's properties dialog made public as
    `ChartPropertiesDialog`. Spec §26.7 added.
  - **Deferred to v2:** Active Channel concept (next priority — vertical
    zoom currently no-ops on auto-mode Y), editable keybinding settings
    table, Maximise, GpsMapChart menu (different op set), LapTable menu,
    Print/Export, Cut/Copy/Paste/Delete, Pan-to-Cursor.
- **Data tab redesign.** Three-column layout (filter rail · results · detail
  pane). Sessions grouped by Date·Venue. Track names inline on session rows.
  New side-panel detail cards for sessions, venues, and tracks. Delete-session
  flow with app-only / everywhere scope. Rescan-visits toolbar button. Venue
  facet in the filter rail. Spec §24 rewritten.
- **Analyze tab — Session Sheet worksheet kind** — pinned Lap Table + Lap
  Progression chart at the top of every session-analysis worksheet, with
  bidirectional XOR selection sync to the Data tab.
  - `Worksheet.kind: WorksheetKind { standard, sessionSheet }` added to
    `lib/providers/workspace_provider.dart`. JSON `kind` field is omitted
    when standard (the default) so older app builds reading newer prefs
    just ignore it; missing key + unknown values both fall back to
    `standard`. No `_kSupportedWorkspaceVersion` bump — that constant
    governs the `.idl0w` per-session schema, not the runtime workbook
    persisted via `shared_preferences`.
  - `Worksheet.sessionSheet(name:)` convenience constructor pre-populates
    `charts` with `[ChartSlot(chartType: ChartType.lapTable),
    ChartSlot(chartType: ChartType.lapProgression)]`.
  - `ChartType` extended with `lapTable` (formalised — was a hardcoded
    `const LapTable()` rendered below every worksheet) and `lapProgression`
    (new). `chart_workspace.dart` dispatches both via the existing slot
    switch; the unconditional `LapTable` at the bottom of the worksheet
    is removed (only Session Sheets show one now).
  - `WorkspaceNotifier`: `_defaultState()` now ships **two** worksheets
    per workbook — `Worksheet.sessionSheet(name: 'Session')` at index 0,
    blank `Worksheet(name: 'Charts')` at index 1. `addWorkbook` does the
    same. `addWorksheet(name, {kind})` accepts a kind. New
    `removeWorksheet(int)` (refuses to drop the last sheet, clamps the
    active index). `removeChart` refuses to drop pinned slots
    (`kSessionSheetPinnedSlotCount = 2`) on Session Sheets — no-op + a
    `debugPrint` for tooling visibility. One-shot load-time migration
    `_ensureSessionSheet`: any workbook in prefs missing a Session Sheet
    gets one prepended on first read.
  - **`lib/ui/tabs/analyze/lap_progression_chart.dart`** — new widget,
    one fl_chart line per session in `effectiveSessionIdsProvider` scope
    (works in both selection modes), X = lap index 1..N, Y = lap time
    seconds. Per-session palette colour, fastest-lap dot enlarged. **No
    ignored-lap or track filtering** — this chart's job is "did I get
    faster", filtering defeats it. Empty state when nothing is selected.
  - **`lib/ui/widgets/mode_aware_checkbox.dart`** — shared
    `ModeAwareCheckbox` widget; renders at full opacity when its row's
    selection kind matches the active `SelectionMode`, at 40 % when
    muted (other-mode active). Tapping a muted box still flips the mode
    and toggles the entry — matches the Data tab's "click anywhere to
    switch mode" affordance.
  - **`lib/ui/tabs/analyze/lap_table.dart`** — section headers and lap
    rows gain `ModeAwareCheckbox`es wired to
    `selectionProvider.toggleSession` / `toggleLap`. Session-row
    checkboxes mute in lap-mode; lap-row checkboxes mute in session-mode.
    A new column at the front of the data table holds each lap's
    checkbox.
  - **`_ChartHeader`** picks up a `pinned` flag — pinned slots render a
    small `Icons.push_pin` + "PINNED" badge, hide the properties button,
    and hide the new remove button. Non-pinned slots get an
    `Icons.close` remove button (this is also a small UX upgrade for
    standard sheets — previously charts had no per-slot remove
    affordance). Drag-resize handle and "Add Channel" shortcut are
    suppressed for `lapTable` / `lapProgression` slots since they have
    intrinsic sizing and no channel config.
  - **Workbook bar**: Session Sheet tabs render with a leading
    `Icons.list_alt` (12 dp, dim). The "+" `IconButton` is replaced by a
    `PopupMenuButton<WorksheetKind>` offering **Standard** /
    **Session Sheet**; Session Sheets auto-name as `Session N`.
  - 13 new tests (5 workspace_provider — default shape, addWorksheet
    kind, removeChart-pinned-no-op, removeWorksheet last-sheet refusal,
    `Worksheet.fromJson` migration; 1 chart_workspace test still
    passing; 3 lap_progression_chart — empty/3×5/lap-mode scope; 2
    lap_table mode-aware checkbox flips; 2 workbook_bar — initial
    SESSION+CHARTS render and Standard/Session-Sheet picker). Several
    pre-existing tests updated to seed the standard `Charts` worksheet
    before mutating chart slots. `flutter test` passes 409/409,
    `flutter analyze` clean.
- **Saucy Eng Field Manual brand system** — full visual / typographic
  refresh across all five tabs. Logic, providers, and behaviour
  unchanged.
  - `lib/ui/brand/` — new module with eight reusable widgets and the
    palette/typography tokens. Tokens enforce a closed eight-colour
    palette (`brandBg`, `brandSurface`, `brandSurface2`, `brandFg`,
    `brandFgDim`, `brandRule`, `brandAccent`, `brandHivis`),
    `brandControlRadius = 2 px`, `brandHairlineWidth = 1 px`. Widgets:
    `SectionHead`, `SpecRow` (NATOPS leader-dot row), `TickBlock`,
    `BracketedCta`, `StatusBadge` (active / alert / inert),
    `HairlineDivider` (speedline), `LiveryStripe`. `brand.dart`
    re-exports everything for a single-line import.
  - `lib/ui/app.dart` — replaced the cyan default theme with a
    Field Manual `ThemeData`. Tourney for display, IBM Plex Mono for
    body / UI / numerics, `FontFeature.tabularFigures()` baked into every
    `TextStyle` so digits align in tables and charts. Structural
    surfaces (cards, dialogs, popups, snackbars, tooltips) get
    `BorderRadius.zero` + a 1 px `brandRule` border; interactive
    controls (buttons, inputs, chips, segmented buttons, checkboxes) cap
    at 2 px. NavigationBar / NavigationRail use uppercase tracked
    labels with a `brandHivis` active indicator.
  - `lib/ui/shell/adaptive_shell.dart` — mounts a single `LiveryStripe`
    at the top of every screen and uppercases the five nav labels.
  - **Settings tab** — `SectionHead` per group (`§01 PROFILE`,
    `§02 UNITS`, `§03 DRIVE SYNC`, `§04 HOW-TOS`, `§05 ABOUT`). Drive
    Sync surfaces a `StatusBadge` + `BracketedCta` for sign in / out;
    How-To articles render as tap-to-open `TickBlock`s indexed
    `§04.1`–`§04.4`; About uses `SpecRow`s for version, schema, build.
  - **Device tab** — three collapsible sections wrapped in `SectionHead`
    headers (`§01 CONNECTION / Link`, `§02 CONFIG / Profile`,
    `§03 CALIBRATION / Reference`). Connection panel uses `StatusBadge`
    for connected state and `BracketedCta` for connect / disconnect
    and recording. Calibration checklist now lives inside a `TickBlock`.
  - **Runs tab** — Drive strip across the top is a flat
    `StatusBadge` + `BracketedCta` (replaces the old `ExpansionTile`).
    Panel headers gain a `brandAccent` tick + tracked label; library
    actions use `BracketedCta` for **Tracks** and **Import**;
    `_LibraryBody` mode toggle keeps its `SegmentedButton` but the
    labels are uppercased. The flat session list (`SessionList` /
    `SessionListItem`) drops `Card` chrome for a hairline-bordered
    row, mono uppercase date, and a debossed `GPX` badge. The
    hierarchical view's tag chips are uppercased; day / track headers
    pick up a brand tick + tracked label; lap rows render
    `LAP n` … leader dots … `m:ss.t` with the day-best in `brandHivis`
    instead of the prior gold star tint.
  - **Maths tab** — channel list header gains a `brandAccent` tick +
    tracked label; channel rows render uppercase mono;
    `FunctionHelpPanel` is now a `TickBlock`; insert panels
    (Channels / Functions / Constants) get `_PanelCard`s with the
    same tick-and-label header pattern; expression preview drops its
    rounded corners.
  - **Analyze tab** — `WorkbookBar` loses its `Material elevation: 1`
    in favour of a hairline bottom rule and uppercase tracked tab
    labels. `ChartWorkspace`, `LapTable`, and `GpsMapChart` had their
    rounded corners (3 / 4 / 6 / 8 px) flattened to zero — overlay
    badges, scale chips, and tile-source picker chrome now follow the
    structural-surface rule.
  - Test surfaces updated to match: `device_tab_test` looks for
    `CONNECTION` and a `BracketedCta` widget instead of the old
    `Connection` text and `ElevatedButton`; `workbook_bar_test` asserts
    `SHEET 1` instead of `Sheet 1`. New `test/ui/brand/` directory
    covers the eight new widgets (19 cases) and adds a
    `flutter_test_config.dart` that disables `GoogleFonts.config.
    allowRuntimeFetching` so the suite stays offline-clean.
  - Pubspec gains `google_fonts: ^6.2.1` for Tourney + IBM Plex Mono.
- **Track entity (Phase 2 — auto-detection + manual binding UI)** —
  metadata editor surfaces a Track row above the existing fields and lets
  the user bind / unbind / create directly. See `docs/IDL0_SPEC.md §12.3`.
  - `lib/data/polyline_geometry.dart` — new shared helper exposing
    `closestPointOnPolyline(px, py, refLat, refLon)` returning
    `(segmentIndex, t, distSq)`. New callers (`TrackMatcher`) use it; the
    existing windowed `GhostLap.ghostLapDelta` keeps its hot-path
    inlined-search optimisation rather than regressing to an unbounded
    scan.
  - `buildGpsTrack(channels)` lifted from
    `lib/providers/lap_provider.dart` to public API in
    `lib/data/lap_detector.dart` (next to `GpsFix`); the previous private
    `_buildGpsTrack` is gone.
  - `lib/data/track_matcher.dart` — new `TrackMatcher.findMatchingTrack`.
    Algorithm: (1) bounding-box pre-filter on lat/lon ranges; (2)
    sub-sample the session GPS to ~50 evenly-spaced fixes; (3) project
    each sample onto every surviving Track's `referencePolyline` via the
    shared `PolylineGeometry`, converting to a local east/north metric
    frame using a flat-earth approximation centred on the session
    bounding-box centroid; (4) accept the candidate with the smallest
    mean distance if it is below `thresholdMeters` (50 m default). Pure
    Dart; no Rust bridge call (per CLAUDE.md §1).
  - `lib/ui/tabs/runs/metadata_editor.dart` — converted from
    `StatefulWidget` to `ConsumerStatefulWidget`. New `_TrackRow` at the
    top of the form renders three states:
    - **Bound:** Track name with **Change** (re-opens picker) and
      **Detach** (`Icons.link_off`) actions.
    - **Unbound + auto-detected:** "Auto-detected: <name>" with
      **Confirm** / **Choose other** actions.
    - **Unbound + no match:** "No track" with **Assign** (opens picker)
      / **Create** (opens create dialog) actions.
    Live `SessionMetadata.trackId` is re-read from `sessionProvider` on
    every build so external mutations (e.g. another part of the UI
    binding the session) update the row in real time. Track-binding
    mutations are applied immediately via `trackProvider` — they do not
    wait for Save and are not undone by Cancel; the dialog is a thin
    shell around the live providers.
  - `_TrackPicker` bottom sheet lists every known Track (auto-matched
    one first, then by `updatedAtMs` descending), tags the matched one
    `(auto-detected)`, ticks the currently bound one, and exposes
    "Create new" + "Detach from current Track" actions.
  - `_CreateTrackDialog` takes a name (default = `meta.venueName` or
    `Unnamed Track`), then via `TrackNotifier.createTrack` copies the
    current `Workspace.lapGates` / `sectorGates` and the session's GPS
    (via `buildGpsTrack(channels)`) onto the new Track and binds it.
  - Tests: `test/data/track_matcher_test.dart` (8 cases — exact overlap,
    bbox-rejection, threshold-rejection, best-of-many, empty inputs,
    empty polyline, threshold tightening). Three new metadata-editor
    widget tests in `test/providers/runs_provider_test.dart` covering
    the no-track, bound, and Assign-tap-→-picker-→-assign flows; the
    pre-existing save test was wrapped in `ProviderScope` with the new
    overrides. `flutter test` 338/338, `flutter analyze` clean.
- **Track entity (Phase 1 — foundation, no UI yet)** — cross-session,
  cross-device anchor for venues, stored as JSON in Drive
  (`IDL0/tracks/<trackId>.idl0t`) with a local SQLite cache for fast
  queries. See `docs/IDL0_SPEC.md §12.3`.
  - `lib/data/track.dart` — new `Track` model. Holds `trackId` (UUID),
    `name`, `venueName`, canonical `lapGates` / `sectorGates` (firmware
    × 1e7 scale, reusing `LapGate` / `SectorGate`), and a
    `referencePolyline` of `GpsFix` for auto-detection. `Track.create`
    generates UUID + timestamps; `copyWith` auto-bumps `updatedAtMs` on
    content change unless an explicit `updatedAtMs` is supplied (used by
    Drive-download paths that carry remote authoritative timestamps).
  - `GpsFix` gains `toJson` / `fromJson` so reference polylines round-trip.
  - `lib/data/track_index.dart` — new SQLite-backed `TrackIndex` cache
    (separate `tracks.db`, schema v1). Single-table schema with a
    `full_json` column; gates and polyline are read/written together so
    no normalised joins are needed.
  - `SessionIndex` — bumped to **schema v3**. Adds nullable `track_id`
    column via `ALTER TABLE` migration; existing rows load unchanged with
    `trackId == null`. `SessionMetadata` gains `trackId: String?` plus a
    `clearTrackId()` method (mirrors `Workspace.clearReferenceLapNumber`).
  - `lib/transport/drive_service.dart` — `DriveService` interface adds
    `listTracks` / `downloadTrack` / `uploadTrack` and a new
    `DriveTrackFile` value class. `GoogleDriveService` implements them
    against `IDL0/tracks/`: list filters `*.idl0t` whose basename is a
    valid UUID v4, download streams JSON via `DownloadOptions.fullMedia`,
    upload uses Files.create on first push and Files.update on subsequent
    edits (parents stay implicit on update). Folder is created lazily on
    first upload; missing folders return `[]` from `listTracks` rather
    than failing.
  - `lib/providers/track_provider.dart` — new `TrackNotifier`
    (`AsyncNotifierProvider<TrackNotifier, List<Track>>`). `build()` opens
    the cache, returns it immediately, then fires-and-forgets a
    `_syncWithDrive` reconciliation. Conflict policy is **last-write-wins
    by `Track.updatedAtMs`** — Drive copy wins iff its `modifiedTime`
    exceeds local `updated_at_ms`, otherwise local is uploaded. Methods:
    `createTrack`, `updateTrack`, `deleteTrack` (cascades a detach to
    every session bound to that Track in both `SessionIndex` and the
    `sessionProvider` in-memory list), `assignSessionToTrack`,
    `unassignSession`, `pushSessionGatesToTrack`. A
    `debugSyncCompletion` future is exposed for deterministic test waits.
  - Tests: `test/data/track_test.dart`,
    `test/data/track_index_test.dart`, expanded
    `test/data/session_index_test.dart` (v3 migration round-trip), and
    `test/providers/track_provider_test.dart` (8 tests covering create
    flow, offline cache, remote-newer download, local-only upload,
    bind / unbind / delete cascade, push-to-Track). The fake
    `DriveService` in `test/providers/drive_sync_provider_test.dart` got
    inert stubs for the new track methods so the existing suite compiles.
- Analyze tab — ghost as a worksheet chart + synchronized cursor across
  GPS map / time-series / ghost charts:
  - **`ChartType.ghostDelta`**: new chart type. `ChartSlot` extended with
    nullable `sourceSessionId: String?` and `targetLapNumber: int?` (default
    null for non-ghost slots; `_unset` sentinel in `copyWith` so callers can
    explicitly clear). `toJson` omits both keys when null; `fromJson` reads
    them with null defaults so old workbook layouts load unchanged. Unknown
    `chartType` strings still fall back to `timeSeries`.
  - **`WorkspaceNotifier`** gains `addGhostChart({sourceSessionId,
    targetLapNumber})` and `removeChart(int chartIndex)`.
  - **`GhostChart`** widget (`lib/ui/tabs/analyze/ghost_chart.dart`):
    resolves the reference lap at render time via the new shared
    `resolveGhostReferenceLapNumber` (pinned-when-not-ignored else fastest
    non-ignored, with extra fallback when target == active reference),
    reads `ghostDeltaProvider`, draws `fl_chart` `LineChart` (x = lap
    seconds, y = delta seconds, zero line). Title bar shows
    "Ghost — Lap N vs Lap M (best[, target ignored])" plus a remove button
    that calls `WorkspaceNotifier.removeChart`.
  - **`LapTable` ghost button** no longer pushes a full-screen route — it
    calls `addGhostChart` so the chart appears in the active worksheet
    next to the GPS map and time-series charts. **Removed**
    `ghost_delta_page.dart` (no callers remain).
  - **Synchronized cursor**:
    - `cursorProvider` keeps its existing `String → double?` (session-relative
      seconds) contract; each chart converts at render time.
    - `GhostChart` reads `cursorProvider(worksheetId)`, converts to lap-
      relative seconds via `lapStartSeconds = (lap.startTimestampMs −
      GPS_EpochMs[0]) / 1000`, and renders a vertical line only when the
      cursor falls inside `[0, lapDuration]`. Tap/horizontal-drag inside
      the chart writes the cursor back as `lapStartSeconds + localTapSecs`.
    - `GpsMapChart` accepts a new `worksheetId` parameter. For each selected
      session it converts the worksheet cursor to absolute UTC ms via
      `cursorEpochMs`, binary-searches `GPS_EpochMs` with `nearestEpochIndex`,
      and renders a small white-filled coloured-ring `Marker` per session.
      Sessions whose epoch range doesn't include the cursor render no
      marker.
    - **Tap-to-set-cursor on GPS map (non-edit mode, no gate selected)**:
      finds the closest GPS sample of the primary session by squared
      flat-earth distance and writes
      `cursorSecondsFromEpoch(sessionStartMs, sampleEpochMs)` to
      `cursorProvider(worksheetId)`. Edit-mode placement and selection-
      dismiss behaviours take precedence as before.
  - **`lib/data/cursor_lookup.dart`** new file with three pure helpers
    (`nearestEpochIndex`, `cursorEpochMs`, `cursorSecondsFromEpoch`) so the
    binary-search math is unit testable without a `flutter_map` widget.
  - **`resolveGhostReferenceLapNumber`** lifted from `lap_table.dart` to
    `lap_provider.dart` as a top-level public function — single source of
    truth shared by lap table and ghost chart.
  - **`chart_workspace` dispatch**: `ChartType.ghostDelta` → `GhostChart`;
    `worksheetId` threaded to `GpsMapChart` for cursor sync. Generic
    `_ChartHeader` skipped for ghost slots since `GhostChart` provides its
    own title bar with the remove button. Drag-resize handle and "Add
    Channel" shortcut hidden for ghost slots (no channels apply).
  - 16 new tests: 8 cursor-lookup math, 5 `addGhostChart`/`removeChart`/
    JSON round-trip on `workspaceProvider`, 6 `resolveGhostReferenceLapNumber`
    variants on `lapProvider`, 1 lap-table widget test (ghost button
    appends slot). `flutter test` passes 304/304.
- Analyze tab — ignore laps for timing without deleting them:
  - **Workspace v3**: `Workspace.ignoredLapNumbers: Set<int>` (1-based, matches
    `Lap.lapNumber`); `_kSupportedWorkspaceVersion` bumped 2 → 3. JSON key
    `ignored_lap_numbers` (`List<int>`, sorted for stable diffs, omitted
    when empty); v1/v2 files load with empty default. Note: the original
    task description said "bump 1 → 2" — the codebase was already at v2 from
    the previous gate-placement task, so this is the same intent applied
    one version forward.
  - **Notifier methods**: `SessionWorkspaceNotifier.ignoreLap(int)`,
    `unignoreLap(int)`, `clearIgnoredLaps()`. Synchronous save on every
    mutation (no debounce); duplicate ignores and unignoring an absent lap
    are no-ops.
  - **Lap table UI**:
    - Per-row `Icons.block` (idle) / `Icons.visibility_off` (ignored)
      `IconButton` toggles the ignore state; tooltip changes accordingly.
    - Ignored rows render with `surfaceContainerHighest` row background and
      `TextDecoration.lineThrough` text at 60% opacity. Best-lap highlight
      and Δ columns suppressed for ignored rows.
    - `Icons.star` marks the best non-ignored lap (the lap the ghost button
      compares against); `Icons.flag` marks an explicitly *pinned*
      reference, only when the user has set one — otherwise the active
      reference equals the starred lap.
    - Best-lap and per-sector best are computed across non-ignored laps
      only and stay stable when the user toggles "Show ignored".
    - Worksheet-level `_ShowIgnoredToggle` (visibility / visibility_off
      icon + label) above the table, default ON, local widget state.
    - Ghost button is disabled on the active reference, when no eligible
      reference exists, OR when fewer than two non-ignored laps exist.
  - **Ghost route**: reference resolution layered as
    `pinned-when-not-ignored ?? fastest-non-ignored`; pinned reference is
    silently overridden when the user later ignores it. Implemented in
    `_resolveReferenceLapNumber` in `lap_table.dart`; `GhostDeltaPage`
    receives the resolved number unchanged.
  - 12 new tests (4 workspace: v3 round-trip, empty-set omission, v2
    forward-compat, copyWith; 3 notifier: round-trip, duplicate no-op,
    clear; 1 lap-table widget: lap 2 ignored produces correct
    star/block/visibility-off counts, lap 3 takes best). `flutter test`
    passes 283/283.
- Analyze tab — GPS map zoom controls, clearer edit-mode FAB, and gate
  endpoint editing:
  - **Zoom buttons**: vertical pair of `FloatingActionButton.small` (+ / −) at
    bottom-right; each calls `MapController.move(currentCenter, zoom ± 1)`
    clamped to `MapOptions.minZoom = 1.0` / `maxZoom = 19.0`.
  - **Edit-mode FAB**: replaced ambiguous `Icons.location_searching` small FAB
    with `FloatingActionButton.extended` carrying an icon + text label
    (`Icons.add_location_alt` + "Place Gate" idle / `Icons.close` + "Cancel"
    active). Active state uses `Theme.colorScheme.error` background so edit
    mode is visually unmistakable.
  - **Gate endpoint reposition**: each gate renders two extra `Marker`s — one
    per endpoint — with a `Icons.drag_indicator` handle. Handles are visible
    only when the gate is selected or edit mode is active (uncluttered
    otherwise). Each handle wraps a `GestureDetector` whose `onPanStart`
    captures the endpoint's screen point via
    `mapController.camera.latLngToScreenPoint`, `onPanUpdate` accumulates
    pixel deltas and converts back via `pointToLatLng` for live preview, and
    `onPanEnd` commits via `SessionWorkspaceNotifier.updateLapGate` /
    `updateSectorGate`. Gate `Polyline` re-renders with the previewed
    endpoint while the user drags so the move is visible immediately.
  - **Swap Start/Finish**: new `Icons.swap_horiz` button in
    `_SelectedGatePanel` shown only when the selected gate is a lap gate
    AND `lapGates.length >= 2`. Calls
    `SessionWorkspaceNotifier.swapLapGates()` which exchanges
    `lapGates[0]` and `lapGates[1]`.
  - 5 new tests (`updateLapGate` apply + out-of-range no-op, `updateSectorGate`
    apply, `swapLapGates` exchange + length-<2 no-op). `flutter test` passes
    275/275.
- Analyze tab — map provider switch + tile-layer toggle: replaced
  `google_maps_flutter` with `flutter_map` + `latlong2` so the GPS map no
  longer needs a Google Maps API key, has no Google Play Services dependency,
  and gains free OSM tile usage. New `lib/ui/tabs/analyze/map_tile_source.dart`
  exposes `MapTileSource` (`osmStandard`, `esriSatellite`, `esriHybrid`) and
  `tileSpecsFor()` returning one or more `MapTileLayerSpec`s; hybrid stacks
  satellite + boundaries/labels via two `TileLayer`s. `gps_map_chart.dart`
  rewritten on `FlutterMap`: track polylines via `PolylineLayer`, gate
  midpoint markers via `MarkerLayer` with a flag-and-label child, attribution
  badge bottom-right, `Map | Satellite | Hybrid` `SegmentedButton` top-right,
  initial camera fit via `MapOptions.initialCameraFit`. `SessionWorkspaceNotifier`
  gains `reorderSectorGates(int oldIndex, int newIndex)` (handles
  `ReorderableListView`'s `newIndex > oldIndex` adjustment); a new top-right
  `Icons.reorder` button opens a bottom-sheet `ReorderableListView` of sector
  gates. Google Maps API key meta-data and the long Maps setup comment removed
  from `AndroidManifest.xml`. 7 new tests (3 `reorderSectorGates`, 4
  `tileSpecsFor`); existing GPS-map widget tests still pass unchanged.
- Analyze tab — FFT X-axis scale toggle: `FftXScale` enum (`linear`, `log`)
  added to `fft_chart.dart`; defaults to `log` (the right choice for sensor
  spectrum analysis). Log scale transforms spot X to `log₁₀(freq_Hz)`, skips
  the DC bin (log(0) undefined), and renders one label per decade
  (0.1, 1, 10, 100, 1k …) via a custom `getTitlesWidget`. New `Lin | Log`
  `SegmentedButton` in the FFT title bar alongside the window selector.
- Analyze tab — bug fixes + UX pass:
  - **FFT on v1 files**: `_parseV1()` infers `sampleRateHz` from IMU timestamps
    `(N-1)/(lastTs-firstTs)` so FFT no longer shows "requires fixed-rate channel"
    on ESPL recordings.
  - **"Add Channel" button**: hidden once a chart has channels; use the ⚙ properties
    dialog for subsequent changes.
  - **Workspace persistence**: `WorkspaceState` serialised to JSON and stored under
    `shared_preferences` key `workspace_state`; restored on app restart with safe
    fallback to defaults on corrupt/missing data.
  - **Rename workbook/worksheet**: double-tap the workbook dropdown label or any
    worksheet tab to enter an inline `TextField`; confirm on Enter or focus-out.
  - **Chart properties — reorder channels**: channels section uses
    `ReorderableListView`; drag to reorder; order committed to provider on drop.
  - **Chart properties — add channel**: "+ Add Channel" button opens
    `_ChannelPickerDialog` on top of the properties dialog without closing it.
  - **Chart properties — edit math channel**: edit icon on math channel rows sets
    `mathChannelProvider.activeChannelId` and navigates to the Maths tab.
  - **Drag-to-resize**: 12 px strip at the bottom of each chart acts as a drag
    handle; height is committed on drag end; Size slider removed from properties.
  - **Pinch-to-zoom**: `onScaleUpdate` in `TimeSeriesChart` handles multi-finger
    zoom centred on the focal point; single-finger drag still moves the cursor;
    double-tap resets to full view; all charts in a worksheet share one
    `XAxisRange`; zoom-active banner with "Reset zoom" button shown above charts.
- Analyze tab: math channels in charts + chart properties dialog.
  `ChartSlot` gains `mathChannelIds: List<String>`, `yScaleMode: YScaleMode`,
  `yMin: double?`, `yMax: double?`, `heightFactor: double` (0.5–3.0×, default
  1.0), and `channelColors: Map<String, int>` (ARGB ints, JSON-serializable).
  `YScaleMode` enum added to `workspace_provider.dart`.
  `WorkspaceNotifier` gains `addMathChannelToChart`, `removeMathChannelFromChart`,
  `updateChartProperties`. `_ChannelPickerDialog` extended with a "Math Channels"
  section (watches `mathChannelProvider`; section omitted when list is empty).
  `_ChartSlotView` evaluates math channels via `mathChannelEvalProvider` per
  selected session using a `ConsumerWidget` `ref.watch` loop; results combined with
  raw `SessionChannelData`; evaluation errors shown as `_MathErrorOverlay` on the
  chart without blocking raw-channel rendering. `_ChartHeader` (chart type label
  + `Icons.tune` button) added above each chart slot. `_ChartPropertiesDialog`:
  Channels section with per-channel colour swatches (`_ChannelColorRow`) opening
  `_ColorPickerDialog` (8 preset ARGB colours) + remove buttons; Y Axis section
  with `SegmentedButton<YScaleMode>` and optional Min/Max `TextField`s (hidden for
  GPS map); Size section with `Slider` (0.5–3.0×). GPS map colour section keyed by
  session ID (no remove). `TimeSeriesChart` and `FftChart` accept `yMin`/`yMax`
  (wired to `LineChartData.minY`/`maxY`) and `channelColors` (per-channel colour
  overrides). 8 new tests (4 provider, 4 widget).
- Analyze tab: deferred chart types. `FftChart` — one-sided magnitude spectrum
  via Rust `fft()` bridge; Hann/Hamming/Rect window picker; event-driven channel
  guard. `GpsMapChart` — `GPS_Latitude`/`GPS_Longitude` channels rendered as
  per-session `Polyline`s on `google_maps_flutter`; camera fitted to bounding
  box; no-GPS empty state. `LapTable` — per-session lap × sector `DataTable`;
  fastest lap highlighted; "No laps detected" prompt; shown automatically below
  charts. `lapDataProvider` (`FutureProvider.family` keyed by session UUID)
  mirrors `channelDataProvider` pattern. `ChartType` enum added to
  `workspace_provider.dart` (`timeSeries`, `fft`, `gpsMap`); `ChartSlot` gains
  `chartType` field; `addChart([ChartType])` accepts optional type. "Add Chart"
  button replaced with `_AddChartDialog` offering all three types. Google Maps
  API key placeholder added to `AndroidManifest.xml`. 9 new tests (3 provider,
  2 GPS map widget, 3 lap table widget, 3 FFT chart widget).
- Transport: Google Drive sync — sign-in, folder creation, `.idl0`/`.idl0w`
  auto-upload, sync status wired to Runs tab. `DriveService` abstract interface
  + `GoogleDriveService` (`google_sign_in` + `googleapis`). `_AuthenticatedClient`
  injects fresh OAuth headers per upload call. `DriveSyncNotifier` manages
  auth state and per-session `SyncStatus` (moved from `RunsState`).
  `RunsNotifier.importFiles` calls `queueUpload` after every successful import.
  `DriveSyncIndicator` / `SessionList` now read from `driveSyncProvider`.
  Collapsible Google Drive strip added at the top of the Runs tab (sign-in,
  account email, sign-out). `DriveAuthException` and `DriveUploadException`
  added to exception hierarchy (§16). 8 new tests (4 service, 4 provider).
- Transport: Android WiFi network binding (TODO #11) — `WifiNetworkPlugin.kt`
  (`idl0/wifi_network` MethodChannel) uses `WifiNetworkSpecifier` + `NetworkCallback` +
  `bindProcessToNetwork` to bind all process HTTP traffic to the device AP on Android 10+
  (API 29+); no-op on API < 29. `WifiNetworkBinder` Dart wrapper throws
  `DeviceUnreachableException` on timeout or unavailable. `RealWifiService` wraps
  `WifiTransfer` + `WifiNetworkBinder` with bind/release in `try/finally` for
  `getFileList` and `downloadFile`; wired into `wifiServiceProvider` (SSID from
  `deviceProvider.deviceName`). 4 new unit tests. Manual on-device verification required
  on Android 10+ against real device AP.
- Analyze tab: real channel data wiring. `ChartSlot` added to workspace model;
  `Worksheet` gains a stable UUID `id` field. `ChartWorkspace` reads
  `workspaceProvider.activeWorksheet.charts` and loads channel data via
  `channelDataProvider` per selected session — no more `channels: const []`.
  `LinearProgressIndicator` shown while sessions are parsing. Per-chart "Add
  Channel" button opens `_ChannelPickerDialog` (`CheckboxListTile` per available
  channel). `WorkspaceNotifier` gains `addChart`, `addChannelToChart`,
  `removeChannelFromChart`. Cursor provider rekeyed from `int` to `String`
  (worksheet UUID) — fixes latent cross-workbook cursor leak. `TimeSeriesChart`
  converted to `ConsumerStatefulWidget`; cursor `_moveCursor` now converts pixel
  offset to seconds using `GlobalKey` render width. 7 new tests (4 workspace
  provider, 3 chart workspace widget).
- Maths tab (Tab 3): `MathChannel`, `MathConstant`, `MathChannelLibrary` (6
  shipped templates), `MathChannelValidator` (syntax + channel-ref validation),
  `MathChannelRepository` (SQLite, persists across restarts).
  `MathChannelNotifier` (`NotifierProvider`). UI: `ChannelMetadataBar`,
  `ExpressionEditor` (300 ms validation debounce, 500 ms preview debounce,
  operator toolbar, `FunctionHelpPanel`), `InsertPanels` (Channels / Functions
  / Constants; desktop columns, mobile TabBar), `ExpressionPreview` placeholder.
  35 new tests. `flutter test` passes 154/155 (pre-existing DLL failure unchanged).
- Maths tab: `MathChannelEvaluator` — recursive-descent expression interpreter
  supporting arithmetic, comparison and logical operators; `integrate`, `butter`
  (highpass/lowpass), `fft`, `differentiate`, `rms`/`mean`/`std`, `abs`/`sqrt`/
  `pow`/`sign`/`floor`/`ceil`/`round`, trig (`sin`/`cos`/`tan`/`asin`/`acos`/
  `atan`/`atan2`/`sinh`/`cosh`/`tanh`/`deg2rad`/`rad2deg`), `min`/`max`/`clamp`,
  `if`; `DspAdapter` seam for test isolation. `mathChannelEvalProvider` wired
  with auto-invalidation on expression change. `ExpressionPreview` upgraded from
  placeholder to live `fl_chart` preview downsampled to ≤500 points. 18 new
  tests (15 evaluator unit, 3 provider).
- Analyze tab (Tab 4): `WorkbookBar` with workbook dropdown, worksheet `TabBar`, and "+" button; `ChartWorkspace` with `XAxisSelector`, scrollable chart list, and "Add Chart" button; `TimeSeriesChart` with wheel/GPS X axis fallback warnings; `ChartCursor` readout widget showing time and per-channel values at cursor position; `XAxisMode` per-worksheet state persisted in `WorkspaceNotifier`; `cursorProvider.family` keyed by worksheet index for synchronized cross-chart cursors. 17 new tests (8 provider unit, 3 time-series chart, 2 x-axis selector, 4 cursor isolation). `flutter test` passes 118/119 (pre-existing DLL failure excluded).
- Initial Flutter project scaffold
- Processing layer: binary parser (v1 and v2 formats)
- Processing layer: IMU calibration math
- Processing layer: high-pass filter, integration, FFT
- UI: Device tab scaffold — connection panel, config editor (all §8 fields), calibration flow; BLE transport mocked via `MockBleService`; `DeviceNotifier` provider; 7 new tests (5 provider unit, 2 widget)

### Firmware contract
- **P5: SD-card session logger.** Firmware mounts the SD card over SPI and
  exposes its presence in the §7.3 BLE status string. New v2 binary-format
  encoders write the file header, `IMU_SAMPLE`, `GPS_FIX`, `CHANNEL_SAMPLE`,
  and `SESSION_END` records with a CRC-32/ISO-HDLC trailer. An
  `idl0_config.json` loader reads the device config off the SD card. Session
  start/stop now writes a complete `header + SESSION_END` `.idl0` file —
  `IMU_SAMPLE` bodies (P7), `GPS_FIX` bodies + the writer ring buffer (P6),
  and channel-registry population for wheel/analog channels (deferred with
  the ADC work) follow in later plans.
- **v2 binary format: per-sample timestamps.** `IMU_SAMPLE` (§5.5) replaces
  `sample_counter:u32` with `timestamp_us:i64`; `GPS_FIX` (§5.6) replaces
  `sample_counter:u32` with `device_timestamp_us:i64`. The same `esp_timer`
  clock is shared across all IMUs and GPS, so cross-channel sync works
  regardless of per-chip ODR drift, and dropped samples are visible
  app-side as gaps larger than `1 / ODR`. No schema version bump (no v2
  sessions existed on disk). Dart parser updated; storing the timestamps
  for drift compensation is a follow-up.
- **§3.6 device identification.** Locked the derivation from
  `esp_efuse_mac_get_default()`: 16-char hex `device_id` and 4-char SSID /
  BLE-name suffix. Closes TODO #13.
- **§5.1 CRC32 algorithm.** Specified as CRC-32/ISO-HDLC (zlib/PKZIP
  variant). `esp_rom_crc32_le` on the firmware side, `package:crclib`
  `Crc32` on the app side.
- **§5.3 SESSION_END semantics.** Trigger paths and crash-recovery
  behaviour documented.
- **§10.2 session file naming.** Files land at
  `/sessions/tmp_<boot_ms>.idl0` then rename to
  `/sessions/YYYY-MM-DD_HH-MM-SS.idl0` on first GPS fix.
- **Firmware project scaffold.** New `firmware/` directory with ESP-IDF
  5.5 project skeleton (CMakeLists, sdkconfig.defaults, .gitignore;
  pre-existing OTA `partitions.csv` and README preserved unchanged),
  `lsm6dso32x_STdC` driver vendored as a component, bare `app_main` that
  logs a boot line and idles, and module-header stubs declaring the
  public API for the IMU / GPS / SD / BLE / WiFi / session subsystems.
  No flashable behaviour yet — pin assignments and module
  implementations land in subsequent plans. The KiCad netlist export
  is already present at `firmware/hardware/netlist.net`.
- **P3: pinout lock + LED hello-world.** `firmware/main/pins.h`
  populated from `firmware/hardware/netlist.net` — 13 named GPIOs locked
  (LED, SPI bus, three IMU CS, GPS UART, two wheel-speed Halls, two
  pressure ADCs, single `/BUTTONS` net). LED is on GPIO9 (BOOT strap,
  runtime-output-safe), active-high through R1+D1. New `led_status`
  module exposes `off / on / slow-blink / fast-blink` patterns driven
  by a FreeRTOS software timer; `app_main` initialises it to the 1 Hz
  idle pattern. Build verification deferred — `idf.py` is not on the
  current session's PATH and the `esp-idf-eim` MCP is not responding;
  the user will flash and verify manually.
- **P4: BLE control plane.** NimBLE peripheral advertising as `IDL0-XXXX`
  (name derived from the eFuse MAC, §3.6). GATT service `0x00FF` with the
  control characteristic `0xFF03` (write — the five §7.2 command bytes)
  and the status characteristic `0xFF04` (read + notify, §7.3 format).
  `app_main` dispatches commands to a handler that tracks logging state
  and reflects it on the status LED; real command behaviour lands with
  the SD and sensor subsystems. New `device_id` module; NimBLE enabled
  in `sdkconfig.defaults`.

### Firmware
- **Schema v3 — per-channel scale/offset in registry.** Binary file format
  schema bumped 2 → 3. The channel registry entry grew from 32 to 40 bytes
  to carry two new fields: `scale: f32` and `offset: f32`. Files are now
  self-describing for unit conversion — the app applies
  `physical = stored × scale + offset` at parse time with no external config
  dependency.

  IMU axes are now registry-resident. Each enabled axis (derived from the
  channel mask) gets its own entry carrying a name (`IMU0_AccelX`,
  `IMU0_GyroZ`, etc.), units (`g` or `dps`), and a scale factor derived from
  the per-IMU `accel_range_g[3]` / `gyro_range_dps[3]` arrays in
  `idl0_config_t`. Replacing the former scalar fields with per-IMU arrays
  supports mixed-range configurations — e.g. IMU0 at ±32 g while IMU1 runs
  at ±16 g — with no change to the `IMU_SAMPLE` (0x01) wire format (raw
  int16 axes per mask; scaling lives entirely in the registry).

  `idl0_config.json` gains `imu.imu0` / `.imu1` / `.imu2` sub-blocks each
  carrying their own `accel_range_g` and `gyro_range_dps` (§8). Top-level
  scalar values seed all three slots at load time as a back-compat default.

  Session header buffer in `session.c` is now derived from
  `SESSION_REGISTRY_MAX × IDL0_REGISTRY_ENTRY_BYTES` so it auto-grows if
  the registry limit is raised. Host-runnable test in
  `firmware/test/test_idl0_format.c` asserts schema = 3 and the 40-byte
  registry layout.

- **P9: OTA endpoint + manual rollback.** New `ota` module wraps the
  ESP-IDF `esp_ota_*` API as a streaming write session (`idl0_ota_begin`
  / `_write` / `_end`) plus a pending-verify latch and a
  mark-valid helper. `POST /ota` on the existing WiFi AP streams the
  raw `.bin` body in 8 KB chunks through `esp_ota_write`; `esp_ota_end`
  verifies the image's embedded SHA-256 (rejects corrupt uploads with
  HTTP 400) and the device reboots ~500 ms after the 200 response. If
  `Content-Length` is set, a short upload is also rejected (HTTP 400)
  so a truncated stream never reaches validation. `httpd` recv/send
  timeouts raised from the 5 s default to 30 s for ~1.5 MB uploads.
  New BLE command `CMD_OTA_CONFIRM = 0x06` (§7.2) calls
  `esp_ota_mark_app_valid_cancel_rollback`; until it is received, the
  §7.3 status string carries an `OTA: PENDING_VERIFY` line and the
  bootloader rolls back on the next reboot. `app_main` latches the
  pending-verify state at boot via `esp_ota_get_state_partition` —
  intentionally never auto-marking valid. Spec §4.6 / §6.1 `/ota` /
  §7.2 0x06 / §7.3 `OTA:` line updated together; partition-table
  migration (TODO #19) closed.
- **P7: IMU SPI sampling.** Firmware reads IMU0 (LSM6DSO32 on CS=GPIO2) via
  SPI with vendor register-access driver `lsm6dso32x_STdC` (vendored under
  `firmware/components/` pinned to upstream tag **v2.3.0**). New `imu_driver.c`
  module performs WHO_AM_I 0x6C check, configures ODR (104 Hz default; configurable
  up to 1666 Hz via `idl0_config.json`), full-scale (±32 g accel, ±2000 °/s gyro),
  power mode, and continuous FIFO with BDR=ODR. New `imu_task` polls the FIFO every 50 ms via tagged-word reads,
  pairs gyro+accel samples into `IMU_SAMPLE` records (§5.5), assigns per-sample
  `timestamp_us` walking back from the read instant at the configured ODR
  (enables app-side time-sync regardless of ODR drift), and submits one record
  per pair to the writer pipeline. `IMU: OK|PARTIAL|ERROR|ABSENT` line added
  to the §7.3 BLE status string (PARTIAL reserved for multi-IMU future). On-chip
  FIFO overrun flagged via the chip's `fifo_status2_t.fifo_ovr_ia` sticky bit
  but not written to the file (§5.5 — timestamp gaps are visible app-side).
  Multi-IMU (IMU1 on CS=GPIO21 + IMU2 on CS=GPIO22) deferred until a 3-IMU
  harness is available; driver singleton architecture supports the multi-IMU
  path as the only structural change.
- **P8: on-demand WiFi AP + HTTP file server.** Firmware enables `esp_wifi`
  in SoftAP mode via `CMD_WIFI_ON` / `CMD_WIFI_OFF` (control commands §7.2).
  SSID = `IDL0-XXXX` (§3.6 device-specific suffix), password = `datalogger123`
  (§6 shared default), IP = 192.168.4.1. `esp_http_server` exposes four endpoints:
  `GET /files` returns JSON enumeration of session files in `/sdcard/sessions/`;
  `GET /download?file=…` streams chunked 8 KB blocks with HTTP 206 Partial Content
  + Content-Range support for resumable downloads; `GET /delete?file=…` deletes
  files with path-traversal guards (basename only); `POST /config` validates JSON
  syntax and persists the body verbatim to `/sdcard/idl0_config.json` (on-disk bytes
  drive the config CRC32 — no reformatting). Throughput tuning: lwIP TCP send buffer
  + window → 16 KB; WiFi RX buffer count (static) → 16; TX buffers (dynamic) → 32;
  httpd task stack → 8 KB. Brings prototype ~100 KB/s into the 500+ KB/s band on
  the C6 AP. `WiFi: ON|OFF` state in §7.3 BLE status string (retrieved from
  `idl0_wifi_state()`); BLE remains active for simultaneous dual-stack operation
  (single radio with lwIP coexistence time-slicing). App-side `WifiTransfer`
  already targets these endpoints (no app changes in this milestone). OTA endpoint
  (`POST /ota`) and `partitions.csv` dual-OTA migration deferred to P9.
- **P6: GPS UART + writer ring buffer.** New `writer_task` implements a
  single-consumer ring buffer (FreeRTOS NOSPLIT) for SD writes; the logging
  loop appends `GPS_FIX` records to the buffer and returns immediately, allowing
  sensor tasks to continue sampling without blocking on disk I/O. Firmware
  receives NMEA RMC/GGA sentences from the MAX-M10S module (factory defaults:
  9600 baud, 1 Hz, portable mode) via `UART_NUM_1`. NMEA RMC/GGA parser in
  `gps_driver.c` decodes latitude, longitude, fix quality, satellite count,
  and UTC timestamp from RMC and GGA sentences — host-testable, pure C99. `gps_task`
  invokes the parser and emits `GPS_FIX` records (§5.6 timestamp fields) into
  the writer ring buffer. New centralised `status` module consolidates §7.3
  BLE status publishing; all three components (SD, GPS, IMU) push updates
  through a single notifier, preventing status-character thrashing. Session
  files land at `/sessions/tmp_<boot_ms>.idl0` and rename to
  `/sessions/YYYY-MM-DD_HH-MM-SS.idl0` on first GPS fix (§10.2). `GPS:
  FIX|NOFIX|ABSENT` state added to the BLE status character. A 5-second
  lost-lock watchdog transitions the GPS state from FIX to NOFIX when RMC
  silence is sustained.
  - **Hardware note:** ESP→MAX-M10S TX trace is open on the current board
    revision; the module runs at factory defaults (9600 baud / 1 Hz /
    portable). The `gps_sample_rate_hz` config field is pinned to
    `IDL0_GPS_ACTUAL_RATE_HZ = 1` regardless of `idl0_config.json` content.
    UBX-CFG init burst for configurable rate is deferred behind a `TODO(idl0)`
    until the next board revision restores the TX trace.
- Partition table migration to OTA layout
- Unique device ID in SSID and BLE name
- JSON file listing endpoint (`/files`)
- HTTP Range request support for resumable downloads

---

*Releases will be tagged as `vMAJOR.MINOR.PATCH` on the main branch.*
*Firmware releases tagged as `fw-vMAJOR.MINOR.PATCH`.*
