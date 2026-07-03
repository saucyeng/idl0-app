# estimator_sim — a transparent reference + simulation for the suspension estimator

A runnable Python mirror of the offline IDL0 suspension-kinematics estimator
(`rust/core/src/estimate/`), built so a human can **see, smell, and feel** the
matrices and the linear algebra. The Rust engine is fast but opaque; this tool
makes F, Q, H, R, K and P printable, FD-checkable, and shows the **offline
advantage** a fixed-interval smoother has over the shipped forward-only filter.

It is intentionally NOT wired into the build. It is a desk-side reference: every
matrix here is the same math `idl-rs` ships, cross-checked against finite
difference so "mirror" is a proof, not a claim.

## Quick start

```bash
cd tools/estimator_sim
python -m pip install numpy scipy sympy      # one-time
python demo.py        # the headline: forward filter vs RTS smoother + matrix dump
python models.py      # symbolic F and H (sympy), printed readably
python sim.py         # sanity-check the synthetic ground truth
```

Tested on Python 3.13, numpy 2.4, scipy 1.18, sympy 1.14. MATLAB/Octave-portable
in spirit: pure dense linear algebra, no exotic numpy.

## Interactive tuning GUI on YOUR real data (`gui.py`)

Drag sliders and watch travel respond on a real session — instantly.

```bash
# 1. Export the real per-sample wheel-drive from the Rust engine (once per session):
cd rust
cargo run -q --example estimate_trace -- "C:/path/to/your_session.idl0" > ../tools/estimator_sim/trace.csv
# 2. Launch the GUI (needs matplotlib):
cd ../tools/estimator_sim
python -m pip install matplotlib        # one-time
python gui.py
#    headless faithfulness check (no display): python gui.py --check
```

**How it stays faithful.** The Rust engine does the hard, divergence-prone part —
mounts (incl. the IMU0 X-rear/Y-right yaw), lever transport, the diff-accel — and
`estimate_trace` exports the **exact** per-sample wheel-drive it fed its integrators
(`run_trace` in `estimate/run.rs`). `gui.py` only re-runs the linear 2-state `{w, ẇ}`
travel recursion over that real drive, so the sliders are instant. The grey "engine"
line is the full 24-DOF engine's actual travel, overlaid as ground truth: at default
sliders the replay matches it to **~0.0 mm front / ~0.04 mm rear** — i.e. the travel
sub-filter is effectively decoupled from the rest of the 24-DOF state, so this 2-state
model *is* the engine's travel behaviour, not an approximation. Every slider therefore
shows exactly what the engine would do.

Sliders: `sag_sigma`, `wheel_vel_rw`, `wheel_pos_rw`, `zupt_sigma`, `topout_sigma`,
`barrier_sigma`, `airborne_accel_thresh`, `airborne_diff_thresh`, `init_wheel_travel`.
Use the matplotlib toolbar to zoom (e.g. the 2:48 jump ≈ 168 s). Things to feel:

- **`sag_sigma` and `wheel_vel_rw` are the dominant knobs, and they're the same
  *anchor-strength* axis, inverted.** Lower `sag_sigma` **or** higher `wheel_vel_rw`
  pins travel harder toward the 46 mm sag line (less motion, less drift); higher
  `sag_sigma` **or** lower `wheel_vel_rw` lets it follow the diff-accel (livelier, but
  it drifts). Measured on the reference session: front-travel std over a riding window
  spans ~7 mm (pinned) to ~32 mm (free) across either knob, and `sag_sigma=0.25` ≈
  `wheel_vel_rw=10` to the millimetre. The catch: this axis can't separate *drift* from
  *real motion* — it flattens both — so "looks more stable" means "more pinned to sag,"
  which is the forward-filter ceiling the smoother (M5) is meant to break.
- **`airborne_accel_thresh` / `airborne_diff_thresh` / `topout_sigma`** control the
  jump zeroing — flat during steady riding, dominant at floats. Raise
  `airborne_diff_thresh` → more samples read as airborne and zero to topout.
