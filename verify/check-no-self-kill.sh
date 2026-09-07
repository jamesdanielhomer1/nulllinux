#!/usr/bin/env bash
# A RESTART CLAUSE THAT KILLS THE SHELL HOLDING IT.
#
# `pkill -f PATTERN` matches every process's full command line, and the shell
# running the pkill is a process with a command line. Write the restart the
# obvious way --
#
#     pkill -f 'null-battery watch'; .../null-battery watch
#
# -- and the pattern is present in that shell's own command line, so pkill
# SIGTERMs it and everything after the semicolon never runs.
#
# config/sway/config carried exactly that line. verify/check-battery.sh passed,
# because the warner is correct; it simply never started. A feature can be
# written, tested, verified and dead.
#
# NULL.md 8.6 records the hazard, and it was quoted in a commit message here by
# somebody who then made the same mistake in the same evening. That is the
# argument for a check rather than another sentence.
#
# WHAT THIS DETECTS is the same-line shape, which is the one that is invisible:
# the pattern and the thing it names sit together, so the line reads correctly.
# It cannot detect a pattern that happens to match the invoking shell's command
# line for some other reason -- lib/once.sh exists so that no component has to
# reason about that at all.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

# The 15-character check below reads CODE, not prose: this file and its
# neighbours quote the broken forms on purpose.
[ -r lib/source.sh ] || { note "lib/source.sh is gone"; exit 1; }
. lib/source.sh

# 1. THE HELPER EXISTS AND SPARES ITS OWN ANCESTORS.
#
#    Behavioural, not a grep: start a process whose command line carries a
#    marker, call the helper from a shell whose command line carries the SAME
#    marker, and require that the process died and the shell did not.
[ -r lib/once.sh ] || { note "lib/once.sh is gone -- components would go back to pkill -f"; exit 1; }

marker="nullLinux-once-probe-$$"
here=$(pwd)
out=$(sh -c "sleep 120 & echo \$! > /tmp/$marker.pid;
             cd '$here' && . lib/once.sh && null_only_one '$marker' && echo SURVIVED" 2>/dev/null)
# The `sleep` above does not carry the marker; the SHELL's command line does,
# which is precisely the process pkill would have killed. So the assertion is
# about the shell.
if [ "$out" = SURVIVED ]; then
  note "ok    null_only_one spares the shell that called it"
else
  note "null_only_one killed its own caller -- the thing it exists to prevent"
  fail=1
fi
[ -f "/tmp/$marker.pid" ] && { kill "$(cat "/tmp/$marker.pid")" 2>/dev/null; rm -f "/tmp/$marker.pid"; }

# And it must actually kill a match, or it is a no-op that looks like a fix.
sh -c "exec -a '$marker-victim sleeping' sleep 120" &
victim=$!
sleep 0.3
( . lib/once.sh && null_only_one "$marker-victim" )
sleep 0.3
if kill -0 "$victim" 2>/dev/null; then
  note "null_only_one did not kill a process whose command line matched"
  kill "$victim" 2>/dev/null
  fail=1
else
  note "ok    null_only_one displaces a running match"
fi
wait "$victim" 2>/dev/null

# 2. NOTHING MAY NAME WHAT IT IS ABOUT TO START.
scan() {
  local f=$1 n=0 line pat rest hits=0
  while IFS= read -r line; do
    n=$((n+1))
    # A COMMENT ABOUT pkill IS NOT A CALL TO IT, and the comment most likely
    # to be here is the one explaining this very hazard. Prose has fooled a
    # check in this suite five times now; the first version of THIS check was
    # the fifth, flagging its own explanation in bin/null-battery.
    #
    # Leading whitespace stripped in full: ${line# } removes one space, and
    # that comment is indented four.
    local t=${line}
    t=${t#"${t%%[![:space:]]*}"}
    case $t in \#*) continue ;; esac
    case $line in *"pkill -f"*|*"pkill --full"*) ;; *) continue ;; esac

    pat=$(sed -n "s/.*pkill[[:space:]]\+\(-f\|--full\)[[:space:]]\+'\([^']*\)'.*/\2/p" <<<"$line")
    [ -n "$pat" ] || pat=$(sed -n 's/.*pkill[[:space:]]\+\(-f\|--full\)[[:space:]]\+"\([^"]*\)".*/\2/p' <<<"$line")
    [ -n "$pat" ] || continue

    # everything on the line EXCEPT the pkill invocation itself
    rest=$(sed "s/pkill[[:space:]]\+\(-f\|--full\)[[:space:]]\+['\"][^'\"]*['\"]//" <<<"$line")
    if grep -qE -- "$pat" <<<"$rest" 2>/dev/null; then
      note "$f:$n  pkill -f '$pat' shares a line with something that matches it"
      note "      the shell running it carries that command line, so it kills itself"
      hits=$((hits+1))
    fi
  done < "$f"
  [ "$hits" = 0 ]
}

