#!/usr/bin/env python3
"""Kerr geodesics in Kerr-Schild coordinates (NULL.md §3.3).

The reference implementation. It exists to be GROUND TRUTH, not to render the
bake: a compute shader is close to undebuggable, and this is the thing it gets
checked against (§10.2).

Kerr-Schild rather than Boyer-Lindquist because it is horizon-penetrating and
has no coordinate singularity at the horizon, which removes all turning-point
sign bookkeeping -- the single largest source of defects in geodesic renderers.
"""

import numpy as np

M = 1.0     # geometric units throughout


# --- closed-form results, for checking against -------------------------

def horizon_radius(a):
    """r_+ = M + sqrt(M^2 - a^2)."""
    return M + np.sqrt(M * M - a * a)


def isco_radius(a, prograde=True):
    """Bardeen, Press & Teukolsky (1972). At a=0.9 prograde this is ~2.32 M --
    NOT 6 M, which is the Schwarzschild value (§3.3)."""
    z1 = 1 + (1 - a * a) ** (1 / 3) * ((1 + a) ** (1 / 3) + (1 - a) ** (1 / 3))
    z2 = np.sqrt(3 * a * a + z1 * z1)
    s = -1 if prograde else 1
    return M * (3 + z2 + s * np.sqrt((3 - z1) * (3 + z1 + 2 * z2)))


def photon_orbit_radius(a, prograde=True):
    """Equatorial circular photon orbit. 3M at a=0, falling toward M for
    prograde and rising toward 4M for retrograde as a increases."""
    s = -1 if prograde else 1
    return 2 * M * (1 + np.cos((2 / 3) * np.arccos(s * a / M)))


def critical_impact_parameter(a, prograde=True):
    """Impact parameter of the equatorial circular photon orbit.

    The a -> 0 limit is 3*sqrt(3) M and must be taken explicitly: the general
    expression is 0/0 there.
    """
    if abs(a) < 1e-12:
        return 3 * np.sqrt(3) * M
    r = photon_orbit_radius(a, prograde)
    num = r ** 3 - 3 * M * r ** 2 + a * a * r + M * a * a
    den = a * (r - M)
    return abs(-num / den)


# --- Kerr-Schild geometry ----------------------------------------------

def ks_radius(x, y, z, a):
    """The positive root of r^4 - (rho^2 - a^2) r^2 - a^2 z^2 = 0."""
    rho2 = x * x + y * y + z * z
    t = rho2 - a * a
    return np.sqrt(0.5 * (t + np.sqrt(t * t + 4.0 * a * a * z * z)))


def ks_f_and_k(x, y, z, a):
    """f and the covariant null vector k_mu = (1, kx, ky, kz)."""
    r = ks_radius(x, y, z, a)
    r2 = r * r
    f = 2.0 * M * r2 * r / (r2 * r2 + a * a * z * z)
    d = r2 + a * a
    kx = (r * x + a * y) / d
    ky = (r * y - a * x) / d
    kz = z / r
    return f, kx, ky, kz, r


def inverse_metric(x, y, z, a, flat=False):
    """g^{mu nu} = eta^{mu nu} - f k^mu k^nu.

    With eta = diag(-1, 1, 1, 1) and k_0 = 1, raising gives k^0 = -1.
    The inverse metric is a rank-one update to Minkowski, which is what makes
    the Hamiltonian form cheap.
    """
    f, kx, ky, kz, _ = ks_f_and_k(x, y, z, a)
    # `flat` is not "spin zero" -- that is still Schwarzschild and still bends
    # light. Disabling LENSING means f = 0, which is Minkowski and straight
    # lines. Conflating the two makes the lensing check vacuous (§10.2).
    if flat:
        f = np.zeros_like(f)
    ku = np.stack([-np.ones_like(f), kx, ky, kz], axis=-1)
    eta = np.diag([-1.0, 1.0, 1.0, 1.0])
    return eta - f[..., None, None] * ku[..., :, None] * ku[..., None, :]


def hamiltonian(pos, p, a, flat=False):
    """H = 1/2 g^{mu nu} p_mu p_nu. Zero for a null geodesic."""
    g = inverse_metric(pos[..., 1], pos[..., 2], pos[..., 3], a, flat)
    return 0.5 * np.einsum("...ij,...i,...j->...", g, p, p)


