#!/usr/bin/env python3
"""One frame of the hero, all the way to glyphs, for choosing parameters.

The point is to compare in the FINAL MEDIUM. Spin and inclination change the
raytraced image, but what anyone actually sees is that image quantised to a
glyph ramp and a palette, and the quantiser is not a neutral observer -- it has
a tone curve, an ink target and a hysteresis rule. Judging the choice on raw
radiance would be judging something nobody looks at.
"""

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, "bake")
import kerr        # noqa: E402
import ladder      # noqa: E402

GPU = "bake/gpu/target/release/kerr-gpu"
RENDER = "render/target/release/render"


def preview(spin, incl, half_width, cols, rows, ss, out_png, quiet=False,
            t_inner=20000.0, black=30.0, white=99.0, gamma=0.8):
    tmp = Path(tempfile.mkdtemp(prefix="null-preview-"))
    try:
        # The inner edge is the ISCO, which MOVES WITH SPIN -- 6M at a=0 down
        # to about 1.24M at a=0.998. Holding it fixed while changing spin would
        # be changing two things and calling it one.
        r_in = kerr.isco_radius(spin, prograde=True)

        # Whitespace columns, not JSON: the tracer parses "m n r amp width
        # phase" per line. The ladder is rebuilt FOR THIS SPIN, because the
        # mode radii are derived from it (§3.4.1) and reusing the a=0.9 table
        # would put the bands where they belong on a different black hole.
        bands = ladder.build(a=spin)
        bands_file = tmp / "bands.txt"
        bands_file.write_text("".join(
            f"{b['m']} {b['n']} {b['r']} {b['amp']} {b['width']} {b['phase']}\n"
            for b in bands))

        subprocess.run([GPU, "--cols", str(cols * ss), "--rows", str(rows * ss),
                        "--frames", "2", "--spin", str(spin),
                        "--inclination", str(incl), "--half-width", str(half_width),
                        "--r-in", str(r_in), "--r-out", str(ladder.R_OUT),
                        "--t-inner", str(t_inner),
                        "--bands", str(bands_file), "--out", str(tmp / "hdr_big")],
                       check=True, capture_output=True)

        # Downsample exactly as the real bake does.
        sys.path.insert(0, "bake")
        from bake import read_hdr, write_hdr, box_average          # noqa: E402
        import numpy as np                                          # noqa: E402
        d = tmp / "hdr"
        d.mkdir()
        for i in range(2):
            big = read_hdr(tmp / "hdr_big" / f"{i:04d}.hdr")
            write_hdr(d / f"{i:04d}.hdr", box_average(big, ss).astype(np.float32))

        cells = tmp / "preview.cells"
        subprocess.run(["python3", "bake/quantise.py", "--frames-dir", str(d),
                        "--black-pct", str(black), "--white-pct", str(white),
                        "--gamma", str(gamma), "--out", str(cells)],
                       check=True, capture_output=True)
        subprocess.run([RENDER, "--file", str(cells),
                        "--atlas", "assets/atlas-bake.bin", "raster",
                        "--frame", "0", "--out", str(tmp / "p.ppm")],
                       check=True, capture_output=True)
        from PIL import Image                                       # noqa: E402
        Image.open(tmp / "p.ppm").save(out_png)
        if not quiet:
            print(f"  a={spin:<5} i={incl:<6} T={t_inner:<8.0f} "
                  f"ISCO={r_in:.3f}  -> {out_png}")
        return r_in
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spin", type=float, default=0.9)
    ap.add_argument("--inclination", type=float, default=80.0)
    ap.add_argument("--half-width", type=float, default=28.0)
    ap.add_argument("--cols", type=int, default=320)
    ap.add_argument("--rows", type=int, default=90)
    ap.add_argument("--ss", type=int, default=3)
    ap.add_argument("--t-inner", type=float, default=20000.0)
    ap.add_argument("--black", type=float, default=30.0)
    ap.add_argument("--white", type=float, default=99.0)
    ap.add_argument("--gamma", type=float, default=0.8)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    preview(a.spin, a.inclination, a.half_width, a.cols, a.rows, a.ss, a.out,
            t_inner=a.t_inner, black=a.black, white=a.white, gamma=a.gamma)


if __name__ == "__main__":
    main()
