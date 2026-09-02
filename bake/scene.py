#!/usr/bin/env python3
"""The settled scene — one owner (NULL.md Appendix A, §3.5, §10.3).

Every consumer takes the scene from here: the reference tracer, the bake, the
preview, and the cross-validation's invocation of the shader.

This module exists because those numbers had already drifted into THREE
disagreeing copies, and the drift was invisible until the cross-validation
started failing and blamed the shader:

    bake.py          inclination 70, T_inner 5000   (current)
    render_kerr.py   inclination 80, T_inner 20000  (stale)
    gpu/src/main.rs  a 0.9, inclination 80, T 20000 (stale, compiled in)

The cross-validation passed no scene flags at all, so it compared a reference
at a=0.6 against a shader at a=0.9 and reported "the shader does not match".
The shader was fine. Two copies of a number are a bug waiting for a reason to
appear; three are a bug that has already happened.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kerr        # noqa: E402
import ladder      # noqa: E402

SPIN = ladder.A_SPIN          # §3.3
R_OUT = ladder.R_OUT          # anchors the mode ladder (§3.4.1)
INCLINATION = 85.0            # §3.5 -- 5° above the disk plane
HALF_WIDTH = 32.0             # §3.5
T_INNER = 5000.0              # §3.5 -- decides the colour of the whole image


def r_in(a=SPIN):
    """The disk's inner edge: the ISCO, which MOVES WITH SPIN."""
    return kerr.isco_radius(a, prograde=True)


def gpu_flags(a=SPIN, inclination=INCLINATION, half_width=HALF_WIDTH,
              r_out=R_OUT, t_inner=T_INNER):
    """Every scene flag the shader needs, so no caller relies on its defaults.

    The shader now REFUSES to run without these rather than substituting its
    own, because a silent default is how the two tracers came to disagree.
    """
    # repr() of a numpy scalar is "np.float64(3.83...)", which the shader
    # cannot parse. Coerce to a plain float: these cross a process boundary as
    # text, so the type on this side is not the type that matters.
    f = lambda v: repr(float(v))
    return ["--spin", f(a),
            "--inclination", f(inclination),
            "--half-width", f(half_width),
            "--r-in", f(r_in(a)),
            "--r-out", f(r_out),
            "--t-inner", f(t_inner)]


if __name__ == "__main__":
    print(f"spin        {SPIN}")
    print(f"inclination {INCLINATION}")
    print(f"half-width  {HALF_WIDTH}")
    print(f"r_in (ISCO) {r_in():.6f}")
    print(f"r_out       {R_OUT}")
    print(f"T_inner     {T_INNER}")
