#!/usr/bin/env bash
# Every screen gets its own furniture (NULL.md §0.2, §6.3).
#
# A layer surface created with no output is placed by the compositor on
# whichever screen it likes. With one monitor that is always right, so the bug
# is invisible on the machine this was written on -- and on a second monitor
# the desktop simply is not there. Nothing reports it: the process is running,
# drawing, and costing CPU, exactly as it does when correct.
#
# Two things are checked, because either alone can be true while the desktop is
# still wrong:
#
#   1. no surface may pass None for its output, unless it says why;
#   2. the chosen hero must never be LARGER than the screen it is for -- a
#      surface bigger than its output is drawn cropped, and a cropped hero
#      looks like a working desktop.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
cd "$ROOT"
fail=0

echo "== every layer surface is pinned, or says why not"
while IFS= read -r loc; do
  f=${loc%%:*}; n=${loc#*:}; n=${n%%:*}
  # The five lines before the call must either bind an output, or carry the
  # word `deliberate` -- an exemption that has to be written down, not assumed.
  ctx=$(sed -n "$((n>12 ? n-12 : 1)),$((n+3))p" "$f")
  if printf '%s' "$ctx" | grep -q "wl_out\|find_output"; then
    printf '  ok        %-28s pinned to a named output\n' "$(basename "$f"):$n"
  elif printf '%s' "$ctx" | grep -qi "deliberate"; then
    printf '  declared  %-28s unpinned, and says why\n' "$(basename "$f"):$n"
  else
    printf '  FAIL      %-28s passes None with no justification\n' "$(basename "$f"):$n"
    fail=1
  fi
done < <(grep -rn "create_layer_surface" render/src --include='*.rs')

echo
echo "== the launchers start one per screen"
for l in bin/null-wallpaper bin/null-bar; do
  if grep -q 'supervise' "$l" && grep -q -- '--output' "$l"; then
    printf '  ok        %-28s supervises one surface per output\n' "$l"
  else
    printf '  FAIL      %-28s starts a single surface for all screens\n' "$l"
    fail=1
  fi
done

echo
echo "== the chosen hero never overflows its screen"
# Real panels, plus the awkward ones. 1366x768 is the point of this: 1366 is
# 2 x 683 and 683 is prime, so nothing in the ladder divides it.
bad=0; n=0
for r in 640x480 800x600 1024x600 1024x768 1280x720 1280x800 1366x768 1440x900 \
         1600x900 1680x1050 1920x1080 1920x1200 2256x1504 2560x1080 2560x1440 \
         3440x1440 3840x2160 5120x1440 7680x4320; do
  w=${r%x*}; h=${r#*x}
  out=$(./bin/machine choose-assets "$w" "$h" 2>/dev/null) || {
    printf '  FAIL      %-12s no prebuilt hero fits at all\n' "$r"; fail=1; bad=1; continue; }
  set -- $out
  pw=$3; ph=$4; cov=$5
  n=$((n+1))
  if [ "$pw" -gt "$w" ] || [ "$ph" -gt "$h" ]; then
    printf '  FAIL      %-12s hero %sx%s OVERFLOWS the screen\n' "$r" "$pw" "$ph"
    fail=1; bad=1
  elif [ "$cov" -lt 50 ]; then
    printf '  thin      %-12s hero %sx%s covers only %s%%\n' "$r" "$pw" "$ph" "$cov"
  fi
done
[ "$bad" -eq 0 ] && printf '  ok        %s resolutions, none overflowing\n' "$n"

echo
if [ $fail = 0 ]; then
  echo "PASS: every screen gets its own surface, and none is drawn cropped"
else
  echo "FAIL: a screen would be left bare, or drawn cropped"
fi
exit $fail
