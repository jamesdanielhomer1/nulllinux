#!/usr/bin/env bash
# Measure the renderer's own CPU time (NULL.md §6.4, §10.7).
#
# CPU time, not battery draw: this battery exposes no power reading, that
# figure is the charge current while on mains, and the kernel's energy counters
# are root-only. CPU time needs no privileges and isolates OUR process.
#
# §10.7 discipline: the state measured is FORCED rather than left to whatever
# the desktop is doing; several runs are taken and the median reported with the
# range, because a single sample of a sub-1%-of-a-core figure is worth about as
# much as a coin toss; and a process that died is refused rather than reported
# as a flawless 0.00%.

set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd); cd "$ROOT"

# A SESSION LOCK INVALIDATES EVERY MEASUREMENT HERE. A layer-shell surface
# under a lock surface receives no frame callbacks, so it never draws and burns
# nothing -- and the harness then reports 0.00%, which reads as a triumph.
# --force-animate sets OUR flag; it cannot make the compositor deliver frame
# callbacks.
#
# This is §10.7's "refuse to report a process that died as a flawless zero",
# generalised: a surface that never DREW must not be reported as one either.
if pgrep -x swaylock >/dev/null 2>&1; then
  echo "REFUSING: the session is locked." >&2
  echo "  A layer-shell surface under a lock surface gets no frame callbacks," >&2
  echo "  so every figure here would be 0.00% and every one of them a lie." >&2
  exit 1
fi

RENDER=./render/target/release/render
CELLS=${CELLS:-assets/placeholder.cells}
ATLAS=${ATLAS:-assets/atlas-bake.bin}
WINDOW=${WINDOW:-10}
RUNS=${RUNS:-5}
HZ=$(getconf CLK_TCK)

# sample <label> <env-assignments...> -- <cli-flags...>
sample() {
  local label=$1; shift
  local envs=() flags=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  while [ $# -gt 0 ]; do flags+=("$1"); shift; done

  local vals=()
  for _ in $(seq "$RUNS"); do
    env "${envs[@]}" "$RENDER" --file "$CELLS" --atlas "$ATLAS" layershell "${flags[@]}" \
        >/dev/null 2>&1 &
    local pid=$!
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
      printf '  %-28s DIED on startup -- refusing to report 0.00%%\n' "$label"; return 1
    fi
    local t0 t1
    t0=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null)
    sleep "$WINDOW"
    if ! kill -0 "$pid" 2>/dev/null; then
      printf '  %-28s DIED mid-window -- refusing to report a number\n' "$label"; return 1
    fi
    t1=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null)
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    vals+=( "$(awk -v a="$t0" -v b="$t1" -v hz="$HZ" -v w="$WINDOW" \
              'BEGIN{printf "%.2f", (b-a)/hz/w*100}')" )
    sleep 0.5
  done
  printf '  %-28s ' "$label"
  # An exactly-zero median for a sample that is meant to be working is not a
  # result, it is a missing measurement. Say so rather than printing it.
  printf '%s\n' "${vals[@]}" | sort -n | awk -v n="${#vals[@]}" -v z="${EXPECT_NONZERO:-0}" '
    {v[NR]=$1}
    END{ med=(n%2)?v[(n+1)/2]:(v[n/2]+v[n/2+1])/2
         if (z && med == 0 && v[n] == 0) {
           print "ALL SAMPLES EXACTLY ZERO -- the surface never drew;"
           printf "%-30s not a result. Something stopped it (lock, occlusion, no output).\n", ""
           exit 1
         }
         printf "median %5.2f%%   range %.2f-%.2f\n", med, v[1], v[n] }'
}

echo "renderer CPU, % of one core -- ${WINDOW}s window, median of ${RUNS} runs"
echo "  asset    $CELLS"
echo "  machine  $(./bin/machine get name), $(nproc) threads"
echo "  load     $(uptime | sed 's/.*load average: //')"
awk -v h="$HZ" -v w="$WINDOW" 'BEGIN{printf "  floor    one scheduler tick is %.2f%% over this window\n", 100/h/w}'
echo
EXPECT_NONZERO=1 sample "animating"        -- --force-animate
sample "suspended"        RENDER_ASSUME_OCCLUDED=1 --
EXPECT_NONZERO=1 sample "animating, battery" RENDER_ASSUME_BATTERY=1 -- --force-animate
