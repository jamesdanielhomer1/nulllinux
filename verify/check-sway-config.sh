#!/usr/bin/env bash
# The compositor's own validator.
#
# It reports errors on stdout while STILL EXITING 0, so the output is the
# evidence and the status is not (§10.1 rule 1). This wrapper exists so that
# distinction is made once, here, rather than forgotten at each call site.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd); cd "$ROOT"
out=$(sway --validate --config "$ROOT/config/sway/config" 2>&1)
if grep -q ERROR <<<"$out"; then
  echo "FAIL: the compositor rejects this configuration"
  grep ERROR <<<"$out" | head -8
  exit 1
fi
echo "PASS: the compositor accepts this configuration"
