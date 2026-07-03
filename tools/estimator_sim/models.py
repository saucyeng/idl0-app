"""State vector, process model, and measurement models for the MTB suspension
estimator — a transparent Python mirror of the Rust `idl-rs` `estimate/` module.

Everything here is *explicit*: F, Q, H, R are built as plain numpy arrays so you
can print them, eyeball the block structure, and compare entry-by-entry against
the Rust analytic Jacobians. A sympy section at the bottom derives F (and one H)
symbolically so the matrices are human-readable rather than a wall of floats.

CONVENTION (pinned, load-bearing — matches rust/core/src/estimate/model.rs:1-6):
  error-state, RIGHT (local) perturbation, x_true = x_nom (+) delta, with the
  SO(3) block R_nom * Exp([dtheta]_x). Every analytic Jacobian is dr/ddelta at
  delta = 0 under this one boxplus.

ERROR-STATE LAYOUT (24 DOF, matches state.rs:10-12 / schema.rs:61-76 exactly):
   idx  block        symbol     meaning
   0:3  SO3          dtheta     chassis attitude (R_chassis), sensor/vehicle->nav
   3:6  R3           dv         chassis velocity, nav frame                m/s
   6:9  R3           db_g0      IMU0 gyro bias                             rad/s
   9:12 R3           db_a0      IMU0 accel bias                            m/s^2
  12:15 R3           db_g1      front-unsprung (IMU1) gyro bias            rad/s
  15:18 R3           db_g2      rear-unsprung  (IMU2) gyro bias            rad/s
  18    R1           dw_f       front wheel travel                         m
  19    R1           ddw_f      front wheel velocity                       m/s
  20    R1           dw_r       rear  wheel travel                         m
  21    R1           ddw_r      rear  wheel velocity                       m/s
  22    R1           dpsi       steer angle (frozen in M2a)                rad
  23    R1           ddpsi      steer rate  (frozen in M2a)                rad/s

Rust source map (file:line):
  - process model + analytic F/Q .......... rust/core/src/estimate/process.rs:101-185
  - oplus / ominus on SO(3) (+) R^n ....... rust/core/src/estimate/state.rs:51-91
  - exp_so3 / log_so3 / skew / J_r ........ rust/core/src/rotation.rs:36-118
  - lever_arm_accel / wheel_drive_accel ... rust/core/src/rotation.rs:142-149,
                                            rust/core/src/estimate/process.rs:88-99
  - measurement factors ................... rust/core/src/estimate/measurements/*.rs
  - process noise discretization .......... rust/core/src/estimate/noise.rs:39-46
"""

from __future__ import annotations

import numpy as np
from scipy.spatial.transform import Rotation

# ----------------------------------------------------------------------------
# Constants (mirror Rust)
# ----------------------------------------------------------------------------

GRAVITY = 9.81  # m/s^2 — process.rs:23
DOF = 24        # state.rs:43

# Error-state column offsets — measurements/mod.rs:27-42.
I_THETA, I_V = 0, 3
I_BG0, I_BA0, I_BG1, I_BG2 = 6, 9, 12, 15
I_WF, I_DWF, I_WR, I_DWR = 18, 19, 20, 21
I_PSI, I_DPSI = 22, 23


# ----------------------------------------------------------------------------
# SO(3) helpers — numerically identical role to rust/core/src/rotation.rs
# ----------------------------------------------------------------------------

def skew(v):
    """[v]_x — the cross-product matrix, [v]_x w == v x w. rotation.rs:36-42."""
    x, y, z = v
    return np.array([[0.0, -z, y],
                     [z, 0.0, -x],
                     [-y, x, 0.0]])


def exp_so3(omega):
    """SO(3) exponential as a rotation matrix. rotation.rs:50-52 (quaternion form
    there; scipy gives the equivalent matrix). Right-perturbation retraction."""
    return Rotation.from_rotvec(np.asarray(omega, float)).as_matrix()


def log_so3(R):
    """SO(3) log -> rotation vector (<= pi). rotation.rs:59-61."""
    return Rotation.from_matrix(R).as_rotvec()


