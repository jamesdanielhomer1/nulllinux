#!/usr/bin/env python3
"""HDR cells -> quantised animation (NULL.md §4.1-4.4, §10.3).

Three things this must get right, and each has a check:

  GLOBAL EXPOSURE.  The black and white points are percentiles over the WHOLE
  sequence. Per-frame auto-exposure makes the image pulse as the object
  rotates.

  HYSTERESIS.  A cell changes glyph only once luminance crosses a ramp
  boundary by a margin, or cells near a boundary flip frame to frame and the
  render sizzles. This is STATEFUL across frames, so the state is iterated to
  a fixed point over the looping sequence before anything is emitted.

  LOOP CLOSURE.  Frame 0 is re-quantised from the final hysteresis state and
  must come back byte-identical, or nothing is written.
"""

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from formats import read_hdr, write_cells

# Rec.709 luma from linear RGB.
LUMA = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)

N_VALUES = 8      # palette value axis (§4.5)


def luminance(arr):
    return arr[..., :3] @ LUMA


def tone_curve(L, black, white, gamma):
    """Log-exposure with two INDEPENDENT anchors (§4.1).

    One parameter cannot serve as both toe and spread: raising it to crush the
    faint halo also compresses the bright core. Two anchors separate them.
    """
    with np.errstate(divide="ignore", invalid="ignore"):
        num = np.log(np.maximum(L, 1e-12)) - math.log(black)
        den = math.log(white) - math.log(black)
        t = np.clip(num / den, 0.0, 1.0)
    return np.power(t, gamma, dtype=np.float32)


class Ramp:
    """The ramp, and the boundaries hysteresis is measured against."""

    def __init__(self, doc):
        self.chars = doc["ramp"]
        self.coverage = np.array(doc["coverage"], dtype=np.float32)
        self.peak = float(self.coverage[-1])
        if not np.all(np.diff(self.coverage) > 0):
            raise SystemExit("ramp is not monotonic in measured coverage -- invalid (§2.3)")
        # Boundaries are midpoints of MEASURED coverage. Coverage steps are
        # uneven and quantised, so assuming even spacing here would put every
        # boundary in the wrong place (§2.4).
        self.bounds = (self.coverage[:-1] + self.coverage[1:]) / 2.0
        self.steps = np.diff(self.coverage)

    def __len__(self):
        return len(self.chars)

    def ideal_index(self, target):
        """Nearest ramp step to a target coverage, ignoring hysteresis."""
        return np.searchsorted(self.bounds, target).astype(np.uint8)

    def apply_hysteresis(self, target, current, margin):
        """Move a cell only when it crosses a boundary by `margin` of a step.

        Colour absorbs the small changes (§4.3), so glyphs change rarely and
        the animation is stable without any dithering.
        """
        idx = current.astype(np.int16)
        n = len(self.chars)

        up_from = np.clip(idx, 0, n - 2)
        up_thr = self.bounds[up_from] + margin * self.steps[up_from]
        can_up = (idx < n - 1) & (target > up_thr)

        dn_from = np.clip(idx - 1, 0, n - 2)
        dn_thr = self.bounds[dn_from] - margin * self.steps[dn_from]
        can_dn = (idx > 0) & (target < dn_thr)

        ideal = self.ideal_index(target).astype(np.int16)
        # Move at most toward the ideal, and only in a direction the margin
        # permits. Jumping straight to the ideal is correct: the margin governs
        # WHETHER to move, not how far.
        out = idx.copy()
        out = np.where(can_up & (ideal > idx), ideal, out)
        out = np.where(can_dn & (ideal < idx), ideal, out)
        return out.astype(np.uint8)


def temperature_indices(temps_k, palette_temps):
    """Nearest of the palette's 32 temperatures. Colour is a function of one
    variable (§4.5), so this is the whole chromaticity decision."""
    edges = (palette_temps[:-1] + palette_temps[1:]) / 2.0
    return np.searchsorted(edges, temps_k).astype(np.uint8)


