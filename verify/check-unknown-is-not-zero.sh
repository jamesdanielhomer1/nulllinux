#!/usr/bin/env bash
# "I COULD NOT CHECK" IS NOT "NOTHING TO REPORT".
#
# lib/pkg/dnf5.sh had this:
#
#     dnf -q check-upgrade 2>/dev/null | grep -cE '^[a-zA-Z0-9]' || true
#
# dnf's errors go to /dev/null; an empty stdout makes `grep -c` print 0; and
# `|| true` clears the failing status. So a broken repository, a machine with
# no network, and a machine that is genuinely up to date all produced the same
# string: "0". bin/null-update said "PACKAGES: up to date" and the settings
# panel said "0 waiting" about a question nobody had managed to ask.
#
# Both callers already had an unknown branch -- one tests for an empty string,
# the other falls back to NULL_UNMEASURED -- and neither could ever be reached.
# The rule was already written down, one function further down the same file:
# "No metadata and metadata saying no updates are different answers."
#
# THIS RUNS THE THING, with a `dnf` that fails, and requires a different answer
# from the one a working machine gives. Reading the source could not tell them
# apart; that is how the defect survived being read.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

[ -x bin/pkg ] || { note "bin/pkg is gone"; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# ASK THE ABSTRACTION WHICH BACKEND IT IS (NULL.md 9.1: nothing outside
# lib/pkg/ names a package manager). `bin/pkg backend` exists to answer exactly
# that, and the first version of this file parsed bin/pkg's source for a
# variable instead -- reimplementing, badly, a question the tool already
# answers. It skipped every time, silently.
#
# The program to stand in for is then read from that backend's own file, so
# this names no package manager either.
backend=$(./bin/pkg backend 2>/dev/null)
[ -n "$backend" ] && [ -r "lib/pkg/$backend.sh" ] \
  || { note "(cannot tell which backend bin/pkg uses; skipped)"; exit 0; }
# COMMENTS STRIPPED FIRST. This file's own header quotes the broken line, and
# a check that reads its subject's prose is the mistake this suite has now made
# six times.
prog=$(grep -v '^[[:space:]]*#' "lib/pkg/$backend.sh" \
       | grep -oE '[a-z0-9]+ -q check-upgrade' | awk '{print $1}' | head -1)
[ -n "$prog" ] || { note "(the $backend backend does not use check-upgrade; skipped)"; exit 0; }

run_with() {  # <stand-in script body> -> prints "rc=N out=..."
  printf '#!/bin/sh\n%s\n' "$1" > "$tmp/bin/$prog"
  chmod +x "$tmp/bin/$prog"
  local out rc=0
  out=$(PATH="$tmp/bin:$PATH" ./bin/pkg upgrade-count 2>/dev/null) || rc=$?
  printf 'rc=%s out=%s\n' "$rc" "$out"
}

# 1. A MACHINE THAT CANNOT ANSWER MUST NOT SAY ZERO.
broke=$(run_with 'echo "Errors during downloading metadata" >&2
exit 2')
case $broke in
  rc=0*) note "with a failing $prog, upgrade-count still succeeded: $broke"
         note "      so 'could not check' is indistinguishable from 'up to date'"; fail=1 ;;
  *)     note "ok    a $prog that fails makes upgrade-count fail too" ;;
esac
case $broke in
  *"out=0") note "with a failing $prog, upgrade-count printed 0"; fail=1 ;;
esac

# 2. AND A MACHINE WITH NOTHING PENDING MUST SAY ZERO, or the fix has simply
#    moved the ambiguity to the other side.
none=$(run_with 'exit 0')
[ "$none" = "rc=0 out=0" ] \
  && note "ok    nothing pending is reported as 0, and succeeds" \
  || { note "a machine with no upgrades reported '$none' rather than 'rc=0 out=0'"; fail=1; }

# 3. AND ONE WITH UPGRADES MUST COUNT THEM. dnf5 exits 100 when there are any,
#    which is a success, and a backend that treats every non-zero status as a
#    failure would report a machine with updates as unable to check.
some=$(run_with 'cat <<EOF
foo.x86_64  1.2-3  updates
bar.noarch  4.5-6  updates
EOF
exit 100')
[ "$some" = "rc=0 out=2" ] \
  && note "ok    two pending upgrades are counted as 2" \
  || { note "a machine with two upgrades reported '$some' rather than 'rc=0 out=2'"; fail=1; }

# 4. THE CALLERS MUST HAVE SOMEWHERE TO PUT THE UNKNOWN. A backend that
#    distinguishes them is no use if the panel prints the empty string.
grep -q 'NULL_UNMEASURED' bin/null-settings \
  || { note "bin/null-settings has no unmeasured fallback for the update count"; fail=1; }
grep -qE '\[ -z "\$n" \]|\[ -z "\$\{n' bin/null-update \
  || { note "bin/null-update does not test for an empty count, so it cannot report 'unknown'"; fail=1; }

[ $fail = 0 ] && echo "PASS: not knowing and nothing-to-report are different answers"
exit $fail
