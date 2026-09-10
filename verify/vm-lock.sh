#!/usr/bin/env bash
# THE SESSION-LOCK CLIENT LOCKS, HOLDS, AND UNLOCKS -- AGAINST A REAL COMPOSITOR.
#
# Not a gating check: it needs a running compositor and grim. Run it in the guest
# deliberately -- never on the build host, which is the machine this is based on:
#
#     verify/in-guest.sh -- bash /opt/nulllinux/verify/vm-lock.sh
#
# The static wiring is guarded by verify/check-lock-screen.sh and the PAM core by
# render/src/bin/lock.rs's own tests. This is the integration proof of the three
# properties that only a live ext-session-lock can show:
#
#   1. IT LOCKS. The client acquires the lock and prints its LOCKED handshake,
#      running as comm "lock" -- the exact name null-lock's already-locked guard
#      greps for. It draws the greeter's panel (line/dim/neutral ink), not a
#      blank field.
#   2. IT HOLDS. Kill the client mid-lock and the compositor keeps the session
#      locked (wlroots paints solid red); the desktop is NEVER revealed, even
#      when something tries to open a window. This is the whole point of
#      ext-session-lock over a plain overlay, and it must never regress.
#   3. IT UNLOCKS. The right password unlocks and the client exits; the wrong one
#      is refused and it holds. This needs the password to reach the client, and
#      a headless VM has no keyboard device -- so it runs only when a build made
#      with `--features lock-test-hook` is deployed (that build auto-submits
#      $NULL_LOCK_TEST_PW once through the SAME PAM path a keypress takes). With a
#      production binary this section is SKIPPED, loudly, rather than faked.
set -u
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/0}
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
export NULL_ROOT=${NULL_ROOT:-$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)}
LOCKBIN="$NULL_ROOT/render/target/release/lock"
# THIS KILLS AND RESTARTS sway BY NAME. On the build host that is somebody's
# live session (lib/host.sh knows the history). Refuse anywhere that is not a
# machine whose state nobody minds.
. "$NULL_ROOT/lib/host.sh"
null_only_on_a_test_machine "the live lock/hold/unlock proof" || exit 0
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_HEADLESS_OUTPUTS=1
export SWAYSOCK=/tmp/null-vmlock.sock
LINE="35 44 64"   # 0x232c40, the rule colour the panel frame is drawn in
fail=0
note() { printf '  %s\n' "$*"; }

command -v grim >/dev/null || { echo "SKIPPED: grim is not here"; exit 0; }
command -v sway >/dev/null || { echo "SKIPPED: sway is not here"; exit 0; }
[ -x "$LOCKBIN" ] || { echo "SKIPPED: $LOCKBIN is not built"; exit 0; }