def quantise_frame(arr, ramp, pal_temps, black, white, gamma, margin, state, k_residual):
    L = luminance(arr)
    Lt = tone_curve(L, black, white, gamma)
    target = Lt * ramp.peak

    glyph = ramp.apply_hysteresis(target, state, margin)

    # The residual is what the chosen glyph over- or under-states. Colour
    # carries it, which is what removes banding without dithering (§4.3, I4).
    residual = (target - ramp.coverage[glyph]) / ramp.peak
    v = np.clip(0.5 + k_residual * residual, 0.0, 1.0)
    value_idx = np.clip((v * (N_VALUES - 1)).round(), 0, N_VALUES - 1).astype(np.uint8)

    t_idx = temperature_indices(arr[..., 3], pal_temps)
    colour = (t_idx.astype(np.uint16) * N_VALUES + value_idx).astype(np.uint8)

    # The void is the space character and carries no colour (I3).
    dark = glyph == 0
    colour = np.where(dark, 0, colour).astype(np.uint8)
    return glyph, colour


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--frames-dir", required=True)
    ap.add_argument("--ramp", default="assets/ramp-bake.json")
    ap.add_argument("--palette-meta", default="assets/palette.json")
    ap.add_argument("--palette", default="assets/palette.bin")
    ap.add_argument("--out", required=True)
    ap.add_argument("--black-pct", type=float, default=30.0)
    ap.add_argument("--white-pct", type=float, default=99.5)
    ap.add_argument("--gamma", type=float, default=0.8)
    ap.add_argument("--hysteresis", type=float, default=0.25)
    ap.add_argument("--k-residual", type=float, default=1.5)
    ap.add_argument("--fps", type=int, default=24)
    ap.add_argument("--max-iterations", type=int, default=12)
    ap.add_argument("--report", default=None)
    args = ap.parse_args()

    ramp = Ramp(json.loads(Path(args.ramp).read_text()))
    pmeta = json.loads(Path(args.palette_meta).read_text())
    pal_temps = np.array(pmeta["temperatures_K"], dtype=np.float32)
    pal_raw = Path(args.palette).read_bytes()
    palette = [tuple(pal_raw[i:i + 3]) for i in range(0, len(pal_raw), 3)]

    paths = sorted(Path(args.frames_dir).glob("*.hdr"))
    if not paths:
        raise SystemExit(f"no HDR frames in {args.frames_dir}")
    frames = [read_hdr(p) for p in paths]
    rows, cols, _ = frames[0].shape
    print(f"{len(frames)} frames of {cols}x{rows}")

    # --- global exposure over the whole sequence (§4.1) -----------------
    lit = np.concatenate([luminance(f)[luminance(f) > 0] for f in frames])
    if lit.size == 0:
        raise SystemExit("every cell is dark -- nothing to expose")
    black = float(np.percentile(lit, args.black_pct))
    white = float(np.percentile(lit, args.white_pct))
    print(f"  exposure: black P{args.black_pct} = {black:.6g}, white P{args.white_pct} = {white:.6g}, gamma {args.gamma}")

    # --- iterate the hysteresis state to a fixed point (§4.4) -----------
    state = ramp.ideal_index(tone_curve(luminance(frames[0]), black, white, args.gamma) * ramp.peak)
    glyphs = colours = None
    for it in range(args.max_iterations):
        g_planes, c_planes = [], []
        for arr in frames:
            g, c = quantise_frame(arr, ramp, pal_temps, black, white,
                                  args.gamma, args.hysteresis, state, args.k_residual)
            g_planes.append(g); c_planes.append(c)
            state = g
        if glyphs is not None and all(np.array_equal(a, b) for a, b in zip(glyphs, g_planes)):
            print(f"  hysteresis converged after {it} iteration(s)")
            glyphs, colours = g_planes, c_planes
            break
        glyphs, colours = g_planes, c_planes
    else:
        raise SystemExit(f"hysteresis did not converge in {args.max_iterations} iterations")

    # --- loop closure, exact (§10.3) ------------------------------------
    # Re-quantise frame 0 from the state AFTER the last frame. If it does not
    # come back identical the loop has a seam, and nothing is written.
    g0, c0 = quantise_frame(frames[0], ramp, pal_temps, black, white,
                            args.gamma, args.hysteresis, glyphs[-1], args.k_residual)
    if not np.array_equal(g0, glyphs[0]):
        n = int((g0 != glyphs[0]).sum())
        raise SystemExit(f"LOOP CLOSURE FAILED: {n} glyph cells differ on the wrap -- refusing to write")
    if not np.array_equal(c0, colours[0]):
        n = int((c0 != colours[0]).sum())
        raise SystemExit(f"LOOP CLOSURE FAILED: {n} colour cells differ on the wrap -- refusing to write")
    print("  LOOP CLOSURE: frame 0 reproduces byte-identically from the final state")

    # --- metrics (§4.2, §10.3) ------------------------------------------
    total = cols * rows * len(frames)
    ink = float(sum(int((g > 0).sum()) for g in glyphs)) / total
    hist = np.bincount(np.concatenate([g.ravel() for g in glyphs]), minlength=len(ramp)).astype(float)
    p = hist / hist.sum()
    nz = p[p > 0]
    entropy = float(-(nz * np.log2(nz)).sum() / math.log2(len(ramp)))

    gch = [float((glyphs[i] != glyphs[i - 1]).mean()) for i in range(1, len(glyphs))]
    cch = [float((colours[i] != colours[i - 1]).mean()) for i in range(1, len(colours))]
    wrap_g = float((glyphs[0] != glyphs[-1]).mean())

    print(f"  ink {ink*100:.1f}% (target ~20%), ramp entropy {entropy:.3f}")
    print(f"  churn: glyph {np.mean(gch)*100:.2f}%/frame, colour {np.mean(cch)*100:.2f}%/frame")
    print(f"  wrap glyph churn {wrap_g*100:.2f}% vs interior max {max(gch)*100:.2f}% "
          f"(ratio {wrap_g/max(gch) if max(gch) else 0:.2f}, scale-free -- §10.3)")

    raw, comp = write_cells(args.out, cols, rows, args.fps, ramp.chars, palette, glyphs, colours)
    print(f"  -> {args.out}  {raw} raw -> {comp} bytes ({raw/comp:.1f}x)")

    if args.report:
        Path(args.report).write_text(json.dumps({
            "frames": len(frames), "cols": cols, "rows": rows,
            "black": black, "white": white, "gamma": args.gamma,
            "hysteresis_margin": args.hysteresis, "k_residual": args.k_residual,
            "ink_fraction": ink, "ramp_entropy": entropy,
            "glyph_churn_mean": float(np.mean(gch)), "colour_churn_mean": float(np.mean(cch)),
            "wrap_glyph_churn": wrap_g, "interior_max_glyph_churn": float(max(gch)),
            "loop_closure": "exact", "raw_bytes": raw, "compressed_bytes": comp,
        }, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
