#!/usr/bin/env bash
# DOES IT COME BACK, AND IS IT LOCKED WHEN IT DOES?
#
# nox is a laptop. Closing the lid and opening it again is the commonest thing
# anybody does to one, and nothing in this repository had ever tried it.
#
# TWO QUESTIONS, and the second is the one that matters for a machine somebody
# carries:
#
#   does the session survive S3 -- the compositor, the renderers, the bar and
#     the column all still running and still drawing afterwards
#   is the screen LOCKED on resume -- config/sway/idle.conf has
#     `before-sleep '... null-lock'`, which is the right place for it, and a
#     line in a config file is not evidence that a lock appeared
#
# A machine that wakes unlocked is one that hands its contents to whoever
# opened it, and that failure is invisible until it matters.
#
# HOW IT SUSPENDS. qemu implements S3, so `systemctl suspend` in the guest
# really does stop the VM, and `system_wakeup` on the monitor really is the
# power button. It is not a simulation of suspend; it is suspend, on virtual
# hardware.
#
#   verify/suspend-resume.sh                 the ISO-installed guest
#   NULL_VM_PORT=2225 ... MONITOR=...        another one
set -uo pipefail
ROOT=${NULL_ROOT:-$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)}
WORK=${NULL_VM_WORK:-/var/lib/nulllinux-test}
PORT=${NULL_VM_PORT:-2223}
KEY="$WORK/id_guest"
MONITOR=${NULL_VM_MONITOR:-$WORK/install-monitor}

fails=0
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
info() { printf '        %s\n' "$*"; }
head_() { printf '\n== %s\n' "$*"; }

g() { ssh -i "$KEY" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=8 -o LogLevel=ERROR root@127.0.0.1 "$@" 2>/dev/null; }

mon() {  # one HMP command, answer on stdout
  python3 - "$MONITOR" "$1" <<'PY'
import socket, sys, time
sock, cmd = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX)
try: s.connect(sock)
except Exception: sys.exit(1)
s.settimeout(5); time.sleep(0.2)
try: s.recv(65536)
except Exception: pass
s.sendall((cmd + "\n").encode()); time.sleep(0.8)
buf = b""
try:
    while True:
        d = s.recv(262144)
        if not d: break
        buf += d
        if buf.rstrip().endswith(b"(qemu)"): break
except Exception: pass
s.close()
print(buf.decode(errors="replace"))
PY
}

[ -S "$MONITOR" ] || { echo "suspend-resume: no qemu monitor at $MONITOR" >&2; exit 1; }
g true >/dev/null 2>&1 || { echo "suspend-resume: the guest is not answering on port $PORT" >&2; exit 1; }

head_ "before"
before_boot=$(g 'cat /proc/sys/kernel/random/boot_id')
before_up=$(g 'cut -d. -f1 /proc/uptime')
sway_pid=$(g 'pgrep -u 1000 -x sway | head -1')
info "boot_id  ${before_boot:0:8}...   uptime ${before_up}s   sway pid ${sway_pid:-none}"
[ -n "$sway_pid" ] && ok "a session is running to suspend" \
                   || bad "no session is running; suspend would prove nothing"

head_ "suspend"
# `systemctl suspend` returns immediately and the machine goes down under it,
# so the ssh channel dies -- which is the expected outcome, not an error.
g 'systemd-run --on-active=1 systemctl suspend' >/dev/null 2>&1 \
  || g 'nohup systemctl suspend >/dev/null 2>&1 &' >/dev/null 2>&1
for _ in $(seq 1 30); do
  st=$(mon 'info status' 2>/dev/null | tr -d '\r' | grep -oE 'VM status: [a-z ]+' | head -1)
  case $st in *suspended*|*paused*) break ;; esac
  sleep 1
done
info "qemu says: ${st:-<nothing>}"
case $st in
  *suspended*|*paused*) ok "the guest actually entered S3" ;;
  *) bad "the guest never suspended -- ${st:-no answer from the monitor}" ;;
esac

head_ "resume"
mon 'system_wakeup' >/dev/null 2>&1
back=0
for _ in $(seq 1 40); do
  g true >/dev/null 2>&1 && { back=1; break; }
  sleep 3
done
[ "$back" = 1 ] && ok "the machine answers again after wakeup" \
                || { bad "it did not come back"; echo; exit 1; }

after_boot=$(g 'cat /proc/sys/kernel/random/boot_id')
after_up=$(g 'cut -d. -f1 /proc/uptime')
info "boot_id  ${after_boot:0:8}...   uptime ${after_up}s"
if [ "$before_boot" = "$after_boot" ]; then
  ok "same boot_id -- it resumed rather than rebooted"
else
  bad "the boot_id changed: that was a reboot, not a resume"
fi

after_sway=$(g 'pgrep -u 1000 -x sway | head -1')
[ -n "$after_sway" ] && [ "$after_sway" = "$sway_pid" ] \
  && ok "the same compositor is still running (pid $after_sway)" \
  || bad "the compositor did not survive: was ${sway_pid:-none}, now ${after_sway:-none}"

head_ "and it is locked"
# swaylock is what config/sway/idle.conf's before-sleep line runs. Its presence
# is the only thing that distinguishes a machine that protects itself from one
# that merely came back.
lock=$(g 'pgrep -u 1000 -x swaylock | head -1')
info "swaylock pid: ${lock:-none}"
[ -n "$lock" ] \
  && ok "the screen is locked after resume" \
  || bad "it woke UNLOCKED -- before-sleep did not run, or null-lock failed"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: it suspends, it comes back, and it comes back locked"
else echo "FAIL: $fails problem(s) across suspend and resume"; fi
exit $((fails > 0))