def right_jacobian_so3(phi):
    """SO(3) right Jacobian J_r(phi). rotation.rs:107-118.
    J_r = I - ((1-cos t)/t^2)[phi]x + ((t-sin t)/t^3)[phi]x^2, t = ||phi||,
    with the small-angle limit I - 1/2[phi]x."""
    phi = np.asarray(phi, float)
    t = np.linalg.norm(phi)
    K = skew(phi)
    if t < 1e-8:
        return np.eye(3) - 0.5 * K
    a = (1.0 - np.cos(t)) / (t * t)
    b = (t - np.sin(t)) / (t ** 3)
    return np.eye(3) - a * K + b * (K @ K)


def lever_arm_accel(a_ref, omega, omega_dot, lever):
    """Rigid-body acceleration transfer a = a_ref + w_dot x L + w x (w x L).
    rotation.rs:142-149. The two rotational terms are mandatory (omitting them
    aliases body rotation into false travel)."""
    return a_ref + np.cross(omega_dot, lever) + np.cross(omega, np.cross(omega, lever))


def wheel_drive_accel(axis, accel_unsprung, accel0, omega0, omega0_dot, lever):
    """Projected differential specific force along `axis` (the wheel-drive control
    w_ddot). process.rs:88-99. The Coriolis term drops out of the projection."""
    lever_term = lever_arm_accel(np.zeros(3), omega0, omega0_dot, lever)
    return float(np.dot(axis, accel_unsprung - accel0 - lever_term))


# ----------------------------------------------------------------------------
# State
# ----------------------------------------------------------------------------

class MtbState:
    """The 24-DOF full-suspension estimator mean. Mirrors state.rs:14-39.

    R_chassis is stored as a 3x3 rotation matrix (sensor/vehicle -> nav)."""

    def __init__(self, R_chassis=None, v_chassis=None, b_g0=None, b_a0=None,
                 b_g1=None, b_g2=None, d_f=0.0, dd_f=0.0, s_r=0.0, ds_r=0.0,
                 psi=0.0, dpsi=0.0):
        self.R_chassis = np.eye(3) if R_chassis is None else np.asarray(R_chassis, float)
        self.v_chassis = np.zeros(3) if v_chassis is None else np.asarray(v_chassis, float)
        self.b_g0 = np.zeros(3) if b_g0 is None else np.asarray(b_g0, float)
        self.b_a0 = np.zeros(3) if b_a0 is None else np.asarray(b_a0, float)
        self.b_g1 = np.zeros(3) if b_g1 is None else np.asarray(b_g1, float)
        self.b_g2 = np.zeros(3) if b_g2 is None else np.asarray(b_g2, float)
        self.d_f, self.dd_f = float(d_f), float(dd_f)
        self.s_r, self.ds_r = float(s_r), float(ds_r)
        self.psi, self.dpsi = float(psi), float(dpsi)

    def copy(self):
        return MtbState(self.R_chassis.copy(), self.v_chassis.copy(),
                        self.b_g0.copy(), self.b_a0.copy(), self.b_g1.copy(),
                        self.b_g2.copy(), self.d_f, self.dd_f, self.s_r,
                        self.ds_r, self.psi, self.dpsi)

    # --- boxplus / boxminus on SO(3) (+) R^n (state.rs:51-91) ---------------

    def oplus(self, d):
        """x (+) delta. SO(3): R * Exp([dtheta]x); all others add. state.rs:51-67."""
        d = np.asarray(d, float)
        return MtbState(
            R_chassis=self.R_chassis @ exp_so3(d[0:3]),
            v_chassis=self.v_chassis + d[3:6],
            b_g0=self.b_g0 + d[6:9],
            b_a0=self.b_a0 + d[9:12],
            b_g1=self.b_g1 + d[12:15],
            b_g2=self.b_g2 + d[15:18],
            d_f=self.d_f + d[18], dd_f=self.dd_f + d[19],
            s_r=self.s_r + d[20], ds_r=self.ds_r + d[21],
            psi=self.psi + d[22], dpsi=self.dpsi + d[23],
        )

    def ominus(self, o):
        """x (-) other. SO(3): log(R_o^T R_self); all others subtract. state.rs:69-91."""
        dtheta = log_so3(o.R_chassis.T @ self.R_chassis)
        out = np.zeros(DOF)
        out[0:3] = dtheta
        out[3:6] = self.v_chassis - o.v_chassis
        out[6:9] = self.b_g0 - o.b_g0
        out[9:12] = self.b_a0 - o.b_a0
        out[12:15] = self.b_g1 - o.b_g1
        out[15:18] = self.b_g2 - o.b_g2
        out[18] = self.d_f - o.d_f
        out[19] = self.dd_f - o.dd_f
        out[20] = self.s_r - o.s_r
        out[21] = self.ds_r - o.ds_r
        out[22] = self.psi - o.psi
        out[23] = self.dpsi - o.dpsi
        return out


