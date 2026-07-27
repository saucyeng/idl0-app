# Attitude Channels + Overlay Visualizations — Design

**Date:** 2026-07-11
**Status:** Approved design, ready for implementation planning
**Scope:** (A) of the four-part decomposition agreed 2026-07-11. (B) steering
angle, (C) geometry-as-configuration, and (D) understeer/oversteer are separate
specs and are **not** designed here.

---

## 1. Goal

Get physically correct **roll and pitch** out of the engine and onto video, and
add two new overlay visualizations — a **rolling suspension spectrogram** and a
**g-g plot** — reusing the estimator and DSP the engine already has.

The trigger: the lean angle in the first real overlay render (2026-07-15
footage) reads near zero through berms, which is where lean is greatest.

---

## 2. Why the current lean angle is wrong

The scratch layout derived lean as `atan2(AccelY, AccelZ)` from the low-passed
accelerometer. An accelerometer measures **specific force** — the resultant of
gravity and cornering acceleration — not gravity. In a coordinated turn the
rider leans precisely so that resultant runs down the bike's own vertical axis;
that is what makes a good berm feel planted. So `atan2(Ay, Az)` reads ≈0°
regardless of actual lean, under-reading hardest exactly where lean is greatest.

This is not a filter-tuning problem. Accelerometer-only lean is structurally
blind to coordinated turns — the same reason an aircraft's turn-and-bank ball
centres in a coordinated turn, and why real AHRS use gyros as the primary
attitude source with accelerometers only for slow levelling.

**The engine already solves this and throws the answer away.** The suspension
IEKF estimates chassis attitude as a first-class state (`R_chassis`, SO(3)):
gyro-propagated, gravity-levelled through a soft constraint that is gated off
when airborne, bias-corrected by zero-angular-rate updates when stationary, and
aided by GPS velocity. Because it carries a velocity state constrained by GPS,
it attributes horizontal acceleration correctly instead of mistaking cornering
force for gravity. But `run()` deliberately discards the per-sample state and
retains only `final_state.r_chassis` — one quaternion at the end of the run —
and nothing anywhere converts a quaternion to Euler angles.

So this design is mostly **output plumbing for an estimator that already
works**, not new estimation.

---

## 3. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Roll means **absolute lean vs gravity** (plane-AHRS convention), not ground-relative | What the IEKF already estimates; well observed and drift-free. Ground-relative needs a surface-normal estimate the sensors observe poorly. |
| D2 | **No traction/friction-demand channel** in this spec | Wanted, but deserves its own design session. |
| D3 | Use the estimator's **hardcoded mount calibration as-is** | Smallest scope. Geometry-as-configuration is needed anyway for (D) understeer, which wants a wheelbase `BikeGeometry` does not have, so it has a natural home there. |
| D4 | Spectrogram and g-g are **video overlay elements**, not Analyze charts | User intent: these are for footage. |
| D5 | Spectrogram shows suspension **velocity** | Damping acts on velocity; conventional view for reading compression/rebound behaviour. |
| D6 | Estimator outputs become **real evaluator functions** | `wheel_travel`/`wheel_velocity` are today Dart-side name sentinels with no evaluator match arm, so workbooks using them render in the app and fail in `idl-rs overlay`. Closing this makes workbooks portable and lets the Dart interception be deleted. |
| D7 | Also emit **gravity-removed vehicle-frame acceleration** | The physically correct friction-circle quantity; a few lines once attitude is out. |
| D8 | Workbook stays at **version 2** | `overlay_layouts` shipped days ago and no real workbook uses it yet — only a scratch file. A bump would protect nobody. |
| D9 | Chart/overlay descriptor convergence is a **follow-up spec** | New elements are shaped to match their Analyze equivalents' option names and data calls so they are pre-shaped for merging, but the unification is designed properly rather than squeezed in here. |
| D10 | **No yaw angle output** | Free gauge at rest, only weakly observed via GPS course — it would be the one untrustworthy number in the set. Yaw *rate* is already available as raw gyro. |

---

## 4. Architecture

Two phases. **Phase 1 is independently shippable and fixes the original
complaint with no overlay work at all**, because the `attitude` overlay element
already exists with a `roll` style and a `range_deg` field — it has been
waiting for a channel to point at. Phase 2 is gated on phase 1 validating.

