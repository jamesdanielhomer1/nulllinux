#!/usr/bin/env bash
# No surface may assert the size of the screen (NULL.md §0.2, §2.1).
#
# §0.2 says hardware capability is PROBED AT RUNTIME, never declared. The
# renderer declared it anyway, in two lines that were invisible because they
# were correct on the machine they were written on:
#
#   bar.rs      let cols = 1920 / atlas.cell_w;
#   column.rs   let rows = (1080 - bar_px) / atlas.cell_h;
#
# 1920x1080 is this laptop's panel. On a 2560x1440 screen the bar was 1920 wide
# and the column stopped 205 px short of the bottom -- and nothing reported it,
# because both surfaces were drawing perfectly, at the wrong size.
#
# Both are anchored to opposite edges, so the compositor will say how big they
# are for the asking, and asking is passing 0 on that axis. That is the only
# correct source for the number.
#
# Comments are stripped: the comments explaining this bug quote the old lines.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
cd "$ROOT"

# Sizes a display might plausibly be. Not an exhaustive list of resolutions --
# the point is that a SCREEN DIMENSION should never be a literal in this code.
DIMS='1024|1280|1366|1440|1600|1680|1920|2048|2160|2560|2880|3440|3840|4096|5120'
fail=0
found=''

for f in render/src/*.rs render/src/bin/*.rs; do
  [ -f "$f" ] || continue
  # A dimension literal is only a screen dimension when it is being used AS
  # one. `[0u8; 4096]` is a buffer, `up_min / 1440` is minutes in a day, and
  # `* 1024` is a kilobyte -- flagging those would train people to ignore this.
  # The bug's shape is a dimension divided by a cell size into a grid extent,
  # so the line must also mention something that sizes a surface.
  SIZING='cols|rows|px_w|px_h|set_size|cell_w|cell_h|width|height'
  hits=$(sed -e 's|//.*$||' "$f" \
         | grep -nE "(^|[^0-9_.])($DIMS)([^0-9_]|$)" \
         | grep -E "($SIZING)" || true)
  [ -n "$hits" ] || continue
  while IFS= read -r line; do
    found="$found  $f:$line"$'\n'
    fail=1
  done <<< "$hits"
done

if [ $fail = 0 ]; then
  echo "PASS: no surface hard-codes a screen dimension"
  echo "      (the compositor is asked, by requesting 0 on an anchored axis)"
else
  echo "FAIL: a screen dimension is written into the renderer"
  echo
  printf '%s' "$found"
  echo
  echo "  A layer surface anchored to opposite edges is told its real size if it"
  echo "  requests 0 on that axis. Use that instead of a number. See §0.2."
fi
exit $fail