class ImuInput:
    """Driving input for one propagation step. Mirrors model.rs:15-27.
    gyro0/accel0 are in the chassis frame (IMU0 mount already applied)."""

    def __init__(self, gyro0, accel0, wheel_accel_front=0.0, wheel_accel_rear=0.0):
        self.gyro0 = np.asarray(gyro0, float)
        self.accel0 = np.asarray(accel0, float)
        self.wheel_accel_front = float(wheel_accel_front)
        self.wheel_accel_rear = float(wheel_accel_rear)


# ----------------------------------------------------------------------------
# Process model — IMU0 strapdown + wheel double integrators (process.rs)
# ----------------------------------------------------------------------------

class ProcessNoiseConfig:
    """Process-noise PSDs (random-walk coeffs N; variance over dt = N^2 dt).
    Mirrors process.rs:44-61 reference_default()."""

    def __init__(self):
        # IMU0 (Allan) — noise.rs:13-18 / process.rs:48-53
        self.gyro_arw = 0.003       # rad/sqrt(s)
        self.accel_vrw = 0.05       # (m/s)/sqrt(s)
        self.gyro_bias_rw = 1.0e-4  # (rad/s)/sqrt(s)
        self.accel_bias_rw = 1.0e-3 # (m/s^2)/sqrt(s)
        self.gyro1_bias_rw = 1.0e-4
        self.gyro2_bias_rw = 1.0e-4
        self.wheel_vel_rw = 5.0     # (m/s^2)/sqrt(s) — suspension is energetic
        self.wheel_pos_rw = 1.0e-3  # (m)/sqrt(s)
        self.steer_rate_rw = 1.0


# Active flags for the M2a wheels-first full-suspension schema (schema.rs:63-76).
# steering (psi, dpsi) frozen; everything else active on a full-sus bike.
M2A_ACTIVE = {
    "R_chassis": True, "v_chassis": True, "b_g0": True, "b_a0": True,
    "b_g1": True, "b_g2": True, "w_f": True, "dw_f": True,
    "w_r": True, "dw_r": True, "psi": False, "dpsi": False,
}


