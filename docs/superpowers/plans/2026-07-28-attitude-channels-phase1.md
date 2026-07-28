# Attitude Channels (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Emit per-sample roll, pitch and gravity-removed body-frame acceleration from the suspension IEKF, and make all estimator outputs reachable as real evaluator functions so they work in the CLI as well as the app.

**Architecture:** The IEKF already estimates chassis attitude (`R_chassis`) every sample and discards it, keeping only `final_state`. This adds four output vectors alongside the existing four wheel outputs, extracts them through a new pure `estimate::attitude` module (so the sign conventions are testable without running a filter), and exposes every estimator output through a new `ChannelLookup::estimator_channel` hook that runs the estimator once per session and caches all eight channels in the derived store.

**Tech Stack:** Rust (`idl-rs` engine, nalgebra), Dart/Flutter (built-in math channel definitions only — no UI work).

**Spec:** `docs/superpowers/specs/2026-07-11-attitude-and-overlay-visualization-design.md` §5. Phase 2 (spectrogram + scatter overlay elements) is **not** in this plan and is gated on the §7 validation in Task 7 passing.

## Global Constraints

- **Repo topology:** engine work happens in the **submodule checkout** `idl0-app\rust` (NOT the sibling `saucyeng\idl-rs` clone). App work in `idl0-app\app`. The submodule pointer bump lands in the final task.
- **NEVER add Co-Authored-By or any AI-attribution trailer to commits.**
- **Never run `cargo fmt`** in the rust repo — it is not rustfmt-formatted (66-file churn incident). Match surrounding style by hand. **Stage files individually** (`git add <file>`), never a directory.
- Frame is **ISO 8855**: X forward, Y left, Z up. Standard gravity is `9.80665` m/s².
- Sign conventions are **physical, not library-native** — roll > 0 is leaning right, pitch > 0 is nose up, lateral > 0 is accelerating right. Tests assert the physical meaning, never restate the implementation.
- All public symbols get doc comments **with units**. Rust functions document which nalgebra/sci-rs call is used and why.
- No bare `// TODO` — use `// TODO(idl0):`.
- `cargo test` green before every rust commit; `flutter test` + `flutter analyze` clean before every app commit.
- Spec disposition: **spec-during** — the math-function table in `docs/IDL0_SPEC.md` and `docs/workbook_format.md` is updated in the final task with the code.

---

### Task 1: Pure attitude + gravity-removal module

**Files:**
- Create: `rust/core/src/estimate/attitude.rs`
- Modify: `rust/core/src/estimate/mod.rs` (add `pub mod attitude;` to the module list, alphabetically — it goes first, before the existing modules)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces:
  - `pub const G_MPS2: f64 = 9.80665;`
  - `pub fn roll_pitch_deg(r_chassis: &UnitQuaternion<f64>) -> (f64, f64)` — returns `(roll_deg, pitch_deg)`
  - `pub fn body_accel_g(f_body: &Vector3<f64>, r_chassis: &UnitQuaternion<f64>) -> (f64, f64)` — returns `(longitudinal_g, lateral_g)`

- [ ] **Step 1: Write the failing tests**

