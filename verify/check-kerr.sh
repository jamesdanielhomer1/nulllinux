#!/usr/bin/env bash
# The analytic checks, and the shader against the reference (NULL.md §10.2).
#
# Run BEFORE any long bake. Every failure mode these cover produces an image
# that looks entirely fine, which is the whole argument for analytic checks
# over eyeballing.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd); cd "$ROOT"
fail=0
python3 bake/validate.py || fail=1
echo
if [ -x bake/gpu/target/release/kerr-gpu ]; then
  python3 bake/crossvalidate.py --cols 80 --rows 24 || fail=1
else
  echo "  (compute shader not built -- cross-validation skipped, and that is"
  echo "   a GAP rather than a pass)"
  fail=1
fi
exit $fail