class MtbProcess:
    """IMU0-driven kinematic process model with analytic F and discrete Q.
    Mirrors process.rs:101-185."""

    def __init__(self, noise=None, gravity=GRAVITY, active=None):
        self.noise = noise or ProcessNoiseConfig()
        self.gravity = gravity
        self.active = active or dict(M2A_ACTIVE)

    def predict(self, x: MtbState, u: ImuInput, dt: float) -> MtbState:
        """Propagate the mean. process.rs:102-127."""
        omega0 = u.gyro0 - x.b_g0
        R = x.R_chassis @ exp_so3(omega0 * dt)
        f_nav = x.R_chassis @ (u.accel0 - x.b_a0)
        a_nav = f_nav + np.array([0.0, 0.0, -self.gravity])
        v = x.v_chassis + a_nav * dt
        return MtbState(
            R_chassis=R, v_chassis=v,
            b_g0=x.b_g0.copy(), b_a0=x.b_a0.copy(),
            b_g1=x.b_g1.copy(), b_g2=x.b_g2.copy(),
            # wheel double integrators (process.rs:118-122)
            d_f=x.d_f + x.dd_f * dt, dd_f=x.dd_f + u.wheel_accel_front * dt,
            s_r=x.s_r + x.ds_r * dt, ds_r=x.ds_r + u.wheel_accel_rear * dt,
            # steering kinematics (frozen in M2a via Q)
            psi=x.psi + x.dpsi * dt, dpsi=x.dpsi,
        )

    def jacobian_noise(self, x: MtbState, u: ImuInput, dt: float):
        """Analytic (F, Q) in error-state coordinates. process.rs:129-184.

        F blocks (the only non-identity ones):
          dtheta+ / dtheta   = Exp(-phi)            (attitude self, process.rs:138,142)
          dtheta+ / db_g0    = -J_r(phi) dt         (gyro-bias coupling, :139,143)
          dv+     / dtheta   = -R [a0 - b_a0]x dt   (process.rs:147-148,152)
          dv+     / db_a0    = -R dt                (process.rs:149,153)
          w (+= v) couplings = dt                   (process.rs:157-159)
        """
        n = DOF
        omega0 = u.gyro0 - x.b_g0
        phi = omega0 * dt
        R = x.R_chassis

        F = np.eye(n)
        # attitude self + gyro-bias coupling
        F[0:3, 0:3] = exp_so3(-phi)
        F[0:3, 6:9] = -right_jacobian_so3(phi) * dt
        # velocity <- attitude, velocity <- accel bias
        a_skew = skew(u.accel0 - x.b_a0)
        F[3:6, 0:3] = -(R @ a_skew) * dt
        F[3:6, 9:12] = -R * dt
        # double-integrator position <- velocity couplings
        F[I_WF, I_DWF] = dt
        F[I_WR, I_DWR] = dt
        F[I_PSI, I_DPSI] = dt

        # --- Q (diagonal; frozen components -> 0). process.rs:161-183 / noise.rs:39-46
        nz = self.noise
        Q = np.zeros((n, n))

        def setblk(lo, hi, v):
            for i in range(lo, hi):
                Q[i, i] = v

        setblk(0, 3, nz.gyro_arw ** 2 * dt)       # attitude
        setblk(3, 6, nz.accel_vrw ** 2 * dt)      # velocity
        setblk(6, 9, nz.gyro_bias_rw ** 2 * dt)   # b_g0
        setblk(9, 12, nz.accel_bias_rw ** 2 * dt) # b_a0
        setblk(12, 15, nz.gyro1_bias_rw ** 2 * dt)  # b_g1 (front always present)
        gate = lambda sym, v: v if self.active.get(sym, False) else 0.0
        setblk(15, 18, gate("b_g2", nz.gyro2_bias_rw ** 2 * dt))
        Q[I_WF, I_WF] = gate("w_f", nz.wheel_pos_rw ** 2 * dt)
        Q[I_DWF, I_DWF] = gate("dw_f", nz.wheel_vel_rw ** 2 * dt)
        Q[I_WR, I_WR] = gate("w_r", nz.wheel_pos_rw ** 2 * dt)
        Q[I_DWR, I_DWR] = gate("dw_r", nz.wheel_vel_rw ** 2 * dt)
        Q[I_PSI, I_PSI] = gate("psi", nz.wheel_pos_rw ** 2 * dt)
        Q[I_DPSI, I_DPSI] = gate("dpsi", nz.steer_rate_rw ** 2 * dt)
        return F, Q


# ----------------------------------------------------------------------------
# Measurement factors — each returns (residual r, jacobian H, noise R)
# r = z (-) h(x); H = dr/ddelta at delta=0; mirrors measurements/*.rs
# ----------------------------------------------------------------------------

class GravityLeveling:
    """Acceleration-compensated gravity leveling — 2-DOF residual on the gravity
    DIRECTION (S^2 tangent). gravity.rs:38-82.

    NOTE (adversarial finding, gravity.rs:45): the Rust uses an UNCHECKED
    normalize() — NaN-prone in true free fall where ||m|| -> 0. Here we mirror
    that exactly but expose `well_conditioned()` so the runner can gate it off
    in free fall (the recommended fix). The sim runner does gate it."""

    def __init__(self, accel0, a_kin_nav=None, sigma=0.05):
        self.accel0 = np.asarray(accel0, float)
        self.a_kin_nav = np.zeros(3) if a_kin_nav is None else np.asarray(a_kin_nav, float)
        self.sigma = sigma

    def up_body_raw(self, x):
        # m = a0 - b_a0 - R^T a_kin   (gravity.rs:33-35)
        return self.accel0 - x.b_a0 - x.R_chassis.T @ self.a_kin_nav

    def well_conditioned(self, x, floor=0.5):
        return np.linalg.norm(self.up_body_raw(x)) > floor

    def residual(self, x):
        up_nav = x.R_chassis @ (self.up_body_raw(x) / np.linalg.norm(self.up_body_raw(x)))
        return np.array([up_nav[0], up_nav[1]])

    def jacobian(self, x):
        R = x.R_chassis
        m = self.up_body_raw(x)
        norm = np.linalg.norm(m)
        u = m / norm
        P_u = (np.eye(3) - np.outer(u, u)) / norm
        rt_akin = R.T @ self.a_kin_nav
        dp_dtheta = R @ P_u @ (-skew(rt_akin)) - R @ skew(u)  # gravity.rs:62
        dp_dba = -(R @ P_u)                                   # gravity.rs:63
        H = np.zeros((2, DOF))
        H[:, I_THETA:I_THETA + 3] = dp_dtheta[0:2, :]
        H[:, I_BA0:I_BA0 + 3] = dp_dba[0:2, :]
        return H

    def noise(self, x):
        return np.eye(2) * self.sigma ** 2


