"""Synthetic kinematic GROUND-TRUTH generator for the suspension estimator.

Produces a bike doing  compression -> takeoff -> float -> landing  with KNOWN
front/rear travel w_f(t), w_r(t), and synthesizes the three IMUs' specific-force
+ gyro using the REAL lever-arm transport (rotation.rs:142-149) and the REAL IMU
mounts from BikeGeometry::reference_bike() (geometry.rs:112-171):
   IMU0 mounted X-rear / Y-right  -> 180deg yaw from the ISO chassis frame
   IMU1 (fork lower)  sensor +X -> chassis +Z (up)   [matrix at geometry.rs:136]
   IMU2 (seatstay)    sensor +Y -> chassis +Z (up)   [matrix at geometry.rs:139]

Frames (ISO 8855 chassis frame, geometry.rs:1-3): X=forward, Y=left, Z=up.

Generation model (kinematics only — pure data-in/data-out, no filter):
  - The chassis (sprung mass / IMU0 body) has a known attitude trajectory R(t)
    (a pitch wobble + a yaw) and a known nav-frame acceleration a_chassis(t).
  - The two unsprung masses (front/rear axles) move along their travel axes
    relative to the chassis by w_f(t), w_r(t); we differentiate twice to get the
    relative axle acceleration, transport it through the lever arm + chassis
    rotation, and add it to the chassis acceleration at the unsprung IMU.
  - Each IMU's SPECIFIC FORCE in nav = a_imu_nav - g_nav (g_nav = (0,0,-g)); we
    rotate into the IMU body frame (chassis attitude, then inverse mount) to get
    what the sensor would actually read. accel is returned in g, gyro in dps —
    exactly the units imu_series_from_lookup expects (run.rs:67-79).

The wheel-drive control the estimator integrates is the projected differential
specific force; by transporting the SAME lever arm here that wheel_drive_accel
subtracts there, a correct estimator recovers w_f/w_r up to the DC drift the
forward filter cannot bound (which is the whole demonstration).
"""

from __future__ import annotations

import numpy as np

from models import GRAVITY, exp_so3, lever_arm_accel

DEG2RAD = np.pi / 180.0
RAD2DEG = 180.0 / np.pi

# --- Reference-bike geometry (geometry.rs:112-171) -------------------------

# Head angle 63.5deg -> 26.5deg off vertical; front/steer tangent points up+rear.
_OFF_VERT = np.deg2rad(90.0 - 63.5)
FRONT_AXIS = np.array([-np.sin(_OFF_VERT), 0.0, np.cos(_OFF_VERT)])  # unit, chassis frame
REAR_AXIS_NEUTRAL = np.array([-0.008, 0.0, 0.040])
REAR_AXIS_NEUTRAL = REAR_AXIS_NEUTRAL / np.linalg.norm(REAR_AXIS_NEUTRAL)  # ~vertical, rear lean

FRONT_TRAVEL_MAX = 0.170
REAR_TRAVEL_MAX = 0.160
FRONT_SAG = 0.27 * FRONT_TRAVEL_MAX   # 0.0459 m
REAR_SAG = 0.27 * REAR_TRAVEL_MAX     # 0.0432 m

# IMU0 mount: 180deg yaw about Z (sensor X-rear/Y-right -> ISO X-fwd/Y-left).
# chassis = mount * sensor, so mount maps sensor->chassis. geometry.rs:159-162.
MOUNT0 = exp_so3([0.0, 0.0, np.pi])
# IMU1 / IMU2 coarse mounts (geometry.rs:135-140), as chassis = R * sensor.
MOUNT1 = np.array([[0.0, 1.0, 0.0], [0.0, 0.0, 1.0], [1.0, 0.0, 0.0]])
MOUNT2 = np.array([[-1.0, 0.0, 0.0], [0.0, 0.0, 1.0], [0.0, 1.0, 0.0]])
# Lever arms from IMU0, chassis frame (geometry.rs:168-169).
LEVER1 = np.array([0.835, 0.0, -0.4])
LEVER2 = np.array([-0.445, 0.0, -0.4])

