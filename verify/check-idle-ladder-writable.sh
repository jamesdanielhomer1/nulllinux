#!/usr/bin/env bash
# A USER CAN CHANGE THEIR OWN SCREEN TIMEOUT.
#
# bin/null-idle wrote $ROOT/config/sway/idle.conf unconditionally. On an
# installed machine $ROOT is /opt/nulllinux, which is root-owned -- and the
# session deliberately does not run as root, so that is every user of the
# product. The tool worked perfectly on a developer's checkout and not at all
# on the thing that ships.
#
# AND IT DID NOT WORK THERE EITHER. write_conf called current(), which reads
# the FILE, so after set_stage had computed new values into STAGES the write
# read the old ones back off disk and wrote those. `null-idle set lock 600`
# printed "set lock to 600s" and wrote 300. It only ever appeared to work on a
# machine whose config did not exist yet, where the read fell through to the
# compiled-in defaults -- which is to say, exactly once, on a fresh install,
# and never again.
#
# Both are checked here by running the tool as a real unprivileged user against
# a throwaway HOME. Nothing else finds this: as root, on a checkout, it looks
# fine.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

[ -x bin/null-idle ] || { note "bin/null-idle is gone"; exit 1; }

# The paths must still be separate. A single CONF is the original bug.
if grep -q 'USER_CONF=' bin/null-idle && grep -q 'SYSTEM_CONF=' bin/null-idle; then
  note "ok    the system default and the user's copy are separate paths"
else
  note "bin/null-idle no longer separates the system default from the user's copy"
  fail=1
fi

# write_conf must not read the file. This is the line that made `set` a no-op.
if sed -n '/^write_conf()/,/^}/p' bin/null-idle | grep -q 'current "'; then
  note "write_conf reads the file again -- 'set' will report a change it did not make"
  fail=1
else
  note "ok    write_conf works from the array, not from the file"
fi

if [ "$(id -u)" -ne 0 ]; then
  note "(not root, so the unprivileged run is skipped -- the checks above stand)"
  [ $fail = 0 ] && echo "PASS: the idle ladder is writable by the person it belongs to"
  exit $fail
fi

U=nobody
id -u "$U" >/dev/null 2>&1 || { note "(no '$U' account here; unprivileged run skipped)"; \
  [ $fail = 0 ] && echo "PASS: the idle ladder is writable by the person it belongs to"; exit $fail; }

# The throwaway HOME must belong to the user we are pretending to be, or the
# check fails on its own fixture rather than on the tool -- which it did.
h=$(mktemp -d); chown "$U:$(id -gn "$U")" "$h"; chmod 700 "$h"
before=$(grep -h 'null-stage lock' config/sway/idle.conf)
run() {
  setpriv --reuid="$(id -u "$U")" --regid="$(id -g "$U")" --clear-groups \
    env HOME="$h" XDG_CONFIG_HOME="$h/.config" NULL_ROOT="$PWD" \
    ./bin/null-idle "$@" 2>&1
}

# 1. An ordinary user can set a stage at all.
if run set lock 600 >/dev/null 2>&1; then
  note "ok    an unprivileged user can change a stage"
else
  note "an unprivileged user CANNOT change a stage -- $(run set lock 600 | tail -1)"
  fail=1
fi

# 2. The value they asked for is the value written, and the ladder invariant
#    still drags the later stages.
got=$(sed -n 's/^# null-stage lock \([0-9]*\)$/\1/p' "$h/.config/nulllinux/idle.conf" 2>/dev/null)
[ "$got" = 600 ] && note "ok    the value asked for is the value written ($got)" \
                 || { note "asked for 600, the file says '${got:-nothing}'"; fail=1; }
off=$(sed -n 's/^# null-stage screenoff \([0-9]*\)$/\1/p' "$h/.config/nulllinux/idle.conf" 2>/dev/null)
[ -n "$off" ] && [ "$off" -gt 600 ] && note "ok    the ladder still drags later stages (screenoff $off)" \
                 || { note "screenoff is '${off:-nothing}', which does not follow lock at 600"; fail=1; }

# 3. A second change must not reset the first. This is what re-reading the
#    file was supposed to achieve and did not.
run set dim 100 >/dev/null 2>&1
still=$(sed -n 's/^# null-stage lock \([0-9]*\)$/\1/p' "$h/.config/nulllinux/idle.conf" 2>/dev/null)
[ "$still" = 600 ] && note "ok    a second change keeps the first" \
                   || { note "after changing dim, lock is '${still:-nothing}' rather than 600"; fail=1; }

# 4. THE SYSTEM DEFAULT IS UNTOUCHED. A user editing their own copy must not
#    change what every other account on the machine sees.
after=$(grep -h 'null-stage lock' config/sway/idle.conf)
[ "$before" = "$after" ] && note "ok    the system default is untouched" \
                         || { note "an unprivileged run changed the system file: '$before' -> '$after'"; fail=1; }
rm -rf "$h"

[ $fail = 0 ] && echo "PASS: the idle ladder is writable by the person it belongs to"
exit $fail