class GpsVelocity:
    """GPS velocity-vector anchor. r = z - v. gps.rs:21-46."""

    def __init__(self, measured, sigma=0.2):
        self.measured = np.asarray(measured, float)
        self.sigma = sigma

    def residual(self, x):
        return self.measured - x.v_chassis

    def jacobian(self, x):
        H = np.zeros((3, DOF))
        for i in range(3):
            H[i, I_V + i] = -1.0
        return H

    def noise(self, x):
        return np.eye(3) * self.sigma ** 2


class ZeroVelocity:
    """ZUPT: v_chassis = 0 on stationary samples. r = -v. zupt.rs:19-43."""

    def __init__(self, sigma=0.02):
        self.sigma = sigma

    def residual(self, x):
        return -x.v_chassis.copy()

    def jacobian(self, x):
        H = np.zeros((3, DOF))
        for i in range(3):
            H[i, I_V + i] = -1.0
        return H

    def noise(self, x):
        return np.eye(3) * self.sigma ** 2


# Gyro-bias targets for ZARU (zupt.rs:46-72).
_BG_COL = {"imu0": I_BG0, "imu1": I_BG1, "imu2": I_BG2}


class ZeroAngularRate:
    """ZARU: pin a gyro-bias block to the measured rate. r = w_meas - b. zupt.rs:86-112."""

    def __init__(self, target, measured, sigma=1e-3):
        self.target = target
        self.measured = np.asarray(measured, float)
        self.sigma = sigma

    def _bias_of(self, x):
        return {"imu0": x.b_g0, "imu1": x.b_g1, "imu2": x.b_g2}[self.target]

    def residual(self, x):
        return self.measured - self._bias_of(x)

    def jacobian(self, x):
        H = np.zeros((3, DOF))
        c = _BG_COL[self.target]
        for i in range(3):
            H[i, c + i] = -1.0
        return H

    def noise(self, x):
        return np.eye(3) * self.sigma ** 2


_WHEEL_TRAVEL_COL = {"front": I_WF, "rear": I_WR}
_WHEEL_VEL_COL = {"front": I_DWF, "rear": I_DWR}


def _travel_of(x, wheel):
    return x.d_f if wheel == "front" else x.s_r


def _vel_of(x, wheel):
    return x.dd_f if wheel == "front" else x.ds_r


class SagPrior:
    """Soft pull of wheel travel toward sag. r = sag - w. prior.rs:49-71."""

    def __init__(self, wheel, sag, sigma=0.5):
        self.wheel, self.sag, self.sigma = wheel, sag, sigma

    def residual(self, x):
        return np.array([self.sag - _travel_of(x, self.wheel)])

    def jacobian(self, x):
        H = np.zeros((1, DOF))
        H[0, _WHEEL_TRAVEL_COL[self.wheel]] = -1.0
        return H

    def noise(self, x):
        return np.array([[self.sigma ** 2]])


class TopoutReference:
    """Airborne topout: travel = 0. r = -w. The load-bearing travel-DC anchor.
    prior.rs:135-157."""

    def __init__(self, wheel, sigma=0.01):
        self.wheel, self.sigma = wheel, sigma

    def residual(self, x):
        return np.array([-_travel_of(x, self.wheel)])

    def jacobian(self, x):
        H = np.zeros((1, DOF))
        H[0, _WHEEL_TRAVEL_COL[self.wheel]] = -1.0
        return H

    def noise(self, x):
        return np.array([[self.sigma ** 2]])


