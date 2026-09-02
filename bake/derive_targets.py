#!/usr/bin/env python3
"""Derive every target from the HDR cell master (NULL.md §5.3).

Targets whose grid DIVIDES the master are box-downsampled in the HDR domain,
before quantisation. Targets whose grid does not are RE-RENDERED at their own
grid, for two reasons:

  * Glyph indices cannot be averaged. The mean of '.' and '@' is not a tone, it
    is a different glyph -- so any downsampling must happen in the HDR domain.
  * A target with a different aspect needs its own camera framing, not a crop
    of someone else's.
"""

import argparse
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bake as bakemod
import ladder
from formats import read_hdr, write_hdr


def downsample_dir(src, dst, factor, frames):
    dst = Path(dst); dst.mkdir(parents=True, exist_ok=True)
    for i in range(frames):
        a = read_hdr(Path(src) / f"{i:04d}.hdr")
        write_hdr(dst / f"{i:04d}.hdr",
                  bakemod.box_average(a, factor).astype(np.float32))
    return dst


def quantise(frames_dir, out, ramp, black, white, gamma, hysteresis, report=None):
    cmd = [sys.executable, "bake/quantise.py", "--frames-dir", str(frames_dir),
           "--out", str(out), "--ramp", ramp,
           "--black-pct", str(black), "--white-pct", str(white),
           "--gamma", str(gamma), "--hysteresis", str(hysteresis)]
    if report:
        cmd += ["--report", str(report)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout); print(r.stderr, file=sys.stderr)
        raise SystemExit(f"quantise failed for {out}")
    return r.stdout


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--master", required=True, help="HDR cell master directory")
    ap.add_argument("--frames", type=int, default=ladder.FRAMES)
    ap.add_argument("--black-pct", type=float, required=True)
    ap.add_argument("--white-pct", type=float, required=True)
    ap.add_argument("--gamma", type=float, required=True)
    ap.add_argument("--hysteresis", type=float, default=0.40)
    ap.add_argument("--ss", type=int, default=4)
    ap.add_argument("--max-steps", type=int, default=3000)
    args = ap.parse_args()

    curve = dict(black=args.black_pct, white=args.white_pct,
                 gamma=args.gamma, hysteresis=args.hysteresis)
    Path("assets").mkdir(exist_ok=True)

    print("master 640x180")
    print(quantise(args.master, "assets/master.cells", "assets/ramp-bake.json",
                   report="assets/master-report.json", **curve).rstrip())

    # --- divides the master: downsample in the HDR domain ---------------
    for name, factor, grid in (("target-2", 2, "320x90"), ("target-4", 4, "160x45")):
        print(f"\n{name} {grid}  (master / {factor}, box-averaged in HDR)")
        d = downsample_dir(args.master, f"/tmp/null-{name}", factor, args.frames)
        print(quantise(d, f"assets/{name}.cells", "assets/ramp-bake.json",
                       report=f"assets/{name}-report.json", **curve).rstrip())

    # --- does NOT divide: re-render at its own grid ---------------------
    # 180 rows does not divide by 24, and the crop has its own aspect, so both
    # of these are traced again rather than averaged down (§5.3).
    # The logo keeps the SETTLED framing rather than a tight crop. A tight
    # crop at 9 M filled 83% of the frame with disk, and the quantiser then
    # reported 66% ink against a ~20% target -- the void stops being empty and
    # the composition stops reading, which is precisely what §4.2 warns
    # against. The logo is the hero at logo size, not a close-up of it.
    for name, cols, rows, half in (("tty", 80, 24, bakemod.HALF_WIDTH),
                                   ("logo", 40, 16, bakemod.HALF_WIDTH)):
        print(f"\n{name} {cols}x{rows}  (RE-RENDERED: the grid does not divide the master)")
        t0 = time.time()
        d = bakemod.bake(cols, rows, args.frames, args.ss, f"/tmp/null-{name}",
                         args.max_steps, half_width=half, quiet=True)
        print(f"  re-traced in {time.time()-t0:.1f}s")
        print(quantise(d, f"assets/{name}.cells", "assets/ramp-bake.json",
                       report=f"assets/{name}-report.json", **curve).rstrip())

    print("\nderived:")
    for p in sorted(Path("assets").glob("*.cells")):
        print(f"  {p.name:<18} {p.stat().st_size:>9,} bytes")


if __name__ == "__main__":
    main()
