#!/usr/bin/env bash
# Prove the structural check can FAIL.
#
# NULL.md §10.1 rule 3: a measurement where every candidate returns the same
# answer usually means the measurement is broken. A structural check that has
# never failed is indistinguishable from one that cannot fail, and the second
# kind is worse than none -- it reports success for ever.
#
# This plants a real violation, confirms the check catches it, removes it, and
# confirms the check passes again.

set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
cd "$ROOT"

PLANT=bin/__selftest_violation
cleanup() { rm -f "$PLANT"; git -C "$ROOT" rm --cached -q "$PLANT" 2>/dev/null || true; }
trap cleanup EXIT

# 1. clean state must pass
if ! ./verify/check-package-abstraction.sh >/dev/null 2>&1; then
  echo "SELFTEST FAIL: check does not pass on a clean tree"; exit 1
fi

# 2. plant a violation and make it visible to the checker
printf '#!/bin/sh\ndnf install -y something\n' > "$PLANT"
chmod +x "$PLANT"
git -C "$ROOT" add -N "$PLANT" >/dev/null 2>&1

if ./verify/check-package-abstraction.sh >/dev/null 2>&1; then
  echo "SELFTEST FAIL: check PASSED with a planted violation -- it cannot fail, so it proves nothing"
  exit 1
fi

# 3. remove it and confirm the check recovers
cleanup
trap - EXIT
if ! ./verify/check-package-abstraction.sh >/dev/null 2>&1; then
  echo "SELFTEST FAIL: check still fails after the violation was removed"; exit 1
fi

echo "PASS: the structural check catches a planted violation and clears when it is removed"