class TravelBarrier:
    """One-sided quadratic wall keeping travel in [0, travel_max]. prior.rs:87-119.
    Residual [relu(-w), relu(w-max)] with a piecewise-constant (kinked) Jacobian."""

    def __init__(self, wheel, travel_max, sigma=0.005):
        self.wheel, self.travel_max, self.sigma = wheel, travel_max, sigma

    def residual(self, x):
        w = _travel_of(x, self.wheel)
        return np.array([max(-w, 0.0), max(w - self.travel_max, 0.0)])

    def jacobian(self, x):
        w = _travel_of(x, self.wheel)
        c = _WHEEL_TRAVEL_COL[self.wheel]
        H = np.zeros((2, DOF))
        if w < 0.0:
            H[0, c] = -1.0
        if w > self.travel_max:
            H[1, c] = 1.0
        return H

    def noise(self, x):
        return np.eye(2) * self.sigma ** 2


class ZeroWheelVelocity:
    """Pin a wheel travel-rate dw = 0 (stationary or topped-out). r = -dw. zupt.rs:122-167."""

    def __init__(self, wheel, sigma=0.02):
        self.wheel, self.sigma = wheel, sigma

    def residual(self, x):
        return np.array([-_vel_of(x, self.wheel)])

    def jacobian(self, x):
        H = np.zeros((1, DOF))
        H[0, _WHEEL_VEL_COL[self.wheel]] = -1.0
        return H

    def noise(self, x):
        return np.array([[self.sigma ** 2]])


# ----------------------------------------------------------------------------
# Numerical finite-difference Jacobian — the SAME cross-check the Rust tests use
# (measurements/mod.rs:48-71, process.rs:337-378). Lets demo.py prove F and H.
# ----------------------------------------------------------------------------

def fd_measurement_jacobian(factor, x, eps=1e-6):
    """Central-difference dr/ddelta under the pinned boxplus."""
    dim = len(factor.residual(x))
    J = np.zeros((dim, DOF))
    for col in range(DOF):
        ep = np.zeros(DOF); ep[col] = eps
        em = np.zeros(DOF); em[col] = -eps
        J[:, col] = (factor.residual(x.oplus(ep)) - factor.residual(x.oplus(em))) / (2 * eps)
    return J


def fd_transition_jacobian(process, x, u, dt, eps=1e-6):
    """Central-difference the process F via predict((x (+) +/-eps)) (-) x_next."""
    x_next = process.predict(x, u, dt)
    F = np.zeros((DOF, DOF))
    for col in range(DOF):
        ep = np.zeros(DOF); ep[col] = eps
        em = np.zeros(DOF); em[col] = -eps
        F[:, col] = (process.predict(x.oplus(ep), u, dt).ominus(x_next)
                     - process.predict(x.oplus(em), u, dt).ominus(x_next)) / (2 * eps)
    return F


# ----------------------------------------------------------------------------
# SYMBOLIC F and H via sympy — so the matrices are human-readable
# ----------------------------------------------------------------------------

def symbolic_transition_jacobian():
    """Return (F_sym, symbols_dict): the small-angle symbolic transition Jacobian
    of the non-trivial process blocks, derived with sympy. We linearize about the
    operating point with the standard first-order identities the Rust code bakes
    in analytically:
        Exp([dtheta]x) ~ I + [dtheta]x,
        dtheta+ ~ dtheta - phi x dtheta - J_r(phi) db_g0 dt   (here shown to
                  first order; the closed form Exp(-phi) and -J_r(phi)dt is what
                  process.rs:138-143 ships),
        dv+     ~ dv - R [a0-b_a0]x dt dtheta - R dt db_a0.
    The point of this function is READABILITY: it prints the block structure of F
    symbolically rather than as floats."""
    import sympy as sp

    dt = sp.Symbol('dt', positive=True)
    # IMU0 specific force minus accel bias (the a0 - b_a0 vector), nav rotation R.
    a = sp.Matrix(sp.symbols('a_x a_y a_z'))          # a0 - b_a0
    R = sp.Matrix(3, 3, sp.symbols('R0:3(0:3)'))      # chassis->nav rotation
    phi = sp.Matrix(sp.symbols('phi_x phi_y phi_z'))  # (omega0 - b_g0) dt

    def sskew(v):
        return sp.Matrix([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])

    # Attitude self block: Exp(-phi) to first order ~ I - [phi]x.
    F_theta_theta = sp.eye(3) - sskew(phi)
    # Gyro-bias coupling: -J_r(phi) dt ~ -(I - 1/2[phi]x) dt to first order.
    Jr = sp.eye(3) - sp.Rational(1, 2) * sskew(phi)
    F_theta_bg0 = -Jr * dt
    # Velocity <- attitude: -R [a]x dt ; Velocity <- accel-bias: -R dt.
    F_v_theta = -(R * sskew(a)) * dt
    F_v_ba0 = -R * dt

    blocks = {
        "dtheta+/dtheta (Exp(-phi))": sp.simplify(F_theta_theta),
        "dtheta+/db_g0 (-J_r dt)": sp.simplify(F_theta_bg0),
        "dv+/dtheta (-R[a0-ba0]x dt)": sp.simplify(F_v_theta),
        "dv+/db_a0 (-R dt)": sp.simplify(F_v_ba0),
    }
    return blocks, {"dt": dt, "a": a, "R": R, "phi": phi}


