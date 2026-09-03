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

echo
printf '  %d tool(s) invoked, %d declared operator entry points\n' "$called" "$operator"
if [ $fail = 0 ]; then
  echo "PASS: every tool is either invoked or declares why it is not"
else
  echo "FAIL: a tool that nothing calls is a tool that never runs"
fi
exit $fail
