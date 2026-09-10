#!/usr/bin/env python3
"""The bake (NULL.md §5.1, §5.5, §11 Phase 9).

Renders supersampled on the GPU and box-averages down to the HDR CELL MASTER,
which is the artefact worth keeping: tone, colour and quantisation all operate
on it and re-run in seconds, so the curve is re-tunable without ever
re-tracing.

The full-resolution frames beneath it are large and deletable, so they are
never written to disk at all -- each frame is downsampled and the big buffer
discarded before the next.

Parameters live HERE rather than in shell history because they are no longer
free: r_out anchors n=1 in the mode ladder, so changing it re-derives every
n_k and invalidates the loop closure (§3.4.1).
"""

import argparse
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kerr
import ladder
from formats import LUMA, read_hdr, write_hdr
from provenance import MANIFEST, sha256, write_manifest

GPU = "bake/gpu/target/release/kerr-gpu"

# Settled (§3.5, Appendix A). Not free parameters.
import scene
SPIN = scene.SPIN
INCLINATION = scene.INCLINATION
HALF_WIDTH = scene.HALF_WIDTH
R_OUT = scene.R_OUT
T_INNER = scene.T_INNER

# How many supersampled frames may exist on disk at once. At 640x180 with 4x
# supersampling each is ~29 MB, so this bounds the working set to about 700 MB
# regardless of how many frames are baked.
CHUNK_FRAMES = 24


def write_bands(path):
    """The ladder comes from the ONE generator; three copies of a table drift
    and only one of them is the physics (§10.3)."""
    bands = ladder.build()
    with open(path, "w") as f:
        for b in bands:
            f.write(f"{b['m']} {b['n']} {b['r']} {b['amp']} {b['width']} {b['phase']}\n")
    return len(bands)


def box_average(arr, ss):
    """Average each cell's true sub-sample footprint.

    This is what makes aspect and antialiasing exact rather than approximately
    corrected (§2.5). Averaging is weighted by nothing: every sub-sample is one
    sample of the same cell.
    """
    if ss == 1:
        return arr
    rows, cols, ch = arr.shape
    result = arr.reshape(rows // ss, ss, cols // ss, ss, ch).mean(axis=(1, 3))
    # Temperature is an intensive quantity: an empty subsample reduces the
    # light, not its temperature. Average the additive luminance moment L*T,
    # then divide by the averaged L. This composes across repeated reductions.
    light = arr[..., :3] @ LUMA
    shape = (rows // ss, ss, cols // ss, ss)
    mean_light = light.reshape(shape).mean(axis=(1, 3))
    moment = (light * arr[..., 3]).reshape(shape).mean(axis=(1, 3))
    result[..., 3] = np.divide(moment, mean_light, out=np.zeros_like(moment),
                               where=mean_light > 0)
    return result


def bake(cols, rows, frames, ss, outdir, max_steps, half_width=HALF_WIDTH,
         inclination=INCLINATION, quiet=False):
    outdir = Path(outdir); outdir.mkdir(parents=True, exist_ok=True)
    # Invalidate completion before overwriting any frame; a failed run must
    # never inherit a previous run's success marker.
    (outdir / MANIFEST).unlink(missing_ok=True)
    scratch = tempfile.TemporaryDirectory(prefix='null-bake-')
    tmp = Path(scratch.name) / 'raw'
    bands_file = Path(scratch.name) / 'bands.txt'
    n_bands = write_bands(bands_file)
    r_in = kerr.isco_radius(SPIN)
    metadata = {'cols': cols, 'rows': rows, 'frames': frames, 'fps': ladder.FPS,
                'supersample': ss, 'max_steps': max_steps,
                'scene': {'spin': SPIN, 'inclination': inclination,
                          'half_width': half_width, 'r_in': float(r_in),
                          'r_out': R_OUT, 't_inner': T_INNER},
                'renderer_sha256': sha256(GPU), 'bands_sha256': sha256(bands_file),
                'sources_sha256': {name: sha256(Path(__file__).parent / name)
                    for name in ('bake.py', 'formats.py', 'scene.py', 'ladder.py',
                                 'kerr.py', 'provenance.py', 'gpu/src/main.rs',
                                 'gpu/src/kerr.wgsl')}}

    if not quiet:
        print(f"  {frames} frames, {cols}x{rows} cells, {ss}x supersampling "
              f"({cols*ss}x{rows*ss} rays = {cols*ss*rows*ss:,}/frame)")
        print(f"  a={SPIN} inc={inclination} half_width={half_width} "
              f"r_in={r_in:.4f} r_out={R_OUT} bands={n_bands}")

    # CHUNKED. Tracing every frame before downsampling any of them writes the
    # full-resolution sequence to disk -- 240 frames at 2560x720 is about 7 GB,
    # which filled a 7.8 GB filesystem and killed the second bake with no
    # output at all. The docstring above always said the big frames are never
    # kept; this is what makes that true rather than aspirational.
    trace_t = down_t = 0.0
    chunk = max(1, min(frames, CHUNK_FRAMES))
    for start in range(0, frames, chunk):
        count = min(chunk, frames - start)
        shutil.rmtree(tmp, ignore_errors=True)

        t0 = time.time()
        subprocess.run([GPU, "--cols", str(cols * ss), "--rows", str(rows * ss),
                        "--frames", str(count),
                        "--frame-start", str(start), "--frame-total", str(frames),
                        "--max-steps", str(max_steps),
                        "--spin", str(SPIN), "--inclination", str(inclination),
                        "--half-width", str(half_width),
                        "--r-in", str(r_in), "--r-out", str(R_OUT),
                        "--t-inner", str(T_INNER),
                        "--bands", str(bands_file), "--out", str(tmp)],
                       check=True, capture_output=True)
        trace_t += time.time() - t0

        t1 = time.time()
        for i in range(start, start + count):
            big = read_hdr(tmp / f"{i:04d}.hdr")
            write_hdr(outdir / f"{i:04d}.hdr", box_average(big, ss).astype(np.float32))
        down_t += time.time() - t1
        if not quiet:
            print(f"  completed {start + count}/{frames} HDR frames", flush=True)
    shutil.rmtree(tmp, ignore_errors=True)
    scratch.cleanup()
    write_manifest(outdir, metadata)

    if not quiet:
        print(f"  traced in {trace_t:.1f}s, downsampled in {down_t:.1f}s "
              f"({(trace_t+down_t)/frames:.3f}s/frame)")
    return outdir


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cols", type=int, default=640)
    ap.add_argument("--rows", type=int, default=180)
    ap.add_argument("--frames", type=int, default=ladder.FRAMES)
    ap.add_argument("--ss", type=int, default=4)
    ap.add_argument("--max-steps", type=int, default=3000)
    ap.add_argument("--half-width", type=float, default=HALF_WIDTH)
    ap.add_argument("--inclination", type=float, default=INCLINATION)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    bake(args.cols, args.rows, args.frames, args.ss, args.out, args.max_steps,
         args.half_width, args.inclination)


if __name__ == "__main__":
    main()
