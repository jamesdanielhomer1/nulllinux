#!/usr/bin/env bash
# THE LOCK SCREEN IS A SURFACE OF THIS SYSTEM, NOT A PROGRAM'S DEFAULT.
#
# swaylock was invoked as a bare `swaylock -f` from four places, so locking the
# machine put up a FULL-SCREEN WHITE FIELD with a rounded ring on it: the
# second most-seen window in the system, in the palette of a program nobody had
# configured, at the one moment the machine is asking for a password.
#
# Three things have to keep holding, and each is easy to lose separately:
# nothing calls swaylock directly, the config exists and uses palette roles,
# and every colour in it still matches the palette the rest of the system is
# generated from.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
[ -r lib/source.sh ] && . lib/source.sh
note() { printf '  %s\n' "$*"; }

CONF=config/swaylock/config
COLOURS=config/sway/colours.conf

[ -r "$CONF" ] || { note "$CONF is gone -- the lock screen is stock swaylock again"; exit 1; }
[ -x bin/null-lock ] || { note "bin/null-lock is gone"; exit 1; }

# 1. NOTHING CALLS swaylock DIRECTLY. One wrapper, so one place decides what
#    the lock screen looks like. A new call site is how three of the four
#    original ones came to exist.
direct=$(grep -rn 'swaylock' bin/ config/ 2>/dev/null \
         | grep -v '^bin/null-lock:' \
         | grep -v "^$CONF:" \
         | grep -vE ':[0-9]+: *#' \
         | grep -vE "null_row '[a-z]+' +'swaylock'")
if [ -n "$direct" ]; then
  note "swaylock is called directly, bypassing bin/null-lock:"
  printf '%s\n' "$direct" | sed 's/^/    /'
  fail=1
else
  note "ok    every lock goes through bin/null-lock"
fi

# 2. THE WRAPPER MUST ALWAYS REACH AN exec. A lock that declines to start
#    because an optional image was missing is a machine left unlocked.
if grep -qE '^exec swaylock' bin/null-lock; then
  note "ok    bin/null-lock ends in an unconditional exec"
else
  note "bin/null-lock: no unconditional 'exec swaylock' -- a missing image could leave the screen unlocked"
  fail=1
fi

# 3. EVERY COLOUR IS A PALETTE ROLE. swaylock takes RRGGBB with no '#', so the
#    comparison strips it. A hex value typed by hand is the failure NULL.md
#    forbids everywhere else and would be invisible here.
if [ -r "$COLOURS" ]; then
  roles=$(grep -oE '^set \$c_[a-z]+ #[0-9a-fA-F]{6}' "$COLOURS" | awk '{print tolower(substr($3,2))}' | sort -u)
  bad=""
  while read -r line; do
    case $line in ''|\#*) continue ;; esac
    case $line in *=*) ;; *) continue ;; esac
    v=${line#*=}
    case $v in
      [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
      *) continue ;;
    esac
    printf '%s\n' "$roles" | grep -qix "$v" || bad="$bad ${line%%=*}=$v"
  done < "$CONF"
  if [ -n "$bad" ]; then
    note "colours in $CONF that are not palette roles:$bad"
    fail=1
  else
    note "ok    every colour in $CONF is a role from $COLOURS"
  fi
else
  note "($COLOURS absent; palette comparison skipped)"
fi

# 4. ONE TYPEFACE. The design system has exactly one, and a lock screen is the
#    easiest place to forget it because swaylock's default is whatever
#    fontconfig hands back.
grep -qE '^font=Terminus' "$CONF" \
  || { note "$CONF does not set font=Terminus"; fail=1; }

# 5. A FILLED INDICATOR IS A BOX (§7.1, I1). The inside must be the ground, so
#    state is carried by the ring rather than by a filled disc.
inside=$(grep -E '^inside(-[a-z]+)?-color=' "$CONF" | cut -d= -f2 | sort -u)
ground=$(grep -E '^color=' "$CONF" | head -1 | cut -d= -f2)
if [ "$(printf '%s\n' "$inside" | grep -cv "^$ground$")" -gt 0 ]; then
  note "the indicator is filled with something other than the ground -- that is a box, not a rule"
  fail=1
else
  note "ok    the indicator is a rule on the ground, not a filled disc"
fi

# 3. AND SOMETHING HAS TO START THE THING THAT CALLS IT.
#
#    A lock screen nothing invokes is a lock screen that never appears. The
#    compositor's line starting the idle ladder was commented out -- correctly,
#    for one machine, in the file every machine reads -- so no installed
#    nullLinux dimmed, blanked, locked, slept, or locked before sleeping.
#
#    Found by suspending a guest and resuming it: same boot_id, same compositor
#    pid, and no lock screen. A laptop that wakes unlocked hands its contents to
#    whoever opened it, and nothing about it looks wrong until it matters.
if null_code_only config/sway/config 2>/dev/null | grep -q 'null-idle start'; then
  note "ok    the compositor starts the idle ladder"
else
  note "config/sway/config does not start the idle ladder"
  note "      nothing would dim, lock, sleep, or lock before sleeping"
  fail=1
fi

# 4. AND THE LADDER LOCKS BEFORE IT SLEEPS.
#
#    `before-sleep` is the difference between a laptop that protects itself when
#    the lid closes and one that does not. It is one line in idle.conf and it is
#    load-bearing.
for f in config/sway/idle.conf; do
  [ -r "$f" ] || { note "$f is gone"; fail=1; continue; }
  if grep -qE "^before-sleep .*null-lock" "$f"; then
    note "ok    $f locks before sleeping"
  else
    note "$f has no before-sleep that locks -- the machine would wake unlocked"
    fail=1
  fi
done

# 5. AND "OFF" HAS SOMEWHERE TO BE REMEMBERED, or the only way to turn the
#    ladder off is to edit a file that ships -- which is exactly how this got
#    switched off for everybody.
grep -q 'IDLE_OFF' bin/null-idle \
  || { note "bin/null-idle cannot remember that somebody turned the ladder off"; fail=1; }

[ $fail = 0 ] && echo "PASS: the lock screen is this system's, not swaylock's"
exit $fail
