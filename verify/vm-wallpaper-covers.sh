#!/usr/bin/env bash
# THE WALLPAPER COVERS ANY SCREEN, AND ANY NUMBER OF THEM.
#
# Not a gating check: it needs a running compositor and grim, and it is timing
# sensitive (a live mode change flashes the compositor background for a moment
# while the surface restarts). Run it in the guest deliberately:
#
#     verify/in-guest.sh -- bash /opt/nulllinux/verify/vm-wallpaper-covers.sh
#
# The property, verified on WEIRD geometry rather than one machine's numbers:
# every edge of every output is the palette background, never the compositor's
# own (which reads as pure black), because the surface spans the whole output
# and the hero is centred with the background filling the rest. The unit tests
# in render/src/{raster,grid,atlas}.rs guard the same logic deterministically;
# this is the integration proof against a real compositor.
set -u
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/0}
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
export NULL_ROOT=${NULL_ROOT:-$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)}
# THIS KILLS AND RESTARTS sway BY NAME. On the build host that is somebody's
# live session (lib/host.sh knows the history). Refuse anywhere that is not a
# machine whose state nobody minds.
. "$NULL_ROOT/lib/host.sh"
null_only_on_a_test_machine "the wallpaper-covers proof" || exit 0
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=3
export SWAYSOCK=/tmp/null-wpcover.sock
BG="5 6 10"
command -v grim >/dev/null || { echo "SKIPPED: grim is not here"; exit 0; }
command -v sway >/dev/null || { echo "SKIPPED: sway is not here"; exit 0; }

setsid sway -c "$NULL_ROOT/config/sway/config" >/tmp/null-wpcover.log 2>&1 &
sleep 4
swaymsg -t get_version >/dev/null 2>&1 || { echo "FAIL: sway did not start"; tail -5 /tmp/null-wpcover.log; exit 1; }
export WAYLAND_DISPLAY=$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | tail -1)

fail=0
edges() {  # <output> — assert right and bottom edge pixels are the background
  local n=$1 p=/tmp/null-wpcover-$n.ppm
  grim -t ppm -o "$n" "$p" 2>/dev/null || { echo "  $n: grim failed"; fail=1; return; }
  python3 - "$p" "$n" "$BG" <<'PY'
import sys
p,n,bg=sys.argv[1],sys.argv[2],tuple(int(x) for x in sys.argv[3].split())
d=open(p,'rb').read(); a=d.split(None,4); w,h=int(a[1]),int(a[2]); raw=a[4]
px=lambda x,y:(lambda o:tuple(raw[o:o+3]))((y*w+x)*3)
r,b=px(w-1,h//2),px(w//2,h-1)
ok = r==bg and b==bg
print(f"  {n} {w}x{h}: right={r} bottom={b} {'ok' if ok else 'WRONG (compositor bg showing)'}")
sys.exit(0 if ok else 1)
PY
  [ $? -ne 0 ] && fail=1
}

# Weird, deliberately: odd widths the cell does not divide, an ultrawide, a portrait.
swaymsg -- output HEADLESS-1 mode --custom 1366x768  >/dev/null
swaymsg -- output HEADLESS-2 mode --custom 1917x1131 >/dev/null
swaymsg -- output HEADLESS-3 mode --custom 803x1279  >/dev/null
sleep 12
echo "three weird outputs at once:"
for n in HEADLESS-1 HEADLESS-2 HEADLESS-3; do edges "$n"; done

echo "a live shrink, and a live grow (generous settle -- a restart is not instant):"
swaymsg -- output HEADLESS-2 mode --custom 1201x901  >/dev/null; sleep 20; edges HEADLESS-2
swaymsg -- output HEADLESS-3 mode --custom 2560x1440 >/dev/null; sleep 20; edges HEADLESS-3

panics=$(grep -c panicked /tmp/null-wpcover.log)
[ "$panics" = 0 ] || { echo "  $panics panic(s) in the session log"; fail=1; }

swaymsg exit >/dev/null 2>&1; sleep 1
for x in sway render bar column dwindle swayidle swaylock; do pkill -x "$x" 2>/dev/null; done
rm -f /tmp/null-wpcover-*.ppm
[ $fail = 0 ] && echo "PASS: the wallpaper covers every screen, at every weird size, with no panic"
exit $fail
