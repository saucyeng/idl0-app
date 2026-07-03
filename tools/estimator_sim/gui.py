#!/usr/bin/env python3
"""Interactive tuning GUI for the suspension estimator's TRAVEL dynamics, on REAL data.

Replays the 2-state {w, ẇ} travel sub-filter over the *actual* per-sample wheel-drive your
real session produced (exported from the Rust engine via `cargo run --example estimate_trace`),
with live sliders. The grey "engine" line is the full 24-DOF engine's travel (ground truth);
at default sliders the replay matches it to ~0.04 mm, so the travel sub-filter is effectively
decoupled and this 2-state model *is* the engine's travel behaviour.

New in this version:
  * sliders auto-ranged + sensitivity-labelled (a swept ΔRMS span per knob, so dead knobs are
    obvious and live knobs show their leverage),
  * a ±1σ = ±√P_ww confidence BAND around travel — the "predicted confidence matrix", visible:
    it collapses at each topout and balloons between (the forward-filter sawtooth).

Usage:
    cargo run -q --example estimate_trace -- <session.idl0> > tools/estimator_sim/trace.csv
    cd tools/estimator_sim
    python gui.py              # the sliders + confidence band
    python gui.py --check      # headless: replay-vs-engine RMS at defaults (no matplotlib)
    python gui.py --ranges     # headless: print the auto-derived slider ranges + sensitivity
"""
import sys
import os
import numpy as np

DT_FALLBACK = 1.0 / 833.0
TRACE = os.path.join(os.path.dirname(__file__), "trace.csv")

FRONT_TRAVEL_MAX = 0.170
REAR_TRAVEL_MAX = 0.160
FRONT_SAG = 0.27 * FRONT_TRAVEL_MAX
REAR_SAG = 0.27 * REAR_TRAVEL_MAX
AIRBORNE_MAX_GAP_S = 0.10
AIRBORNE_MIN_DURATION_S = 0.05

DEFAULTS = dict(
    sag_sigma=0.5, wheel_vel_rw=5.0, wheel_pos_rw=1.0e-3, zupt_sigma=0.02,
    topout_sigma=0.01, barrier_sigma=0.005, airborne_accel_thresh=2.5,
    airborne_diff_thresh=5.0, init_wheel_travel=0.05, init_wheel_velocity=1.0,
)

# (broad candidate range, log-spaced?) for the sensitivity sweep that auto-ranges the sliders.
SWEEP = dict(
    sag_sigma=(0.05, 5.0, True),
    wheel_vel_rw=(0.2, 50.0, True),
    wheel_pos_rw=(1e-5, 1e-1, True),
    zupt_sigma=(1e-3, 0.5, True),
    topout_sigma=(1e-3, 0.2, True),
    barrier_sigma=(5e-4, 0.1, True),
    airborne_accel_thresh=(0.5, 10.0, False),
    airborne_diff_thresh=(1.0, 30.0, False),
    init_wheel_travel=(1e-3, 0.2, True),
)


def close_short_gaps(flags, max_gap):
    out = list(flags); n = len(out); i = 0
    while i < n:
        if out[i]:
            i += 1; continue
        start = i
        while i < n and not out[i]:
            i += 1
        end = i
        if start > 0 and end < n and (end - start) <= max_gap:
            for k in range(start, end):
                out[k] = True
    return out


def sustained_runs(flags, min_len):
    out = [False] * len(flags); i = 0; n = len(flags)
    while i < n:
        if not flags[i]:
            i += 1; continue
        start = i
        while i < n and flags[i]:
            i += 1
        if i - start >= min_len:
            for k in range(start, i):
                out[k] = True
    return out


def derive_airborne(a0, fd, rd, accel_th, diff_th, dt):
    raw = [(a0[i] < accel_th) and (fd[i] < diff_th) and (rd[i] < diff_th) for i in range(len(a0))]
    return sustained_runs(close_short_gaps(raw, max(1, round(AIRBORNE_MAX_GAP_S / dt))),
                          max(1, round(AIRBORNE_MIN_DURATION_S / dt)))


