"""Forward iterated EKF (IEKF) on the error state — a transparent Python mirror of
rust/core/src/estimate/iekf.rs.

The measurement update is written in Gauss-Newton / information form, the same MAP
step a batch solve stacks (Bell 1994). For a factor with residual r = z (-) h(x)
and analytic H = dr/ddelta, anchored at the predicted mean x_bar with covariance P,
each iteration i (linearizing at x_i, delta_i = x_i (-) x_bar) computes:

    S = H P H^T + R          K = P H^T S^-1
    delta = K (H delta_i - r)        x_{i+1} = x_bar (+) delta

and on convergence updates P+ = (I - K H) P (I - K H)^T + K R K^T (Joseph form).
One iteration is the plain EKF. iekf.rs:124-182.

This forward pass is the SCAFFOLD: it is causal, so a future topout cannot inform
travel before the event. demo.py contrasts it with smoother.py to show the
travel-DC drift the forward filter structurally cannot fix.
"""

from __future__ import annotations

import numpy as np

from models import DOF, MtbProcess, MtbState

# Variance a frozen state carries — small but nonzero (iekf.rs:29).
FROZEN_VARIANCE = 1.0e-12


class InitStd:
    """Initial 1-sigma priors for the active components. iekf.rs:32-64."""

    def __init__(self):
        self.attitude = np.deg2rad(5.0)
        self.velocity = 1.0
        self.gyro_bias = 0.05
        self.accel_bias = 0.5
        self.wheel_travel = 0.05
        self.wheel_velocity = 1.0
        self.steer_angle = 0.2
        self.steer_rate = 1.0


# Component layout: (symbol, error_index, dim) — schema.rs:63-76 ordering.
_COMPONENTS = [
    ("R_chassis", 0, 3), ("v_chassis", 3, 3), ("b_g0", 6, 3), ("b_a0", 9, 3),
    ("b_g1", 12, 3), ("b_g2", 15, 3), ("w_f", 18, 1), ("dw_f", 19, 1),
    ("w_r", 20, 1), ("dw_r", 21, 1), ("psi", 22, 1), ("dpsi", 23, 1),
]


def initial_covariance(std: InitStd, active: dict) -> np.ndarray:
    """Diagonal P0: active blocks use `std`, frozen blocks use FROZEN_VARIANCE.
    iekf.rs:79-103."""
    var_of = {
        "R_chassis": std.attitude ** 2, "v_chassis": std.velocity ** 2,
        "b_g0": std.gyro_bias ** 2, "b_g1": std.gyro_bias ** 2, "b_g2": std.gyro_bias ** 2,
        "b_a0": std.accel_bias ** 2, "w_f": std.wheel_travel ** 2, "w_r": std.wheel_travel ** 2,
        "dw_f": std.wheel_velocity ** 2, "dw_r": std.wheel_velocity ** 2,
        "psi": std.steer_angle ** 2, "dpsi": std.steer_rate ** 2,
    }
    P = np.zeros((DOF, DOF))
    for sym, idx, dim in _COMPONENTS:
        var = var_of[sym] if active.get(sym, False) else FROZEN_VARIANCE
        for k in range(dim):
            P[idx + k, idx + k] = var
    return P


class FilterState:
    """Belief at one instant: mean x + error-state covariance P. iekf.rs:67-74."""

    def __init__(self, x: MtbState, P: np.ndarray):
        self.x = x
        self.P = P

    def copy(self):
        return FilterState(self.x.copy(), self.P.copy())


class Iekf:
    """Iterated EKF over MtbProcess + the measurement factors. iekf.rs:106-183."""

    def __init__(self, process: MtbProcess, max_iters=1, tol=1e-9):
        self.process = process
        self.max_iters = max_iters
        self.tol = tol

    def predict(self, fs: FilterState, u, dt: float) -> FilterState:
        """Time update: propagate mean; P <- F P F^T + Q. iekf.rs:124-129."""
        F, Q = self.process.jacobian_noise(fs.x, u, dt)
        x = self.process.predict(fs.x, u, dt)
        P = F @ fs.P @ F.T + Q
        return FilterState(x, P)

    def update(self, fs: FilterState, factor, record=None) -> FilterState:
        """Measurement update for one factor (Gauss-Newton / Joseph form).
        Returns fs unchanged if S is singular OR if the update is non-finite (the
        NaN-poisoning guard the finding recommends — iekf.rs:156-159 only guards
        singular S; we additionally reject non-finite deltas). iekf.rs:134-182.

        `record` (optional dict) captures F/P/H/K/S/Q snapshots for inspection."""
        n = DOF
        x_bar = fs.x.copy()
        x = x_bar.copy()
        last_H = factor.jacobian(x)
        last_K = None
        S = None

        for _ in range(max(self.max_iters, 1)):
            H = factor.jacobian(x)
            r = factor.residual(x)
            R = factor.noise(x)
            delta_i = x.ominus(x_bar)  # x_i (-) x_bar

            S = H @ fs.P @ H.T + R
            # Guard a singular innovation (iekf.rs:156-159): skip the factor.
            if np.linalg.cond(S) > 1e14 or not np.all(np.isfinite(S)):
                return fs.copy()
            S_inv = np.linalg.inv(S)
            K = fs.P @ H.T @ S_inv             # n x dim
            delta = K @ (H @ delta_i - r)      # n
            # NaN-poisoning guard (the adversarial finding's recommended defense in
            # depth): a non-finite update poisons the whole trajectory — skip it.
            if not np.all(np.isfinite(delta)):
                return fs.copy()
            x = x_bar.oplus(delta)

            last_H, last_K = H, K
            step = np.linalg.norm(delta - delta_i)
            if step < self.tol:
                break

        # Covariance update at the final linearization (Joseph form, iekf.rs:172-180).
        if last_K is not None:
            R = factor.noise(x)
            IKH = np.eye(n) - last_K @ last_H
            P = IKH @ fs.P @ IKH.T + last_K @ R @ last_K.T
        else:
            P = fs.P.copy()

        if record is not None:
            record.update(dict(H=last_H, K=last_K, S=S, R=factor.noise(x), P_post=P))
        return FilterState(x, P)
