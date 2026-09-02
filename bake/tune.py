#!/usr/bin/env python3
"""Sweep tone-curve candidates: coverage first, then ink, then entropy (§4.2).

§4.2: entropy over the ramp is a tempting objective and it is WRONG.
Maximising it fills every cell with mid-tones and erases the composition -- the
void reads precisely because most of the frame is empty. Constrain INK, and
maximise entropy subject to that constraint.

But ink is a WHOLE-FRAME statistic, and a whole-frame statistic can be met by
deleting part of the subject. That is not a hypothetical: judged on ink and
entropy alone, this sweep once returned a curve that blanked a THIRD of the
disk -- the entire receding side, which g^4 beaming leaves several times dimmer
than the approaching side -- and reported it as the best candidate, because a
smaller subject and a well-exposed one score identically.

So COVERAGE is the first constraint and it is hard: of the cells the render
actually lit, what fraction survive to carry ink. The dual of "no curve can
light a cell the render left empty" is "no curve may blank a cell the render
lit", and only the first half was being checked.

Ink then becomes an OUTCOME to read, not a lever to pull. If coverage is
complete and ink is still too high, that is a FRAMING problem and the fix is to
move the camera back (§3.5) -- never to crush the curve until the subject fits.
"""

import argparse, json, math, sys
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from formats import read_hdr
from quantise import luminance, tone_curve, Ramp


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--frames-dir", required=True)
    ap.add_argument("--ramp", default="assets/ramp-bake.json")
    ap.add_argument("--ink-target", type=float, default=0.20)
    ap.add_argument("--min-coverage", type=float, default=0.98,
                    help="fraction of LIT cells that must still carry ink")
    ap.add_argument("--black", type=float, nargs="*", default=[0, 5, 10, 20, 30])
    ap.add_argument("--white", type=float, nargs="*", default=[99.0, 99.5])
    ap.add_argument("--gamma", type=float, nargs="*", default=[0.6, 0.8, 1.0])
    args = ap.parse_args()

    ramp = Ramp(json.loads(Path(args.ramp).read_text()))
    frames = [read_hdr(p) for p in sorted(Path(args.frames_dir).glob("*.hdr"))]
    L = [luminance(f) for f in frames]
    total = sum(l.size for l in L)
    lit = np.concatenate([l[l > 0] for l in L])

    ceiling = lit.size / total
    print(f"{len(frames)} frames; lit-cell ceiling {ceiling*100:.2f}% "
          f"-- no curve can exceed this (§4.2)")
    if ceiling < args.ink_target:
        print(f"  WARNING: the ink target {args.ink_target*100:.0f}% is ABOVE the ceiling.")
        print("  That is a COMPOSITION problem, not a curve problem: reframe, do not")
        print("  reach for a curve that cannot get there.")
    elif ceiling > args.ink_target * 1.25:
        print(f"  NOTE: the ceiling is well above the {args.ink_target*100:.0f}% ink target.")
        print("  Ink can only be brought down to it by BLANKING LIT CELLS, which deletes")
        print("  part of the subject. Coverage is enforced below and ink is reported as")
        print("  an outcome; if it stays high, reframe (§3.5) rather than crushing the curve.")
    print()

    print(f"{'blackP':>7} {'whiteP':>7} {'gamma':>6} {'ink%':>7} {'covered':>9} {'entropy':>8}  verdict")
    cands = []
    for bp in args.black:
        for wp in args.white:
            for g in args.gamma:
                b = float(np.percentile(lit, bp)) if bp > 0 else float(lit.min())
                w = float(np.percentile(lit, wp))
                ink = kept = nlit = 0
                hist = np.zeros(len(ramp))
                for l in L:
                    idx = ramp.ideal_index(tone_curve(l, b, w, g) * ramp.peak)
                    inked = idx > 0
                    islit = l > 0
                    ink += int(inked.sum())
                    kept += int((inked & islit).sum())
                    nlit += int(islit.sum())
                    hist += np.bincount(idx.ravel(), minlength=len(ramp))
                inkf = ink / total
                cov = kept / max(1, nlit)
                p = hist / hist.sum(); nz = p[p > 0]
                ent = float(-(nz * np.log2(nz)).sum() / math.log2(len(ramp)))
                ok = cov >= args.min_coverage
                note = "" if ok else f"BLANKS {(1-cov)*100:.0f}% OF THE SUBJECT"
                print(f"{bp:>7.1f} {wp:>7.1f} {g:>6.2f} {inkf*100:>7.2f} {cov*100:>8.1f}% "
                      f"{ent:>8.3f}  {note}")
                if ok:
                    cands.append((-ent, bp, wp, g, inkf, ent, cov))

    if not cands:
        print(f"\nNo candidate keeps {args.min_coverage*100:.0f}% of the subject.")
        print("Lower --min-coverage only with a reason; the default exists because")
        print("blanking lit cells deletes the hero and no whole-frame metric shows it.")
        return 1
    cands.sort()
    print(f"\nBest: highest entropy among candidates keeping "
          f">= {args.min_coverage*100:.0f}% of the subject --")
    for ne, bp, wp, g, inkf, ent, cov in cands[:3]:
        print(f"  --black-pct {bp} --white-pct {wp} --gamma {g}   "
              f"ink {inkf*100:.2f}%  covered {cov*100:.1f}%  entropy {ent:.3f}")
    best_ink = cands[0][4]
    if abs(best_ink - args.ink_target) > 0.03:
        print(f"\n  Ink is {best_ink*100:.1f}% against a {args.ink_target*100:.0f}% target, with the")
        print("  subject intact. That is a FRAMING result, not a curve result: the lit")
        print(f"  ceiling is {ceiling*100:.1f}%, so this is what the subject costs at this")
        print("  framing. Move the camera back to spend less (§3.5).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
