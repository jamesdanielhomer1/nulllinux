#!/usr/bin/env python3
"""The disk mode ladder — the single source of truth (NULL.md §3.4).

Every consumer reads the table from here: the simulation, the placeholder, and
the checks. Three copies of a table drift, and only one of them is the physics
(§10.3).

The pattern is a sum of azimuthal modes whose temporal frequencies are
INTEGERS, so each term is periodic over the loop by construction and the loop
closes with no crossfade:

    pattern(r, phi, t) = SUM_k  A_k(r) cos( m_k phi - n_k w_loop t + ph_k )
"""

import math

# The ISCO comes from the metric module, not from a second copy of the closed
# form. There is no import cycle to avoid -- kerr.py imports nothing from here
# -- and two copies of one formula is the drift §10.3 exists to prevent. They
# agreed exactly when this was checked, which is how drift always starts.
from kerr import isco_radius as _isco

A_SPIN = 0.6        # Kerr spin parameter, prograde
R_OUT = 20.0        # anchors n = 1; changing it re-derives every n_k (§3.4.1)
FRAMES = 240
FPS = 24
PITCH_DEG = 15.0    # logarithmic spiral pitch (§3.4.3)
TAPER = -0.45       # amplitude falls outward, gently (§3.4.4)
ENVELOPE_W = 0.17   # gaussian envelope width, as a fraction of r_k

# How far the pattern moves the local temperature, as a fraction.
#
# Intensity follows as T^4, so this is raised to the fourth before it reaches
# the image: a depth of 0.18 against a normalised modulation gives an intensity
# ratio of about 4x between crest and trough, which reads as texture. Left
# UNNORMALISED it was 347x -- the pattern stopped modulating the disk and
# started gating it, punching voids wherever several envelopes happened to
# align negative.
MODULATION_DEPTH = 0.18

NYQUIST_HARD = FRAMES // 2      # above this the pattern strobes backwards
NYQUIST_COMFORT = 30            # at least 8 frames per pattern cycle

# The slowest a band's pattern may turn, in seconds per full revolution.
#
# A band cos(m*phi - n*w*t) has constant phase where m*phi = n*w*t, so the
# pattern turns once every LOOP_PERIOD * m / n seconds. Nyquist bounds what can
# be SAMPLED without strobing; this bounds what can be WATCHED without
# shimmering, which is a stricter and separate question. At 1.1 s per
# revolution the inner bands read as noise rather than motion.
#
# Physically the shear really is faster inward, and this does not pretend
# otherwise -- it says that where the disk turns faster than the eye can
# follow, the honest thing is to carry NO mode rather than an aliased one. The
# inner disk is smooth for the same reason the frame rate is finite.
MIN_REVOLUTION_S = 2.0

# Bands must sit in real material: outside the ISCO, inside r_out. The ISCO
# MOVES WITH SPIN -- 6 M at a=0 to about 1.24 M at a=0.998 -- so a hard-coded
# table is a table for one particular black hole. The previous one was written
# for a=0.9, where q reaches about 20 at the ISCO; at a=0.6 it reaches 11.1,
# and three of its twelve bands sat INSIDE the inner edge, modulating material
# that is not there. They were also the three fastest.
ISCO_MARGIN = 1.5 * ENVELOPE_W   # keep the envelope's shoulder out of the hole

LOOP_PERIOD = FRAMES / FPS                 # exactly 10.000 s
OMEGA_LOOP = 2.0 * math.pi / LOOP_PERIOD


def radius_for(m, n, a=A_SPIN, r_out=R_OUT):
    """Invert the resonance condition: choose the integers, let the radius follow.

    q(r) = Omega(r)/Omega(r_out) = (r_out^1.5 + a) / (r^1.5 + a);  set q = n/m.

    Picking a radius by hand and rounding n afterwards puts the rounding error
    straight into the shear, leaving the mode turning at a speed the disk does
    not have where it sits. Done this way the snap error at the peak of every
    envelope is ZERO by construction (§3.4.1).
    """
    return ((m / n) * (r_out ** 1.5 + a) - a) ** (2.0 / 3.0)