def symbolic_gravity_jacobian():
    """Symbolic H for GravityLeveling (the genuinely state-dependent factor),
    derived with sympy from p = R * (m / ||m||), m = a0 - b_a0 (a_kin = 0 case).
    Returns (H_sym rows {x,y}, symbols). gravity.rs:49-73 closed form."""
    import sympy as sp

    R = sp.Matrix(3, 3, sp.symbols('R0:3(0:3)'))
    m = sp.Matrix(sp.symbols('m_x m_y m_z'))  # a0 - b_a0
    dtheta = sp.Matrix(sp.symbols('dth_x dth_y dth_z'))
    dba = sp.Matrix(sp.symbols('dba_x dba_y dba_z'))

    def sskew(v):
        return sp.Matrix([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])

    # Perturbed: R -> R(I+[dtheta]x), m -> m - dba (a_kin=0 so no R^T a_kin term).
    R_pert = R * (sp.eye(3) + sskew(dtheta))
    m_pert = m - dba
    norm = sp.sqrt((m_pert.T * m_pert)[0])
    p = R_pert * (m_pert / norm)
    # H = d p_{x,y} / d(dtheta, dba) at perturbation = 0.
    H = sp.zeros(2, 6)
    vars6 = list(dtheta) + list(dba)
    for r in range(2):
        for c, var in enumerate(vars6):
            H[r, c] = sp.diff(p[r], var).subs({s: 0 for s in dtheta}).subs({s: 0 for s in dba})
    return sp.simplify(H), {"R": R, "m": m}


if __name__ == "__main__":
    import sympy as sp
    np.set_printoptions(precision=4, suppress=True, linewidth=160)

    print("=" * 78)
    print("SYMBOLIC TRANSITION JACOBIAN F (non-trivial blocks) — sympy")
    print("=" * 78)
    blocks, _ = symbolic_transition_jacobian()
    for name, M in blocks.items():
        print(f"\n  {name}:")
        sp.pprint(M)

    print("\n" + "=" * 78)
    print("SYMBOLIC MEASUREMENT JACOBIAN H — GravityLeveling rows {x, y} — sympy")
    print("=" * 78)
    H, _ = symbolic_gravity_jacobian()
    print("\n  columns = [dtheta_x dtheta_y dtheta_z | dba_x dba_y dba_z]:")
    sp.pprint(H)

    print("\n" + "=" * 78)
    print("NUMERIC F vs FINITE DIFFERENCE — analytic Jacobian self-check")
    print("=" * 78)
    proc = MtbProcess()
    x = MtbState(R_chassis=exp_so3([0.1, -0.2, 0.3]),
                 v_chassis=[1.5, -0.5, 0.2], b_g0=[0.01, -0.02, 0.015],
                 b_a0=[0.05, -0.03, 0.04], d_f=0.03, dd_f=-0.2, s_r=0.02, ds_r=0.1)
    u = ImuInput([0.4, -0.3, 0.6], [0.7, -1.2, GRAVITY + 0.5], 1.3, -0.8)
    F, Q = proc.jacobian_noise(x, u, 0.01)
    Ffd = fd_transition_jacobian(proc, x, u, 0.01)
    print(f"  max |F_analytic - F_fd| = {np.max(np.abs(F - Ffd)):.3e}  (should be ~1e-9)")