def run_wheel(drive, airborne, stationary, dt, sag, travel_max, p):
    """2-state {w, ẇ} travel filter over a real drive. Returns (travel[m], P_ww[m²]) per sample."""
    Qpp = p["wheel_pos_rw"] ** 2 * dt
    Qvv = p["wheel_vel_rw"] ** 2 * dt
    Rzupt = p["zupt_sigma"] ** 2
    Rsag = p["sag_sigma"] ** 2
    Rtop = p["topout_sigma"] ** 2
    Rbar = p["barrier_sigma"] ** 2
    w = 0.0; wd = 0.0
    Pww = p["init_wheel_travel"] ** 2; Pwd = 0.0; Pdd = p["init_wheel_velocity"] ** 2
    n = len(drive)
    out = [0.0] * n
    var = [0.0] * n

    for i in range(n):
        # predict
        w = w + dt * wd
        wd = wd + dt * drive[i]
        Pww = Pww + 2.0 * dt * Pwd + dt * dt * Pdd + Qpp
        Pwd = Pwd + dt * Pdd
        Pdd = Pdd + Qvv

        if airborne[i]:
            S = Pww + Rtop; Kw = Pww / S; Kd = Pwd / S; y = -w
            w += Kw * y; wd += Kd * y; t = Pwd; Pww -= Kw * Pww; Pwd -= Kw * t; Pdd -= Kd * t
            S = Pdd + Rzupt; Kw = Pwd / S; Kd = Pdd / S; y = -wd
            w += Kw * y; wd += Kd * y; t = Pdd; Pww -= Kw * Pwd; Pwd -= Kw * t; Pdd -= Kd * t
        elif stationary[i]:
            S = Pdd + Rzupt; Kw = Pwd / S; Kd = Pdd / S; y = -wd
            w += Kw * y; wd += Kd * y; t = Pdd; Pww -= Kw * Pwd; Pwd -= Kw * t; Pdd -= Kd * t
        else:
            S = Pww + Rsag; Kw = Pww / S; Kd = Pwd / S; y = sag - w
            w += Kw * y; wd += Kd * y; t = Pwd; Pww -= Kw * Pww; Pwd -= Kw * t; Pdd -= Kd * t

        if w < 0.0:
            S = Pww + Rbar; Kw = Pww / S; Kd = Pwd / S; y = -w
            w += Kw * y; wd += Kd * y; t = Pwd; Pww -= Kw * Pww; Pwd -= Kw * t; Pdd -= Kd * t
        elif w > travel_max:
            S = Pww + Rbar; Kw = Pww / S; Kd = Pwd / S; y = travel_max - w
            w += Kw * y; wd += Kd * y; t = Pwd; Pww -= Kw * Pww; Pwd -= Kw * t; Pdd -= Kd * t

        out[i] = w
        var[i] = Pww
    return out, var


def load_trace(path):
    data = np.loadtxt(path, delimiter=",", skiprows=1)
    return dict(
        t=data[:, 0],
        front_drive=list(data[:, 1]), rear_drive=list(data[:, 2]),
        a0=list(data[:, 3]), fd=list(data[:, 4]), rd=list(data[:, 5]),
        stationary=[bool(v) for v in data[:, 6]],
        eng_front_mm=data[:, 7], eng_rear_mm=data[:, 8],
    )


def replay(tr, p, dt):
    """Returns front/rear travel (mm), front/rear ±1σ (mm), airborne flags."""
    air = derive_airborne(tr["a0"], tr["fd"], tr["rd"], p["airborne_accel_thresh"], p["airborne_diff_thresh"], dt)
    fw, fv = run_wheel(tr["front_drive"], air, tr["stationary"], dt, FRONT_SAG, FRONT_TRAVEL_MAX, p)
    rw, rv = run_wheel(tr["rear_drive"], air, tr["stationary"], dt, REAR_SAG, REAR_TRAVEL_MAX, p)
    f = np.array(fw) * 1000.0; r = np.array(rw) * 1000.0
    fs = np.sqrt(np.array(fv)) * 1000.0; rs = np.sqrt(np.array(rv)) * 1000.0
    return f, r, fs, rs, air


def rms(a, b):
    return float(np.sqrt(np.mean((np.asarray(a) - np.asarray(b)) ** 2)))


def decimate(tr, k):
    d = {key: (val[::k] if isinstance(val, list) else val[::k]) for key, val in tr.items()}
    return d


