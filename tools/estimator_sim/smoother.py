"""Fixed-interval RTS smoother over the SAME model the forward IEKF uses.

This is the M5 backward/batch pass the Rust engine has NOT yet built
(rust/core/src/estimate/run.rs:518-630 is a single causal forward sweep; every
'smoother/RTS/batch' reference in estimate/ is future/M5). The design itself
asserts the equivalence we exploit here: the Kalman forward +
RTS backward sweep IS the block-tridiagonal batch-MAP solve, and the iterated
smoother IS Gauss-Newton on the MAP cost.

WHY THE SMOOTHER MATTERS (the load-bearing point):
  Travel is a strictly forward-only double-integrator driven by diff-accel
  (process.rs:118-122). A forward filter cannot let a FUTURE topout (a hard d=0
  factor, prior.rs:135-157) constrain travel BEFORE the event. The RTS backward
  sweep distributes each topout's endpoint constraint backward over the whole
  inter-topout interval, retro-correcting the travel-DC drift the forward pass
  accumulates. That is exactly the boundary-value (vs initial-value) solve a
  forward filter structurally cannot do.

RTS on the error state
-----------------------
We run a forward IEKF that retains, at each step k:
    x_k^f (filtered mean), P_k^f (filtered cov),
    x_k^p (predicted mean), P_k^p (predicted cov),
    F_k   (transition Jacobian used to predict step k from k-1).
The backward recursion (Rauch-Tung-Striebel), expressed in the error tangent at
the filtered mean, is:
    C_k   = P_k^f F_{k+1}^T (P_{k+1}^p)^-1
    dx_k  = C_k ( x_{k+1}^s (-) x_{k+1}^p )         # smoothed correction, tangent
    x_k^s = x_k^f (+) dx_k
    P_k^s = P_k^f + C_k (P_{k+1}^s - P_{k+1}^p) C_k^T
The boxminus/boxplus keep the SO(3) attitude on-manifold; for the wheel/velocity
double-integrator blocks (the whole point) it reduces to the linear RTS update.
"""

from __future__ import annotations

import numpy as np

from ekf import FilterState, Iekf
from models import DOF, MtbState


class ForwardTrace:
    """Per-step forward record needed by the RTS backward sweep."""

    def __init__(self):
        self.x_filt = []   # filtered means  x_k^f
        self.P_filt = []   # filtered covs   P_k^f
        self.x_pred = []   # predicted means x_k^p  (x_pred[0] == x_filt[0]: prior)
        self.P_pred = []   # predicted covs  P_k^p
        self.F = []        # transition F_k (F[0] = I; F[k] propagates k-1 -> k)


def run_forward_with_trace(iekf: Iekf, fs0: FilterState, inputs, dt,
                           apply_measurements):
    """Forward IEKF that records the trajectory + covariances + transitions.

    `inputs[k]` is the ImuInput for step k (k>=1 propagates; k=0 is the prior).
    `apply_measurements(iekf, fs, k)` applies all factors active at sample k and
    returns the updated FilterState. Returns (ForwardTrace, final FilterState)."""
    tr = ForwardTrace()
    n = len(inputs)

    # k = 0: prior, no propagation. Predicted == filtered prior, F0 = I.
    fs = apply_measurements(iekf, fs0.copy(), 0)
    tr.x_pred.append(fs0.x.copy()); tr.P_pred.append(fs0.P.copy())
    tr.F.append(np.eye(DOF))
    tr.x_filt.append(fs.x.copy()); tr.P_filt.append(fs.P.copy())

    for k in range(1, n):
        F, Q = iekf.process.jacobian_noise(fs.x, inputs[k], dt)
        fs_pred = iekf.predict(fs, inputs[k], dt)
        tr.x_pred.append(fs_pred.x.copy()); tr.P_pred.append(fs_pred.P.copy())
        tr.F.append(F)
        fs = apply_measurements(iekf, fs_pred, k)
        tr.x_filt.append(fs.x.copy()); tr.P_filt.append(fs.P.copy())

    return tr, fs


def rts_smooth(tr: ForwardTrace):
    """Backward RTS sweep over the forward trace. Returns (x_smooth, P_smooth)
    lists. Operates in the error tangent at each filtered mean."""
    n = len(tr.x_filt)
    x_s = [None] * n
    P_s = [None] * n
    x_s[-1] = tr.x_filt[-1].copy()
    P_s[-1] = tr.P_filt[-1].copy()

    for k in range(n - 2, -1, -1):
        Pf = tr.P_filt[k]
        Fk1 = tr.F[k + 1]              # transition that produced step k+1
        Pp1 = tr.P_pred[k + 1]         # predicted cov at k+1
        # Smoother gain C_k = Pf F^T (Pp1)^-1. Pseudo-inverse for the frozen,
        # near-singular blocks (FROZEN_VARIANCE rows make Pp1 ill-conditioned).
        C = Pf @ Fk1.T @ np.linalg.pinv(Pp1, rcond=1e-12)
        # Innovation in the tangent: x_{k+1}^s (-) x_{k+1}^p (on-manifold for SO3).
        innov = x_s[k + 1].ominus(tr.x_pred[k + 1])
        dx = C @ innov
        x_s[k] = tr.x_filt[k].oplus(dx)
        P_s[k] = Pf + C @ (P_s[k + 1] - Pp1) @ C.T
        # Symmetrize (round-off hygiene; the finding flags missing symmetrization).
        P_s[k] = 0.5 * (P_s[k] + P_s[k].T)

    return x_s, P_s
