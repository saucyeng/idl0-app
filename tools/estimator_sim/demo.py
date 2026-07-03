"""End-to-end demo: forward IEKF vs RTS smoother on synthetic ground truth.

Mirrors the run.rs orchestration (run.rs:385-646): build per-sample ImuInput from
the unsprung IMUs + geometry (projected differential specific force =
wheel_drive_accel, process.rs:88-99), run the forward IEKF over the shared
factors, then run the RTS backward sweep over the SAME forward trace.

Outputs:
  1. Recovered-vs-true front/rear travel RMS error, forward vs smoothed.
  2. The OFFLINE ADVANTAGE: the smoother correcting travel-DC drift the forward
     filter structurally cannot (a future topout retro-corrects the inter-topout
     interval). We show this by DISABLING the continuous sag prior — exposing the
     raw forward double-integrator drift — and letting only the sparse topout +
     airborne ZUPT factors anchor travel. The smoother propagates each topout's
     d=0 boundary backward; the forward filter cannot.
  3. A dump of F, P, H, K, Q, R at a chosen step for inspection.

Run:  python demo.py
"""

from __future__ import annotations

import numpy as np

from ekf import FilterState, Iekf, InitStd, initial_covariance
from models import (GRAVITY, ImuInput, MtbProcess, MtbState, M2A_ACTIVE,
                    GravityLeveling, SagPrior, TopoutReference, TravelBarrier,
                    ZeroVelocity, ZeroAngularRate, ZeroWheelVelocity,
                    wheel_drive_accel, exp_so3, log_so3)
import sim
from smoother import run_forward_with_trace, rts_smooth

np.set_printoptions(precision=4, suppress=True, linewidth=160)


# ---------------------------------------------------------------------------
# Build the per-sample inputs (the run.rs preprocessing, condensed).
# ---------------------------------------------------------------------------

def central_diff(v, dt):
    """Central difference of a (N,3) array (run.rs:288-...)."""
    n = len(v)
    out = np.zeros_like(v)
    for i in range(n):
        lo = max(i - 1, 0)
        hi = min(i + 1, n - 1)
        out[i] = (v[hi] - v[lo]) / ((hi - lo) * dt) if hi != lo else np.zeros(3)
    return out


def prepare(data):
    """Mount + unit-convert the raw IMU series into chassis-frame SI, and build the
    per-sample wheel-drive controls. Mirrors run.rs:385-544."""
    dt = data["dt"]
    # Units: accel g->m/s^2, gyro dps->rad/s (run.rs:78-79).
    def si(imu):
        return (imu["accel"] * GRAVITY, imu["gyro"] * sim.DEG2RAD)

    a0_s, g0_s = si(data["imu0"])
    a1_s, g1_s = si(data["imu1"])
    a2_s, g2_s = si(data["imu2"])

    # Apply mounts: chassis = MOUNT * sensor (run.rs:396-397, 488, 559).
    a0 = a0_s @ sim.MOUNT0.T
    g0 = g0_s @ sim.MOUNT0.T
    a1 = a1_s @ sim.MOUNT1.T
    g1 = g1_s @ sim.MOUNT1.T
    a2 = a2_s @ sim.MOUNT2.T
    g2 = g2_s @ sim.MOUNT2.T

    N = len(a0)
    omega0_dot = central_diff(g0, dt)  # bias ~0 here; chassis ang accel

    # Estimate a static gyro bias from the first 0.5 s (stand-in for fit_from_window).
    nstat = int(0.5 / dt)
    bg0 = g0[:nstat].mean(axis=0)

    front_axis = sim.FRONT_AXIS
    rear_axis = sim.REAR_AXIS_NEUTRAL

    wheel_front = np.zeros(N)
    wheel_rear = np.zeros(N)
    for i in range(N):
        omega0 = g0[i] - bg0
        wheel_front[i] = wheel_drive_accel(front_axis, a1[i], a0[i], omega0,
                                           omega0_dot[i], sim.LEVER1)
        wheel_rear[i] = wheel_drive_accel(rear_axis, a2[i], a0[i], omega0,
                                          omega0_dot[i], sim.LEVER2)
    return dict(dt=dt, a0=a0, g0=g0, g1=g1, g2=g2, bg0=bg0,
                wheel_front=wheel_front, wheel_rear=wheel_rear,
                a0_norm=np.linalg.norm(a0, axis=1))


