#!/usr/bin/env python3
"""Derive a glyph ramp from a bitmap font strike (NULL.md §2.4).

A ramp from any external source is calibrated to a different font and is
invalid here (I7). Because the font is a bitmap, ink coverage is an EXACT
integer pixel count and no rasteriser is involved.

A ramp belongs to exactly one strike (§2.3). Ink is not proportional between
strikes -- each is independently drawn -- so a ramp derived at one strike can
run BACKWARDS at another, and every meter built on it would decrease as its
value rose. Derive per strike; the monotonicity check is what catches it.

    derive_ramp.py --font <psf> --levels 16 --out assets/ramp-<strike>.txt
    derive_ramp.py --font <psf> --report
    derive_ramp.py --verify assets/ramp-<strike>.txt
"""

import argparse
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fontlib import Font

# --- step 2: reject by class -------------------------------------------
# Block, shade, box-drawing and braille are reserved for chrome (§7) and are
# banned as tone (I1). Restricting to printable ASCII excludes all of them and
# everything else non-ASCII besides.
ASCII_PRINTABLE = range(0x20, 0x7F)


def moments(bitmap, width, height):
    """Ink centroid and covariance, treating each lit pixel as a UNIT SQUARE.

    Two details here are load-bearing and both were found by the check failing
    (§2.4):

    * The CROSS TERM is essential. Variance in x and y alone scores a diagonal
      stroke as isotropic, because a perfect diagonal has equal spread on both
      axes. The off-diagonal term is what tells them apart.

    * Each pixel carries the second moment of a unit square, 1/12, about its
      own centre. Adding that to the diagonal is the principled form of §2.4's
      "floor both eigenvalues at 1/12": without it every two-pixel glyph is
      exactly collinear, its minor eigenvalue is 0, the ratio is infinite, and
      sparse glyphs such as '.' are wrongly rejected -- removing precisely the
      low end of the ramp the void depends on.
    """
    pts = [(x, y) for y, row in enumerate(bitmap) for x, v in enumerate(row) if v]
    n = len(pts)
    if n == 0:
        return 0, (0.0, 0.0), (0.0, 0.0, 0.0)

    cx = sum(p[0] for p in pts) / n
    cy = sum(p[1] for p in pts) / n
    sxx = sum((p[0] - cx) ** 2 for p in pts) / n + 1.0 / 12.0
    syy = sum((p[1] - cy) ** 2 for p in pts) / n + 1.0 / 12.0
    sxy = sum((p[0] - cx) * (p[1] - cy) for p in pts) / n
    return n, (cx, cy), (sxx, syy, sxy)


def anisotropy(sxx, syy, sxy):
    """Ratio of covariance eigenvalues. 1.0 is perfectly isotropic."""
    half = (sxx + syy) / 2.0
    disc = math.sqrt(((sxx - syy) / 2.0) ** 2 + sxy ** 2)
    lo = half - disc
    hi = half + disc
    return hi / lo if lo > 1e-12 else float("inf")


def centroid_offset(cx, cy, width, height):
    """How far the ink sits from the cell centre, as a fraction of the cell.

    A glyph whose ink is pushed to one edge reads as a shifted texture: a field
    of them shows visible ruling, because the ink lands on the same edge of
    every cell.
    """
    dx = (cx - (width - 1) / 2.0) / width
    dy = (cy - (height - 1) / 2.0) / height
    return math.hypot(dx, dy)


def analyse(font, max_anisotropy, max_centroid):
    """Measure every candidate glyph and record why each was kept or rejected."""
    rows = []
    for cp in ASCII_PRINTABLE:
        idx = font.cp_to_index.get(cp)
        if idx is None:
            continue
        bm = font.bitmap(idx)
        n, (cx, cy), (sxx, syy, sxy) = moments(bm, font.width, font.height)

        aniso = anisotropy(sxx, syy, sxy) if n else 1.0
        off = centroid_offset(cx, cy, font.width, font.height) if n else 0.0

        reason = None
        if cp != 0x20:                       # space is the void and is always kept
            if aniso > max_anisotropy:
                reason = f"directional (anisotropy {aniso:.2f} > {max_anisotropy})"
            elif off > max_centroid:
                reason = f"off-centre (offset {off:.3f} > {max_centroid})"

        rows.append({
            "cp": cp, "char": chr(cp), "ink": n,
            "coverage": n / font.cell_pixels,
            "anisotropy": aniso, "centroid_offset": off,
            "rejected": reason,
        })
    return rows


