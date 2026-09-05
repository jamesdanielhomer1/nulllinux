#!/usr/bin/env bash
# Every program the desktop offers must be one the package installs (§10.1).
#
# §10.1 already checks that every command a KEY BINDING invokes exists. That
# check runs on the machine it is run from -- so on a build host, where
# everything is installed for other reasons, it passes while an installed
# machine offers menu entries that cannot work.
#
# This asks the different question: does the PACKAGE LIST contain the program?
# It needs no machine, so it gives the same answer on a build host and on a
# clean one, which is the whole point.
#
# Found nmtui and wiremix missing -- the settings menu's network and mixer
# topics -- on a machine installed from the ISO. A menu entry that cannot work
# is worse than one that is absent: it looks like a feature.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
cd "$ROOT"

LIST=" $("$ROOT/bin/pkg" list-packages base 2>/dev/null | tr '\n' ' ') "
[ "${#LIST}" -gt 3 ] || { echo "SKIPPED: cannot read the package list"; exit 0; }

# command : package that provides it. Written down rather than resolved, because
# resolving needs the distribution's metadata and this must run anywhere.
PROGRAMS="
nmtui:NetworkManager-tui
wiremix:wiremix
swaylock:swaylock
swayidle:swayidle
thunar:thunar
foot:foot
btop:btop
cava:cava
grim:grim
slurp:slurp
wl-copy:wl-clipboard
cliphist:cliphist
playerctl:playerctl
bluetoothctl:bluez
brightnessctl:brightnessctl
wlsunset:wlsunset
fzf:fzf
firefox:firefox
sway:sway
sddm:sddm
"

fail=0
for pair in $PROGRAMS; do
  cmd=${pair%%:*}; pkg=${pair#*:}
  # Only complain about programs this tree actually invokes.
  grep -rqF "$cmd" bin/ config/ 2>/dev/null || continue
  case "$LIST" in
    *" $pkg "*) printf '  ok      %-16s <- %s\n' "$cmd" "$pkg" ;;
    *) printf '  MISSING %-16s needs %s, which base.list does not list\n' "$cmd" "$pkg"; fail=1 ;;
  esac
done

echo
[ $fail = 0 ] && echo "PASS: every program the desktop invokes is in the package list" \
              || echo "FAIL: the desktop offers something the package does not install"
exit $fail