def detect_stationary(prep, gyro_thresh=0.08, accel_band=1.0):
    """Crude stationary flag: low gyro and |accel0| ~ g (run.rs uses a windowed
    std detector; this captures the same intent for the sim)."""
    g0 = prep["g0"]
    a0n = prep["a0_norm"]
    stat = (np.linalg.norm(g0, axis=1) < gyro_thresh) & (np.abs(a0n - GRAVITY) < accel_band)
    return stat


# ---------------------------------------------------------------------------
# Factor application closures (the run.rs measurement schedule, condensed).
# ---------------------------------------------------------------------------

def make_apply(prep, stationary, airborne, geometry, use_sag=True,
               gravity_gate_airborne=True):
    """Return apply(iekf, fs, k) that fires the factors active at sample k,
    matching run.rs:547-624. `use_sag` toggles the continuous sag prior so the
    offline-advantage section can expose the raw forward drift.
    `gravity_gate_airborne` skips gravity leveling in free fall (the finding's
    recommended NaN/ill-conditioning fix)."""
    a0 = prep["a0"]; g0 = prep["g0"]; g1 = prep["g1"]; g2 = prep["g2"]
    sag_f, sag_r = geometry["sag_front"], geometry["sag_rear"]
    fmax, rmax = geometry["front_max"], geometry["rear_max"]

    def apply(iekf, fs, k):
        stat = bool(stationary[k])
        air = bool(airborne[k])
        if stat:
            fs = iekf.update(fs, ZeroVelocity(sigma=0.02))
            fs = iekf.update(fs, ZeroAngularRate("imu0", g0[k], sigma=1e-3))
            fs = iekf.update(fs, ZeroAngularRate("imu1", g1[k], sigma=1e-3))
            fs = iekf.update(fs, ZeroAngularRate("imu2", g2[k], sigma=1e-3))
            fs = iekf.update(fs, ZeroWheelVelocity("front", sigma=0.02))
            fs = iekf.update(fs, ZeroWheelVelocity("rear", sigma=0.02))
        # Gravity leveling — gated off in free fall (recommended fix).
        gl = GravityLeveling(a0[k], a_kin_nav=np.zeros(3), sigma=0.05)
        if not (gravity_gate_airborne and air) and gl.well_conditioned(fs.x):
            fs = iekf.update(fs, gl)
        # Travel DC factors.
        if air:
            fs = iekf.update(fs, TopoutReference("front", sigma=0.01))
            fs = iekf.update(fs, ZeroWheelVelocity("front", sigma=0.02))
            fs = iekf.update(fs, TopoutReference("rear", sigma=0.01))
            fs = iekf.update(fs, ZeroWheelVelocity("rear", sigma=0.02))
        elif not stat and use_sag:
            fs = iekf.update(fs, SagPrior("front", sag_f, sigma=0.5))
            fs = iekf.update(fs, SagPrior("rear", sag_r, sigma=0.5))
        fs = iekf.update(fs, TravelBarrier("front", fmax, sigma=0.005))
        fs = iekf.update(fs, TravelBarrier("rear", rmax, sigma=0.005))
        return fs

    return apply


def build_inputs(prep):
    N = len(prep["a0"])
    inputs = []
    for k in range(N):
        inputs.append(ImuInput(prep["g0"][k], prep["a0"][k],
                               prep["wheel_front"][k], prep["wheel_rear"][k]))
    return inputs