def select(rows, levels):
    """Step 5: choose glyphs with DISTINCT ink, spaced as evenly as the font allows.

    Duplicates render identically and silently shorten the ramp. Within one ink
    count the most isotropic glyph wins, because it reads as tone rather than
    as texture.
    """
    by_ink = {}
    for r in rows:
        if r["rejected"]:
            continue
        cur = by_ink.get(r["ink"])
        if cur is None or r["anisotropy"] < cur["anisotropy"]:
            by_ink[r["ink"]] = r

    available = sorted(by_ink)
    if not available:
        raise SystemExit("no glyphs survived the filters")

    # Space must anchor the ramp: the void is the space character (I3).
    if 0 not in by_ink:
        raise SystemExit("the space glyph was rejected -- the void has no glyph")

    lo, hi = available[0], available[-1]
    chosen, used = [], set()
    for i in range(levels):
        target = lo + (hi - lo) * i / (levels - 1)
        best = min((k for k in available if k not in used), key=lambda k: abs(k - target), default=None)
        if best is None:
            break
        used.add(best)
        chosen.append(by_ink[best])

    chosen.sort(key=lambda r: r["ink"])
    return chosen, len(available)


def write_ramp(path, font, chosen, meta):
    ramp = "".join(r["char"] for r in chosen)
    doc = {
        "ramp": ramp,
        "font": font.path,
        "font_sha256": font.sha256,
        "cell": [font.width, font.height],
        "cell_pixels": font.cell_pixels,
        "levels": len(chosen),
        "peak_coverage": chosen[-1]["coverage"],
        "coverage": [r["coverage"] for r in chosen],
        "ink": [r["ink"] for r in chosen],
        "params": meta,
    }
    Path(path).write_text(json.dumps(doc, indent=2) + "\n")
    return doc


def check_monotonic(doc):
    """§2.3 / §10.3. Strictly increasing measured coverage, or the ramp is invalid."""
    cov = doc["coverage"]
    bad = [(i, cov[i - 1], cov[i]) for i in range(1, len(cov)) if cov[i] <= cov[i - 1]]
    return bad


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--font")
    ap.add_argument("--levels", type=int, default=16)
    ap.add_argument("--out")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--verify", metavar="RAMP_JSON")
    ap.add_argument("--max-anisotropy", type=float, default=5.0)
    ap.add_argument("--max-centroid", type=float, default=0.30)
    args = ap.parse_args()

    if args.verify:
        doc = json.loads(Path(args.verify).read_text())
        font = Font(doc["font"])
        problems = []
        if font.sha256 != doc["font_sha256"]:
            problems.append(
                f"FONT HASH MISMATCH\n  ramp derived against {doc['font_sha256'][:16]}...\n"
                f"  font on disk is     {font.sha256[:16]}...\n"
                f"  the font changed; re-derive the ramp (§2.4)")
        bad = check_monotonic(doc)
        if bad:
            problems.append("RAMP IS NOT MONOTONIC IN MEASURED COVERAGE:\n" + "\n".join(
                f"  level {i}: {a:.4f} -> {b:.4f}" for i, a, b in bad))
        if problems:
            print("\n\n".join(problems)); return 1
        print(f"PASS: ramp {doc['ramp']!r} — {doc['levels']} levels, "
              f"monotonic, peak coverage {doc['peak_coverage']:.3f}, font hash matches")
        return 0

    if not args.font:
        ap.error("--font is required unless --verify is given")

    font = Font(args.font)
    rows = analyse(font, args.max_anisotropy, args.max_centroid)

    if args.report:
        print(f"{font}\n")
        print(f"  {'ch':>3} {'ink':>4} {'cover':>7} {'aniso':>7} {'offset':>7}  verdict")
        for r in sorted(rows, key=lambda r: (r["ink"], r["cp"])):
            v = "rejected: " + r["rejected"] if r["rejected"] else "kept"
            print(f"  {r['char']!r:>3} {r['ink']:>4} {r['coverage']:>7.4f} "
                  f"{r['anisotropy']:>7.2f} {r['centroid_offset']:>7.3f}  {v}")
        kept = [r for r in rows if not r["rejected"]]
        print(f"\n  {len(kept)}/{len(rows)} kept, {len({r['ink'] for r in kept})} distinct ink counts")
        return 0

    chosen, distinct = select(rows, args.levels)
    meta = {"max_anisotropy": args.max_anisotropy, "max_centroid": args.max_centroid,
            "requested_levels": args.levels, "distinct_ink_available": distinct}

    out = args.out or f"assets/ramp-{Path(font.path).name.split('.')[0]}.json"
    doc = write_ramp(out, font, chosen, meta)

    bad = check_monotonic(doc)
    print(f"ramp: {doc['ramp']!r}")
    print(f"  {doc['levels']} levels from {distinct} distinct ink counts available")
    print(f"  peak coverage {doc['peak_coverage']:.4f}")
    print(f"  cell {font.width}x{font.height} = {font.cell_pixels} px")
    print(f"  font sha256 {font.sha256[:16]}...")
    print(f"  written to {out}")
    if bad:
        print("  NOT MONOTONIC — invalid"); return 1
    print("  monotonic in measured coverage: PASS")
    if doc["levels"] < args.levels:
        print(f"  NOTE: asked for {args.levels}, font ceiling is {doc['levels']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
