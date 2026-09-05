#!/usr/bin/env bash
# Dwindle really splits along the longer axis (NULL.md §8.2).
#
# Asserted by OPENING WINDOWS AND MEASURING, not by reading the configuration
# back. A layout daemon that has crashed, or that is being overridden, leaves a
# configuration that still says exactly what it said before.
#
# The signature of dwindle on a 16:9 output is that the split direction
# ALTERNATES: the space starts wider than tall, so it splits side by side; each
# half is then taller than wide, so it splits top and bottom; and so on. Any
# layout that does not do this produces slivers, which is the thing dwindle
# exists to prevent.
set -uo pipefail
N=${1:-5}
WS=${NULL_TEST_WS:-99}

# A CHECK THAT CANNOT RUN HERE IS NOT A CHECK THAT FAILED.
#
# These exited 1, so the suite reported a failure whenever it was run without a
# graphical session -- from a systemd unit or cron, say. That is indistinguish-
# able from the layout being broken, and it trains people to ignore the suite.
command -v swaymsg >/dev/null || {
  echo "SKIPPED: no swaymsg, so there is no compositor to ask"; exit 0; }
swaymsg -t get_version >/dev/null 2>&1 || {
  echo "SKIPPED: no compositor answering; run this from a graphical session"; exit 0; }

pgrep -x dwindle >/dev/null || { echo "FAIL: the dwindle daemon is not running"; exit 1; }
echo "daemon running (pid $(pgrep -x dwindle | head -1))"

prev=$(swaymsg -t get_workspaces | python3 -c \
  'import json,sys; print(next(w["name"] for w in json.load(sys.stdin) if w["focused"]))')
swaymsg "workspace $WS" >/dev/null

opened=0
cleanup() {
  for _ in $(seq 1 "$opened"); do swaymsg kill >/dev/null 2>&1; sleep 0.2; done
  swaymsg "workspace $prev" >/dev/null 2>&1
}
trap cleanup EXIT


echo
printf '%-4s %-26s %s\n' "win" "focused rect before open" "verdict"
fail=0
for i in $(seq 1 "$N"); do
  # The rect the daemon is deciding about is the focused one, before the split.
  before=$(swaymsg -t get_tree | python3 -c '
import json,sys
def f(v):
    if v.get("focused"): return v
    for k in ("nodes","floating_nodes"):
        for c in v.get(k) or []:
            r=f(c)
            if r: return r
n=f(json.load(sys.stdin))
r=(n or {}).get("rect",{})
print(r.get("width",0), r.get("height",0))')
  bw=${before%% *}; bh=${before##* }

  foot -a dwindle-probe >/dev/null 2>&1 &
  opened=$((opened + 1))
  sleep 1.2

  if [ "$i" -gt 1 ]; then
    # After splitting a WxH box along its longer axis, no leaf should be more
    # than ~2.2x the aspect ratio of the box it came from in the wrong
    # direction. The simple, decisive check: the new focused window's longer
    # side must be the one that did NOT get divided.
    now=$(swaymsg -t get_tree | python3 -c '
import json,sys
def f(v):
    if v.get("focused"): return v
    for k in ("nodes","floating_nodes"):
        for c in v.get(k) or []:
            r=f(c)
            if r: return r
n=f(json.load(sys.stdin)); r=(n or {}).get("rect",{})
print(r.get("width",0), r.get("height",0))')
    nw=${now%% *}; nh=${now##* }
    if [ "$bw" -gt "$bh" ]; then
      # was wider: the WIDTH should have been divided, height kept
      if [ "$nh" -eq "$bh" ] && [ "$nw" -lt "$bw" ]; then v="ok  split side by side"; else v="FAIL expected a vertical cut"; fail=1; fi
    else
      if [ "$nw" -eq "$bw" ] && [ "$nh" -lt "$bh" ]; then v="ok  split top and bottom"; else v="FAIL expected a horizontal cut"; fail=1; fi
    fi
    printf '%-4s %-26s %s (now %sx%s)\n' "$i" "${bw}x${bh}" "$v" "$nw" "$nh"
  else
    printf '%-4s %-26s %s\n' "$i" "${bw}x${bh}" "(first window; nothing to split)"
  fi
done

echo
echo "final leaves:"
python3 "$(dirname "$0")/dwindle_leaves.py" "$WS"
exit "$fail"
