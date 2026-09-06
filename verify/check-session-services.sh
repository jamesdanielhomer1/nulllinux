#!/usr/bin/env bash
# THE SERVICES A DESKTOP SESSION CANNOT WORK WITHOUT.
#
# Three things this system depends on were present only because something else
# dragged them in, and each failure is silent in its own way:
#
#   nftables  -- the firewall's own binary, arriving via the firewalld we
#                stopped using (fixed earlier; kept honest by check-firewall)
#   polkit    -- with no authentication agent running, every privileged action
#                fails with NO PROMPT AND NO MESSAGE. Mounting a USB stick just
#                does not happen.
#   pipewire  -- audio. "Audio has never worked" sat in the status notes for
#                weeks; it was the session running as root, and pipewire was
#                never declared either way.
#
# A package that is not declared is a package that can be removed by a
# dependency change nobody made deliberately.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

LIST=packages/fedora/base.list

# READ THE LIST THE WAY THE INSTALLER READS IT.
#
# This used `grep -qx <pkg> base.list`, which cannot match a line with a
# trailing comment -- and half the list has one. It reported swaylock as
# undeclared when swaylock has been declared all along, as
# "swaylock   # the lock the idle ladder calls". A check that parses a file
# differently from the thing that consumes it reports on a file nobody uses.
DECLARED=$(./bin/pkg list-packages base 2>/dev/null | tr ' ' '\n')

need() {  # <package> <why it matters when it is missing>
  if printf '%s\n' "$DECLARED" | grep -qx "$1"; then
    note "ok    $1 is declared"
  else
    note "$LIST: $1 is not declared -- $2"
    fail=1
  fi
}

need polkit              "privileged actions would have nothing to authenticate against"
need xfce-polkit         "nothing would put the password prompt on screen"
need pipewire            "there would be no sound server"
need wireplumber         "pipewire would run and route nothing, which reads as missing hardware"
need swaylock            "the screen could not be locked at all"

# THE AGENT MUST ACTUALLY BE STARTED. sway does not run XDG autostart, so
# shipping the package is not the same as running it -- and the two failures
# look identical from the user's side.
if grep -qE '^exec(_always)? .*xfce-polkit' config/sway/config; then
  note "ok    the session starts the polkit agent"
else
  note "config/sway/config: nothing starts xfce-polkit -- sway ignores /etc/xdg/autostart, so the package would be installed and idle"
  fail=1
fi

# A GTK3 AGENT IS STYLED BY INHERITANCE. If it is ever swapped for a Qt one,
# the prompt silently leaves the palette, because there is no Qt platform
# theme here.
for qt in lxqt-policykit polkit-kde plasma-polkit-agent; do
  printf '%s\n' "$DECLARED" | grep -qx "$qt" && {
    note "$LIST: $qt is a Qt agent and there is no Qt platform theme -- the prompt would render in stock Fusion light"
    fail=1
  }
done

[ $fail = 0 ] && echo "PASS: the session's services are declared, started, and styled"
exit $fail
