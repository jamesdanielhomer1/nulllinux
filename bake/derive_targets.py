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
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bake as bakemod
import ladder
from formats import read_hdr, write_hdr
from provenance import sha256
from quantise import HYSTERESIS_DEFAULT


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


def preparation_key(master, frames, ss, max_steps):
    paths = sorted(Path(master).glob('*.hdr'))
    if [p.name for p in paths] != [f'{i:04d}.hdr' for i in range(frames)]:
        raise ValueError('the HDR master does not contain exactly the requested frame sequence')
    return {'frames': frames, 'ss': ss, 'max_steps': max_steps,
            'master': {p.name: sha256(p) for p in paths},
            'renderer': sha256(bakemod.GPU),
            'sources': {p: sha256(Path(__file__).parent / p) for p in
                        ('derive_targets.py', 'bake.py', 'scene.py', 'ladder.py', 'formats.py')}}


def prepare(master, cache, frames, ss, max_steps):
    """Trace camera geometry once; a font changes quantisation, never HDR."""
    cache = Path(cache)
    cache.mkdir(parents=True, exist_ok=True)
    key = preparation_key(master, frames, ss, max_steps)
    for name, factor in (('target-2', 2), ('target-4', 4)):
        downsample_dir(master, cache / name, factor, frames)
    for name, cols, rows in (('tty', 80, 24), ('logo', 40, 16)):
        print(f'  tracing {name} once at {cols}x{rows}', flush=True)
        bakemod.bake(cols, rows, frames, ss, cache / name, max_steps, quiet=True)
    key['targets'] = {str(p.relative_to(cache)): sha256(p) for p in sorted(cache.glob('*/*.hdr'))}
    (cache / 'prepared.json').write_text(json.dumps(key, sort_keys=True) + '\n')


def verify_prepared(master, cache, frames, ss, max_steps):
    cache = Path(cache)
    doc = json.loads((cache / 'prepared.json').read_text())
    expected = preparation_key(master, frames, ss, max_steps)
    target_hashes = doc.pop('targets')
    actual = {str(p.relative_to(cache)): sha256(p) for p in sorted(cache.glob('*/*.hdr'))}
    if doc != expected or target_hashes != actual or len(actual) != frames * 4:
        raise ValueError(f'{cache}: prepared HDR targets are incomplete or belong to different inputs')


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--master", required=True, help="HDR cell master directory")
    ap.add_argument("--frames", type=int, default=ladder.FRAMES)
    ap.add_argument("--black-pct", type=float, required=True)
    ap.add_argument("--white-pct", type=float, required=True)
    ap.add_argument("--gamma", type=float, required=True)
    ap.add_argument("--hysteresis", type=float, default=HYSTERESIS_DEFAULT)
    ap.add_argument("--ss", type=int, default=4)
    ap.add_argument("--max-steps", type=int, default=3000)
    ap.add_argument('--prepared', type=Path, help='reuse verified HDR target geometry from this directory')
    ap.add_argument('--prepare-only', action='store_true', help='write HDR targets once, without quantising')
    args = ap.parse_args()

    if args.prepare_only and not args.prepared:
        ap.error('--prepare-only requires --prepared')
    if args.prepare_only:
        prepare(args.master, args.prepared, args.frames, args.ss, args.max_steps)
        return
    scratch = tempfile.TemporaryDirectory(prefix='null-targets-')
    prepared = args.prepared or Path(scratch.name)
    if not args.prepared:
        prepare(args.master, prepared, args.frames, args.ss, args.max_steps)
    verify_prepared(args.master, prepared, args.frames, args.ss, args.max_steps)

    curve = dict(black=args.black_pct, white=args.white_pct,
                 gamma=args.gamma, hysteresis=args.hysteresis)
    Path("assets").mkdir(exist_ok=True)

    print("master 640x180")
    print(quantise(args.master, "assets/master.cells", "assets/ramp-bake.json",
                   report="assets/master-report.json", **curve).rstrip())

    # --- divides the master: downsample in the HDR domain ---------------
    for name, factor, grid in (("target-2", 2, "320x90"), ("target-4", 4, "160x45")):
        print(f"\n{name} {grid}  (master / {factor}, box-averaged in HDR)")
        d = prepared / name
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
        d = prepared / name
        print(quantise(d, f"assets/{name}.cells", "assets/ramp-bake.json",
                       report=f"assets/{name}-report.json", **curve).rstrip())

    print("\nderived:")
    for p in sorted(Path("assets").glob("*.cells")):
        print(f"  {p.name:<18} {p.stat().st_size:>9,} bytes")
    scratch.cleanup()


if __name__ == "__main__":
    main()