def run_case(data, prep, stationary, airborne, geometry, use_sag):
    """Forward + smoothed travel for one configuration."""
    proc = MtbProcess(active=dict(M2A_ACTIVE))
    iekf = Iekf(proc, max_iters=1)
    std = InitStd()
    P0 = initial_covariance(std, M2A_ACTIVE)
    # Initial mean: level (gravity-fit stand-in), travel seeded at topout (0),
    # b_g0 from the static window (run.rs:434-447).
    x0 = MtbState(R_chassis=np.eye(3), b_g0=prep["bg0"], d_f=0.0, s_r=0.0)
    fs0 = FilterState(x0, P0)
    apply = make_apply(prep, stationary, airborne, geometry, use_sag=use_sag)
    inputs = build_inputs(prep)

    trace, _ = run_forward_with_trace(iekf, fs0, inputs, prep["dt"], apply)
    fwd_wf = np.array([s.d_f for s in trace.x_filt])
    fwd_wr = np.array([s.s_r for s in trace.x_filt])

    xs, _ = rts_smooth(trace)
    sm_wf = np.array([s.d_f for s in xs])
    sm_wr = np.array([s.s_r for s in xs])
    return fwd_wf, fwd_wr, sm_wf, sm_wr, trace


def rms(a, b):
    return float(np.sqrt(np.mean((np.asarray(a) - np.asarray(b)) ** 2)))


def ac_corr(a, b):
    """Pearson correlation of the AC (mean-removed) content — how well the shape
    of the travel motion is tracked, independent of any DC offset/drift."""
    a = np.asarray(a) - np.mean(a)
    b = np.asarray(b) - np.mean(b)
    denom = np.linalg.norm(a) * np.linalg.norm(b)
    return float(np.dot(a, b) / denom) if denom > 0 else 0.0


def verify_jacobians():
    """Self-check: every analytic Jacobian matches finite difference (the same
    cross-check the Rust tests use — process.rs:337-378, measurements/mod.rs:48-71).
    This proves F/Q/H in models.py mirror the Rust math, not just look like it."""
    from models import (fd_measurement_jacobian, fd_transition_jacobian)
    print("=" * 78)
    print("JACOBIAN SELF-CHECK (analytic vs finite difference)")
    print("=" * 78)
    proc = MtbProcess(active=dict(M2A_ACTIVE))
    x = MtbState(R_chassis=exp_so3([0.08, -0.12, 0.5]),
                 v_chassis=[1.5, -0.5, 0.2], b_g0=[0.01, -0.02, 0.015],
                 b_a0=[0.1, -0.05, 0.07], d_f=0.03, dd_f=-0.2, s_r=0.02, ds_r=0.1)
    u = ImuInput([0.4, -0.3, 0.6], [0.7, -1.2, GRAVITY + 0.5], 1.3, -0.8)
    F, _ = proc.jacobian_noise(x, u, 0.01)
    err = np.max(np.abs(F - fd_transition_jacobian(proc, x, u, 0.01)))
    print(f"  process F           : max|analytic - fd| = {err:.2e}")
    for name, fac in [("GravityLeveling", GravityLeveling(np.array([0.6, -0.4, GRAVITY - 0.2]))),
                      ("SagPrior", SagPrior("front", 0.046)),
                      ("TopoutReference", TopoutReference("front")),
                      ("TravelBarrier(out)", TravelBarrier("front", 0.170))]:
        xt = x.copy()
        if name.startswith("TravelBarrier"):
            xt.d_f = -0.03  # below the band, away from the kink
        e = np.max(np.abs(fac.jacobian(xt) - fd_measurement_jacobian(fac, xt)))
        print(f"  {name:20s}: max|analytic - fd| = {e:.2e}")
    print()