start_sway() {
  pkill -x lock 2>/dev/null; pkill -x sway 2>/dev/null; sleep 1
  setsid sway -c "$NULL_ROOT/config/sway/config" >/tmp/null-vmlock.log 2>&1 &
  sleep 4
  swaymsg -t get_version >/dev/null 2>&1 || { note "FAIL: sway did not start"; tail -5 /tmp/null-vmlock.log; exit 1; }
  export WAYLAND_DISPLAY=$(ls "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | tail -1)
  swaymsg -- output HEADLESS-1 mode --custom 1366x768 >/dev/null 2>&1; sleep 2
}
stop_sway() { pkill -x lock 2>/dev/null; swaymsg exit >/dev/null 2>&1; sleep 1; pkill -x sway 2>/dev/null; }

# centre pixel of HEADLESS-1: prints "R G B"
centre() {
  grim -t ppm -o HEADLESS-1 /tmp/null-vmlock.ppm 2>/dev/null || { echo "-1 -1 -1"; return; }
  python3 - <<'PY'
d=open("/tmp/null-vmlock.ppm",'rb').read();a=d.split(None,4);w,h=int(a[1]),int(a[2]);raw=a[4]
o=((h//2)*w+w//2)*3;print(raw[o],raw[o+1],raw[o+2])
PY
}
# count of frame-rule pixels across the panel band (rows 560-680): prints an int
panel_pixels() {
  grim -t ppm -o HEADLESS-1 /tmp/null-vmlock.ppm 2>/dev/null || { echo -1; return; }
  python3 - "$LINE" <<'PY'
import sys
line=tuple(int(x) for x in sys.argv[1].split())
d=open("/tmp/null-vmlock.ppm",'rb').read();a=d.split(None,4);w,h=int(a[1]),int(a[2]);raw=a[4]
def near(o): return all(abs(raw[o+i]-line[i])<=40 for i in range(3))
lo=max(0,h-208); hi=max(0,h-88)
print(sum(1 for y in range(lo,hi) for x in range(0,w,3) if near((y*w+x)*3)))
PY
}

# ---- 1 & 2: it locks, draws, and HOLDS when killed --------------------------
start_sway
USER=${SUDO_USER:-$(id -un)} NULL_ROOT="$NULL_ROOT" "$LOCKBIN" >/tmp/null-vmlock.out 2>/tmp/null-vmlock.err &
lp=$!; disown
sleep 5
if grep -q '^LOCKED$' /tmp/null-vmlock.out && [ "$(cat /proc/$lp/comm 2>/dev/null)" = lock ]; then
  note "ok    the client locked (LOCKED handshake) and runs as comm 'lock'"
else
  note "FAIL: no LOCKED handshake, or comm is not 'lock' (null-lock's guard would miss it)"
  note "      out: $(tr '\n' '|' </tmp/null-vmlock.out)  err: $(tr '\n' '|' </tmp/null-vmlock.err)"
  fail=1
fi
pp=$(panel_pixels)
if [ "$pp" -gt 50 ]; then note "ok    the greeter panel is drawn ($pp frame-rule pixels)"
else note "FAIL: the panel frame is not on screen ($pp rule pixels) -- blank lock"; fail=1; fi

kill -9 $lp 2>/dev/null; sleep 3
held=$(centre)
swaymsg exec 'foot' >/dev/null 2>&1; sleep 2   # try to reveal the desktop
held2=$(centre)
if [ "$held" = "255 0 0" ] && [ "$held2" = "255 0 0" ]; then
  note "ok    killing the client HELD the lock (red compositor fallback; desktop never shown)"
else
  note "FAIL: after kill the centre was '$held' then '$held2' -- expected '255 0 0' (held). A non-red, non-lock screen is an unlocked desktop."
  fail=1
fi
pkill -x foot 2>/dev/null
stop_sway

# ---- 3: it unlocks with the right password, holds with the wrong -----------
pam_verified=0
if grep -aq NULL_LOCK_TEST_PW "$LOCKBIN" 2>/dev/null; then
  U=${SUDO_USER:-$(id -un)}
  # A known password for the test account. Restored by the caller if it matters;
  # on the throwaway guest this is the point.
  TESTPW='vmlock-verify-pw'
  echo "$U:$TESTPW" | chpasswd 2>/dev/null || note "  (could not set $U's password; unlock test may misreport)"
  run_pw() {  # <pw> -> prints "EXITED" or "ALIVE"
    start_sway
    NULL_LOCK_TEST_PW="$1" USER="$U" NULL_ROOT="$NULL_ROOT" "$LOCKBIN" >/tmp/null-vmlock.out 2>/tmp/null-vmlock.err &
    local p=$! i; disown
    for i in $(seq 1 24); do kill -0 $p 2>/dev/null || { echo EXITED; stop_sway; return; }; sleep 0.5; done
    kill -9 $p 2>/dev/null; echo ALIVE; stop_sway
  }
  r_ok=$(run_pw "$TESTPW")
  r_bad=$(run_pw "definitely-not-$TESTPW")
  if [ "$r_ok" = EXITED ]; then note "ok    the correct password unlocked (client exited)"
  else note "FAIL: the correct password did not unlock (client still $r_ok)"; fail=1; fi
  if [ "$r_bad" = ALIVE ]; then note "ok    the wrong password was refused (client held the lock)"
  else note "FAIL: the wrong password did not hold the lock (client $r_bad) -- PAM is not fail-closed"; fail=1; fi
  [ "$r_ok" = EXITED ] && [ "$r_bad" = ALIVE ] && pam_verified=1
else
  note "SKIP  the unlock/refuse test: this is a production binary (no lock-test-hook)."
  note "      Build it with:  cargo build --release --bin lock --features lock-test-hook"
  note "      deploy that over $LOCKBIN, and re-run here to exercise the PAM path."
fi

echo
if [ $fail = 0 ]; then
  if [ "$pam_verified" = 1 ]; then
    echo "PASS: lock handshake, client-death lock retention, and test-hook PAM acceptance/refusal"
  else
    echo "PASS: lock handshake and client-death lock retention; PAM acceptance/refusal NOT TESTED"
  fi
else echo "FAIL: see above"; fi
exit $fail
