#!/usr/bin/env python3
"""Derive this screen's ASCII from the packed master (NULL.md §5.3, §0.5).

WHY NOT SHIP THE ASCII. Quantised cells are a FIXED grid. The package used to
carry forty-five of them -- nine strikes by five rungs -- and a screen was given
whichever came closest, which is exact on 1920x1080 and 2560x1440 and on
nothing else. A 1366x768 panel got a 1280x720 hero with a border round it,
because 1366 = 2 x 683 and 683 is prime and no rung divides it.

The master is not a grid, it is a rendering. Ship that (9 MB, smaller than the
forty-five it replaces) and any screen can derive its own grid, exactly.

THE FRAMING IS NOT NEGOTIABLE. The master is 640x180 cells of one camera at one
half-width, so 640:180 is the shape of the image, not an arbitrary array size.
A target grid with a different ratio is a different framing, and §5.3 is
explicit that a different framing needs its own camera rather than a stretched
copy of someone else's. So the hero is fitted INSIDE the target at its own
ratio and centred; whatever is left over is void, which for a black hole in
empty space is the correct thing for it to be.

In practice almost nothing is left over. Cells are half as wide as they are
tall, so a 16:9 screen at any strike lands within one cell of 640:180.

Resampling happens in the HDR domain and quantisation happens once, afterwards
-- never the other way round. Glyph indices cannot be averaged: the mean of '.'
and '@' is not a tone, it is a different glyph (§5.3).
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from formats import write_cells
from pack_master import read_master
from quantise import Ramp, quantise_sequence


def area_weights(n_in, n_out):
    """(n_out, n_in) matrix whose rows average the input spans exactly.

    Not nearest-neighbour and not bilinear: every input cell contributes in
    proportion to how much of it the output cell covers, which is what makes
    this an average of radiance rather than a sample of it.
    """
    w = np.zeros((n_out, n_in), dtype=np.float64)
    scale = n_in / n_out
    for i in range(n_out):
        lo, hi = i * scale, (i + 1) * scale
        first, last = int(np.floor(lo)), int(np.ceil(hi))
        for j in range(first, min(last, n_in)):
            w[i, j] = min(hi, j + 1) - max(lo, j)
    s = w.sum(axis=1, keepdims=True)
    return (w / np.where(s == 0, 1, s)).astype(np.float32)


def fit_preserving_aspect(master_cols, master_rows, cols, rows):
    """The largest sub-grid of (cols, rows) with the master's ratio."""
    by_width = (cols, max(1, round(cols * master_rows / master_cols)))
    by_height = (max(1, round(rows * master_cols / master_rows)), rows)
    if by_width[1] <= rows:
        return by_width
    return by_height


def derive(master_path, cols, rows, ramp_doc, pal_meta, *, log=print, **opts):
    m_cols, m_rows, fps, tone, arr = read_master(master_path)
    # The curve that was swept for this master. A caller may override it, but
    # the default is the one the bake itself used -- otherwise every screen
    # gets a different exposure from the one the hero was tuned for.
    opts.setdefault("black_pct", float(tone[0]))
    opts.setdefault("white_pct", float(tone[1]))
    opts.setdefault("gamma", float(tone[2]))
    hc, hr = fit_preserving_aspect(m_cols, m_rows, cols, rows)
    log(f"master {m_cols}x{m_rows} -> hero {hc}x{hr} inside a {cols}x{rows} grid "
        f"({100*hc*hr//(cols*rows)}% of the cells)")

    Wc = area_weights(m_cols, hc)
    Wr = area_weights(m_rows, hr)

    L_frames, T_frames = [], []
    for f in range(arr.shape[0]):
        # Separable area resample: rows then columns, in the HDR domain.
        lt = np.einsum('ij,jkc->ikc', Wr, arr[f])
        lt = np.einsum('ij,kjc->kic', Wc, lt)
        L = np.zeros((rows, cols), dtype=np.float32)
        T = np.full((rows, cols), lt[..., 1].min(), dtype=np.float32)
        y0, x0 = (rows - hr) // 2, (cols - hc) // 2
        L[y0:y0 + hr, x0:x0 + hc] = lt[..., 0]
        T[y0:y0 + hr, x0:x0 + hc] = lt[..., 1]
        L_frames.append(L); T_frames.append(T)

    ramp = Ramp(ramp_doc)
    pal_temps = np.array(pal_meta["temperatures_K"], dtype=np.float32)
    glyphs, colours, black, white = quantise_sequence(
        L_frames, T_frames, ramp, pal_temps, log=log, **opts)
    return glyphs, colours, fps, ramp


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--master", default="assets/master.hero")
    ap.add_argument("--cols", type=int, required=True)
    ap.add_argument("--rows", type=int, required=True)
    ap.add_argument("--ramp", default="assets/ramp-bake.json")
    ap.add_argument("--palette-meta", default="assets/palette.json")
    ap.add_argument("--palette", default="assets/palette.bin")
    ap.add_argument("--out", required=True)
    # Default to the master's own swept curve, not to a number written here.
    ap.add_argument("--black-pct", type=float, default=None)
    ap.add_argument("--white-pct", type=float, default=None)
    ap.add_argument("--gamma", type=float, default=None)
    ap.add_argument("--hysteresis", type=float, default=0.25)
    ap.add_argument("--k-residual", type=float, default=1.5)
    args = ap.parse_args()

    ramp_doc = json.loads(Path(args.ramp).read_text())
    pal_meta = json.loads(Path(args.palette_meta).read_text())
    pal_raw = Path(args.palette).read_bytes()
    palette = [tuple(pal_raw[i:i + 3]) for i in range(0, len(pal_raw), 3)]

    glyphs, colours, fps, ramp = derive(
        args.master, args.cols, args.rows, ramp_doc, pal_meta,
        **{k: v for k, v in (("black_pct", args.black_pct),
                             ("white_pct", args.white_pct),
                             ("gamma", args.gamma)) if v is not None},
        hysteresis=args.hysteresis, k_residual=args.k_residual)

    write_cells(args.out, args.cols, args.rows, fps, "".join(ramp.chars),
                palette, glyphs, colours)
    n = Path(args.out).stat().st_size
    print(f"  -> {args.out}  {n:,} bytes")


if __name__ == "__main__":
    main()
