#!/usr/bin/env bash
# The Rust deriver must agree with the Python one (NULL.md §5.3, §10.2).
#
# There are two implementations of one tone curve, and there is exactly one
# reason that is acceptable: the Python needs numpy, about 30 MB on every
# installed machine to run for two minutes once per screen, and nothing else on
# an installed machine needs numpy at all. The Rust does the same work in a
# tenth of the time with no dependency.
#
# Two implementations drift. The drift would not look like a bug -- it would
# look like a slightly different picture -- so it is measured here rather than
# hoped for.
#
# NOT BIT-IDENTICAL, and that is not achievable: numpy and Rust reach f32 log
# through different libm, and an area resample sums in a different order. The
# standard is the one §2.3 already uses for a ramp -- WITHIN ONE STEP. A cell
# two steps out is a real disagreement; a cell one step out at a boundary is
# two correct answers to a tie.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
cd "$ROOT"

MASTER=assets/prebuilt/master.hero
RAMP=assets/prebuilt/strikes/ramp-ter-112n.json
RENDER=render/target/release/render

[ -r "$MASTER" ] || { echo "SKIPPED: no $MASTER -- run bin/null-prebake"; exit 0; }
[ -x "$RENDER" ] || { echo "SKIPPED: $RENDER is not built"; exit 0; }
python3 -c "import numpy" 2>/dev/null || { echo "SKIPPED: no numpy, so there is nothing to compare against"; exit 0; }

# A SMALL GRID ON PURPOSE. The full one takes two minutes in Python and this
# has to be cheap enough that nobody is tempted to skip it. Every stage runs
# either way: resample, exposure, hysteresis to a fixed point, loop closure.
COLS=${PARITY_COLS:-80}
ROWS=${PARITY_ROWS:-24}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

echo "== deriving ${COLS}x${ROWS} both ways"
"$RENDER" derive --master "$MASTER" --cols "$COLS" --rows "$ROWS" --ramp "$RAMP" \
  --palette-meta assets/palette.json --palette assets/palette.bin \
  --out "$tmp/rust.cells" >/dev/null 2>&1 || { echo "FAIL: the Rust deriver failed"; exit 1; }
python3 bake/derive_for_screen.py --master "$MASTER" --cols "$COLS" --rows "$ROWS" --ramp "$RAMP" \
  --palette-meta assets/palette.json --palette assets/palette.bin \
  --out "$tmp/py.cells" >/dev/null 2>&1 || { echo "FAIL: the Python deriver failed"; exit 1; }

python3 - "$tmp/rust.cells" "$tmp/py.cells" <<'PY'
import sys
sys.path.insert(0, "bake")
from formats import read_cells
import numpy as np

a = read_cells(sys.argv[1])
b = read_cells(sys.argv[2])
bad = 0

for k in ("cols", "rows", "frames", "fps", "ramp"):
    if a[k] != b[k]:
        print(f"  FAIL  {k}: rust={a[k]!r} python={b[k]!r}")
        bad = 1
    else:
        print(f"  ok    {k} agrees: {a[k]!r}")

ga, gb = np.array(a["glyphs"]), np.array(b["glyphs"])
ca, cb = np.array(a["colours"]), np.array(b["colours"])
if ga.shape != gb.shape:
    print(f"  FAIL  shapes differ: {ga.shape} vs {gb.shape}")
    raise SystemExit(1)

for name, x, y in (("glyphs", ga, gb), ("colours", ca, cb)):
    d = np.abs(x.astype(int) - y.astype(int))
    same = 100 * (d == 0).mean()
    worst = int(d.max())
    n_over = int((d > 1).sum())
    print(f"  {name:8} identical in {same:.4f}% of cells, largest disagreement {worst} step(s)")
    if n_over:
        print(f"  FAIL  {n_over} cell(s) differ by MORE than one step -- that is drift, not a tie")
        bad = 1

# A ramp is 16 steps; agreeing to within one step on ~99.99% of cells is what
# two libm implementations of the same curve look like. Much below that and
# something is actually different.
agree = 100 * (ga == gb).mean()
if agree < 99.9:
    print(f"  FAIL  glyphs agree on only {agree:.3f}% of cells")
    bad = 1

raise SystemExit(bad)
PY
st=$?
echo
[ $st -eq 0 ] && echo "PASS: the Rust deriver agrees with the Python one to within one ramp step" \
              || echo "FAIL: the two derivers disagree"
exit $st
