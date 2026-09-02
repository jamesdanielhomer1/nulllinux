#!/usr/bin/env bash
# Measure the bar's own CPU time (NULL.md §6.4, §7.2, §10.7).
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd); cd "$ROOT"
# Same reason as measure-render.sh: under a session lock a layer-shell surface
# gets no frame callbacks, draws nothing, and would be reported at 0.00% --
# a number that looks like success and means "not measured" (§10.7).
if pgrep -x swaylock >/dev/null 2>&1; then
  echo "REFUSING: the session is locked; every figure here would be a false zero." >&2
  exit 1
fi

BAR=./render/target/release/bar
WINDOW=${WINDOW:-10}; RUNS=${RUNS:-5}; HZ=$(getconf CLK_TCK)
vals=()
for _ in $(seq "$RUNS"); do
  NULL_ROOT="$ROOT" "$BAR" >/dev/null 2>&1 & pid=$!
  sleep 1
  kill -0 "$pid" 2>/dev/null || { echo "  bar died on startup -- refusing to report 0.00%"; exit 1; }
  t0=$(awk '{print $14+$15}' "/proc/$pid/stat"); sleep "$WINDOW"
  kill -0 "$pid" 2>/dev/null || { echo "  bar died mid-window -- refusing to report"; exit 1; }
  t1=$(awk '{print $14+$15}' "/proc/$pid/stat")
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  vals+=( "$(awk -v a=$t0 -v b=$t1 -v hz=$HZ -v w=$WINDOW 'BEGIN{printf "%.2f",(b-a)/hz/w*100}')" )
  sleep 0.5
done
echo "bar CPU, % of one core -- ${WINDOW}s window, median of ${RUNS} runs"
echo "  load $(uptime | sed 's/.*load average: //')"
awk -v h=$HZ -v w=$WINDOW 'BEGIN{printf "  floor: one tick is %.2f%% over this window\n",100/h/w}'
printf '%s\n' "${vals[@]}" | sort -n | awk -v n=${#vals[@]} '
  {v[NR]=$1} END{m=(n%2)?v[(n+1)/2]:(v[n/2]+v[n/2+1])/2
  printf "  median %5.2f%%   range %.2f-%.2f\n",m,v[1],v[n]}'
