#!/usr/bin/env bash
# Exclusive-zone transitions, measured against a REAL tiled window (§7.3, §11).
#
# The claim under test is that a window RESIZES with the column rather than
# being covered by it, at every width, and that the zone is released when the
# column stops -- a null-buffer unmap does NOT release it, which leaves the
# surface gone and the windows still squashed beside a column that is no longer
# there.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd); cd "$ROOT"
export NULL_ROOT="$ROOT"
COL=./render/target/release/column

# THIS CHECK TEARS DOWN THE LIVE COLUMN, so it must put it back -- on success,
# on failure, and on interrupt. It did not, and the desktop was twice left with
# no sidebar until someone noticed and restarted it by hand.
#
# A check that damages the thing it checks is worse than no check: it is a
# check with a cost nobody attributed to it, so the surface looked flaky and
# the verifier looked innocent.
was_running=0
pgrep -x column >/dev/null 2>&1 && was_running=1

restore_column() {
  pkill -x column 2>/dev/null
  sleep 0.5
  if [ "$was_running" -eq 1 ]; then
    NULL_ROOT="$ROOT" setsid "$ROOT/bin/null-column" >/dev/null 2>&1 &
    sleep 1
    if pgrep -x column >/dev/null 2>&1; then
      echo "  (the column was running before this check and has been restarted)"
    else
      echo "  WARNING: could not restart the column -- the desktop is left without it" >&2
    fi
  fi
}
trap restore_column EXIT

geom() {  # geometry of the first real tiled window
  swaymsg -t get_tree | python3 -c "
import json,sys
def w(n):
    for c in (n.get('nodes') or [])+(n.get('floating_nodes') or []):
        if c.get('pid') and c.get('app_id'):
            r=c['rect']; print(f\"{r['x']},{r['y']} {r['width']}x{r['height']}\"); return True
        if w(c): return True
    return False
w(json.load(sys.stdin)) or print('none')"
}

pkill -x column 2>/dev/null; sleep 0.5
swaymsg workspace 3 >/dev/null 2>&1; sleep 0.5
foot >/dev/null 2>&1 & FOOT=$!
sleep 2
printf '  %-34s %s\n' "no column:" "$(geom)"

"$COL" >/dev/null 2>&1 & COLPID=$!
sleep 2
printf '  %-34s %s\n' "column up, not hosting (zone 0):" "$(geom)"

"$COL" --send open keys >/dev/null 2>&1; sleep 2
printf '  %-34s %s\n' "hosting keys (65 cells = 650 px):" "$(geom)"

"$COL" --send open monitor >/dev/null 2>&1; sleep 3
printf '  %-34s %s\n' "hosting monitor (82 cells = 820 px):" "$(geom)"

"$COL" --send close >/dev/null 2>&1; sleep 2
printf '  %-34s %s\n' "closed (zone released):" "$(geom)"

kill $COLPID 2>/dev/null; sleep 1.5
printf '  %-34s %s\n' "column gone entirely:" "$(geom)"

kill $FOOT 2>/dev/null; wait $FOOT 2>/dev/null
swaymsg workspace 1 >/dev/null 2>&1
# restore_column runs from the EXIT trap, so it also covers a failure or a ^C