def dH_dx(pos, p, a, h_rel=1e-6, flat=False):
    """-dp_mu/dlambda, by central differences on the cheap scalars.

    The step SCALES WITH POSITION. A fixed absolute step adequate near the
    horizon falls below floating-point epsilon at large radius and the
    difference degenerates into rounding noise (§5.5).
    """
    out = np.zeros_like(p)
    scale = np.maximum(np.abs(pos[..., 1:]).max(axis=-1, keepdims=True), 1.0)
    for i in range(1, 4):
        step = h_rel * scale[..., 0]
        pp = pos.copy(); pp[..., i] += step
        pm = pos.copy(); pm[..., i] -= step
        out[..., i] = (hamiltonian(pp, p, a, flat) - hamiltonian(pm, p, a, flat)) / (2 * step)
    return out       # index 0 stays zero: the metric is stationary


def geodesic_rhs(pos, p, a, flat=False):
    g = inverse_metric(pos[..., 1], pos[..., 2], pos[..., 3], a, flat)
    dx = np.einsum("...ij,...j->...i", g, p)
    dp = -dH_dx(pos, p, a, flat=flat)
    return dx, dp


def project_null(pos, p, a, flat=False):
    """Re-project p onto the null cone.

    Done periodically rather than trusting drift to stay bounded: it is cheaper
    and far more robust than shrinking the step size (§5.5). Scales the spatial
    part to restore H = 0 at fixed p_t.
    """
    g = inverse_metric(pos[..., 1], pos[..., 2], pos[..., 3], a, flat)
    tt = g[..., 0, 0]
    tv = 2.0 * np.einsum("...j,...j->...", g[..., 0, 1:], p[..., 1:])
    vv = np.einsum("...ij,...i,...j->...", g[..., 1:, 1:], p[..., 1:], p[..., 1:])
    A = vv
    B = tv * p[..., 0]
    C = tt * p[..., 0] * p[..., 0]
    disc = B * B - 4 * A * C
    ok = (A != 0) & (disc >= 0)
    s = np.ones_like(A)
    s[ok] = (-B[ok] + np.sqrt(disc[ok])) / (2 * A[ok])
    good = ok & np.isfinite(s) & (s > 0)
    p = p.copy()
    p[..., 1:] = np.where(good[..., None], p[..., 1:] * s[..., None], p[..., 1:])
    return p


# --- integration --------------------------------------------------------

ESCAPE_R = 400.0 * M


class Outcome:
    """Termination is a THREE-way result. Step-budget exhaustion is not escape:
    scoring it as escape produces a plausible image with a subtly wrong shadow
    edge, and it is invisible without a test that separates the three (§3.3)."""
    HORIZON, ESCAPED, EXHAUSTED = 0, 1, 2


def rk4_step(pos, p, a, dl, flat=False):
    k1x, k1p = geodesic_rhs(pos, p, a, flat)
    k2x, k2p = geodesic_rhs(pos + 0.5 * dl[..., None] * k1x, p + 0.5 * dl[..., None] * k1p, a, flat)
    k3x, k3p = geodesic_rhs(pos + 0.5 * dl[..., None] * k2x, p + 0.5 * dl[..., None] * k2p, a, flat)
    k4x, k4p = geodesic_rhs(pos + dl[..., None] * k3x, p + dl[..., None] * k3p, a, flat)
    pos = pos + (dl[..., None] / 6.0) * (k1x + 2 * k2x + 2 * k3x + k4x)
    p = p + (dl[..., None] / 6.0) * (k1p + 2 * k2p + 2 * k3p + k4p)
    return pos, p


