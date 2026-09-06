#!/usr/bin/env bash
# THE SCREENS GO WHERE SOMEBODY SAID, ON A MACHINE THAT HAS NONE.
#
# sway was given no `output` line anywhere in this configuration, so until
# bin/null-outputs existed a machine with two screens got the DRM connector
# order -- the order the card lists its ports, which has nothing to do with
# which side of the desk anything is on. There was no way to correct it from
# inside the session, and "any panel, any number of monitors" is the hardware
# promise this project rests on.
#
# THIS IS TESTED WITHOUT A COMPOSITOR, deliberately. The build host has one
# screen and the guest has one screen, so the interesting cases -- three
# screens, one above another, one switched off, one unplugged since the rule
# was written -- exist nowhere this suite can reach. The solver is therefore
# pure: screens in, positions out, no compositor involved, and `null-outputs
# solve` is the door the verifier comes in by.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

O=bin/null-outputs
[ -x "$O" ] || { note "$O is gone -- there is no way to place a second screen"; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
tsv=$tmp/screens
# key, name, identity, active, x, y, w, h, mode, scale
{ printf 'LAPTOP\teDP-1\tLAPTOP\t1\t0\t0\t1366\t768\t1366x768\t1\n'
  printf 'BIGONE\tDP-1\tBIGONE\t1\t1366\t0\t1920\t1080\t1920x1080\t1\n'
  printf 'TOPONE\tHDMI-A-1\tTOPONE\t1\t3286\t0\t1280\t1024\t1280x1024\t1\n'
} > "$tsv"

sol() { "./$O" solve "$1" < "$tsv" 2>"$tmp/err"; }
xy()  { sed -n "s/^output \"$2\" position \([0-9-]*\) \([0-9-]*\)$/\1 \2/p" <<<"$1"; }

# 1. EVERY RELATION PUTS EDGES TOGETHER. A gap is a place the pointer falls
#    into; an overlap is two screens showing the same corner of the desktop.
for rel in right-of left-of above below; do
  printf 'place\tBIGONE\t%s\tLAPTOP\n' "$rel" > "$tmp/c"
  out=$(sol "$tmp/c") || { note "solving '$rel' failed: $(cat "$tmp/err")"; fail=1; continue; }
  read -r lx ly <<<"$(xy "$out" LAPTOP)"
  read -r bx by <<<"$(xy "$out" BIGONE)"
  if [ -z "$lx" ] || [ -z "$bx" ]; then
    note "'$rel' did not place both screens"; fail=1; continue
  fi
  case $rel in
    right-of) want_x=$((lx + 1366)); want_y=$ly ;;
    left-of)  want_x=$((lx - 1920)); want_y=$ly ;;
    above)    want_x=$lx; want_y=$((ly - 1080)) ;;
    below)    want_x=$lx; want_y=$((ly + 768)) ;;
  esac
  if [ "$bx" = "$want_x" ] && [ "$by" = "$want_y" ]; then
    note "ok    $rel puts the edges together"
  else
    note "$rel put BIGONE at $bx,$by; touching LAPTOP at $lx,$ly means $want_x,$want_y"
    fail=1
  fi
done

# 2. POSITIONS ARE DERIVED, NOT STORED. The same file against a LAPTOP of a
#    different size must produce a different position -- otherwise the tool is
#    remembering coordinates, and coordinates go stale silently the first time
#    anything changes resolution.
printf 'place\tBIGONE\tright-of\tLAPTOP\n' > "$tmp/c"
a=$(sol "$tmp/c"); read -r ax _ <<<"$(xy "$a" BIGONE)"
sed -i 's/\t1366\t768\t1366x768/\t2560\t1440\t2560x1440/' "$tsv"
b=$(sol "$tmp/c"); read -r bx2 _ <<<"$(xy "$b" BIGONE)"
if [ -n "$ax" ] && [ -n "$bx2" ] && [ "$ax" != "$bx2" ] && [ $((bx2 - ax)) = $((2560 - 1366)) ]; then
  note "ok    a wider first screen moves the second by exactly the difference"