```
Phase 1 (engine only)
  estimate::run          → StateEstimate gains roll/pitch/accel_long/accel_lat
  math::eval             → attitude(), body_accel(), wheel_travel(), wheel_velocity()
                           run the estimator once, cache into the derived store
  ⇒ roll renders on video from the CLI using the EXISTING attitude element

Phase 2 (overlay only)
  overlay::model         → Spectrogram, GgPlot element variants
  overlay::sample        → prepare-once STFT; per-frame column slice / trail window
  overlay::render        → heatmap painter; friction-circle painter
  app/lib/data/overlay_layout.dart → Dart mirrors
```

---

## 5. Phase 1 — estimator outputs reachable everywhere

### 5.1 New `StateEstimate` fields

Four per-sample vectors alongside the existing four wheel outputs, pushed in
the same forward loop where those are already pushed:

| Field | Type | Units | Meaning |
|---|---|---|---|
| `roll` | `Vec<f64>` | deg | Absolute lean vs gravity. **Positive = leaning right** (right side down). |
| `pitch` | `Vec<f64>` | deg | Absolute pitch vs gravity. **Positive = nose up** (climbing). |
| `accel_long` | `Vec<f64>` | g | Gravity-removed longitudinal acceleration. **Positive = accelerating forward.** |
| `accel_lat` | `Vec<f64>` | g | Gravity-removed lateral acceleration. **Positive = accelerating right.** |

Attitude is extracted from the live `r_chassis` per sample. Signs are defined
by physical meaning above, not by a raw library convention — ISO 8855
(X forward, Y left, Z up) makes a naive Euler extraction give nose-*down*
positive pitch and left-positive lateral, so the implementation negates where
needed to match the table. Tests assert the physical meaning directly from
synthetic attitudes rather than restating the implementation.

**Gravity removal** is done in the **body** frame:

```
a_body = f_body + Rᵀ · g_nav        g_nav = (0, 0, −9.80665) m/s²
```

where `f_body` is the measured specific force. Longitudinal is `a_body.x`,
lateral is `−a_body.y` (negated for right-positive). This formulation is
deliberate: expressing the result in the body frame requires only the **tilt**
part of attitude, which is well observed, and never touches yaw, which is not.
It is the friction-circle quantity without inheriting yaw's uncertainty.

Stationary and upright, both accelerations must read 0.

### 5.2 Estimator-backed evaluator functions

| Function | Returns | Stored channel |
|---|---|---|
| `attitude("roll")` | roll series | `Roll (deg)` |
| `attitude("pitch")` | pitch series | `Pitch (deg)` |
| `body_accel("long")` | longitudinal series | `Longitudinal accel (g)` |
| `body_accel("lat")` | lateral series | `Lateral accel (g)` |
| `wheel_travel("front"\|"rear")` | travel series | `Front travel (mm)` / `Rear travel (mm)` |
| `wheel_velocity("front"\|"rear")` | velocity series | `Front velocity (mm/s)` / `Rear velocity (mm/s)` |

Semantics:

- **One run, cached.** The first call to any of these runs the estimator once
  and writes *all eight* channels into the handle's derived store under the
  names above; subsequent calls are store reads. The store is already
  interior-mutable, so this needs no signature change.
- **Names match what the bridge already stores** for the four wheel channels,
  so the app does not end up with duplicate entries for the same quantity.
- **Geometry** is `BikeGeometry::reference_bike()` and config is
  `EstimatorConfig::default()`, per D3.
- **Failure** is a typed math-eval error naming the missing input (e.g. a
  session with no IMU0 channels), degrading that channel only — consistent with
  the existing rule that a failed math channel never blocks the others.
- An unknown argument (`attitude("yaw")`, `wheel_travel("middle")`) is a
  validation error listing the accepted values.

The four wheel names keep working for existing workbooks, so nothing the user
has authored breaks. The Dart sentinel interception in
`app/lib/data/math_channel.dart` becomes redundant and is removed in the same
change, since the engine now answers for itself in both app and CLI.

### 5.3 What phase 1 delivers on its own

Point the existing `attitude` element at `Roll (deg)` and re-render — correct
lean on video, from the CLI, with no phase-2 work.

---

## 6. Phase 2 — new overlay elements

### 6.1 Spectrogram

```json
{ "type": "spectrogram", "rect": [0.04, 0.86, 0.92, 0.12],
  "channel": "Front velocity (mm/s)",
  "window_s": 6.0, "max_hz": 30.0, "db_floor": -40.0,
  "nperseg": 256, "noverlap": 128, "fft_window": "hann",
  "detrend": "constant", "scaling": "density" }
```

