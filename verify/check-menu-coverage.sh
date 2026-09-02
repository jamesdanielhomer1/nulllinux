#!/usr/bin/env bash
# Every menu topic must audit at ZERO unrenderable codepoints, or be explicitly
# not hosted with its count recorded as the reason (NULL.md §11 Phase 6, §10.5).
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd); cd "$ROOT"
export NULL_ROOT="$ROOT"
# TOPICS ARE DERIVED FROM THE MENU, not listed here. A hand-kept list stops
# covering the topics added after it was written -- which had already happened:
# seven topics existed that this file had never heard of, and it reported PASS.
#
# Read from the case branches of bin/null-menu. Branches that only re-exec into
# another topic still draw a picker, so they are included too.
derive_topics() {
  # Not anchored to end-of-line: a one-line branch such as
  #   apps)     exec "$B/null-run" ;;
  # is still a topic, and matching only `name)$` silently skipped six of them.
  sed -nE 's/^  ([a-z][a-z|-]*)\).*/\1/p' bin/null-menu | tr '|' '\n' | sort -u
}
TOPICS=${TOPICS:-$(derive_topics)}
[ -n "$TOPICS" ] || { echo "no topics derived from bin/null-menu -- refusing to pass" >&2; exit 1; }
echo "topics derived from bin/null-menu: $(wc -w <<<"$TOPICS")"
# Topics that draw nothing IN A PTY, with the reason recorded rather than the
# topic quietly dropped (§10.5). These are not exemptions from the rule; they
# are surfaces the rule cannot reach with this instrument.
declare -A NOT_DRAWN=(
  [monitor]="sends an IPC message to the running column; it draws in the column, not here"
  [netconfig]="sends an IPC message to the running column; nmtui is measured directly, and is clean"
  [mixer]="sends an IPC message to the running column; wiremix cannot be measured without a PipeWire session"
)

# Five seconds, not two. The update topic asks the package manager and takes
# about 2.7 s to build its list -- longer than the old window -- so it reported
# NOTHING DREW and that read as a failure of the topic rather than of the
# probe. A window shorter than the thing being measured measures nothing.
SECS=${SECS:-6}

fail=0
for t in $TOPICS; do
  if [ -n "${NOT_DRAWN[$t]:-}" ]; then
    printf '  %-10s not drawn here -- %s\n' "$t" "${NOT_DRAWN[$t]}"
    continue
  fi
  json=$(timeout 30 python3 verify/coverage.py --cols 63 --rows 54 --seconds "$SECS" --json -- \
    env NULL_COLUMN=1 NULL_ROOT="$ROOT" "$ROOT/bin/null-menu" "$t" 2>/dev/null) || true
  if [ -z "$json" ]; then printf '  %-10s NO OUTPUT\n' "$t"; fail=1; continue; fi
  res=$(python3 - <<PY
import json
d=json.loads('''$json''')
tot=sum(d['unrenderable'].values())
if d['printable_cells']<200:
    print(f"NOTHING DREW ({d['printable_cells']} cells) -- a zero here is not evidence"); raise SystemExit(2)
if tot: print(" ".join(f"{k}x{v}" for k,v in d['unrenderable'].items())); raise SystemExit(1)
print(f"clean ({d['printable_cells']} printable)")
PY
)
  st=$?
  printf '  %-10s %s\n' "$t" "$res"
  [ $st -ne 0 ] && fail=1
done
if [ $fail -eq 0 ]; then echo "PASS: every menu topic draws only glyphs the atlas has"; else exit 1; fi
