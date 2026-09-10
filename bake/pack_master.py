#!/usr/bin/env python3
"""Pack the HDR bake into ONE shippable master (NULL.md §5.3, §0.5).

WHY THIS EXISTS. The package used to ship QUANTISED ASCII -- nine strikes times
five fixed grids -- and a screen got whichever of those forty-five came closest.
That works exactly on 1920x1080 and 2560x1440 and on nothing else: a 1366x768
panel got a 1280x720 hero with a border, because 1366 = 2 x 683 and 683 is
prime, so no rung of the ladder divides it. Ship the master instead and the
grid for a given screen is DERIVED, exactly, on that screen.

WHAT IS IN IT, AND WHY SO LITTLE. The quantiser reads exactly two things from
an HDR frame:

    L = arr[..., :3] @ LUMA     a luminance scalar
    T = arr[..., 3]             the observed temperature, in Kelvin

Colour is a function of one variable (§4.5), so RGB is never used except to be
collapsed into L. Storing two channels rather than four is therefore lossless
with respect to everything downstream, and halves the file.

    240 frames of 640x180, float32, 4 channels   423 MB   (the bake directory)
    ... two channels, float16, zstd -19            9.1 MB (this file)

Nine megabytes, smaller than the forty-five quantised grids it replaces, and it
can produce any grid rather than five.

float16 is not a compromise here: L is a linear radiance that the tone curve
immediately takes the log of, and T is a temperature the palette quantises to
one of 32 values. Neither carries eleven significant digits.
"""

import argparse
import json
import struct
from pathlib import Path
from compression import zstd

import numpy as np

import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from formats import LUMA, read_hdr
from provenance import sha256, verify_manifest

MAGIC = b"NLHM"
VERSION = 1


def write_master(path, cols, rows, fps, planes, tone):
    """planes: list of float16 (rows, cols, 2) -- (luminance, temperature).

    tone: (black_pct, white_pct, gamma). THE CURVE TRAVELS WITH THE MASTER.

    It is swept by bake/tune.py over the whole sequence, and it is a property of
    the emission model rather than of any grid (§4.1) -- so every grid derived
    from this master must use the same one, and a machine deriving its own grid
    cannot be expected to re-run a sweep to find it. Leaving it out is not a
    small omission: the defaults blank 34% of the subject and drop ink from
    15.4% to 10.2%, which looks like a dimmer picture rather than a wrong one.
    """
    payload = b"".join(np.ascontiguousarray(p, dtype="<f2").tobytes() for p in planes)
    body = zstd.compress(payload, level=19)
    with open(path, "wb") as fh:
        fh.write(MAGIC)
        fh.write(struct.pack("<HHHHH", VERSION, cols, rows, len(planes), fps))
        fh.write(struct.pack("<fff", *tone))
        fh.write(struct.pack("<Q", len(payload)))
        fh.write(body)


def read_master(path):
    """-> (cols, rows, fps, tone, float32 array (frames, rows, cols, 2))"""
    with open(path, "rb") as fh:
        if fh.read(4) != MAGIC:
            raise ValueError(f"{path}: not a hero master")
        version, cols, rows, frames, fps = struct.unpack("<HHHHH", fh.read(10))
        if version != VERSION:
            raise ValueError(f"{path}: version {version}, expected {VERSION}")
        tone = struct.unpack("<fff", fh.read(12))
        raw_len = struct.unpack("<Q", fh.read(8))[0]
        payload = zstd.decompress(fh.read())
    if len(payload) != raw_len:
        raise ValueError(f"{path}: payload {len(payload)} bytes, header says {raw_len}")
    a = np.frombuffer(payload, dtype="<f2").reshape(frames, rows, cols, 2)
    # float32 for the arithmetic downstream; float16 is a STORAGE decision.
    return cols, rows, fps, tone, a.astype(np.float32)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--frames-dir", default="assets/master.hdrcells")
    ap.add_argument("--out", default="assets/master.hero")
    ap.add_argument("--fps", type=int, default=24)
    # Swept by bake/tune.py; null-prebake passes the same three to the bake.
    ap.add_argument("--black-pct", type=float, required=True)
    ap.add_argument("--white-pct", type=float, required=True)
    ap.add_argument("--gamma", type=float, required=True)
    ap.add_argument("--allow-legacy", action="store_true",
                    help="pack historical HDR for comparisons, explicitly marked legacy")
    args = ap.parse_args()

    try:
        provenance = verify_manifest(args.frames_dir, allow_legacy=args.allow_legacy)
    except (ValueError, OSError) as exc:
        raise SystemExit(str(exc)) from exc
    if provenance['temperature_model'] == 'legacy-unverified':
        print('WARNING: legacy HDR temperature; this is not a corrected release bake', file=sys.stderr)

    paths = sorted(Path(args.frames_dir).glob("*.hdr"))
    if not paths:
        raise SystemExit(f"no .hdr frames in {args.frames_dir}")

    planes = []
    cols = rows = None
    for p in paths:
        a = read_hdr(p)
        if cols is None:
            rows, cols = a.shape[0], a.shape[1]
        elif (a.shape[0], a.shape[1]) != (rows, cols):
            raise SystemExit(f"{p}: {a.shape[1]}x{a.shape[0]}, expected {cols}x{rows}")
        planes.append(np.stack([a[..., :3] @ LUMA, a[..., 3]], axis=-1).astype(np.float16))

    tone = (args.black_pct, args.white_pct, args.gamma)
    write_master(args.out, cols, rows, args.fps, planes, tone)
    n = Path(args.out).stat().st_size
    src = sum(p.stat().st_size for p in paths)
    print(f"master {cols}x{rows}, {len(planes)} frames @ {args.fps} fps")
    print(f"  tone: black P{tone[0]} white P{tone[1]} gamma {tone[2]}")
    print(f"  {args.out}  {n:,} bytes  ({n/1048576:.1f} MB)")
    print(f"  from {src/1048576:.0f} MB of HDR frames -- {src/n:.0f}x smaller")

    # READ IT BACK. A writer that cannot be read is not a format.
    c2, r2, f2, t2, arr = read_master(args.out)
    assert (c2, r2, f2) == (cols, rows, args.fps), "header round-trip failed"
    assert np.allclose(t2, tone), f"tone round-trip failed: {t2} != {tone}"
    assert arr.shape == (len(planes), rows, cols, 2), f"shape {arr.shape}"
    ref = np.stack(planes).astype(np.float32)
    if not np.array_equal(arr, ref):
        raise SystemExit("round-trip differs from what was written")
    print("  round-trip verified, byte for byte")
    Path(str(args.out) + '.provenance.json').write_text(json.dumps({
        'format': 1, 'master_sha256': sha256(args.out), 'source_bake': provenance,
        'tone': tone,
    }, indent=2, sort_keys=True) + '\n')


if __name__ == "__main__":
    main()
