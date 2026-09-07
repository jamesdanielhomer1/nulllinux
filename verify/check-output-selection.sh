#!/usr/bin/env bash
# THE INTERNAL PANEL IS THE REFERENCE, ON ANY NUMBER OF MONITORS.
#
# detect_output used to return the first connected connector in glob order, and
# glob order sorts eDP-1 (lowercase) after DP-1 and HDMI-A-1 (uppercase) -- so a
# laptop docked at first boot derived its profile from the external monitor
# rather than its own screen. The fix prefers an internal panel (eDP/LVDS/DSI)
# and falls through to the first connected output on a desktop that has none.
#
# This cannot be exercised on a build host with one output, so detect_output
# takes NULL_DRM_BASE and this drives it off synthetic /sys trees -- a check
# whose answer does not depend on the machine it runs on (docs/design-language.md).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkconn() {  # <root> <name> <status> <mode>
  mkdir -p "$T/$1/$2"; echo "$3" > "$T/$1/$2/status"; echo "$4" > "$T/$1/$2/modes"
}
picks() {  # <root> -> the detected connector name, or empty
  # -u WAYLAND_DISPLAY forces the /sys path (the real first-boot path, before any
  # compositor); with a live display set, render would answer from it instead.
  env -u WAYLAND_DISPLAY NULL_DRM_BASE="$T/$1" NULL_DRM_WAIT=0 bin/machine detect 2>/dev/null | awk '{print $1}'
}
want() {  # <label> <root> <expected>
  local got; got=$(picks "$2")
  if [ "$got" = "$3" ]; then note "ok    $1 -> $got"
  else note "$1 -> '${got:-<none>}', wanted '$3'"; fail=1; fi
}

# 1. Docked laptop: external DP sorts first, internal eDP must still win.
mkconn dock card0-DP-1  connected 2560x1440
mkconn dock card0-eDP-1 connected 1366x768
want "docked laptop picks the internal panel" dock eDP-1

# 2. Desktop: no internal panel, take the connected output.
mkconn desk card0-DP-1 connected 3840x2160
want "desktop with no panel takes the display" desk DP-1

# 3. A disconnected external must not shadow a connected internal.
mkconn mix card0-HDMI-A-1 disconnected 1920x1080
mkconn mix card0-eDP-1    connected    1920x1200
want "a disconnected output is skipped" mix eDP-1

# 4. LVDS (older panels) counts as internal too.
mkconn old card0-VGA-1  connected 1024x768
mkconn old card0-LVDS-1 connected 1280x800
want "LVDS is treated as an internal panel" old LVDS-1

# 5. Nothing connected: detection fails rather than inventing an output.
mkconn none card0-DP-1 disconnected 1920x1080
if [ -z "$(picks none)" ]; then note "ok    nothing connected -> no output (not invented)"
else note "nothing connected still returned an output"; fail=1; fi

[ $fail = 0 ] && echo "PASS: the internal panel is the reference, on any monitor arrangement"
exit $fail
