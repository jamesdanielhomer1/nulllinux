#!/usr/bin/env bash
# The terminal-adjacent surfaces, verified by RUNNING them and reading the
# codepoints -- never by reading their configuration (NULL.md §7.6, §11 Ph.7).
#
# These tools default to icon-font glyphs and powerline separators, which are
# pictograms from private-use codepoints this font does not have and cannot
# have. Reading a config file would prove only that a file exists.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd); cd "$ROOT"
export NULL_ROOT="$ROOT"
# Longer than one screen, so the pager actually PAGES. With a short file the
# configured -F makes less quit immediately having drawn almost nothing, and
# the audit then reports a zero taken from a blank screen -- which the tool
# refuses, correctly (§10.5).
awk 'BEGIN{for(i=1;i<=200;i++) printf "line %03d  the quick brown fox jumps over the lazy dog\n", i}' \
  > /tmp/null-pager-probe.txt
fail=0

audit() {  # <label> <min-cells> <command...>
  local label=$1 min=$2; shift 2
  timeout 40 python3 verify/coverage.py --cols 100 --rows 30 --seconds 2 --json -- \
    "$@" > /tmp/null-cov.json 2>/dev/null
  python3 - "$label" "$min" <<'PY'
import json, sys
label, minimum = sys.argv[1], int(sys.argv[2])
try:
    d = json.load(open('/tmp/null-cov.json'))
except Exception as e:
    print(f"  {label:<16} could not read coverage: {e}"); raise SystemExit(1)
tot = sum(d['unrenderable'].values())
if d['printable_cells'] < minimum:
    print(f"  {label:<16} ONLY {d['printable_cells']} cells drew -- a zero here is not evidence")
    raise SystemExit(2)
if tot:
    print(f"  {label:<16} {tot} unrenderable: " + " ".join(f"{k}x{v}" for k,v in d['unrenderable'].items()))
    raise SystemExit(1)
print(f"  {label:<16} clean ({d['printable_cells']} cells)")
PY
  [ $? -ne 0 ] && fail=1
  return 0
}

audit "prompt" 100 bash -c '. '"$ROOT"'/config/shell/nullLinux.sh; cd '"$ROOT"'
  for i in $(seq 6); do true; __null_prompt; printf "%s\n" "${PS1@P}"
                        false; __null_prompt; printf "%s\n" "${PS1@P}"; done'
audit "pager"  400 env HOME="$HOME" bash -lc 'less /tmp/null-pager-probe.txt'
# A scratch repository with a KNOWN dirty state, so these probes do not depend
# on whatever the real tree happens to look like. Run against the real repo,
# `git status` drew 51 cells on a clean tree and the audit correctly refused to
# read a zero off a near-empty screen -- a probe whose output depends on
# unrelated state is not a probe.
SCRATCH=/tmp/null-git-probe
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
(
  cd "$SCRATCH"
  git init -q -b main
  git config user.name probe; git config user.email probe@localhost
  # Enough content that the diff exercises real colouring -- added lines,
  # removed lines, hunk headers and context -- rather than one changed word.
  awk 'BEGIN{for(i=1;i<=40;i++) printf "line %02d  the quick brown fox\n", i}' > tracked.txt
  awk 'BEGIN{for(i=1;i<=20;i++) printf "other %02d  jumps over the lazy dog\n", i}' > second.txt
  git add -A && git -c commit.gpgsign=false commit -qm "first"
  awk 'BEGIN{for(i=1;i<=40;i++){ if(i%4==0) printf "line %02d  CHANGED here\n", i;
                                 else printf "line %02d  the quick brown fox\n", i }
             for(i=41;i<=48;i++) printf "line %02d  appended\n", i }' > tracked.txt
  awk 'BEGIN{for(i=1;i<=12;i++) printf "other %02d  jumps over the lazy dog\n", i}' > second.txt
  printf 'new file\n' > untracked.txt
  mkdir -p sub && printf 'deep\n' > sub/deep.txt
) >/dev/null 2>&1

audit "diff"   200 env HOME="$HOME" bash -lc "cd $SCRATCH && git --no-pager diff && git --no-pager log --oneline"
audit "status" 200 env HOME="$HOME" bash -lc "cd $SCRATCH && git --no-pager status"

if [ $fail -eq 0 ]; then
  echo "PASS: every terminal-adjacent surface draws only glyphs the font has"
else
  exit 1
fi