else
  note "resizing LAPTOP moved BIGONE from '$ax' to '$bx2' -- positions are not being derived"
  fail=1
fi
sed -i 's/\t2560\t1440\t2560x1440/\t1366\t768\t1366x768/' "$tsv"

# 3. IT REFUSES WHAT HAS NO ANSWER, rather than applying half of it.
printf 'place\tBIGONE\tleft-of\tLAPTOP\nplace\tLAPTOP\tleft-of\tBIGONE\n' > "$tmp/c"
if sol "$tmp/c" >/dev/null 2>&1; then
  note "a circular arrangement was accepted -- one of the two rules is being ignored"
  fail=1
else
  note "ok    a circular arrangement is refused"
fi

# 4. AND IT REFUSES TO LEAVE NOBODY A SCREEN. A session with every output
#    disabled cannot be recovered from inside itself.
printf 'power\tLAPTOP\toff\npower\tBIGONE\toff\npower\tTOPONE\toff\n' > "$tmp/c"
if sol "$tmp/c" >/dev/null 2>&1; then
  note "switching off every screen was accepted -- the only way back is the power button"
  fail=1
else
  note "ok    switching off the last screen is refused"
fi

# 5. A RULE ABOUT AN UNPLUGGED SCREEN IS NOT AN ERROR. Somebody took the
#    monitor to another room. The rule has to survive, or arranging a docking
#    station is something you do again every morning.
printf 'place\tBIGONE\tleft-of\tSOMETHING-NOT-HERE\n' > "$tmp/c"
out=$(sol "$tmp/c") || { note "a rule naming an absent screen was treated as an error"; fail=1; }
if [ -n "${out:-}" ] && [ "$(grep -c '^output ' <<<"$out")" = 3 ]; then
  note "ok    a rule about an absent screen leaves the others alone"
else
  note "a rule about an absent screen did not fall back to placing the rest"
  fail=1
fi

# 6. ONE SCREEN OFF STILL PLACES THE REST, and says so to the compositor.
printf 'power\tTOPONE\toff\nplace\tBIGONE\tleft-of\tLAPTOP\n' > "$tmp/c"
out=$(sol "$tmp/c") || out=""
grep -q '^output "TOPONE" disable$' <<<"$out" \
  || { note "switching one screen off does not disable it"; fail=1; }
grep -q '^output "TOPONE" position' <<<"$out" \
  && { note "a disabled screen was still given a position"; fail=1; }

# 7. THE COMPOSITOR STARTS IT, or none of the above ever runs. This is the
#    shape that has already gone wrong twice here: written, wired into one
#    place, and never reached from the one that matters.
grep -q 'null-outputs watch' config/sway/config \
  || { note "config/sway/config never starts null-outputs -- a screen plugged in mid-session lands wherever the connector order puts it"; fail=1; }

# 8. AND THE SETTINGS PANEL OFFERS IT. A tool nobody can find is a tool
#    nobody has.
grep -q 'ARRANGEMENT' bin/null-settings \
  || { note "bin/null-settings has no ARRANGEMENT row, so the only way to place a screen is to know the command"; fail=1; }

# 9. `list` CHANGES NOTHING (§8.4 report-first). Run it with a config it must
#    not touch and require the file to be byte-identical afterwards.
conf_dir=$tmp/cfg/nullLinux
mkdir -p "$conf_dir"
printf 'place\tA\tright-of\tB\n' > "$conf_dir/outputs.conf"
before=$(cksum < "$conf_dir/outputs.conf")
XDG_CONFIG_HOME=$tmp/cfg "./$O" list >/dev/null 2>&1
after=$(cksum < "$conf_dir/outputs.conf")
[ "$before" = "$after" ] \
  && note "ok    list reports and writes nothing" \
  || { note "list modified the saved arrangement"; fail=1; }

[ $fail = 0 ] && echo "PASS: the screens go where somebody said, and refuse what has no answer"
exit $fail
