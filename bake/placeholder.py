#!/usr/bin/env python3
"""The analytic placeholder hero (NULL.md §5.4).

Every hard problem in this system except the physics lives DOWNSTREAM of the
simulation, so all of it is built and proven against a cheap stand-in that
emits the same HDR intermediate.

Two rules about this program:

  * Nothing downstream may be able to tell it is a placeholder. If any consumer
    needs to know, the artefact contract (§3.1) is wrong.

  * It is NOT physically meaningful. It needs the right shape, dynamic range
    and temporal statistics to exercise tone mapping and hysteresis honestly,
    and nothing more. In particular a tone curve tuned on this WILL be wrong
    for real physics (§4.1), because g^4 beaming redistributes the light.

It uses the real mode ladder (§3.4), so loop behaviour is genuine rather than
approximated -- which is the part that has to be real for the quantiser's loop
closure to mean anything.
"""

import argparse
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ladder
from derive_palette import planckian_xy, xy_to_linear_srgb

R_ISCO = 2.32          # prograde ISCO at a = 0.9 (§3.3)
T_INNER = 20000.0      # emission temperature at the inner edge, Kelvin


# The real hero is framed at 28 M half-width (§3.5). The stand-in is framed
# tighter, because its crude radial warp does not spread light across the frame
# the way real lensing does, and it must present the pipeline with a comparable
# INK FRACTION or the tone curve is tuned against statistics that will not
# recur. This is a property of the stand-in, not a disagreement with §3.5.
PLACEHOLDER_HALF_WIDTH = 20.0


def render_frame(cols, rows, t_frac, bands, half_width=PLACEHOLDER_HALF_WIDTH, inclination_deg=100.0):
    """One frame of the stand-in, as linear RGB + observed temperature."""
    # Cells are 1:2, so world units per cell differ per axis. Sampling the
    # cell's own footprint is what makes aspect exact (§2.5).
    xs = (np.arange(cols) + 0.5) / cols * 2.0 - 1.0
    ys = (np.arange(rows) + 0.5) / rows * 2.0 - 1.0
    X = xs[None, :] * half_width
    Y = ys[:, None] * half_width * (rows / cols) * 2.0

    inc = math.radians(inclination_deg)
    # Flatten the disk by the viewing angle. 100 degrees is 80 flipped, which
    # puts the far side arcing UNDER the shadow (§3.5).
    Yp = Y / max(abs(math.cos(inc)), 1e-3)

    r = np.hypot(X, Yp)
    phi = np.arctan2(Yp, X)

    # Crude stand-in for lensing: pull the far edge over the shadow. Not
    # physical, and not pretending to be.
    warp = 1.0 + 0.35 * np.exp(-((r - R_ISCO) / 3.0) ** 2) * np.sin(phi)
    r = r * warp

    disk = (r >= R_ISCO) & (r <= ladder.R_OUT)

    with np.errstate(divide="ignore", invalid="ignore"):
        # Shakura-Sunyaev: T falls as r^(-3/4)
        temp = np.where(disk, T_INNER * (r / R_ISCO) ** -0.75, 0.0)

    # Modulation from the real ladder, evaluated per cell.
    mod = np.zeros_like(r)
    for b in bands:
        env = b["amp"] * np.exp(-(((r - b["r"]) / (b["width"] * b["r"])) ** 2))
        ang = b["m"] * phi - 2.0 * math.pi * ((b["n"] * t_frac) % 1.0) + b["phase"]
        mod += env * np.cos(ang)
    temp = temp * (1.0 + 0.18 * mod)

    # A one-sided brightness asymmetry standing in for Doppler beaming. The
    # real thing is g^4 and far more violent; this only has to exercise the
    # dynamic range.
    beam = 1.0 + 2.5 * np.cos(phi) * np.clip(3.0 / np.maximum(r, 0.5), 0, 1.5)
    beam = np.clip(beam, 0.05, None)

    intensity = np.where(disk, (temp / T_INNER) ** 4 * beam, 0.0)

    temp = np.clip(temp, 0.0, 25000.0)
    out = np.zeros((rows, cols, 4), dtype=np.float32)
    lit = disk & (temp > 1667.0)

    # Colour from temperature, exactly as the real hero will: one variable.
    uniq = np.unique(np.round(temp[lit] / 50.0) * 50.0) if lit.any() else []
    lut = {}
    for tk in uniq:
        tk = float(min(max(tk, 1667.0), 25000.0))
        lut[tk] = xy_to_linear_srgb(*planckian_xy(tk))
    if lit.any():
        keys = np.array(sorted(lut))
        idx = np.searchsorted(keys, np.clip(np.round(temp[lit] / 50.0) * 50.0, keys[0], keys[-1]))
        idx = np.clip(idx, 0, len(keys) - 1)
        cols_rgb = np.array([lut[k] for k in keys], dtype=np.float32)[idx]
        I = intensity[lit][:, None]
        out[..., :3][lit] = cols_rgb * I
        out[..., 3][lit] = temp[lit]
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cols", type=int, default=320)
    ap.add_argument("--rows", type=int, default=90)
    ap.add_argument("--frames", type=int, default=ladder.FRAMES)
    ap.add_argument("--out", required=True, help="output directory for HDR frames")
    args = ap.parse_args()

    from formats import write_hdr
    bands = ladder.build()
    outdir = Path(args.out); outdir.mkdir(parents=True, exist_ok=True)

    for i in range(args.frames):
        arr = render_frame(args.cols, args.rows, i / args.frames, bands)
        write_hdr(outdir / f"{i:04d}.hdr", arr)
        if (i + 1) % 40 == 0 or i == args.frames - 1:
            print(f"  {i+1}/{args.frames}", flush=True)

    print(f"{args.frames} frames of {args.cols}x{args.rows} -> {outdir}")


if __name__ == "__main__":
    main()