Option names mirror `spectrogram()`'s own parameters (`nperseg`, `noverlap`,
`window`, `detrend`, `scaling`) rather than inventing a parallel vocabulary —
this is the D9 pre-shaping. The one rename is `window` → `fft_window`, because
`window_s` (the displayed time span) already occupies the shorter name and the
two mean entirely different things.

**The critical design point:** the STFT is computed **once** in `prepare()`
over the whole session. Per-frame sampling reduces to selecting the column
index range covering `[t − window_s, t]`. A per-frame FFT across ~6,900 frames
would be brutal; a column slice is nearly free and fits the existing
prepare-once/sample-per-frame architecture exactly.

`ElementSample::Spectrogram { data: Arc<SpectrogramResult>, col_start, col_end }`
— the `Arc` clone per frame is O(1), so the render signature does not change.

Rendering: X is time with "now" at the right edge (matching `trace_strip`), Y
is frequency from 0 to `max_hz`, colour is magnitude in dB clipped at
`db_floor`. Empty/short input renders the no-data state, never fails.

### 6.2 g-g plot

```json
{ "type": "gg_plot", "rect": [0.66, 0.78, 0.30, 0.12],
  "x_channel": "Lateral accel (g)", "y_channel": "Longitudinal accel (g)",
  "range_g": 1.5, "trail_s": 3.0 }
```

Binds two **arbitrary** channels rather than hardcoding the accel axes, so it
can point at the phase-1 channels or at hand-authored ones for comparison.

`ElementSample::Gg { current: Option<(f64, f64)>, trail: Vec<(f64, f64)> }`.
The trail is the trailing `trail_s` of points decimated to the existing
`MAX_TRACE_POINTS` cap.

Rendering: friction-circle rings at 0.5 g intervals out to `range_g`,
cross-hairs through the origin, trail with alpha falling off with age, and a
filled dot at the current value.

### 6.3 Dart mirror

Two new `OverlayElement` subclasses in `app/lib/data/overlay_layout.dart`, with
engine-parity JSON, extending the existing sealed hierarchy. Workbook stays at
v2 (D8). The engine-parity fixture test gains both element kinds.

---

## 7. Validation

Phase 1 is not "done" until roll is shown to be right:

1. **Visual.** Re-render the 2026-07-15 berm footage with `Roll (deg)` on the
   attitude element. Berms must read a large lean (tens of degrees) where the
   old accelerometer channel read ≈0.
2. **Independent physical cross-check.** In steady-turn windows, compare
   estimator roll against `atan(v·ψ̇/g)` computed offline from GPS speed and
   gyro yaw rate. This shares none of the IEKF's machinery, so agreement is
   real evidence rather than a tautology. (It cannot be authored as a math
   channel — there is no `resample`, so a 1 Hz GPS channel and an 833 Hz gyro
   channel cannot be combined in one expression. Offline, in a test or
   throwaway example, is fine.)
3. **Unit tests.** Sign conventions asserted from synthetic attitudes; gravity
   removal reading (0, 0) stationary upright; the estimator running exactly
   once across repeated function calls.

Phase 2 adds golden-image tests for both new elements, following the phase-1
precedent in `core/tests/golden/`.

---

## 8. Non-goals and deferrals

Explicitly **not** in this spec:

- **Traction / friction-demand channel** (D2) — its own design session.
- **Yaw angle** (D10).
- **Geometry as configuration** — wheelbase, head angle, trail as named
  scalars; per-bike profiles; passing geometry through the bridge instead of
  the hardcoded `reference_bike()`. Its own spec, prerequisite for (D).
- **Steering angle** — the `psi`/`dpsi` states exist but are frozen
  (`estimate_steering` defaults false). Scope (B).
- **Understeer/oversteer** — scope (D); needs (B) and the geometry spec.
- **Chart/overlay descriptor convergence** (D9) — the next spec.
- **Device-side calibration revival** — the `imu.orientation` config path is
  inert end to end (firmware handler is a logged no-op, bridge wrappers pruned
  in June, parser never applies bias or rotation). Fixing it would change the
  data every existing workbook sees. Its own project.

## 9. Known risk

The estimator's per-IMU mount quaternions are compile-time constants fitted
from captures on 2026-06-20 and 2026-06-13. If the IMUs have been remounted, or
a session comes from a different bike, roll and pitch will be **silently
wrong** — no error, just bad angles. Accepted for now per D3; the validation in
§7 is what catches it. The geometry spec removes the risk properly.