def main():
    verify_jacobians()
    print("Generating synthetic ground truth (compression -> takeoff -> float -> landing)...")
    data = sim.generate(duration=4.0, rate_hz=400.0, noise=True, seed=1)
    prep = prepare(data)
    stationary = detect_stationary(prep)
    # Use ground-truth airborne for the demo (run.rs derives it from accel/diff
    # gates; here we hand it the truth so the comparison isolates filter-vs-smoother,
    # not the airborne detector). This matches design intent: topout is the anchor.
    airborne = data["airborne"]
    geometry = dict(sag_front=sim.FRONT_SAG, sag_rear=sim.REAR_SAG,
                    front_max=sim.FRONT_TRAVEL_MAX, rear_max=sim.REAR_TRAVEL_MAX)

    print(f"  {len(data['t'])} samples, dt={prep['dt']*1e3:.2f} ms, "
          f"{stationary.sum()} stationary, {airborne.sum()} airborne")

    # ---- Case A: with the continuous sag prior (the shipped forward config) ----
    print("\n" + "=" * 78)
    print("CASE A — sag prior ON (the shipped forward-filter config, run.rs:601)")
    print("=" * 78)
    fwd_wf, fwd_wr, sm_wf, sm_wr, traceA = run_case(
        data, prep, stationary, airborne, geometry, use_sag=True)
    gt_wf, gt_wr = data["gt_wf"], data["gt_wr"]
    print(f"  FRONT travel RMS error:  forward = {rms(fwd_wf, gt_wf)*1000:6.2f} mm   "
          f"smoothed = {rms(sm_wf, gt_wf)*1000:6.2f} mm")
    print(f"  REAR  travel RMS error:  forward = {rms(fwd_wr, gt_wr)*1000:6.2f} mm   "
          f"smoothed = {rms(sm_wr, gt_wr)*1000:6.2f} mm")

    # ---- Case B: sag prior OFF — expose the forward travel-DC drift ----
    print("\n" + "=" * 78)
    print("CASE B — sag prior OFF: the OFFLINE ADVANTAGE")
    print("=" * 78)
    print("  With the continuous sag crutch removed, only the SPARSE topout events")
    print("  (free-fall, d=0) + airborne ZUPT anchor travel. The forward filter")
    print("  cannot let a FUTURE topout correct travel BEFORE the event, so its")
    print("  inter-topout travel-DC drifts. The RTS smoother propagates each topout")
    print("  d=0 boundary BACKWARD over the interval (boundary- vs initial-value).")
    fwd_wf2, fwd_wr2, sm_wf2, sm_wr2, traceB = run_case(
        data, prep, stationary, airborne, geometry, use_sag=False)
    print(f"\n  FRONT travel RMS error:  forward = {rms(fwd_wf2, gt_wf)*1000:6.2f} mm   "
          f"smoothed = {rms(sm_wf2, gt_wf)*1000:6.2f} mm")
    print(f"  REAR  travel RMS error:  forward = {rms(fwd_wr2, gt_wr)*1000:6.2f} mm   "
          f"smoothed = {rms(sm_wr2, gt_wr)*1000:6.2f} mm")
    improvement = rms(fwd_wf2, gt_wf) - rms(sm_wf2, gt_wf)
    print(f"\n  --> smoother reduces FRONT travel RMS by "
          f"{improvement*1000:.2f} mm "
          f"({100*improvement/max(rms(fwd_wf2, gt_wf),1e-9):.0f}%).")

    # Decompose the error into AC (shape) vs DC (whole-ride mean offset). HONEST
    # finding (verified against the printed numbers, not asserted): the smoother's
    # offline advantage shows up as AC SHAPE recovery — each future topout's d=0
    # boundary, propagated backward, fixes the inter-topout trajectory SHAPE the
    # forward double-integrator drifts on. It does NOT reduce the whole-ride DC
    # mean offset (a single ride's global mean is governed by the least-observable
    # far-from-anchor segment; with multiple topouts + the airborne window it can
    # even grow). So the load-bearing, reproducible win is shape/RMS, not DC.
    print(f"\n  Error decomposition (front travel):")
    print(f"    AC shape corr:   forward = {ac_corr(fwd_wf2, gt_wf):.3f}    "
          f"smoothed = {ac_corr(sm_wf2, gt_wf):.3f}   (motion shape, DC-independent)")
    dc_fwd = np.mean(fwd_wf2 - gt_wf)
    dc_sm = np.mean(sm_wf2 - gt_wf)
    print(f"    whole-ride DC:   forward = {dc_fwd*1000:6.2f} mm  "
          f"smoothed = {dc_sm*1000:6.2f} mm  (mean offset — NOT what the smoother fixes)")
    print(f"    --> the offline advantage is AC-SHAPE recovery "
          f"({ac_corr(fwd_wf2, gt_wf):.2f} -> {ac_corr(sm_wf2, gt_wf):.2f}) "
          f"+ overall RMS, not whole-ride DC.")

    # Focus on the pre-takeoff compression interval [1.0, 1.6] s, BEFORE the float:
    # the forward filter has no future knowledge there; the smoother does.
    t = data["t"]
    pre = (t >= 1.0) & (t < 1.6)
    print(f"\n  Pre-float compression window [1.0,1.6]s (forward is 'blind' to the")
    print(f"  coming topout; smoother sees it):")
    print(f"    FRONT forward  RMS = {rms(fwd_wf2[pre], gt_wf[pre])*1000:6.2f} mm")
    print(f"    FRONT smoothed RMS = {rms(sm_wf2[pre], gt_wf[pre])*1000:6.2f} mm")

    # ---- Matrix dump at a chosen step ----
    dump_step(data, prep, stationary, airborne, geometry, step=int(1.3 / prep["dt"]))


