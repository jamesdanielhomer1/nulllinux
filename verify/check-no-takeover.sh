#!/usr/bin/env bash
# Every installer that writes system-wide files must refuse to take over a
# machine that already runs a different installation. See bin/null-install.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
if ! grep -q 'NULL_REPLACE' bin/null-install; then
  echo "bin/null-install: no takeover guard -- it would silently replace another installation"
  fail=1
fi
# the guard has to come before anything is written
guard=$(grep -n 'NULL_REPLACE' bin/null-install | head -1 | cut -d: -f1)
first_write=$(grep -nE '^\s*(install_|write_|ln -sf|cp .*/etc/)' bin/null-install | head -1 | cut -d: -f1)
if [ -n "$guard" ] && [ -n "$first_write" ] && [ "$guard" -gt "$first_write" ]; then
  echo "bin/null-install: the takeover guard is at line $guard, after the first write at line $first_write"
  fail=1
fi
[ $fail = 0 ] && echo "installers refuse to take over a machine running something else"
exit $fail
