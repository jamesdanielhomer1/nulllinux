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
# THIS NEEDS A GIT CHECKOUT, and says so rather than dying.
#
# It plants a file and asks git to forget it, so on a deployed tree -- which is
# an unpacked tarball, not a repository -- git exits 128 and `set -e` takes the
# script down before it prints anything at all. A check that fails silently on
# a whole class of machine is worse than one that says it cannot run here.
if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "SKIPPED: not a git checkout, and this self-test plants and un-plants a"
  echo "         tracked file. Run it on the build host, where the repository is."
  exit 0
fi
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