def spiral_phase(m, r, r_out=R_OUT, pitch_deg=PITCH_DEG):
    """Put every band's crest on one logarithmic spiral (§3.4.3).

    With all phases zero every band crests at the same azimuth at t=0 and the
    disk shows a radial SPOKE through every annulus, which no accretion disk
    does. Phase does not change frequency, so this costs nothing -- and no
    whole-frame metric can see the defect it fixes, because the spoke is
    two-sided and cancels in any azimuthal sum.
    """
    return -m * math.log(r / r_out) / math.tan(math.radians(pitch_deg))


def _peak_modulation(bands, r_out, samples=256):
    """The largest |sum of bands| anywhere on the disk.

    The per-band amplitudes are RELATIVE WEIGHTS between bands. Nothing about
    them bounds their SUM, and where several envelopes overlap they add -- so
    the field has to be measured, not assumed.
    """
    import itertools
    r = [r_out * (0.10 + 0.90 * i / (samples - 1)) for i in range(samples)]
    phi = [-math.pi + 2 * math.pi * i / (samples - 1) for i in range(samples)]
    peak = 0.0
    for rr, pp in itertools.product(r, phi):
        tot = 0.0
        for b in bands:
            e = (rr - b["r"]) / (b["width"] * b["r"])
            if abs(e) > 4.0:
                continue
            tot += b["amp"] * math.exp(-(e * e)) * math.cos(b["m"] * pp + b["phase"])
        peak = max(peak, abs(tot))
    return peak


def modes_for(a=A_SPIN, r_out=R_OUT, max_arms=6, spacing=1.18):
    """Choose (m, n) from the constraints rather than from a stored table.

    Two independent bounds decide which bands can exist at all:

      * the band must sit in real material, outside the ISCO;
      * its pattern must turn no faster than MIN_REVOLUTION_S.

    Because the radius depends only on the RATIO n/m, those bounds leave many
    (m, n) sharing one radius, and the arm count is the free choice among them.
    It is spent on making arms fall outward-to-inward: six arms crammed into
    the innermost annulus is the same structure everywhere and reads as
    repetition, while a falling count gives each annulus its own character.
    That was the intent of the original hand-written table and it is preserved
    here as a rule rather than as a list.
    """
    r_isco = _isco(a)
    r_min = r_isco * (1.0 + ISCO_MARGIN)
    q_max = (r_out ** 1.5 + a) / (r_min ** 1.5 + a)

    cands = []
    for m in range(1, max_arms + 1):
        for n in range(1, NYQUIST_COMFORT + 1):
            q = n / m
            if q < 1.0 or q > q_max:
                continue                      # outside the disk
            if LOOP_PERIOD * m / n < MIN_REVOLUTION_S:
                continue                      # turns faster than it can be watched
            cands.append((radius_for(m, n, a, r_out), m, n))
    if not cands:
        raise ValueError("no band satisfies both the ISCO and revolution bounds")

    r_in = min(r for r, _, _ in cands)
    steps = max(1, int(math.log(r_out / r_in) / math.log(spacing)))
    chosen, seen = [], set()
    last_m = max_arms
    for k in range(steps + 1):
        # Log-spaced target radii, with the arm count falling linearly with
        # log-radius from max_arms at the rim to one at the inner edge.
        f = k / steps
        target = r_out * (r_in / r_out) ** f
        want_m = max(1, round(max_arms - f * (max_arms - 1)))

        # Falling arms is ENFORCED, not merely preferred. Expressed as a tie-
        # break it loses to whichever radius happens to land nearest the
        # target, which put six arms back in the middle of a falling sequence.
        pool = [c for c in cands
                if c[1] <= last_m and (c[1], c[2]) not in seen
                and not (chosen and c[0] > chosen[-1][0] / 1.02)]
        if not pool:
            continue
        # Weighted, not lexicographic: a band may shift a fraction of a spacing
        # step to reach a better arm count, since the radii are dense and the
        # arm counts are few.
        r, m, n = min(pool, key=lambda c:
                      (math.log(c[0] / target) / math.log(spacing)) ** 2
                      + 0.35 * abs(c[1] - want_m))
        seen.add((m, n))
        chosen.append((r, m, n))
        last_m = m
    return [(m, n) for _, m, n in chosen]


