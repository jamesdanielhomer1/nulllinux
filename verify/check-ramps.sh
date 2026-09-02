#!/usr/bin/env bash
# Ramp monotonicity and the font hash guard, per strike (NULL.md §2.3, §2.4, §10.3).
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd); cd "$ROOT"
fail=0
for r in assets/ramp-*.json; do
  python3 bake/derive_ramp.py --verify "$r" || fail=1
done
exit $fail