- Near-dead on this session: `wheel_pos_rw` (negligible by construction),
  `barrier_sigma` (travel never reaches the 170 mm wall here), `init_wheel_travel`
  (only the first ~1 s), `zupt_sigma` (pins `ẇ` near-hard across its whole range).

## The five files and what each one shows

| File | What it shows | Rust it mirrors |
|------|---------------|-----------------|
| `models.py` | The 24-DOF state, boxplus/boxminus on SO(3)⊕ℝⁿ, the process model f(x,u,dt) and its **explicit** analytic F/Q, all measurement factors (residual/H/R), plus **sympy-derived symbolic F and the GravityLeveling H** printed readably. | `estimate/state.rs`, `estimate/process.rs`, `estimate/noise.rs`, `estimate/measurements/*.rs`, `rotation.rs` |
| `ekf.py` | Forward **iterated EKF** on the error state: predict (`P ← FPFᵀ+Q`), Gauss-Newton/MAP update `δ = K(Hδ_i − r)`, Joseph-form covariance, singular-S **and** non-finite-update guards. | `estimate/iekf.rs` |
| `smoother.py` | A fixed-interval **RTS smoother** over the *same* model — the M5 backward/batch pass the Rust engine has **not** built yet. | (none yet — `iekf.rs:3`, `mod.rs:4-5` flag it as M5) |
| `sim.py` | A synthetic **kinematic ground-truth** generator: compression → takeoff → float → landing with KNOWN front/rear travel, producing IMU0/1/2 specific-force + gyro via the **real lever-arm transport** and the **real IMU mounts**. | `estimate/geometry.rs`, `rotation.rs:142-149`, `estimate/run.rs:385-544` |
| `demo.py` | Runs forward + smoother, prints recovered-vs-true travel error, **demonstrates the offline advantage**, and **dumps F/P/H/K/Q/R** at a chosen step. Self-checks every Jacobian vs finite difference first. | `estimate/run.rs:518-646` |

## The headline result (run `python demo.py`)

1. **Jacobian self-check.** Every analytic F/H matches central finite difference
   to ~1e-11 — the same cross-check the Rust tests use
   (`process.rs:337-378`, `measurements/mod.rs:48-71`). This is what makes the
   word "mirror" load-bearing.

2. **Forward vs smoothed travel error.** Case A runs the shipped forward config
   (continuous sag prior on, `run.rs:601`). Case B turns the sag prior **off** to
   expose the raw forward double-integrator drift, leaving only the **sparse
   topout events** (free-fall, travel = 0, `prior.rs:135-157`) + airborne ZUPT to
   anchor travel. The RTS smoother propagates each topout's `d=0` boundary
   *backward* over the inter-topout interval — the boundary-value solve a forward
   filter structurally cannot do — and the **AC shape correlation of recovered
   front travel jumps (~0.42 → ~0.74)** while overall RMS drops ~27%.

   **Honest qualifier on what improves (verified against the run, not asserted):**
   the demonstrated, reproducible offline advantage is **AC-shape / overall-RMS
   recovery**, *not* a reduction in the whole-ride DC mean offset. The smoother
   distributes each future topout backward as a *shape* (trajectory-tilt)
   correction; the whole-ride mean is set by the least-observable
   far-from-anchor segment, so with multiple topouts plus the airborne window the
   global DC offset can actually grow even as RMS falls (Case B prints
   `whole-ride DC: forward ≈ −13 mm → smoothed ≈ −29 mm` right next to
   `RMS −27%`). A controlled single-endpoint double-integrator check
   (`tools/estimator_sim` scratch diagnostics) confirms the smoother is correct —
   smoothed covariance ≤ filtered at every step, last-step smoothed == filtered —
   and that it reduces *both* RMS and DC only when the offset sits near an anchor;
   the multi-event ride is the harder, honest case where only shape/RMS reliably
   improve.

3. **Matrix dump.** F (with the velocity←attitude `−R[a₀−b_a0]×dt` and
   attitude←gyro-bias `−J_r(φ)dt` blocks called out), Q's diagonal, the predicted
   P (note `cond(P) ≈ 9e12` — the `FROZEN_VARIANCE = 1e-12` conditioning floor),
   and a GravityLeveling + TopoutReference update's H, S, R, K so you can see
   exactly which states a gravity nudge or a `d=0` topout corrects.