def build(a=A_SPIN, r_out=R_OUT):
    bands = []
    for m, n in modes_for(a, r_out):
        r = radius_for(m, n, a, r_out)
        bands.append({
            "m": m, "n": n, "r": r,
            "amp": (r / r_out) ** TAPER,
            "phase": spiral_phase(m, r, r_out),
            "width": ENVELOPE_W,
            "frames_per_cycle": FRAMES / n,
        })

    # NORMALISE THE SUM, not the individual bands. The taper sets how the
    # amplitude is distributed across radius; this sets how far the whole
    # pattern may swing, which is a different decision and has to be made
    # explicitly or the two get conflated.
    # The emitted amplitudes carry the depth as well as the normalisation, so
    # a consumer computes 1 + sum(bands) and nothing else. The depth was
    # previously a bare 0.18 written into BOTH renderers, which is two copies
    # of one number and exactly the drift §10.3 is about.
    peak = _peak_modulation(bands, r_out)
    if peak > 0:
        for b in bands:
            b["amp"] *= MODULATION_DEPTH / peak
    validate(bands, a)
    return bands


def validate(bands, a=A_SPIN):
    r_isco = _isco(a)
    for b in bands:
        if b["r"] < r_isco:
            raise ValueError(f"band at r={b['r']:.3f} is inside the ISCO {r_isco:.3f}: "
                             "there is no material there to modulate")
        rev = LOOP_PERIOD * b["m"] / b["n"]
        if rev < MIN_REVOLUTION_S:
            raise ValueError(f"band (m={b['m']}, n={b['n']}) turns once every "
                             f"{rev:.2f}s, under the {MIN_REVOLUTION_S}s bound")
    for b in bands:
        if b["n"] >= NYQUIST_HARD:
            raise ValueError(f"n={b['n']} at or above the Nyquist limit {NYQUIST_HARD}: "
                             "the pattern would strobe backwards")
        if b["n"] > NYQUIST_COMFORT:
            raise ValueError(f"n={b['n']} exceeds the comfort bound {NYQUIST_COMFORT} "
                             f"({b['frames_per_cycle']:.1f} frames per cycle, want >= 8)")
    return True


def pattern(r, phi, t_frac, bands=None):
    """Modulation at (r, phi) and loop fraction t in [0,1).

    t is a FRACTION of the loop, and the fractional part of n*t is taken before
    scaling by 2*pi. Computing cos(m*phi - n*2*pi*t) directly is not bit-exact
    at t=1 for large n in single precision, and the loop then fails to close by
    a small but non-zero amount (§5.5).
    """
    bands = bands if bands is not None else build()
    total = 0.0
    for b in bands:
        env = b["amp"] * math.exp(-(((r - b["r"]) / (b["width"] * b["r"])) ** 2))
        if env < 1e-6:
            continue
        ang = b["m"] * phi - 2.0 * math.pi * ((b["n"] * t_frac) % 1.0) + b["phase"]
        total += env * math.cos(ang)
    return total


if __name__ == "__main__":
    bands = build()
    print(f"spin a={A_SPIN}  r_out={R_OUT} M  {FRAMES} frames @ {FPS} fps "
          f"= {LOOP_PERIOD:.3f} s loop")
    print(f"Nyquist: hard n<{NYQUIST_HARD}, comfort n<={NYQUIST_COMFORT}\n")
    print(f"  {'r/M':>7} {'m':>3} {'n':>4} {'frames/cyc':>11} {'amp':>7} {'phase':>8} {'snap err':>9}")
    for b in bands:
        # The snap error at the envelope peak is zero BY CONSTRUCTION. Printing
        # it is the check that the inversion is actually being used.
        q_pattern = b["n"] / b["m"]
        q_kepler = (R_OUT ** 1.5 + A_SPIN) / (b["r"] ** 1.5 + A_SPIN)
        err = abs(q_pattern - q_kepler) / q_kepler * 100.0
        print(f"  {b['r']:>7.2f} {b['m']:>3} {b['n']:>4} {b['frames_per_cycle']:>11.1f} "
              f"{b['amp']:>7.3f} {b['phase']:>8.3f} {err:>8.2f}%")
    print(f"\n  all {len(bands)} bands validated against the Nyquist bounds")