G_NAV = np.array([0.0, 0.0, -GRAVITY])


def _smoothstep(t, t0, t1):
    """C2 quintic smootherstep 0->1 ramp on [t0, t1]. The quintic (not the cubic)
    is used so the SECOND derivative is continuous at the endpoints — otherwise
    the synthetic travel acceleration (which the IMUs measure) would have step
    discontinuities at every phase boundary, injecting delta-spikes into the
    diff-accel control."""
    if t <= t0:
        return 0.0
    if t >= t1:
        return 1.0
    u = (t - t0) / (t1 - t0)
    return u * u * u * (u * (u * 6 - 15) + 10)


def _bump(t, t0, t1, t2):
    """A C2 0->1->0 pulse: ramps up on [t0,t1], down on [t1,t2]. Peak 1 at t1."""
    return _smoothstep(t, t0, t1) * (1.0 - _smoothstep(t, t1, t2))


def _window(t, t0, t1, t2, t3):
    """A C2 flat-top trapezoid: ramps 0->1 on [t0,t1], holds 1 on [t1,t2], ramps
    1->0 on [t2,t3]. Used for the float plateau (travel held at 0)."""
    return _smoothstep(t, t0, t1) * (1.0 - _smoothstep(t, t2, t3))


def travel_profile(t):
    """KNOWN front/rear travel (m) over the maneuver.

    Phases (t in seconds):
      0.0-1.0 : settle at sag (rider on, motionless-ish)
      1.0-1.6 : COMPRESSION  — preload/pump, travel dives toward ~0.75*max
      1.6-1.8 : TAKEOFF      — explosive extension, travel shoots toward topout
      1.8-2.6 : FLOAT (air)  — topped out, travel = 0
      2.6-3.4 : LANDING      — big compression spike to ~0.9*max, then rebound
      3.4-4.0 : settle back toward sag
    The profile is built ADDITIVELY from C2 envelopes so travel is C2-continuous
    everywhere (bounded acceleration -> no delta-spikes in the IMU diff-accel):
        travel = sag * weighted(t) + compression_bump - takeoff_dip + landing_bump
    where `weighted` is a sag-presence envelope driven to 0 during the float (the
    wheel tops out), so the float correctly sits at travel = 0.
    Returns (w_f, w_r)."""
    # Sag-presence envelope: 1 on the ground, 0 across the FLAT float plateau
    # [1.9, 2.5] (wheel topped out), ramping out on takeoff and back on landing.
    on_ground = (1.0 - _window(t, 1.65, 1.9, 2.5, 2.62))

    # Compression dip toward 0.75*max, centered 1.3 (rider preload/pump).
    comp = _bump(t, 1.0, 1.3, 1.6)
    # Landing compression spike toward 0.9*max, centered ~2.9, rebound to sag.
    land = _bump(t, 2.62, 2.9, 3.4)

    wf = FRONT_SAG * on_ground \
        + comp * (0.75 * FRONT_TRAVEL_MAX - FRONT_SAG) \
        + land * (0.90 * FRONT_TRAVEL_MAX - FRONT_SAG)
    wr = REAR_SAG * on_ground \
        + comp * (0.75 * REAR_TRAVEL_MAX - REAR_SAG) \
        + land * (0.90 * REAR_TRAVEL_MAX - REAR_SAG)
    return max(wf, 0.0), max(wr, 0.0)


def chassis_attitude(t):
    """KNOWN chassis attitude R(t) (sensor/vehicle->nav), a pitch wobble + slow yaw.
    During the float we add a nose-up pitch (typical jump)."""
    pitch = 0.10 * np.sin(2 * np.pi * 0.5 * t)           # +/-0.1 rad wobble
    pitch += 0.15 * _window(t, 1.9, 2.1, 2.5, 2.6)       # nose-up in the air
    yaw = 0.05 * t                                        # slow drift
    return exp_so3([0.0, pitch, yaw])


