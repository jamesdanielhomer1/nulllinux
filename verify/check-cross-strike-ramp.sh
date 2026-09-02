#!/usr/bin/env bash
# §2.3 is a claim about THIS font, so it is tested rather than asserted: the
# bake ramp must NOT be monotonic at the interface strike. If this ever passes,
# the rule has become vacuous on this font and the reason for deriving per
# strike needs restating from evidence rather than from habit.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd); cd "$ROOT"
python3 - <<'PY'
import sys, json; sys.path.insert(0,'bake')
from fontlib import Font
bake=json.load(open('assets/ramp-bake.json'))
iface=json.load(open('assets/ramp-interface.json'))
f=Font(iface['font'])
cov=[f.ink(f.cp_to_index[ord(c)])/f.cell_pixels for c in bake['ramp']]
bad=[i for i in range(1,len(cov)) if cov[i]<=cov[i-1]]
if bad:
    print(f"PASS: the bake ramp has {len(bad)} inversion(s) at the interface strike "
          f"-- a ramp belongs to one strike (§2.3), demonstrated not assumed")
    sys.exit(0)
print("FAIL: the bake ramp is monotonic at the interface strike too."); sys.exit(1)
PY
