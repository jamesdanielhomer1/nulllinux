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

# HOW LONG TO WATCH, and why it stopped being a constant.
#
# This was 2 s, then 6 s, raised each time because a topic that asks the package
# manager took longer than the window and reported NOTHING DREW -- which reads
# as a failure of the topic rather than of the probe. A window shorter than the
# thing being measured measures nothing.
#
# Six seconds was tuned on one laptop. Moved to a slower one, `update` took
# 6.9 s and the check failed again: the same defect the number was raised to
# fix, and exactly the shape §0.2 warns about -- a constant that is correct on
# the machine it was chosen on.
#
# So a topic that draws NOTHING is retried with a much longer window before it
# is called a failure. A genuinely broken topic still draws nothing after 30 s;
# a merely slow one does not. The check no longer needs to know how fast this
# machine is, which is the only version of it that travels.
SECS=${SECS:-6}
SECS_RETRY=${SECS_RETRY:-30}

fail=0
for t in $TOPICS; do
  if [ -n "${NOT_DRAWN[$t]:-}" ]; then
    printf '  %-10s not drawn here -- %s\n' "$t" "${NOT_DRAWN[$t]}"
    continue
  fi
  probe_topic() {  # <seconds>
    timeout $(( $1 + 20 )) python3 verify/coverage.py --cols 63 --rows 54 \
      --seconds "$1" --json -- \
      env NULL_COLUMN=1 NULL_ROOT="$ROOT" "$ROOT/bin/null-menu" "$t" 2>/dev/null
  }
  cells_of() {
    python3 -c "import json,sys; print(json.loads(sys.argv[1])['printable_cells'])" "$1" 2>/dev/null || echo 0
  }

  json=$(probe_topic "$SECS") || true
  slow=""
  if [ -n "$json" ] && [ "$(cells_of "$json")" -eq 0 ]; then
    # Nothing yet. Slow, or broken? Watch far longer and find out, rather than
    # guessing a bigger constant.
    json=$(probe_topic "$SECS_RETRY") || true
    slow="  [slow here: needed more than ${SECS}s]"
  fi
  if [ -z "$json" ]; then printf '  %-10s NO OUTPUT\n' "$t"; fail=1; continue; fi
  # A TOPIC REPORTING ABSENT HARDWARE IS SUPPOSED TO BE SHORT.
  #
  # The 200-cell floor exists to catch a topic that failed to start, because a
  # real menu draws thousands. But `bluetooth` on a machine with no adapter
  # correctly prints four lines saying so -- 170 cells -- and that is §8.4
  # working, not a broken topic. Lowering the floor for everything would blind
  # the check to the failure it was built for, so the floor moves only for a
  # topic whose hardware is genuinely absent, and the glyph rule still applies.
  floor=200
  case $t in
    bluetooth) "$ROOT/bin/machine" probe bluetooth 2>/dev/null || floor=20 ;;
    network)   "$ROOT/bin/machine" probe wireless  2>/dev/null || floor=20 ;;
  esac
  res=$(python3 - <<PY
import json
d=json.loads('''$json''')
tot=sum(d['unrenderable'].values())
if d['printable_cells']<$floor:
    print(f"NOTHING DREW ({d['printable_cells']} cells) -- a zero here is not evidence"); raise SystemExit(2)
if tot: print(" ".join(f"{k}x{v}" for k,v in d['unrenderable'].items())); raise SystemExit(1)
print(f"clean ({d['printable_cells']} printable)")
PY
)
  st=$?
  printf '  %-10s %s%s\n' "$t" "$res" "$slow"
  [ $st -ne 0 ] && fail=1
done
if [ $fail -eq 0 ]; then echo "PASS: every menu topic draws only glyphs the atlas has"; else exit 1; fi
