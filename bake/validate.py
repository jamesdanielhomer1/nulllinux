#!/usr/bin/env python3
"""Analytic validation of the geodesic integrator (NULL.md §10.2).

All analytic, all cheap, and all run BEFORE any long bake.

Expect most of what these find to be in the TESTS rather than the renderer.
Every failure mode they cover produces an image that looks entirely fine, which
is the whole argument for analytic checks over eyeballing.
"""

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kerr
from kerr import Outcome

CAMERA_R = 200.0        # far enough that the metric is near-flat there


def shoot(bs, a, zoff=0.0, max_steps=6000, flat=False):
    """Fire photons inward from a distant camera at impact parameters `bs`.

    The camera sits on +x looking toward the origin; b is the transverse offset
    in y. Its SIGN is what distinguishes the prograde from the retrograde side,
    and which is which is settled by measurement below rather than by
    inspection -- getting it backwards mirrors the Doppler asymmetry and
    produces an image that looks perfectly plausible (§3.3).
    """
    n = len(bs)
    pos = np.zeros((n, 4))
    pos[:, 1] = CAMERA_R
    pos[:, 2] = bs
    pos[:, 3] = zoff

    p = np.zeros((n, 4))
    p[:, 0] = -1.0          # E = 1, past-directed
    p[:, 1] = -1.0          # travelling in -x
    p = kerr.project_null(pos, p, a, flat)
    return kerr.trace(pos.copy(), p, a, max_steps=max_steps, flat=flat)


def shadow_edge(a, lo, hi, side=+1, fan=48, rounds=4):
    """Find the impact parameter at which rays stop falling in.

    That transition IS the shadow edge, and it must equal the critical impact
    parameter of the equatorial photon orbit.

    A FAN of rays per round rather than one ray per bisection step: the tracer
    is vectorised, so forty-eight rays cost barely more than one, and four
    rounds of refinement beat sixty sequential traces by two orders of
    magnitude in wall-clock. Bisecting one ray at a time was measured taking
    minutes per check.
    """
    for _ in range(rounds):
        bs = np.linspace(lo, hi, fan)
        _, _, out, _ = shoot(side * bs, a)
        fell = out == Outcome.HORIZON
        if not fell.any():
            return None
        last_in = np.flatnonzero(fell)[-1]
        if last_in + 1 >= fan:
            return bs[-1]
        lo, hi = bs[last_in], bs[last_in + 1]
    return 0.5 * (lo + hi)


CHECKS = []
def check(name):
    def deco(fn):
        CHECKS.append((name, fn)); return fn
    return deco


@check("horizon radius, a=0 and a=0.9")
def _():
    got = (kerr.horizon_radius(0.0), kerr.horizon_radius(0.9))
    want = (2.0, 1.4358898944)
    ok = all(abs(g - w) < 1e-9 for g, w in zip(got, want))
    return ok, f"{got[0]:.10f}, {got[1]:.10f}"


@check("inverse metric -> Minkowski as 2M/r")
def _():
    # At large radius the deviation from flat must fall as 2M/r.
    out = []
    for r in (100.0, 1000.0):
        g = kerr.inverse_metric(np.array([r]), np.array([0.0]), np.array([0.0]), 0.0)
        dev = abs(g[0, 0, 0] + 1.0)          # g^tt = -1 + f
        out.append(dev * r / (2 * kerr.M))
    ok = all(abs(v - 1.0) < 0.02 for v in out)
    return ok, f"deviation*r/2M = {out[0]:.4f}, {out[1]:.4f} (want 1)"


@check("H = 0 at emission")
def _():
    n = 64
    pos = np.zeros((n, 4)); pos[:, 1] = CAMERA_R
    pos[:, 2] = np.linspace(-20, 20, n)
    p = np.zeros((n, 4)); p[:, 0] = -1.0; p[:, 1] = -1.0
    p = kerr.project_null(pos, p, 0.9)
    h = np.abs(kerr.hamiltonian(pos, p, 0.9))
    return h.max() < 1e-12, f"max |H| = {h.max():.2e}"


@check("Schwarzschild shadow = 3*sqrt(3) M")
def _():
    # Spin DISABLED first, before anything relies on it (§10.2).
    b = shadow_edge(0.0, 1.0, 12.0)
    want = 3 * np.sqrt(3)
    err = abs(b - want) / want * 100
    return err < 1.0, f"{b:.4f} vs {want:.4f}  ({err:.3f}%)"


@check("Kerr a=0.9 prograde shadow edge")
def _():
    want = kerr.critical_impact_parameter(0.9, prograde=True)
    b = shadow_edge(0.9, 0.5, 12.0, side=kerr.PROGRADE_SIGN)
    err = abs(b - want) / want * 100
    return err < 2.0, f"{b:.4f} vs analytic {want:.4f}  ({err:.3f}%)"


