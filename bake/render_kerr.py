#!/usr/bin/env python3
"""Render the Kerr hero to the HDR intermediate (NULL.md §3.3, §5.2).

The reference renderer. Slow by design -- it exists to be ground truth for the
accelerated implementation, and to render proxy frames for look-tests.

Per disk crossing:
    g      = (p.u)_observer / (p.u)_emitter
    I_obs  = g^4 * I_emit(T_local)
    T_obs  = g * T_local

The exponent 4 is why the approaching limb overwhelms the receding one, and it
is the most important line here (§3.3). T_obs is STORED rather than inferred,
so the quantiser never inverts the Planckian locus out of an RGB triple.
"""

import argparse
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kerr
import ladder
from formats import LUMA, write_hdr
from derive_palette import planckian_xy, xy_to_linear_srgb, T_MIN, T_MAX

import scene
T_INNER = scene.T_INNER  # emission temperature at the inner edge -- §3.5


def emitter_dot_p(P, K, r, a):
    """(p.u) for a prograde circular emitter at the crossing point.

    u^mu has t and phi components only; in Cartesian Kerr-Schild that is
    u = ut * d/dt + uphi * d/dphi, and d/dphi = -y d/dx + x d/dy.
    """
    ut, uphi = kerr.disk_four_velocity(r, a)
    x, y = P[:, 1], P[:, 2]
    # p.u = p_mu u^mu
    return K[:, 0] * ut + uphi * (-y * K[:, 1] + x * K[:, 2])


def render(cols, rows, a=scene.SPIN, inclination=scene.INCLINATION,
           half_width=scene.HALF_WIDTH,
           r_out=ladder.R_OUT, t_frac=0.0, bands=None, max_steps=3000,
           supersample=1, progress=False):
    """One frame as (rows, cols, 4): linear R, G, B, T_obs in Kelvin."""
    r_in = kerr.isco_radius(a)
    bands = bands if bands is not None else ladder.build()
    ss = max(1, supersample)

    acc_rgb = np.zeros((rows * cols, 3))
    acc_t = np.zeros(rows * cols)
    acc_w = np.zeros(rows * cols)

    for sy in range(ss):
        for sx in range(ss):
            pos, p = kerr.camera_rays(cols * ss, rows * ss, a,
                                      inclination_deg=inclination,
                                      half_width=half_width)
            # Take the (sx, sy) sub-sample of the supersampled grid.
            grid = np.arange(cols * ss * rows * ss).reshape(rows * ss, cols * ss)
            take = grid[sy::ss, sx::ss].ravel()
            P, K = pos[take].copy(), p[take].copy()

            t0 = time.time()
            _, _, _, cross = kerr.trace(P, K, a, max_steps=max_steps,
                                        record_crossings=True,
                                        disk_in=r_in, disk_out=r_out)
            if progress:
                print(f"    trace {len(take)} rays in {time.time()-t0:.1f}s, "
                      f"{sum(len(c[0]) for c in cross)} crossings", flush=True)

            for idx, Pc, Kc, rc in cross:
                phi = np.arctan2(Pc[:, 2], Pc[:, 1])

                # The pattern drives TEMPERATURE, not luminance. Brightness
                # follows as T^4, so hue shifts and the colour plane carries
                # the motion (§3.4).
                mod = np.zeros_like(rc)
                for b in bands:
                    env = b["amp"] * np.exp(-(((rc - b["r"]) / (b["width"] * b["r"])) ** 2))
                    ang = (b["m"] * phi
                           - 2 * np.pi * ((b["n"] * t_frac) % 1.0)
                           + b["phase"])
                    mod += env * np.cos(ang)

                # The depth is already folded into the band amplitudes (§3.4).
                t_local = kerr.disk_temperature(rc, r_in, T_INNER) * (1.0 + mod)
                t_local = np.clip(t_local, 200.0, 1e6)

                # Redshift. The observer is at rest at infinity, so
                # (p.u)_obs = -p_t = E = 1 by construction.
                pu_em = emitter_dot_p(Pc, Kc, rc, a)
                with np.errstate(divide="ignore", invalid="ignore"):
                    g = 1.0 / np.abs(pu_em)
                g = np.nan_to_num(g, nan=0.0, posinf=0.0)

                t_obs = np.clip(t_local * g, T_MIN, T_MAX)
                # I_obs = g^4 I_emit, and I_emit ~ T^4 for a blackbody.
                intensity = (g ** 4) * (t_local / T_INNER) ** 4

                keep = np.isfinite(intensity) & (intensity > 0)
                if not keep.any():
                    continue
                ii, tt, inten = idx[keep], t_obs[keep], intensity[keep]

                # Colour is a function of ONE variable (§4.5): quantise the
                # temperature and look the chromaticity up once per bin.
                q = np.clip(np.round(tt / 100.0) * 100.0, T_MIN, T_MAX)
                for tk in np.unique(q):
                    sel = q == tk
                    rgb = np.array(xy_to_linear_srgb(*planckian_xy(float(tk))))
                    w = inten[sel]
                    np.add.at(acc_rgb, ii[sel], rgb[None, :] * w[:, None])
                    # Observed T is the luminance-weighted mean. The moments
                    # (L, L*T) remain additive over crossings and subsamples,
                    # matching box_average and on-screen master resampling.
                    light = w * float(rgb @ LUMA)
                    np.add.at(acc_t, ii[sel], tt[sel] * light)
                    np.add.at(acc_w, ii[sel], light)

    out = np.zeros((rows * cols, 4), dtype=np.float32)
    lit = acc_w > 0
    out[lit, :3] = acc_rgb[lit] / (ss * ss)
    out[lit, 3] = acc_t[lit] / acc_w[lit]
    return out.reshape(rows, cols, 4)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cols", type=int, default=160)
    ap.add_argument("--rows", type=int, default=45)
    ap.add_argument("--frames", type=int, default=1)
    ap.add_argument("--supersample", type=int, default=1)
    ap.add_argument("--max-steps", type=int, default=3000)
    ap.add_argument("--inclination", type=float, default=scene.INCLINATION)
    ap.add_argument("--half-width", type=float, default=28.0)
    ap.add_argument("--out", required=True)
    ap.add_argument("--progress", action="store_true")
    args = ap.parse_args()

    outdir = Path(args.out); outdir.mkdir(parents=True, exist_ok=True)
    bands = ladder.build()
    for i in range(args.frames):
        t0 = time.time()
        arr = render(args.cols, args.rows, t_frac=i / max(args.frames, 1),
                     bands=bands, supersample=args.supersample,
                     max_steps=args.max_steps, inclination=args.inclination,
                     half_width=args.half_width, progress=args.progress)
        write_hdr(outdir / f"{i:04d}.hdr", arr)
        lit = (arr[..., 3] > 0).mean()
        print(f"  frame {i}: {time.time()-t0:.1f}s, {lit*100:.1f}% of cells lit",
              flush=True)
    print(f"{args.frames} frame(s) of {args.cols}x{args.rows} -> {outdir}")


if __name__ == "__main__":
    main()