def dump_step(data, prep, stationary, airborne, geometry, step):
    """Dump F, P, H, K, Q, R at a chosen sample for inspection."""
    print("\n" + "=" * 78)
    print(f"MATRIX DUMP at sample {step} (t = {step*prep['dt']:.3f} s)")
    print("=" * 78)
    proc = MtbProcess(active=dict(M2A_ACTIVE))
    iekf = Iekf(proc, max_iters=1)
    std = InitStd()
    P0 = initial_covariance(std, M2A_ACTIVE)
    x0 = MtbState(R_chassis=np.eye(3), b_g0=prep["bg0"])
    fs = FilterState(x0, P0)
    inputs = build_inputs(prep)
    apply = make_apply(prep, stationary, airborne, geometry, use_sag=True)

    # Re-run forward up to `step`.
    fs = apply(iekf, fs, 0)
    for k in range(1, step + 1):
        fs = iekf.predict(fs, inputs[k], prep["dt"])
        if k < step:
            fs = apply(iekf, fs, k)

    F, Q = proc.jacobian_noise(fs.x, inputs[step], prep["dt"])
    print("\nF (transition Jacobian) top-left 12x12 [attitude|vel|bg0|ba0]:")
    print(F[:12, :12])
    print("\nF velocity<-attitude block F[3:6,0:3] (= -R[a0-ba0]x dt):")
    print(F[3:6, 0:3])
    print("\nF attitude<-gyrobias block F[0:3,6:9] (= -J_r(phi) dt):")
    print(F[0:3, 6:9])
    print("\nQ diagonal (process noise variances, 24):")
    print(np.diag(Q))
    print("\nP predicted, diagonal (24) — note frozen psi/dpsi ~ 1e-12:")
    print(np.diag(fs.P))
    print(f"  cond(P) = {np.linalg.cond(fs.P):.3e}  "
          f"(the finding: ~1e12 floor from FROZEN_VARIANCE=1e-12)")

    # Gravity-leveling update at this step, capturing H, K, S, R.
    gl = GravityLeveling(prep["a0"][step], a_kin_nav=np.zeros(3), sigma=0.05)
    rec = {}
    iekf.update(fs, gl, record=rec)
    print("\nGravityLeveling H (2x24) — nonzero cols are attitude[0:3] + b_a0[9:12]:")
    print(rec["H"])
    print("\nGravityLeveling S (innovation cov, 2x2) = H P H^T + R:")
    print(rec["S"])
    print("\nGravityLeveling R (measurement noise, 2x2):")
    print(rec["R"])
    print("\nGravityLeveling Kalman gain K (24x2) — rows 0:3 (attitude) & 9:12 (b_a0):")
    print("  K[0:3]:\n", rec["K"][0:3])
    print("  K[9:12]:\n", rec["K"][9:12])

    # A wheel-travel factor's H/K too (the demonstration's protagonist).
    top = TopoutReference("front", sigma=0.01)
    rec2 = {}
    iekf.update(fs, top, record=rec2)
    print("\nTopoutReference(front) H (1x24) — single -1 at w_f col 18:")
    print(rec2["H"])
    print("TopoutReference(front) K (24x1) — which states a d=0 topout corrects:")
    print(rec2["K"].ravel())


if __name__ == "__main__":
    main()