@check("Kerr a=0.9 retrograde shadow edge")
def _():
    want = kerr.critical_impact_parameter(0.9, prograde=False)
    b = shadow_edge(0.9, 0.5, 12.0, side=-kerr.PROGRADE_SIGN)
    err = abs(b - want) / want * 100
    return err < 2.0, f"{b:.4f} vs analytic {want:.4f}  ({err:.3f}%)"


@check("the shadow is asymmetric, and PROGRADE_SIGN names the right side")
def _():
    # THE sign-convention test. The prograde side has the smaller critical
    # impact parameter, so its shadow edge sits closer in. This is settled by
    # measurement rather than by inspection: the first version of this suite
    # assumed the opposite sign and was corrected by exactly this check.
    pro = shadow_edge(0.9, 0.5, 12.0, side=kerr.PROGRADE_SIGN)
    ret = shadow_edge(0.9, 0.5, 12.0, side=-kerr.PROGRADE_SIGN)
    ok = pro < ret and (ret - pro) > 1.0
    sgn = "+y" if kerr.PROGRADE_SIGN > 0 else "-y"
    return ok, f"prograde({sgn}) {pro:.3f} < retrograde {ret:.3f}"


@check("null condition held along every geodesic")
def _():
    bs = np.linspace(-15, 15, 48)
    pos, p, out, _ = shoot(bs, 0.9)
    esc = out == Outcome.ESCAPED
    h = np.abs(kerr.hamiltonian(pos[esc], p[esc], 0.9))
    # The single-precision floor is 1e-5; the reference is double and should be
    # far better, but the BOUND that matters downstream is the FP32 one (§5.5).
    return h.max() < 1e-5, f"max |H| on escape = {h.max():.2e} (FP32 budget 1e-5)"


@check("step-budget exhaustion is not counted as escape")
def _():
    # Deliberately starve the integrator; nothing may be scored ESCAPED that
    # merely ran out of steps.
    bs = np.linspace(-8, 8, 24)
    _, _, out, _ = shoot(bs, 0.9, max_steps=12)
    n_esc = int((out == Outcome.ESCAPED).sum())
    n_exh = int((out == Outcome.EXHAUSTED).sum())
    return n_esc == 0 and n_exh > 0, f"{n_exh} exhausted, {n_esc} wrongly escaped"


@check("every equatorial crossing recorded, not just the first")
def _():
    # Uses the REAL camera geometry, near edge-on. Rays passing close to the
    # hole are bent back through the equatorial plane, and the 2nd and 3rd
    # crossings are the far side of the disk arcing over and under the shadow
    # -- the entire iconic image. Miss them and you have a flat annulus with a
    # hole in it, which looks deliberate and is wrong (§3.3).
    pos, p = kerr.camera_rays(60, 24, 0.9, inclination_deg=100.0, half_width=20.0)
    _, _, _, cross = kerr.trace(pos, p, 0.9, max_steps=6000, record_crossings=True,
                                disk_in=kerr.isco_radius(0.9), disk_out=20.0)
    counts = {}
    for idx, _, _, _ in cross:
        for i in idx:
            counts[int(i)] = counts.get(int(i), 0) + 1
    multi = sum(1 for v in counts.values() if v >= 2)
    triple = sum(1 for v in counts.values() if v >= 3)
    return multi > 0, (f"{len(counts)} rays hit the disk; "
                       f"{multi} crossed 2+ times, {triple} crossed 3+")


@check("lensing off: only rays aimed at the horizon are captured")
def _():
    # "Lensing off" means FLAT SPACETIME, not spin zero -- a=0 is still
    # Schwarzschild and still bends light. With f=0 a photon travels in a
    # straight line, so exactly those rays whose impact parameter is inside the
    # horizon are captured, and no others. The first version of this check set
    # a=0 and was therefore vacuous.
    rp = kerr.horizon_radius(0.9)
    bs = np.linspace(-12, 12, 96)
    _, _, out_flat, _ = shoot(bs, 0.9, flat=True)
    _, _, out_lens, _ = shoot(bs, 0.9, flat=False)
    flat_in = int((out_flat == Outcome.HORIZON).sum())
    lens_in = int((out_lens == Outcome.HORIZON).sum())
    expect_flat = int((np.abs(bs) < rp).sum())
    ok = abs(flat_in - expect_flat) <= 2 and lens_in > flat_in + 4
    return ok, (f"flat {flat_in} captured (straight lines predict {expect_flat}), "
                f"lensed {lens_in} -- lensing bends {lens_in - flat_in} more in")


def main():
    print("Kerr geodesic validation (NULL.md §10.2)\n")
    failed = 0
    for name, fn in CHECKS:
        try:
            ok, detail = fn()
        except Exception as e:
            ok, detail = False, f"raised {type(e).__name__}: {e}"
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}")
        print(f"         {detail}")
        if not ok:
            failed += 1
    print()
    if failed:
        print(f"{failed} of {len(CHECKS)} checks FAILED -- no bake until these pass")
        return 1
    print(f"all {len(CHECKS)} checks pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
