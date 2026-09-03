#!/usr/bin/env bash
# Prove check-callers.sh can fail, and that its one exemption really exempts.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
cd "$ROOT"

# SPLIT ON PURPOSE, for the same reason as selftest-package-abstraction.sh:
# this file names the tool it plants, and check-callers.sh treats any file that
# names a tool as that tool's caller -- so written plainly, the plant would
# appear to have a caller and the self-test would silently prove nothing. It
# did, on the first run. Adjacent strings concatenate at parse time, so the
# full name never appears on disk.
PLANT="bin/null-""_selftest_orphan"
cleanup() { rm -f "$PLANT"; }
trap cleanup EXIT
fails=0

./verify/check-callers.sh >/dev/null 2>&1 \
  || { echo "SELFTEST FAIL: does not pass on a clean tree"; exit 1; }

# 1. a tool nothing calls must be caught
printf '#!/bin/sh\n# A tool with no caller.\necho hi\n' > "$PLANT"; chmod +x "$PLANT"
if ./verify/check-callers.sh >/dev/null 2>&1; then
  echo "  MISS  an orphaned tool"; fails=1
else
  echo "  ok    catches an orphaned tool"
fi

# 2. ... and declaring it an operator entry point must clear it
printf '#!/bin/sh\n# OPERATOR ENTRY POINT -- a human runs this by hand.\necho hi\n' > "$PLANT"
if ./verify/check-callers.sh >/dev/null 2>&1; then
  echo "  ok    the declared exemption clears it"
else
  echo "  MISS  the declared exemption did not clear it"; fails=1
fi

# 3. the declaration must be in the HEADER, not buried 200 lines down where it
#    would never be read as a statement of intent.
{ printf '#!/bin/sh\n'; for i in $(seq 1 40); do echo "# filler $i"; done
  printf '# OPERATOR ENTRY POINT\necho hi\n'; } > "$PLANT"
if ./verify/check-callers.sh >/dev/null 2>&1; then
  echo "  MISS  accepted a declaration buried below the header"; fails=1
else
  echo "  ok    requires the declaration in the header"
fi

cleanup; trap - EXIT
./verify/check-callers.sh >/dev/null 2>&1 \
  || { echo "SELFTEST FAIL: still fails after the plant was removed"; exit 1; }

[ $fails = 0 ] || { echo "SELFTEST FAIL: the check does not discriminate"; exit 1; }
echo "PASS: the caller check catches an orphan and honours its one exemption"
