#!/usr/bin/env bash
# Every tool must have a caller (NULL.md §10.1).
#
# THIS BUG HAS HAPPENED THREE TIMES.
#
#   bin/null-join      wrote the shell and git joins. Nothing invoked it, so a
#                      freshly installed machine had no prompt. Fixed by moving
#                      the call into bin/null-firstrun.
#   bin/null-firstrun  then had no caller either -- the same defect, one level
#                      out. Fixed by an `exec` in the compositor configuration.
#   bin/null-toolkit   applies the settings keys that §8.10 says OUTRANK every
#                      configuration file this system writes. Nothing ran it,
#                      so a stale font or icon theme from a previous desktop
#                      silently won.
#
# Each was found by hand, on a machine that was not the one it was written on.
# A tool with no caller is indistinguishable from a tool that works: it is
# present, it is executable, it is tested, and it never runs.
#
# An OPERATOR ENTRY POINT is exempt -- a human types it -- but it must say so
# in its own header, in one specific phrase, so the exemption is a decision
# rather than the default.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
cd "$ROOT"

MARK='OPERATOR ENTRY POINT'
fail=0
called=0 operator=0

for f in bin/*; do
  [ -f "$f" ] || continue
  n=$(basename "$f")

  # Anything that names it, other than itself.
  callers=$(grep -rl --exclude-dir=.git --exclude-dir=rpmbuild --exclude-dir=repo \
              --exclude-dir=prebuilt --exclude-dir=target --exclude-dir=build \
              -F "$n" bin config packaging verify render lib 2>/dev/null \
            | grep -v "^bin/$n\$" || true)

  if [ -n "$callers" ]; then
    called=$((called + 1))
    continue
  fi
  if head -30 "$f" | grep -qF "$MARK"; then
    operator=$((operator + 1))
    printf '  operator  %-22s %s\n' "$n" "(declared; a human runs it)"
    continue
  fi
  printf '  NO CALLER %-22s nothing in the tree invokes it, and it does not\n' "$n"
  printf '            %-22s declare itself an %s\n' "" "$MARK"
  fail=1
done

# AND EVERY CHECK MUST BE IN THE SUITE.
#
# The same defect one level further out. A check file that exists, passes when
# run by hand, and is not in verify/run.sh is indistinguishable from a check
# that works -- and it is easier to end up with than an uncalled tool, because
# writing the check feels like the finish.
#
# It happened while this very line was being written: a sed replacement using
# \& -- which sed reads as "the whole match" rather than as an ampersand, a
# trap this project has already documented once -- REPLACED the line
# registering check-idle-ladder-writable with a bare `&`. That broke run.sh
# outright, so it was caught in seconds; had the substitution been slightly
# different it would have silently dropped a check instead.
suite=verify/run.sh
for c in verify/check-*.sh; do
  b=$(basename "$c")
  if grep -qF "$b" "$suite"; then
    :
  else
    printf '  %s exists but is not in %s -- it would never run\n' "$c" "$suite"
    fail=1
  fi
done
# And the suite must not name a check that is gone, which would fail every run
# for a reason that has nothing to do with the tree.
while read -r named; do
  [ -e "$named" ] || { printf '  %s names %s, which does not exist\n' "$suite" "$named"; fail=1; }
done < <(grep -oE '\./verify/check-[a-z-]+\.sh' "$suite" | sort -u)

echo
printf '  %d tool(s) invoked, %d declared operator entry points, %d check(s) in the suite\n' \
  "$called" "$operator" "$(grep -c '^run ' "$suite")"
if [ $fail = 0 ]; then
  echo "PASS: every tool is either invoked or declares why it is not"
else
  echo "FAIL: a tool that nothing calls is a tool that never runs"
fi
exit $fail