## Why the smoother is the point (the structural argument)

Travel is a strictly **forward-only double-integrator** driven by diff-accel
(`process.rs:118-122`: `d_f += dd_f·dt; dd_f += wheel_accel_front·dt`). The whole
Rust run is one causal forward pass (`run.rs:518-630`). A forward filter **cannot
let a future topout constrain travel before the event**, so its inter-topout
travel-DC drifts — which is precisely why the shipped code needs the continuous
**sag prior** as an anti-drift crutch (`run.rs:183-195, 601`; design §5).

The design doc already asserts the equivalence this tool exploits:
the Kalman forward sweep + RTS backward sweep **is** the block-tridiagonal
batch-MAP solve, and the iterated smoother **is** Gauss-Newton on the MAP cost
(Bell 1994). A future topout is a hard `d=0` factor that, in a two-sided solve,
distributes its endpoint constraint backward over the interval — exactly the
retro-correction the smoother performs here and the forward pass cannot.

One honest qualifier (matching the adversarial finding): the smoother dissolves
sag's load-bearing role **only on intervals bounded by topout events**. On a
topout-free ride the sag anchor remains the only absolute position information.
So sag is a forward-pass anti-drift stopgap *wherever topout
boundary conditions exist*, demoted by the smoother there, but retained as the
residual continuous-position reference where they do not.

## Conventions (pinned, load-bearing)

Error-state, **right (local) perturbation**, `x_true = x_nom ⊞ δ`, SO(3) block
`R_nom · Exp([δθ]×)`; every analytic Jacobian is `∂r/∂δ` at `δ = 0` under this one
boxplus (`model.rs:1-6`). The 24-DOF error-state layout
`[δθ, δv, δb_g0, δb_a0, δb_g1, δb_g2, δw_f, δẇ_f, δw_r, δẇ_r, δψ, δψ̇]`
matches `state.rs` / `schema.rs` exactly; the column offsets are in
`models.py` (`I_THETA … I_DPSI`, mirroring `measurements/mod.rs:27-42`).

## Faithfulness notes & deliberate deviations

- **R_chassis** is carried as a 3×3 matrix (scipy `Rotation`) rather than a
  quaternion; the boxplus/boxminus and `exp/log_so3` are numerically equivalent
  to the nalgebra `UnitQuaternion` path.
- **GravityLeveling** mirrors the Rust unchecked `normalize()` (`gravity.rs:45`,
  NaN-prone in true free fall) but exposes `well_conditioned()`; the sim runner
  gates the factor off in free fall (the adversarial finding's recommended fix).
  The IEKF update additionally rejects non-finite δ (defense-in-depth the Rust
  `iekf.rs:156-159` lacks — it only guards a singular S).
- **Airborne / stationary** detection in `demo.py` is condensed; the demo feeds
  the *ground-truth* airborne flag so the comparison isolates filter-vs-smoother,
  not the airborne detector. The full two-criteria sustained-free-fall gate lives
  in `run.rs:468-509`.
- **GPS** is omitted (M2a's wheels-first path leaves it empty too, `run.rs:117`).
- The synthetic travel profile is built from C2 quintic envelopes so the travel
  *acceleration* the IMUs measure has no delta-spikes at phase boundaries.

## File-by-file Rust line map

- State / retraction: `rust/core/src/estimate/state.rs:51-91`
- Process predict + analytic F/Q: `rust/core/src/estimate/process.rs:101-185`
- exp/log/skew/J_r/lever-arm: `rust/core/src/rotation.rs:36-149`
- IEKF predict/update/Joseph: `rust/core/src/estimate/iekf.rs:124-182`
- Factors: `rust/core/src/estimate/measurements/{gravity,gps,prior,zupt}.rs`
- Geometry + IMU mounts/levers: `rust/core/src/estimate/geometry.rs:112-171`
- Run orchestration: `rust/core/src/estimate/run.rs:385-646`