Create `rust/core/src/estimate/attitude.rs` containing ONLY the test module for now (the file will not compile until Step 3 adds the functions — that is the point):

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use nalgebra::{UnitQuaternion, Vector3};

    /// Chassis-frame specific force for a level, stationary bike: the
    /// accelerometer reads +1 g on Z (SPEC §9).
    fn upright_specific_force() -> Vector3<f64> {
        Vector3::new(0.0, 0.0, G_MPS2)
    }

    #[test]
    fn roll_pitch_of_level_attitude_is_zero() {
        // Arrange
        let level = UnitQuaternion::identity();

        // Act
        let (roll, pitch) = roll_pitch_deg(&level);

        // Assert
        assert!(roll.abs() < 1e-9, "roll {roll}");
        assert!(pitch.abs() < 1e-9, "pitch {pitch}");
    }

    #[test]
    fn positive_rotation_about_forward_axis_reads_as_leaning_right() {
        // Arrange — X is forward; by the right-hand rule a positive rotation
        // about it lifts +Y (left) toward +Z (up), i.e. the right side drops.
        let leaned = UnitQuaternion::from_axis_angle(&Vector3::x_axis(), 30f64.to_radians());

        // Act
        let (roll, pitch) = roll_pitch_deg(&leaned);

        // Assert — right side down is reported positive.
        assert!((roll - 30.0).abs() < 1e-6, "roll {roll}");
        assert!(pitch.abs() < 1e-6, "pitch {pitch}");
    }

    #[test]
    fn positive_rotation_about_left_axis_reads_as_nose_down() {
        // Arrange — Y is left; a positive rotation about it tips +X (forward)
        // toward -Z (down). Reported pitch is nose-up-positive, so this is
        // negative.
        let nose_down = UnitQuaternion::from_axis_angle(&Vector3::y_axis(), 10f64.to_radians());

        // Act
        let (_roll, pitch) = roll_pitch_deg(&nose_down);

        // Assert
        assert!((pitch - -10.0).abs() < 1e-6, "pitch {pitch}");
    }

    #[test]
    fn climbing_reads_as_positive_pitch() {
        // Arrange — the opposite sense: nose up 10°.
        let nose_up = UnitQuaternion::from_axis_angle(&Vector3::y_axis(), -10f64.to_radians());

        // Act
        let (_roll, pitch) = roll_pitch_deg(&nose_up);

        // Assert
        assert!((pitch - 10.0).abs() < 1e-6, "pitch {pitch}");
    }

    #[test]
    fn body_accel_of_level_stationary_bike_is_zero() {
        // Arrange
        let level = UnitQuaternion::identity();

        // Act
        let (long, lat) = body_accel_g(&upright_specific_force(), &level);

        // Assert — gravity fully removed.
        assert!(long.abs() < 1e-12, "long {long}");
        assert!(lat.abs() < 1e-12, "lat {lat}");
    }

    #[test]
    fn body_accel_removes_gravity_even_when_leaned() {
        // Arrange — leaned right 30° and stationary. The accelerometer now
        // reads gravity spread across Y and Z, but true acceleration is zero.
        // This is the berm blind spot the whole design exists to fix: a naive
        // atan2(Ay, Az) would report a lean here while reporting none mid-corner.
        let lean = UnitQuaternion::from_axis_angle(&Vector3::x_axis(), 30f64.to_radians());
        let f_body = lean.inverse_transform_vector(&Vector3::new(0.0, 0.0, G_MPS2));

        // Act
        let (long, lat) = body_accel_g(&f_body, &lean);

        // Assert
        assert!(long.abs() < 1e-9, "long {long}");
        assert!(lat.abs() < 1e-9, "lat {lat}");
    }

    #[test]
    fn forward_acceleration_reads_positive_longitudinal() {
        // Arrange — level, accelerating forward at 0.5 g. Specific force is
        // f = a - g, so it carries both the forward term and the +1 g on Z.
        let level = UnitQuaternion::identity();
        let f_body = Vector3::new(0.5 * G_MPS2, 0.0, G_MPS2);

        // Act
        let (long, lat) = body_accel_g(&f_body, &level);

        // Assert
        assert!((long - 0.5).abs() < 1e-12, "long {long}");
        assert!(lat.abs() < 1e-12, "lat {lat}");
    }

    #[test]
    fn rightward_acceleration_reads_positive_lateral() {
        // Arrange — level, accelerating to the RIGHT at 0.3 g. Y is left, so
        // rightward acceleration is -Y in the body frame.
        let level = UnitQuaternion::identity();
        let f_body = Vector3::new(0.0, -0.3 * G_MPS2, G_MPS2);

        // Act
        let (_long, lat) = body_accel_g(&f_body, &level);

        // Assert — reported right-positive.
        assert!((lat - 0.3).abs() < 1e-12, "lat {lat}");
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd rust && cargo test -p idl-rs --lib estimate::attitude`
Expected: compile error — `cannot find function roll_pitch_deg`, `cannot find value G_MPS2`.

- [ ] **Step 3: Write the implementation**

Prepend to `rust/core/src/estimate/attitude.rs`, above the test module:

```rust
//! Attitude and gravity-removed acceleration, read out of the estimator's
//! chassis rotation. Pure — no filter state, no I/O — so the sign conventions
//! are testable against known orientations without running a filter.
//!
//! Frame is ISO 8855 chassis: X forward, Y left, Z up (SPEC §9). `r_chassis`
//! maps chassis → nav. See
//! `docs/superpowers/specs/2026-07-11-attitude-and-overlay-visualization-design.md` §5.1.

use nalgebra::{UnitQuaternion, Vector3};

/// Standard gravity, m/s².
pub const G_MPS2: f64 = 9.80665;

/// Roll and pitch in **degrees** from the chassis attitude.
///
/// - `roll` > 0 ⇒ leaning **right** (right side down)
/// - `pitch` > 0 ⇒ **nose up** (climbing)
///
/// nalgebra's `euler_angles()` decomposes the rotation as roll about X, pitch
/// about Y, yaw about Z. In ISO 8855 (Y left, Z up) a positive rotation about
/// X drops the right side — so roll passes through — while a positive rotation
/// about Y tips the nose *down*, so pitch is negated to report climbing as
/// positive. Yaw is deliberately not returned: it is a free gauge at rest and
/// only weakly observed via GPS course.
pub fn roll_pitch_deg(r_chassis: &UnitQuaternion<f64>) -> (f64, f64) {
    let (roll, pitch, _yaw) = r_chassis.euler_angles();
    (roll.to_degrees(), -pitch.to_degrees())
}

/// Gravity-removed acceleration in the **chassis body frame**, in g.
///
/// Returns `(longitudinal, lateral)`:
/// - `longitudinal` > 0 ⇒ accelerating **forward**
/// - `lateral` > 0 ⇒ accelerating **right**
///
/// `f_body` is the measured specific force in the chassis frame, m/s² (level
/// and stationary it reads `+g` on Z). Since `f = a − g`, the true
/// acceleration is `a_body = f_body + Rᵀ·g_nav` with `g_nav = (0, 0, −G)`;
/// `UnitQuaternion::inverse_transform_vector` applies `Rᵀ`.
///
/// Resolving in the **body** frame is deliberate: it needs only the tilt part
/// of the attitude, which is well observed, and never touches yaw, which is
/// not. Y is left in ISO 8855, so the lateral component is negated to report
/// right-positive.
pub fn body_accel_g(f_body: &Vector3<f64>, r_chassis: &UnitQuaternion<f64>) -> (f64, f64) {
    let g_nav = Vector3::new(0.0, 0.0, -G_MPS2);
    let a_body = f_body + r_chassis.inverse_transform_vector(&g_nav);
    (a_body.x / G_MPS2, -a_body.y / G_MPS2)
}
```

Then in `rust/core/src/estimate/mod.rs`, add to the module declarations (alphabetically first):

```rust
pub mod attitude;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd rust && cargo test -p idl-rs --lib estimate::attitude`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
cd rust
git add core/src/estimate/attitude.rs core/src/estimate/mod.rs
git commit -m "estimate: pure attitude + gravity-removal readout with physical sign conventions"
```

---

### Task 2: `StateEstimate` emits roll, pitch and body acceleration

**Files:**
- Modify: `rust/core/src/estimate/run.rs` — `StateEstimate` struct (~:319-341), the forward-loop push site (~:785-788), and the two `StateEstimate { .. }` construction sites (`run_with_trace` returns it; find them with the grep in Step 3)

**Interfaces:**
- Consumes: `estimate::attitude::{roll_pitch_deg, body_accel_g}` (Task 1).
- Produces: `StateEstimate.roll: Vec<f64>` (deg), `.pitch: Vec<f64>` (deg), `.accel_long: Vec<f64>` (g), `.accel_lat: Vec<f64>` (g) — each the same length as `front_travel`.

- [ ] **Step 1: Write the failing test**

Append to the existing `#[cfg(test)] mod tests` in `rust/core/src/estimate/run.rs`:

```rust
    /// A level, stationary session: `n` samples of pure +1 g on Z and no
    /// rotation. Physically the bike is parked on flat ground.
    fn level_stationary_input(n: usize) -> EstimatorInput {
        EstimatorInput {
            dt: 1.0 / 800.0,
            imu0: ImuSeries {
                gyro: vec![nalgebra::Vector3::zeros(); n],
                accel: vec![nalgebra::Vector3::new(0.0, 0.0, crate::estimate::attitude::G_MPS2); n],
            },
            imu1: None,
            imu2: None,
            gps: Vec::new(),
        }
    }

    #[test]
    fn run_emits_attitude_and_body_accel_for_every_sample() {
        // Arrange
        let input = level_stationary_input(1600);

        // Act
        let est = run(
            &input,
            &crate::estimate::geometry::BikeGeometry::reference_bike(),
            &EstimatorConfig::default(),
        );

        // Assert — one value per sample, matching the wheel outputs.
        assert_eq!(est.roll.len(), est.front_travel.len());
        assert_eq!(est.pitch.len(), est.front_travel.len());
        assert_eq!(est.accel_long.len(), est.front_travel.len());
        assert_eq!(est.accel_lat.len(), est.front_travel.len());
    }

    #[test]
    fn run_on_a_level_parked_bike_reports_no_lean_and_no_acceleration() {
        // Arrange
        let input = level_stationary_input(1600);

        // Act
        let est = run(
            &input,
            &crate::estimate::geometry::BikeGeometry::reference_bike(),
            &EstimatorConfig::default(),
        );

        // Assert — sampled at the end, after the filter has settled. Tolerances
        // are loose enough to survive init transients but tight enough that a
        // sign error or a missing gravity subtraction fails.
        let last = est.roll.len() - 1;
        assert!(est.roll[last].abs() < 1.0, "roll {}", est.roll[last]);
        assert!(est.pitch[last].abs() < 1.0, "pitch {}", est.pitch[last]);
        assert!(est.accel_long[last].abs() < 0.05, "long {}", est.accel_long[last]);
        assert!(est.accel_lat[last].abs() < 0.05, "lat {}", est.accel_lat[last]);
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd rust && cargo test -p idl-rs --lib estimate::run`
Expected: compile error — `no field roll on type StateEstimate`.

- [ ] **Step 3: Add the fields and populate them**

In the `StateEstimate` struct, after `pub rear_velocity: Vec<f64>,`:

```rust
    /// Chassis roll per sample, degrees. Positive ⇒ leaning right.
    pub roll: Vec<f64>,
    /// Chassis pitch per sample, degrees. Positive ⇒ nose up.
    pub pitch: Vec<f64>,
    /// Gravity-removed longitudinal acceleration per sample, g. Positive ⇒
    /// accelerating forward.
    pub accel_long: Vec<f64>,
    /// Gravity-removed lateral acceleration per sample, g. Positive ⇒
    /// accelerating right.
    pub accel_lat: Vec<f64>,
```

Declare the accumulators beside the existing `front_travel` / `rear_travel` ones (find them with `grep -n "let mut front_travel" core/src/estimate/run.rs`):

```rust
    let mut roll = Vec::with_capacity(n);
    let mut pitch = Vec::with_capacity(n);
    let mut accel_long = Vec::with_capacity(n);
    let mut accel_lat = Vec::with_capacity(n);
```

At the forward-loop push site, immediately after `rear_velocity.push(fs.x.ds_r);`:

```rust
        // Attitude and gravity-removed body acceleration, read off the same
        // posterior the wheel outputs come from. `accel0` is the mount-corrected
        // chassis-frame specific force already bound above for `ImuInput`.
        let (roll_deg, pitch_deg) = crate::estimate::attitude::roll_pitch_deg(&fs.x.r_chassis);
        roll.push(roll_deg);
        pitch.push(pitch_deg);
        let (long_g, lat_g) = crate::estimate::attitude::body_accel_g(&accel0, &fs.x.r_chassis);
        accel_long.push(long_g);
        accel_lat.push(lat_g);
```

Then add `roll,`, `pitch,`, `accel_long,`, `accel_lat,` to **every** `StateEstimate { ... }` construction site. Find them all first:

```bash
grep -n "StateEstimate {" core/src/estimate/run.rs
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd rust && cargo test -p idl-rs --lib`
Expected: PASS, all pre-existing tests plus the 2 new ones.

- [ ] **Step 5: Commit**

```bash
cd rust
git add core/src/estimate/run.rs
git commit -m "estimate: emit per-sample roll, pitch and gravity-removed body accel"
```

---

### Task 3: `estimator_channel` lookup hook with run-once caching

**Files:**
- Modify: `rust/core/src/math/eval.rs` — the `ChannelLookup` trait (~:26-35), adding one defaulted method beside `best_time_base_dims`
- Modify: `rust/core/src/session/handle.rs` — the existing `impl crate::math::eval::ChannelLookup for SessionHandle` block, plus a new `impl SessionHandle` helper

**Interfaces:**
- Consumes: `StateEstimate.{roll,pitch,accel_long,accel_lat}` (Task 2).
- Produces:
  - `ChannelLookup::estimator_channel(&self, channel_id: &str) -> Option<LookupChannel>` (default `None`)
  - `SessionHandle::ESTIMATOR_CHANNELS: [&'static str; 8]`

- [ ] **Step 1: Write the failing test**

Append to the existing `#[cfg(test)] mod tests` in `rust/core/src/session/handle.rs`:

```rust
    /// A level, stationary session in `.idl0` channel form: 2 s of IMU0 at
    /// 800 Hz reading +1 g on Z with no rotation.
    fn level_parked_handle() -> SessionHandle {
        let n = 1600;
        let g = crate::estimate::attitude::G_MPS2;
        let zeros = vec![0.0; n];
        SessionHandle::from_channels(
            SessionMetaInput {
                session_id: String::new(),
                device_id: String::new(),
                timestamp_utc_ms: 0,
                config_checksum: String::new(),
            },
            vec![
                input_channel("IMU0_AccelX", 800.0, zeros.clone()),
                input_channel("IMU0_AccelY", 800.0, zeros.clone()),
                input_channel("IMU0_AccelZ", 800.0, vec![g; n]),
                input_channel("IMU0_GyroX", 800.0, zeros.clone()),
                input_channel("IMU0_GyroY", 800.0, zeros.clone()),
                input_channel("IMU0_GyroZ", 800.0, zeros),
            ],
        )
    }

    #[test]
    fn estimator_channel_caches_every_output_on_first_call() {
        // Arrange
        use crate::math::eval::ChannelLookup;
        let h = level_parked_handle();

        // Act — ask for one channel.
        let roll = h.estimator_channel("Roll (deg)");

        // Assert — all eight are now resident, so the run happened once and
        // populated the whole set rather than one channel at a time.
        assert!(roll.is_some(), "roll channel missing");
        for id in SessionHandle::ESTIMATOR_CHANNELS {
            assert!(
                h.channel_meta(id).is_some(),
                "{id} not cached after the estimator ran"
            );
        }
    }

    #[test]
    fn estimator_channel_returns_none_for_a_session_without_imu0() {
        // Arrange
        use crate::math::eval::ChannelLookup;
        let h = handle_with(vec![input_channel("GPS_SpeedKmh", 1.0, vec![0.0; 10])]);

        // Act + Assert — no IMU0 means the estimator cannot run.
        assert!(h.estimator_channel("Roll (deg)").is_none());
    }

    #[test]
    fn estimator_channel_ignores_names_it_does_not_own() {
        // Arrange
        use crate::math::eval::ChannelLookup;
        let h = level_parked_handle();

        // Act + Assert — a base channel is not an estimator output.
        assert!(h.estimator_channel("IMU0_AccelZ").is_none());
    }
```

Note: `input_channel` and `handle_with` are existing helpers in that test module.

- [ ] **Step 2: Run to verify it fails**

Run: `cd rust && cargo test -p idl-rs --lib session::handle`
Expected: compile error — `no method named estimator_channel`, `no associated item ESTIMATOR_CHANNELS`.

- [ ] **Step 3: Add the trait hook**

In `rust/core/src/math/eval.rs`, inside `pub trait ChannelLookup`, after `best_time_base_dims`:

```rust
    /// Resolve a channel produced by the offline suspension/attitude estimator
    /// by its canonical stored name. Implementations that can drive the
    /// estimator run it **once** and cache every output; the rest return
    /// `None`. Default `None` — test doubles and non-session lookups have no
    /// estimator. `SessionHandle` overrides this.
    fn estimator_channel(&self, _channel_id: &str) -> Option<LookupChannel> {
        None
    }
```

- [ ] **Step 4: Implement it on `SessionHandle`**

In `rust/core/src/session/handle.rs`, add to the main `impl SessionHandle` block:

```rust
    /// Canonical stored names of the estimator's outputs. The four wheel names
    /// match what `idl-rs-bridge` already writes, so the app does not end up
    /// with duplicate entries for the same quantity.
    pub const ESTIMATOR_CHANNELS: [&'static str; 8] = [
        "Front travel (mm)",
        "Front velocity (mm/s)",
        "Rear travel (mm)",
        "Rear velocity (mm/s)",
        "Roll (deg)",
        "Pitch (deg)",
        "Longitudinal accel (g)",
        "Lateral accel (g)",
    ];

    /// Run the suspension/attitude estimator once and cache all of
    /// [`Self::ESTIMATOR_CHANNELS`] into the derived store. Returns `false`
    /// when the session cannot drive it (no IMU0).
    ///
    /// Idempotence is by store presence rather than a dedicated flag: a second
    /// call sees `Roll (deg)` already resident and returns immediately. Two
    /// threads racing the first call would both run it and upsert identical
    /// values — wasteful but correct, and evaluation is sequential per session.
    /// Geometry is `reference_bike()` and tuning is `EstimatorConfig::default()`
    /// (design doc D3).
    fn run_estimator_once(&self) -> bool {
        if self.with_channel("Roll (deg)", |_| ()).is_some() {
            return true;
        }
        let Some(input) = crate::estimate::run::EstimatorInput::from_lookup(self) else {
            return false;
        };
        let est = crate::estimate::run::run(
            &input,
            &crate::estimate::geometry::BikeGeometry::reference_bike(),
            &crate::estimate::run::EstimatorConfig::default(),
        );
        let rate_hz = if est.dt > 0.0 { 1.0 / est.dt } else { 0.0 };
        // Travel/velocity cross the boundary in mm and mm/s, matching the
        // bridge's existing conversion; attitude is already deg and body
        // acceleration already g.
        let mm = |v: &Vec<f64>| v.iter().map(|x| x * 1000.0).collect::<Vec<f64>>();
        self.store_math("Front travel (mm)", rate_hz, mm(&est.front_travel));
        self.store_math("Front velocity (mm/s)", rate_hz, mm(&est.front_velocity));
        self.store_math("Rear travel (mm)", rate_hz, mm(&est.rear_travel));
        self.store_math("Rear velocity (mm/s)", rate_hz, mm(&est.rear_velocity));
        self.store_math("Roll (deg)", rate_hz, est.roll);
        self.store_math("Pitch (deg)", rate_hz, est.pitch);
        self.store_math("Longitudinal accel (g)", rate_hz, est.accel_long);
        self.store_math("Lateral accel (g)", rate_hz, est.accel_lat);
        true
    }
```

And in the existing `impl crate::math::eval::ChannelLookup for SessionHandle` block, beside `lookup`:

```rust
    fn estimator_channel(&self, channel_id: &str) -> Option<crate::math::eval::LookupChannel> {
        if !Self::ESTIMATOR_CHANNELS.contains(&channel_id) {
            return None;
        }
        if !self.run_estimator_once() {
            return None;
        }
        self.lookup(channel_id)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd rust && cargo test -p idl-rs --lib`
Expected: PASS, all tests including the 3 new ones.

- [ ] **Step 6: Commit**

```bash
cd rust
git add core/src/math/eval.rs core/src/session/handle.rs
git commit -m "session: estimator-backed channel lookup, run once and cached"
```

---

### Task 4: Evaluator functions `attitude`, `body_accel`, `wheel_travel`, `wheel_velocity`

**Files:**
- Modify: `rust/core/src/math/eval.rs` — one new arm in `call_function` (~:593 onward) and one new helper beside `require_string` (~:486)

**Interfaces:**
- Consumes: `ChannelLookup::estimator_channel` (Task 3).
- Produces: expression functions `attitude("roll"|"pitch")`, `body_accel("long"|"lat")`, `wheel_travel("front"|"rear")`, `wheel_velocity("front"|"rear")`, each returning a channel `Value`.

- [ ] **Step 1: Write the failing tests**

Append to the existing `#[cfg(test)] mod tests` in `rust/core/src/math/eval.rs`:

```rust
    /// A lookup with no estimator — exercises the default trait method.
    struct NoEstimator;
    impl ChannelLookup for NoEstimator {
        fn lookup(&self, _name: &str) -> Option<LookupChannel> {
            None
        }
    }

    /// A lookup that pretends the estimator ran, returning a 1-sample ramp for
    /// any canonical estimator name so the dispatch can be tested without
    /// running a filter.
    struct FakeEstimator;
    impl ChannelLookup for FakeEstimator {
        fn lookup(&self, _name: &str) -> Option<LookupChannel> {
            None
        }
        fn estimator_channel(&self, channel_id: &str) -> Option<LookupChannel> {
            Some(LookupChannel {
                samples: std::sync::Arc::from(vec![channel_id.len() as f64].as_slice()),
                sample_rate_hz: 800.0,
            })
        }
    }

    #[test]
    fn attitude_roll_resolves_through_the_estimator_hook() {
        // Arrange + Act
        let v = call_function(
            "attitude",
            vec![Value::Str("roll".into())],
            &FakeEstimator,
            &MathLapContext::empty(),
        )
        .unwrap();

        // Assert — "Roll (deg)" is 10 chars, so the fake returns [10.0].
        match v {
            Value::Channel(c) => {
                assert_eq!(c.samples.as_ref(), &[10.0]);
                assert_eq!(c.sample_rate_hz, 800.0);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn body_accel_lat_resolves_through_the_estimator_hook() {
        // Arrange + Act
        let v = call_function(
            "body_accel",
            vec![Value::Str("lat".into())],
            &FakeEstimator,
            &MathLapContext::empty(),
        );

        // Assert
        assert!(v.is_ok(), "{v:?}");
    }

    #[test]
    fn wheel_travel_front_resolves_through_the_estimator_hook() {
        // Arrange + Act
        let v = call_function(
            "wheel_travel",
            vec![Value::Str("front".into())],
            &FakeEstimator,
            &MathLapContext::empty(),
        );

        // Assert
        assert!(v.is_ok(), "{v:?}");
    }

    #[test]
    fn unknown_estimator_argument_names_the_accepted_values() {
        // Arrange + Act
        let e = call_function(
            "attitude",
            vec![Value::Str("yaw".into())],
            &FakeEstimator,
            &MathLapContext::empty(),
        )
        .unwrap_err();

        // Assert — yaw is deliberately not emitted, so the error must say so
        // rather than failing obscurely.
        assert!(e.message.contains("roll"), "{}", e.message);
        assert!(e.message.contains("pitch"), "{}", e.message);
    }

    #[test]
    fn estimator_function_without_an_estimator_reports_why() {
        // Arrange + Act
        let e = call_function(
            "attitude",
            vec![Value::Str("roll".into())],
            &NoEstimator,
            &MathLapContext::empty(),
        )
        .unwrap_err();

        // Assert
        assert!(e.message.contains("IMU0"), "{}", e.message);
    }
```

If `Value::Str` is spelled differently in this module, match the existing variant used by `require_string`'s callers (grep `require_string(&args`) and adjust the three call sites above.

- [ ] **Step 2: Run to verify it fails**

Run: `cd rust && cargo test -p idl-rs --lib math::eval`
Expected: FAIL — `attitude` falls through to the unknown-function arm.

- [ ] **Step 3: Add the helper and the dispatch arm**

Beside `require_string` in `rust/core/src/math/eval.rs`:

```rust
/// Map an estimator-backed function call onto its canonical stored channel
/// name. Errors list the accepted arguments so a typo says what to type.
fn estimator_channel_id(name: &str, arg: &str) -> Result<&'static str, MathEvalError> {
    let expected = match name {
        "wheel_travel" | "wheel_velocity" => "\"front\" or \"rear\"",
        "attitude" => "\"roll\" or \"pitch\"",
        _ => "\"long\" or \"lat\"",
    };
    match (name, arg) {
        ("wheel_travel", "front") => Ok("Front travel (mm)"),
        ("wheel_travel", "rear") => Ok("Rear travel (mm)"),
        ("wheel_velocity", "front") => Ok("Front velocity (mm/s)"),
        ("wheel_velocity", "rear") => Ok("Rear velocity (mm/s)"),
        ("attitude", "roll") => Ok("Roll (deg)"),
        ("attitude", "pitch") => Ok("Pitch (deg)"),
        ("body_accel", "long") => Ok("Longitudinal accel (g)"),
        ("body_accel", "lat") => Ok("Lateral accel (g)"),
        _ => Err(err(
            MathEvalErrorKind::Runtime,
            format!("{name}: unknown argument \"{arg}\"; expected {expected}"),
        )),
    }
}
```

In `call_function`, add a new arm (place it after the `"butter"` arm, inside the A6 DSP group):

```rust
        // ---- Estimator-backed virtual sensors ----
        // The offline geometry-constrained estimator (`estimate::run`) is run
        // once per session by the lookup and cached; these are store reads.
        "wheel_travel" | "wheel_velocity" | "attitude" | "body_accel" => {
            require_arg_count(name, &args, 1)?;
            let arg = require_string(&args[0], name)?;
            let channel_id = estimator_channel_id(name, arg)?;
            let ch = lookup.estimator_channel(channel_id).ok_or_else(|| {
                err(
                    MathEvalErrorKind::Runtime,
                    format!(
                        "{name}(\"{arg}\"): the suspension/attitude estimator could not run for \
                         this session — it needs IMU0 accel and gyro channels"
                    ),
                )
            })?;
            Ok(channel(ch.samples.to_vec(), ch.sample_rate_hz))
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd rust && cargo test -p idl-rs --lib`
Expected: PASS, all tests including the 5 new ones.

- [ ] **Step 5: Verify end-to-end against the real session**

```bash
cd rust
cargo build --release -p idl-rs-cli
```

Write a scratch workbook to your scratchpad directory (NOT the repo) at `<scratch>/attitude_probe.idl0wb`:

```json
{
  "workbook_id": "0a1b2c3d-0000-4000-8000-000000000010",
  "name": "Attitude probe",
  "worksheets": [],
  "math_channels": [
    { "id": "roll", "name": "Roll probe", "expression": "attitude(\"roll\")",
      "quantity": "angle", "units": "deg", "sample_rate_hz": 0,
      "decimal_places": 1, "color": "#FF4FC3F7" }
  ],
  "constants": [],
  "created_at_ms": 1784128800000,
  "updated_at_ms": 1784128800000,
  "workbook_version": 2
}
```

Run: `./target/release/idl-rs math "D:/sessions/edb961024527442308548c2096cabe4b.idl0" --workbook <scratch>/attitude_probe.idl0wb --format csv | head -5`
Expected: `ok       Roll probe`, then CSV rows. Values are degrees and must not be all zero — this session contains berms.

- [ ] **Step 6: Commit**

```bash
cd rust
git add core/src/math/eval.rs
git commit -m "math: attitude/body_accel/wheel_travel/wheel_velocity as real evaluator functions"
```

---

### Task 5: Bridge stores the four new channels

**Files:**
- Modify: `rust/bridge/src/session.rs` — the stored-channel block in `estimate_suspension_into_store` (~:686-697)

**Interfaces:**
- Consumes: `StateEstimate.{roll,pitch,accel_long,accel_lat}` (Task 2).
- Produces: `SuspensionEstimateMeta.channel_ids` grows from 4 to 8 entries. **No FRB signature change** — `channel_ids` is already a `Vec<String>`, so no codegen rerun is needed.

- [ ] **Step 1: Add the four stores**

After the existing four `store_math` calls for travel/velocity, add:

```rust
    handle.store_math("Roll (deg)", rate_hz, est.roll.clone());
    handle.store_math("Pitch (deg)", rate_hz, est.pitch.clone());
    handle.store_math("Longitudinal accel (g)", rate_hz, est.accel_long.clone());
    handle.store_math("Lateral accel (g)", rate_hz, est.accel_lat.clone());
```

and extend the `channel_ids` vector in the returned `SuspensionEstimateMeta` with the same four names, in the same order. Use whatever local binding the existing code uses for the sample rate; if it computes the rate inline, mirror that expression exactly rather than introducing a second one.

- [ ] **Step 2: Build and test**

Run: `cd rust && cargo test --workspace 2>&1 | grep -E "test result|^error"`
Expected: all suites `ok`.

- [ ] **Step 3: Commit**

```bash
cd rust
git add bridge/src/session.rs
git commit -m "bridge: store attitude and body-accel channels alongside suspension outputs"
```

---

### Task 6: Dart built-in channels for the new outputs

**Files:**
- Modify: `app/lib/data/math_channel.dart` — the `kBuiltinMathChannels` list (append after `builtin:EstRearVelocity`, ~:227-236) and the validator's allowed-function set (~:416)
- Test: `app/test/data/math_channel_test.dart` (extend if present; otherwise the analyzer + existing suite is the gate)

**Interfaces:**
- Consumes: the evaluator functions from Task 4 (the app evaluates these through `eval_math_into_store`, which reaches the engine).
- Produces: four new built-in `MathChannel`s with ids `builtin:EstRoll`, `builtin:EstPitch`, `builtin:EstAccelLong`, `builtin:EstAccelLat`.

- [ ] **Step 1: Add the built-ins**

Append inside `kBuiltinMathChannels`, after the `builtin:EstRearVelocity` entry:

```dart
  // Attitude and gravity-removed body acceleration — same estimator run as the
  // suspension channels above, surfaced the same way. Unlike `wheel_*`, these
  // expressions evaluate for real in the engine (idl-rs `math::eval`), so they
  // work in the CLI as well as the app.
  MathChannel(
    id: 'builtin:EstRoll',
    name: 'Roll (deg)',
    quantity: 'angle',
    units: 'deg',
    sampleRateHz: 0.0,
    decimalPlaces: 1,
    color: '#FF81C784',
    expression: 'attitude("roll")',
  ),
  MathChannel(
    id: 'builtin:EstPitch',
    name: 'Pitch (deg)',
    quantity: 'angle',
    units: 'deg',
    sampleRateHz: 0.0,
    decimalPlaces: 1,
    color: '#FFAED581',
    expression: 'attitude("pitch")',
  ),
  MathChannel(
    id: 'builtin:EstAccelLong',
    name: 'Longitudinal accel (g)',
    quantity: 'acceleration',
    units: 'g',
    sampleRateHz: 0.0,
    decimalPlaces: 2,
    color: '#FFE57373',
    expression: 'body_accel("long")',
  ),
  MathChannel(
    id: 'builtin:EstAccelLat',
    name: 'Lateral accel (g)',
    quantity: 'acceleration',
    units: 'g',
    sampleRateHz: 0.0,
    decimalPlaces: 2,
    color: '#FFBA68C8',
    expression: 'body_accel("lat")',
  ),
```

- [ ] **Step 2: Allow the new functions in the validator**

In the allowed-function set, replace the `'wheel_travel', 'wheel_velocity',` line and its preceding comment with:

```dart
    // Estimator-backed virtual sensors (offline geometry-constrained
    // estimator). `wheel_*` are still routed by mathChannelEvalProvider;
    // `attitude`/`body_accel` evaluate for real in the engine.
    'wheel_travel', 'wheel_velocity', 'attitude', 'body_accel',
```

- [ ] **Step 3: Run the app gates**

Run: `cd app && flutter test test/data/ && flutter analyze`
Expected: all tests pass; analyzer reports no NEW issues (a pre-existing count of 15 infos is expected).

- [ ] **Step 4: Commit**

```bash
git add app/lib/data/math_channel.dart
git commit -m "app: built-in roll/pitch/body-accel math channels"
```

**Deliberate scope note — read this rather than assuming an omission.** The design doc §5.2 says the Dart sentinel interception in `mathChannelEvalProvider` "is removed in the same change". It is **not** removed here, and that is a deviation recorded on purpose (CLAUDE.md §9 forbids silent ones). Reasons: the interception only recognises `wheel_*`, so the new `attitude`/`body_accel` channels already bypass it and reach the engine; leaving it in place keeps app behaviour byte-identical while the engine path is still unproven; and removing it is provider surgery that serves no phase-1 goal. Task 8 files it as a follow-up.

---

### Task 7: Validate attitude against the real berm footage

**Files:**
- Create: `rust/core/examples/lean_crosscheck.rs`

**Interfaces:**
- Consumes: `attitude("roll")` via the engine (Task 4).
- Produces: nothing consumed by later tasks — this is the spec §7 gate.

This is the task that decides whether phase 2 proceeds. It is not optional.

- [ ] **Step 1: Write the cross-check example**

`rust/core/examples/lean_crosscheck.rs`:

```rust
//! Cross-checks estimator roll against an independent physical estimate.
//!
//! In a steady coordinated turn, lean satisfies `tan φ = v·ψ̇ / g` — speed times
//! yaw rate over gravity. That estimate shares none of the IEKF's machinery
//! (no gyro integration, no gravity levelling, no filter), so agreement is real
//! evidence rather than a tautology.
//!
//!   cargo run -q --release --example lean_crosscheck -- <session.idl0>
//!
//! Prints one row per second of steady turning: t, estimator roll (deg),
//! geometric roll (deg), difference (deg).

use idl_rs::math::eval::ChannelLookup;
use idl_rs::session::handle::SessionHandle;

fn main() {
    let path = std::env::args()
        .nth(1)
        .expect("usage: lean_crosscheck <session.idl0>");
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("read {path}: {e}"));
    let handle = SessionHandle::from_bytes(&bytes).expect("parse .idl0");

    let roll = handle
        .estimator_channel("Roll (deg)")
        .expect("estimator could not run (needs IMU0)");
    let roll_hz = roll.sample_rate_hz;

    let speed_kmh = handle.channel_samples("GPS_SpeedKmh");
    let yaw_dps = handle.channel_samples("IMU0_GyroZ");
    let yaw_hz = handle
        .channel_meta("IMU0_GyroZ")
        .map(|m| m.sample_rate_hz)
        .unwrap_or(0.0);
    if speed_kmh.is_empty() || yaw_dps.is_empty() {
        eprintln!("session lacks GPS_SpeedKmh or IMU0_GyroZ — cannot cross-check");
        return;
    }

    println!("t_s,estimator_roll_deg,geometric_roll_deg,diff_deg");
    // GPS is 1 Hz; step one second at a time and average the faster channels
    // over that second. No `resample` exists in the math language, which is why
    // this lives here rather than in a workbook.
    for (sec, v_kmh) in speed_kmh.iter().enumerate() {
        let v = v_kmh / 3.6;
        if v < 3.0 {
            continue; // too slow for a meaningful coordinated turn
        }
        let mean = |samples: &[f64], hz: f64| -> f64 {
            let a = (sec as f64 * hz) as usize;
            let b = (((sec + 1) as f64) * hz) as usize;
            if hz <= 0.0 || a >= samples.len() {
                return f64::NAN;
            }
            let b = b.min(samples.len());
            samples[a..b].iter().sum::<f64>() / (b - a) as f64
        };
        let yaw_rate = mean(&yaw_dps, yaw_hz).to_radians();
        if yaw_rate.abs() < 0.15 {
            continue; // near-straight: lean is not turn-driven
        }
        let geometric = (v * yaw_rate / 9.80665).atan().to_degrees();
        let est = mean(&roll.samples, roll_hz);
        println!(
            "{sec},{est:.2},{geometric:.2},{:.2}",
            est - geometric
        );
    }
}
```

- [ ] **Step 2: Run it against the matched session**

Run:
```bash
cd rust
cargo run -q --release --example lean_crosscheck -- "D:/sessions/edb961024527442308548c2096cabe4b.idl0"
```
Expected: rows printed for turning seconds. **Acceptance:** the sign of `estimator_roll_deg` matches `geometric_roll_deg` on essentially every row, and typical `diff_deg` is within roughly ±10°. Large or sign-flipped differences mean either a sign bug from Task 1 or stale mount calibration (design doc §9) — stop and report rather than proceeding to Task 8.

- [ ] **Step 3: Re-render the berm footage**

Copy the scratch overlay workbook used previously and point the attitude element at the new channel: set the `attitude` element's `"channel"` to `"Roll (deg)"` and its `"range_deg"` to `45`. Then:

```bash
cd rust
./target/release/idl-rs overlay "D:/sessions/edb961024527442308548c2096cabe4b.idl0" \
  --video "D:/Media/2026/2026-07-15_1121_GoPro_GX010117.MP4" \
  --workbook <scratch>/mtb_overlay.idl0wb \
  --rotate 90 --hwaccel cuda --start 40 --duration 8 \
  --output <scratch>/roll_check.mp4
```

Extract a frame from inside a berm and confirm the indicator shows a large lean where the old accelerometer channel read ≈0:

```bash
ffmpeg -v error -y -i <scratch>/roll_check.mp4 -vf "select=eq(n\,200),crop=2028:620:0:2084,scale=1000:-1" -vframes 1 <scratch>/roll_check.png
```

- [ ] **Step 4: Commit the example**

```bash
cd rust
git add core/examples/lean_crosscheck.rs
git commit -m "estimate: independent lean cross-check example (speed x yaw rate)"
```

---

### Task 8: Docs, submodule pointer, and follow-up entries

**Files:**
- Modify: `docs/IDL0_SPEC.md` (math-function table in §19), `docs/workbook_format.md` (function table ~:580-601), `CHANGELOG.md`, `TASKS.md`, and the `rust` submodule pointer

- [ ] **Step 1: Document the four functions**

In the function table of `docs/workbook_format.md`, add a row:

```markdown
| Estimator      | `attitude("roll"\|"pitch")` → deg; `body_accel("long"\|"lat")` → g; `wheel_travel("front"\|"rear")` → mm; `wheel_velocity("front"\|"rear")` → mm/s. All eight outputs come from one cached run of the offline geometry-constrained estimator. |
```

Mirror the same row into the §19 function table in `docs/IDL0_SPEC.md`. In both places, remove any wording that describes `wheel_travel`/`wheel_velocity` as "not yet a Rust fn" or as Dart-intercepted sentinels — they are real functions now.

- [ ] **Step 2: CHANGELOG entry**

Under `### Added`:

```markdown
- **Attitude channels — roll, pitch and body acceleration (2026-07-28).** The
  suspension IEKF already estimated chassis attitude every sample and discarded
  it; it now emits `roll` and `pitch` (deg, ISO 8855 — positive is leaning right
  and nose up) plus gravity-removed `accel_long`/`accel_lat` (g, resolved in the
  body frame so they need only well-observed tilt and never touch yaw). Fixes
  lean reading ≈0° through berms, where an accelerometer-derived angle is
  structurally blind: in a coordinated turn the resultant force runs down the
  bike's own vertical axis. Estimator outputs are now **real evaluator
  functions** — `attitude()`, `body_accel()`, `wheel_travel()`,
  `wheel_velocity()` — resolved through a new `ChannelLookup::estimator_channel`
  hook that runs the estimator once per session and caches all eight channels,
  so they work in `idl-rs` CLI renders as well as the app. **Spec disposition:**
  spec-during — §19 function table; design doc
  `docs/superpowers/specs/2026-07-11-attitude-and-overlay-visualization-design.md`.
```

- [ ] **Step 3: TASKS entries**

Tick the phase-1 entry as complete with a one-line result, and add two follow-ups under Active:

```markdown
- [ ] **Remove the Dart `wheel_*` sentinel interception (2026-07-28)** — the
      engine now implements `wheel_travel`/`wheel_velocity` for real, so
      `mathChannelEvalProvider`'s name-based routing to
      `estimate_suspension_into_store` is redundant. Deferred out of the
      attitude phase-1 change deliberately (it is provider surgery serving no
      phase-1 goal). Removing it makes app and CLI share one path.
- [ ] **Estimator config diverges between app and CLI (2026-07-28)** — the
      bridge runs the estimator with the user's `SuspensionConfig`, while the
      evaluator functions use `EstimatorConfig::default()`. A tuned session can
      therefore give different numbers in the app than in a CLI render. Decide
      whether the evaluator should read tuning from the workbook.
```

- [ ] **Step 4: Commit docs, then bump the submodule pointer**

```bash
cd /c/Users/isaac/Documents/Saucy/saucyeng/idl0-app
git add docs/IDL0_SPEC.md docs/workbook_format.md CHANGELOG.md TASKS.md
git commit -m "Docs: attitude channels + estimator evaluator functions (spec-during 19)"
git add rust
git commit -m "rust: bump submodule to attitude channels phase 1"
```

Then push both repos (engine first, so the submodule pointer resolves):

```bash
cd rust && git push origin main
cd .. && git push origin main
```

---

## Self-review checklist (ran at plan time)

- **Spec coverage:** §5.1 four outputs → Tasks 1-2; §5.1 body-frame gravity removal and its yaw-avoidance rationale → Task 1; §5.2 four functions, run-once caching, canonical names matching the bridge, typed failure, unknown-argument validation → Tasks 3-4; §5.2 sentinel removal → **deliberately deferred, recorded in Task 6 and filed in Task 8**; §5.3 render from CLI → Task 7 Step 3; §7 all three validation legs (visual, independent cross-check, unit tests) → Tasks 1-4 and 7; §9 stale-mount risk → Task 7 Step 2 acceptance criterion. Phase 2 (§6) is out of scope by design and gated on Task 7.
- **Placeholder scan:** no TBDs. Two steps say "find them with this grep" (Task 2 Step 3 construction sites, Task 5 Step 1 rate binding) — those are exact commands against code whose line numbers drift, not deferred decisions.
- **Type consistency:** `roll`/`pitch`/`accel_long`/`accel_lat` are the field names in Task 2, read under those names in Tasks 3 and 5. The eight canonical channel strings are defined once in `ESTIMATOR_CHANNELS` (Task 3) and reproduced identically in `estimator_channel_id` (Task 4), the bridge (Task 5), and the Dart built-ins (Task 6) — a mismatch in any one produces a silently absent channel, so they are worth diffing before commit. `roll_pitch_deg` and `body_accel_g` keep their Task 1 signatures at both call sites.
- **Known risk carried from the design:** mount quaternions are compile-time constants fitted in June 2026. Task 7 Step 2 is the check that catches a stale mount, and it gates Task 8.