for f in config/sway/config bin/* lib/*.sh; do
  [ -f "$f" ] && { scan "$f" || fail=1; }
done

# AND IT MUST STILL SEE THE LINE IT WAS WRITTEN FOR. A scanner that passes
# because it stopped looking is the failure mode of every checker in this
# suite that has ever been fooled by prose, so the line that was really in
# config/sway/config is fed back through it.
probe=$(mktemp)
printf "%s\n" "exec_always pkill -f 'null-battery watch'; NULL_ROOT=\$null \$null/bin/null-battery watch" > "$probe"
if scan "$probe" >/dev/null 2>&1; then
  note "the scanner does not flag the exact line this check was written for"
  fail=1
else
  note "ok    the scanner still catches the line that started this"
fi
# and does not flag a restart clause that names something else
printf "%s\n" "exec_always pkill -f 'some-other-daemon'; /usr/bin/null-battery watch" > "$probe"
scan "$probe" >/dev/null 2>&1 \
  || { note "the scanner flags a pkill whose pattern matches nothing on its line"; fail=1; }
rm -f "$probe"

# 3. AND THE COMPOSITOR'S OWN LINES MAY NOT USE IT AT ALL.
#
#    exec_always is where this bites: the compositor re-runs those lines on
#    every configuration reload, so a self-killing restart clause fails quietly
#    for the entire life of the session. Taking over belongs inside the program,
#    which knows its own process tree.
if grep -nE '^[^#]*pkill[[:space:]]+(-f|--full)' config/sway/config >/dev/null 2>&1; then
  note "config/sway/config uses pkill -f; single-instance belongs in the component (lib/once.sh)"
  grep -nE '^[^#]*pkill[[:space:]]+(-f|--full)' config/sway/config | sed 's/^/      /'
  fail=1
else
  note "ok    the compositor starts things; the components displace their own"
fi

# 4. AND A NAME IS NOT AN OWNER.
#
#    `pkill -x NAME` and `pgrep -x NAME` match by process name across the WHOLE
#    MACHINE. From a session that is too wide twice over: killing an
#    identically named process belonging to somebody else, and -- quieter, and
#    the one that actually misleads -- REPORTING somebody else's daemon as this
#    session's own. `null-nightlight state` said "on" because a different user
#    was running wlsunset.
#
#    -u "$(id -u)" makes both the session's.
#
#    The first version of this clause read only config/sway/config, and three
#    of the four instances in the tree were in bin/.
names=0
for f in config/sway/config bin/* lib/*.sh; do
  [ -f "$f" ] || continue
  n=0
  while IFS= read -r line; do
    n=$((n+1))
    t=${line#"${line%%[![:space:]]*}"}
    case $t in \#*) continue ;; esac
    case $line in *"pkill -x"*|*"pgrep -x"*) ;; *) continue ;; esac
    case $line in *" -u "*) continue ;; esac
    note "$f:$n  $t"
    note "      matches that name on the whole machine; add -u \"\$(id -u)\""
    names=$((names+1))
    fail=1
  done < "$f"
done
[ "$names" = 0 ] && note "ok    every name-matched signal and probe is scoped to this user"

# AND A NAME THE KERNEL CANNOT STORE.
#
# Linux truncates a process's comm to fifteen characters (TASK_COMM_LEN is 16,
# including the terminator). `pgrep -x` and `pkill -x` compare against THAT, so
# an exact match on a longer name never fires -- silently, and in the direction
# that reads as "the process is not running".
#
#   pgrep -x qemu-system-x86_64      18 chars; matches nothing, ever
#
# This is worse than a missed kill. Written as a liveness test it inverts to
# "always dead": verify/vm-iso-install.sh aborted every install with "qemu is
# gone and nothing is installed" while the install ran on behind it. pgrep does
# warn on stderr, but only when a human is watching the stream.
#
# Read as CODE -- the comments in this tree quote the broken form on purpose.
long_names=0
for f in $(git ls-files bin lib verify config 2>/dev/null); do
  [ -f "$f" ] || continue
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "${#name}" -gt 15 ] || continue
    note "$f matches on '$name' (${#name} chars) -- comm is truncated to 15, so this never fires"
    long_names=$((long_names+1)); fail=1
  done < <(null_code_only "$f" 2>/dev/null \
             | grep -oE 'p(kill|grep)([[:space:]]+-[a-zA-Z]+)*[[:space:]]+-[a-zA-Z]*x[a-zA-Z]*[[:space:]]+[-a-zA-Z0-9_.]+' \
             | grep -oE '[-a-zA-Z0-9_.]+$')
done
[ "$long_names" = 0 ] && note "ok    every exact-match process name fits in the kernel's 15 characters"

[ $fail = 0 ] && echo "PASS: no restart clause kills the shell that runs it"
exit $fail