def trace(pos, p, a, max_steps=4000, reproject_every=16, record_crossings=None,
          disk_in=None, disk_out=None, flat=False):
    """Integrate a bundle of null geodesics.

    Returns (pos, p, outcome, crossings). `crossings` records EVERY equatorial
    crossing between disk_in and disk_out, not just the first: the second and
    third produce the far side of the disk arcing over and under the shadow,
    which is the entire iconic image (§3.3).
    """
    n = pos.shape[0]
    outcome = np.full(n, Outcome.EXHAUSTED, dtype=np.int8)
    alive = np.ones(n, dtype=bool)
    crossings = [] if record_crossings else None

    rp = horizon_radius(a)
    for step in range(max_steps):
        if not alive.any():
            break
        idx = np.flatnonzero(alive)
        P, K = pos[idx], p[idx]

        r = ks_radius(P[:, 1], P[:, 2], P[:, 3], a)
        # Adaptive: small steps near the horizon, large ones far away.
        dl = np.clip(0.02 * np.maximum(r - rp, 0.05) + 0.01, 0.005, 2.0)
        z0 = P[:, 3]

        Pn, Kn = rk4_step(P, K, a, dl, flat)
        if step % reproject_every == 0:
            Kn = project_null(Pn, Kn, a, flat)

        if crossings is not None:
            z1 = Pn[:, 3]
            crossed = (z0 * z1 < 0)
            if crossed.any():
                t = z0[crossed] / (z0[crossed] - z1[crossed])
                Pc = P[crossed] + t[:, None] * (Pn[crossed] - P[crossed])
                Kc = K[crossed] + t[:, None] * (Kn[crossed] - K[crossed])
                rc = ks_radius(Pc[:, 1], Pc[:, 2], Pc[:, 3], a)
                inb = (rc >= disk_in) & (rc <= disk_out)
                if inb.any():
                    crossings.append((idx[crossed][inb], Pc[inb], Kc[inb], rc[inb]))

        pos[idx], p[idx] = Pn, Kn
        rn = ks_radius(Pn[:, 1], Pn[:, 2], Pn[:, 3], a)
        fell = rn < rp * 1.001
        gone = rn > ESCAPE_R
        outcome[idx[fell]] = Outcome.HORIZON
        outcome[idx[gone]] = Outcome.ESCAPED
        alive[idx[fell | gone]] = False

    return pos, p, outcome, crossings


# --- the emitter --------------------------------------------------------

def disk_four_velocity(r, a):
    """Prograde circular geodesic in the equatorial plane (§3.3)."""
    den = np.sqrt(r ** 3 - 3 * M * r * r + 2 * a * np.sqrt(M) * r ** 1.5)
    ut = (r ** 1.5 + a * np.sqrt(M)) / den
    uphi = np.sqrt(M) / den
    return ut, uphi


def disk_temperature(r, r_in, t_in):
    """Shakura-Sunyaev thin disk: T ~ r^(-3/4), inner edge at the ISCO."""
    return t_in * (r / r_in) ** -0.75


# --- the camera ---------------------------------------------------------

# SETTLED BY MEASUREMENT, not by inspection (§3.3, §10.2).
#
# The prograde side is the one with the SMALLER critical impact parameter, and
# the validation suite finds it at +y: 2.8444 there against 6.8323 at -y, both
# matching the analytic values exactly. Assuming the other sign mirrors the
# Doppler asymmetry and puts the bright limb on the wrong side -- an image that
# looks entirely plausible and is wrong.
PROGRADE_SIGN = +1


def camera_rays(cols, rows, a, inclination_deg=100.0, half_width=28.0,
                distance=200.0):
    """A ray per cell, from a camera at `inclination_deg` from the spin axis.

    Cells are 1:2, so the vertical extent is scaled by the cell's own aspect --
    that is what makes aspect exact rather than approximately corrected (§2.5).
    """
    inc = np.radians(inclination_deg)
    # Camera position on the x-z plane, looking at the origin.
    cam = np.array([distance * np.sin(inc), 0.0, distance * np.cos(inc)])
    fwd = -cam / np.linalg.norm(cam)
    up0 = np.array([0.0, 0.0, 1.0])
    right = np.cross(fwd, up0); right /= np.linalg.norm(right)
    up = np.cross(right, fwd)

    aspect = (rows * 2.0) / cols          # 1:2 cells
    xs = (np.arange(cols) + 0.5) / cols * 2 - 1
    ys = (np.arange(rows) + 0.5) / rows * 2 - 1
    gx, gy = np.meshgrid(xs, ys)
    off = (gx[..., None] * right * half_width
           - gy[..., None] * up * half_width * aspect)

    origin = cam[None, None, :] + off
    n = cols * rows
    pos = np.zeros((n, 4))
    pos[:, 1:] = origin.reshape(n, 3)
    p = np.zeros((n, 4))
    p[:, 0] = -1.0
    p[:, 1:] = np.broadcast_to(fwd, (n, 3))
    return pos, project_null(pos, p, a)
