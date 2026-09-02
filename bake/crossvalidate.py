#!/usr/bin/env python3
"""Cross-validate the accelerated tracer against the reference (NULL.md §10.2).

This is the entire reason the slow one was built first: a compute shader is
close to undebuggable, and this gives it something correct to be checked
against.

Three levels, and the third is the one that matters, because it is what reaches
the screen:

  1. hit geometry   -- which rays strike the disk at all
  2. luminance and temperature
  3. QUANTISED GLYPHS
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kerr
import ladder
import render_kerr
import scene
from formats import read_hdr, write_hdr
from quantise import Ramp, tone_curve, luminance

LUMA = np.array([0.2126, 0.7152, 0.0722])


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cols", type=int, default=80)
    ap.add_argument("--rows", type=int, default=24)
    ap.add_argument("--max-steps", type=int, default=2000)
    ap.add_argument("--ramp", default="assets/ramp-bake.json")
    ap.add_argument("--gpu", default="bake/gpu/target/release/kerr-gpu")
    args = ap.parse_args()

    bands = ladder.build()
    Path("/tmp/xv").mkdir(exist_ok=True)
    with open("/tmp/xv/bands.txt", "w") as f:
        for b in bands:
            f.write(f"{b['m']} {b['n']} {b['r']} {b['amp']} {b['width']} {b['phase']}\n")

    print(f"cross-validation at {args.cols}x{args.rows}\n")

    print("  tracing with the numpy reference (f64)...", flush=True)
    ref = render_kerr.render(args.cols, args.rows, bands=bands,
                             max_steps=args.max_steps)

    print("  tracing with the compute shader (f32)...", flush=True)
    # EVERY scene flag, explicitly. Passing none of them meant the shader ran
    # on its own compiled-in defaults -- a=0.9 against a reference at a=0.6 --
    # so this compared two different black holes and reported the shader
    # broken. The shader was fine (§10.3).
    subprocess.run([args.gpu, "--cols", str(args.cols), "--rows", str(args.rows),
                    "--frames", "1", "--max-steps", str(args.max_steps),
                    *scene.gpu_flags(),
                    "--bands", "/tmp/xv/bands.txt", "--out", "/tmp/xv/gpu"],
                   check=True, capture_output=True)
    gpu = read_hdr("/tmp/xv/gpu/0000.hdr")

    fail = 0

    # --- 1. hit geometry -------------------------------------------------
    hit_ref = ref[..., 3] > 0
    hit_gpu = gpu[..., 3] > 0
    differ = int((hit_ref != hit_gpu).sum())
    total = hit_ref.size
    agree = (total - differ) / total * 100
    ok = agree >= 99.0
    fail += not ok
    print(f"  [{'PASS' if ok else 'FAIL'}] hit geometry")
    print(f"         {agree:.2f}% agreement, {differ} of {total} cells differ")

    # --- 2. luminance and temperature ------------------------------------
    both = hit_ref & hit_gpu
    Lr = (ref[..., :3] @ LUMA)[both]
    Lg = (gpu[..., :3] @ LUMA)[both]
    lum_err = np.abs(Lg - Lr) / np.maximum(Lr, 1e-30) * 100
    Tr, Tg = ref[..., 3][both], gpu[..., 3][both]
    t_err = np.abs(Tg - Tr) / np.maximum(Tr, 1e-30) * 100
    ok = np.median(lum_err) < 5.0 and np.median(t_err) < 1.0
    fail += not ok
    print(f"  [{'PASS' if ok else 'FAIL'}] luminance and temperature")
    print(f"         luminance   median {np.median(lum_err):.3f}%  p95 {np.percentile(lum_err,95):.2f}%")
    print(f"         temperature median {np.median(t_err):.3f}%  p95 {np.percentile(t_err,95):.2f}%")

    # --- 3. quantised glyphs ---------------------------------------------
    # The level that matters: it is what reaches the screen.
    ramp = Ramp(json.loads(Path(args.ramp).read_text()))
    def glyphs(arr):
        L = arr[..., :3] @ LUMA
        lit = L[L > 0]
        b = float(np.percentile(lit, 10)); w = float(np.percentile(lit, 99.5))
        return ramp.ideal_index(tone_curve(L, b, w, 0.6) * ramp.peak)
    gr, gg = glyphs(ref), glyphs(gpu)
    d = gr.astype(int) - gg.astype(int)
    same = int((d == 0).sum())
    adj = int((np.abs(d) == 1).sum())
    worse = int((np.abs(d) > 1).sum())
    pct = same / d.size * 100
    ok = pct >= 99.0 and worse == 0
    fail += not ok
    print(f"  [{'PASS' if ok else 'FAIL'}] quantised glyphs")
    print(f"         {pct:.2f}% identical ({same}/{d.size}); "
          f"{adj} differ by ONE adjacent ramp level; {worse} by more")

    print()
    if fail:
        print(f"{fail} of 3 levels FAILED -- the shader does not match the reference")
        return 1
    print("all 3 levels agree: FP32 WGSL produces the same ASCII as FP64 numpy")
    return 0


if __name__ == "__main__":
    sys.exit(main())
