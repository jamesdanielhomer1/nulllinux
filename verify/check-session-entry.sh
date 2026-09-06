#!/usr/bin/env bash
# THE SESSION THE GREETER OFFERS MUST BE THIS ONE.
#
# The greeter listed Fedora's own sway.desktop -- called "Sway", running bare
# `sway`. So on a nullLinux machine the session list did not contain nullLinux,
# and there was nowhere at all to set session environment: a compositor started
# by a display manager does not read /etc/profile.d, which is for login shells.
# Every variable a Wayland desktop needs was therefore unset.
#
# What that cost, concretely: no XDG_CURRENT_DESKTOP, so xdg-desktop-portal
# never selected the wlr backend and screen sharing silently did not work; no
# GTK_THEME, so a libadwaita application would ignore the theme entirely; no
# QT_QPA_PLATFORMTHEME, so every Qt window came up in stock Fusion light, which
# is white, in a system that has no white in it.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

ENTRY=packaging/nulllinux-session.desktop
WRAP=bin/null-session

[ -r "$ENTRY" ] || { note "$ENTRY is gone -- the greeter falls back to Fedora's Sway"; exit 1; }
[ -x "$WRAP" ]  || { note "$WRAP is gone or not executable"; exit 1; }

# 1. The entry must run OUR wrapper, not sway directly. An entry that runs
#    sway is Fedora's entry with our name on it.
grep -qE '^Exec=.*/bin/null-session' "$ENTRY" \
  || { note "$ENTRY does not Exec bin/null-session"; fail=1; }
grep -qE '^Name=nullLinux' "$ENTRY" \
  || { note "$ENTRY is not named nullLinux"; fail=1; }

# 2. The wrapper must end as sway. A session wrapper that forks and returns
#    ends the session the moment it is started.
grep -qE '^exec sway' "$WRAP" \
  || { note "$WRAP does not exec sway -- the session would end immediately"; fail=1; }

# 3. The variables, each with what breaks without it. These are the point of
#    the wrapper; losing one is silent in every case.
for v in XDG_CURRENT_DESKTOP:"the portal never selects the wlr backend, so screen sharing does not work" \
         GTK_THEME:"libadwaita applications ignore the theme" \
         QT_QPA_PLATFORMTHEME:"Qt windows render in stock Fusion light" \
         XCURSOR_THEME:"the pointer falls back to whatever the toolkit picks" \
         MOZ_ENABLE_WAYLAND:"the browser runs under XWayland"; do
  name=${v%%:*}; why=${v#*:}
  grep -qE "^export $name=" "$WRAP" \
    || { note "$WRAP does not export $name -- $why"; fail=1; }
done

# 4. NOT /etc/environment. That is read by PAM for every session on the machine
#    including the greeter's, and sddm is itself Qt: setting the platform theme
#    there would reskin the one surface this project draws entirely by hand.
if grep -rqE '^\s*QT_QPA_PLATFORMTHEME' bin/null-install packaging/*.ks 2>/dev/null; then
  note "QT_QPA_PLATFORMTHEME is set outside the session wrapper -- it would reach the greeter too"
  fail=1
fi

# 5. null-install has to actually place it.
grep -q 'wayland-sessions' bin/null-install \
  || { note "bin/null-install does not install the session entry"; fail=1; }

[ $fail = 0 ] && echo "PASS: the greeter offers this system's own session"
exit $fail