def chassis_accel_nav(t):
    """KNOWN chassis nav-frame acceleration a_chassis(t) (m/s^2).

    On the ground the bike is roughly grounded (small accelerations); during the
    float the WHOLE bike is in free fall, so a_chassis_nav = g_nav (specific force
    -> ~0). Landing has a big upward deceleration spike."""
    a = np.zeros(3)
    # Ground micro-accelerations (terrain): small forward + vertical jitter.
    a[0] = 0.3 * np.sin(2 * np.pi * 0.7 * t)
    a[2] = 0.4 * np.sin(2 * np.pi * 1.1 * t)
    # Free fall during float: chassis accelerates downward at g (specific force 0).
    air = _window(t, 1.85, 1.95, 2.5, 2.58)
    a = (1 - air) * a + air * G_NAV
    # Landing impact spike (~2.62): strong upward decel as the wheel loads.
    spike = np.exp(-((t - 2.62) / 0.04) ** 2)
    a[2] += spike * 45.0
    a[0] += spike * 8.0
    return a


def _deriv2(f, t, dt=1e-3):
    """Numeric 1st and 2nd time derivative of a vector/scalar function f(t)."""
    fp = (f(t + dt) - f(t - dt)) / (2 * dt)
    fpp = (f(t + dt) - 2 * f(t) + f(t - dt)) / (dt * dt)
    return fp, fpp


def _omega_from_R(t, dt=1e-3):
    """Chassis angular velocity (rad/s) and angular accel (rad/s^2) in the BODY
    (chassis) frame, from finite-differencing R(t). omega_body from
    log(R(t)^T R(t+dt))/dt."""
    R = chassis_attitude(t)
    Rp = chassis_attitude(t + dt)
    Rm = chassis_attitude(t - dt)
    from models import log_so3
    w = log_so3(R.T @ Rp) / dt
    w_m = log_so3(Rm.T @ R) / dt
    w_dot = (w - w_m) / dt
    return w, w_dot