def compute_ranges(tr, dt):
    """Sweep each param; set its slider range to where it actually moves travel, and report the
    ΔRMS span (sensitivity, mm). Uses a decimated trace for speed (heuristic ranges)."""
    k = max(1, len(tr["t"]) // 40000)
    td = decimate(tr, k)
    dtd = dt * k
    base_f, base_r, _, _, _ = replay(td, dict(DEFAULTS), dtd)
    base = np.concatenate([base_f, base_r])
    ranges = {}
    for name, (lo, hi, logsp) in SWEEP.items():
        cands = (np.geomspace(lo, hi, 11) if logsp else np.linspace(lo, hi, 11))
        deltas = []
        for c in cands:
            p = dict(DEFAULTS); p[name] = float(c)
            f, r, _, _, _ = replay(td, p, dtd)
            deltas.append(rms(np.concatenate([f, r]), base))
        deltas = np.array(deltas)
        span = float(deltas.max())
        if span < 0.5:  # structurally dead on this session
            ranges[name] = (lo, hi, span, True)
            continue
        active = cands[deltas > 0.05 * span]
        rlo = float(min(active.min(), DEFAULTS[name]))
        rhi = float(max(active.max(), DEFAULTS[name]))
        ranges[name] = (rlo, rhi, span, False)
    return ranges


def main():
    try:  # Windows consoles default to cp1252, which can't encode Δ/σ/√ in our prints.
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    if not os.path.exists(TRACE):
        sys.exit(f"missing {TRACE}\n  run:  cargo run -q --example estimate_trace -- <session.idl0> > {TRACE}")
    tr = load_trace(TRACE)
    dt = float(tr["t"][1] - tr["t"][0]) if len(tr["t"]) > 1 else DT_FALLBACK

    if "--check" in sys.argv:
        f, r, fs, rs, air = replay(tr, dict(DEFAULTS), dt)
        print(f"samples={len(tr['t'])} dt={dt:.6f}s airborne={sum(air)}")
        print(f"FRONT replay-vs-engine RMS = {rms(f, tr['eng_front_mm']):.2f} mm")
        print(f"REAR  replay-vs-engine RMS = {rms(r, tr['eng_rear_mm']):.2f} mm")
        return

    if "--ranges" in sys.argv:
        print("Auto-derived slider ranges + sensitivity (ΔRMS span of travel, mm):")
        for name, (lo, hi, span, dead) in compute_ranges(tr, dt).items():
            tag = "DEAD" if dead else f"Δ{span:5.1f}mm"
            print(f"  {name:22s} [{lo:9.4g} .. {hi:9.4g}]  {tag}")
        return

    import matplotlib.pyplot as plt
    from matplotlib.widgets import Slider, Button

    print("computing slider ranges (one sweep)...", flush=True)
    ranges = compute_ranges(tr, dt)
    p = dict(DEFAULTS)
    t = tr["t"]
    step = max(1, len(t) // 6000)
    ds = slice(None, None, step)
    td = t[ds]

    fig, (axf, axr) = plt.subplots(2, 1, figsize=(13, 9), sharex=True)
    plt.subplots_adjust(left=0.08, right=0.98, top=0.95, bottom=0.42, hspace=0.18)

    f_mm, r_mm, f_s, r_s, air = replay(tr, p, dt)
    state = {"fill_f": None, "fill_r": None}

    def draw_bands():
        if state["fill_f"]:
            state["fill_f"].remove(); state["fill_r"].remove()
        state["fill_f"] = axf.fill_between(td, (f_mm - f_s)[ds], (f_mm + f_s)[ds], color="tab:blue", alpha=0.15, lw=0)
        state["fill_r"] = axr.fill_between(td, (r_mm - r_s)[ds], (r_mm + r_s)[ds], color="tab:green", alpha=0.15, lw=0)

    axf.plot(td, tr["eng_front_mm"][ds], color="0.6", lw=1.0, label="engine (24-DOF)")
    (lf,) = axf.plot(td, f_mm[ds], color="tab:blue", lw=1.2, label="2-state replay")
    axr.plot(td, tr["eng_rear_mm"][ds], color="0.6", lw=1.0, label="engine")
    (lr,) = axr.plot(td, r_mm[ds], color="tab:green", lw=1.2, label="2-state replay")
    draw_bands()
    for ax, mx in ((axf, FRONT_TRAVEL_MAX), (axr, REAR_TRAVEL_MAX)):
        ax.axhline(0, color="0.85", lw=0.8)
        ax.axhline(mx * 1000.0, color="tab:red", lw=0.8, ls="--")
        ax.set_ylabel("travel (mm)  ±1σ band")
        ax.legend(loc="upper right", fontsize=8)
        ax.grid(alpha=0.2)
    axr.set_xlabel("time (s)  —  zoom with the toolbar; shaded band = √P_ww confidence")

    def titles():
        axf.set_title(f"FRONT  ·  replay-vs-engine RMS = {rms(f_mm, tr['eng_front_mm']):.1f} mm  ·  median ±1σ = {np.median(f_s):.1f} mm  ·  airborne {sum(air)} samp", fontsize=10)
        axr.set_title(f"REAR  ·  RMS = {rms(r_mm, tr['eng_rear_mm']):.1f} mm  ·  median ±1σ = {np.median(r_s):.1f} mm", fontsize=10)
    titles()

    order = ["sag_sigma", "wheel_vel_rw", "airborne_accel_thresh", "airborne_diff_thresh",
             "topout_sigma", "zupt_sigma", "barrier_sigma", "wheel_pos_rw", "init_wheel_travel"]
    sliders = {}
    for i, name in enumerate(order):
        lo, hi, span, dead = ranges[name]
        ax = fig.add_axes([0.34, 0.38 - i * 0.036, 0.55, 0.023])
        label = f"{name}  ({'DEAD' if dead else f'Δ{span:.0f}mm'})"
        s = Slider(ax, label, lo, hi, valinit=min(max(p[name], lo), hi))
        sliders[name] = s

    def recompute(_=None):
        nonlocal f_mm, r_mm, f_s, r_s, air
        for name in sliders:
            p[name] = sliders[name].val
        f_mm, r_mm, f_s, r_s, air = replay(tr, p, dt)
        lf.set_ydata(f_mm[ds]); lr.set_ydata(r_mm[ds])
        draw_bands(); titles(); fig.canvas.draw_idle()

    for s in sliders.values():
        s.on_changed(recompute)

    ax_reset = fig.add_axes([0.08, 0.02, 0.1, 0.03])
    btn = Button(ax_reset, "Reset")
    btn.on_clicked(lambda _: [s.reset() for s in sliders.values()])

    plt.show()


if __name__ == "__main__":
    main()