def generate(duration=4.0, rate_hz=400.0, noise=True, seed=0):
    """Generate the synthetic dataset.

    Returns a dict with:
      t           : (N,) time, s
      dt          : float
      gt_wf,gt_wr : (N,) ground-truth front/rear travel, m
      imu0/1/2    : dict(accel=(N,3) in g, gyro=(N,3) in dps) — sensor body frame,
                    matching the .idl0 channel units (run.rs:67-79)
      airborne    : (N,) bool ground-truth free-fall flag
      R_chassis   : list of (3,3) ground-truth attitude
    """
    rng = np.random.default_rng(seed)
    dt = 1.0 / rate_hz
    N = int(round(duration * rate_hz))
    t = np.arange(N) * dt

    gt_wf = np.zeros(N)
    gt_wr = np.zeros(N)
    airborne = np.zeros(N, bool)

    imu = {0: {"accel": np.zeros((N, 3)), "gyro": np.zeros((N, 3))},
           1: {"accel": np.zeros((N, 3)), "gyro": np.zeros((N, 3))},
           2: {"accel": np.zeros((N, 3)), "gyro": np.zeros((N, 3))}}
    R_list = []

    for i in range(N):
        ti = t[i]
        R = chassis_attitude(ti)
        R_list.append(R)
        wf, wr = travel_profile(ti)
        gt_wf[i] = wf
        gt_wr[i] = wr
        airborne[i] = 1.95 <= ti < 2.5  # the flat free-fall / topout plateau

        a_chassis = chassis_accel_nav(ti)
        omega, omega_dot = _omega_from_R(ti)

        # --- IMU0 (chassis) ---------------------------------------------------
        # Specific force at IMU0 (origin, no lever): a_chassis - g, in nav.
        sf0_nav = a_chassis - G_NAV
        sf0_chassis = R.T @ sf0_nav                 # rotate nav -> chassis/vehicle frame
        sf0_sensor = MOUNT0.T @ sf0_chassis         # chassis -> IMU0 sensor body
        gyro0_chassis = omega                       # chassis angular rate
        gyro0_sensor = MOUNT0.T @ gyro0_chassis

        # --- Unsprung relative axle motion -----------------------------------
        # Front axle relative accel along FRONT_AXIS (chassis frame): d2/dt2 w_f.
        wf_pp = _deriv2(lambda tt: travel_profile(tt)[0], ti)[1]
        wr_pp = _deriv2(lambda tt: travel_profile(tt)[1], ti)[1]
        rel_acc_front_chassis = FRONT_AXIS * wf_pp  # axle moves along tangent
        rel_acc_rear_chassis = REAR_AXIS_NEUTRAL * wr_pp

        # Rigid-body transport of the chassis-frame specific force to the unsprung
        # lever, PLUS the relative axle acceleration. lever_arm_accel gives the
        # rotational transport (omega_dot x L + omega x (omega x L)); the chassis
        # specific force is common; the relative travel accel is added in chassis
        # frame. (rotation.rs:142-149 + the diff-accel control in process.rs:88-99.)
        sf1_chassis = (lever_arm_accel(sf0_chassis, omega, omega_dot, LEVER1)
                       + rel_acc_front_chassis)
        sf2_chassis = (lever_arm_accel(sf0_chassis, omega, omega_dot, LEVER2)
                       + rel_acc_rear_chassis)
        # Unsprung IMUs share the chassis angular rate (axle is roughly rigid w.r.t.
        # the chassis over the small-travel kinematics for M2a's purposes).
        sf1_sensor = MOUNT1.T @ sf1_chassis
        sf2_sensor = MOUNT2.T @ sf2_chassis
        gyro1_sensor = MOUNT1.T @ omega
        gyro2_sensor = MOUNT2.T @ omega

        # --- store in g / dps, with optional MEMS noise ----------------------
        def store(imu_idx, accel_sensor, gyro_sensor):
            a_g = accel_sensor / GRAVITY
            g_dps = gyro_sensor * RAD2DEG
            if noise:
                a_g = a_g + rng.normal(0, 0.01, 3)     # ~0.1 m/s^2
                g_dps = g_dps + rng.normal(0, 0.1, 3)  # ~0.1 dps
            imu[imu_idx]["accel"][i] = a_g
            imu[imu_idx]["gyro"][i] = g_dps

        store(0, sf0_sensor, gyro0_sensor)
        store(1, sf1_sensor, gyro1_sensor)
        store(2, sf2_sensor, gyro2_sensor)

    return dict(t=t, dt=dt, gt_wf=gt_wf, gt_wr=gt_wr, airborne=airborne,
                R_chassis=R_list,
                imu0=imu[0], imu1=imu[1], imu2=imu[2])


if __name__ == "__main__":
    data = generate(noise=False)
    print(f"generated {len(data['t'])} samples at dt={data['dt']*1e3:.2f} ms")
    print(f"front travel: min={data['gt_wf'].min()*1000:.1f} mm  "
          f"max={data['gt_wf'].max()*1000:.1f} mm")
    print(f"rear  travel: min={data['gt_wr'].min()*1000:.1f} mm  "
          f"max={data['gt_wr'].max()*1000:.1f} mm")
    print(f"airborne samples: {data['airborne'].sum()} "
          f"({100*data['airborne'].mean():.0f}%)")
    # Sanity: during float IMU0 should read ~0 specific force (free fall).
    air_idx = np.where(data['airborne'])[0]
    mid = air_idx[len(air_idx)//2]
    print(f"IMU0 |accel| at mid-float = "
          f"{np.linalg.norm(data['imu0']['accel'][mid])*GRAVITY:.2f} m/s^2 "
          f"(should be near 0)")
