# One of a thing, without killing the shell that started it. Sourced, never run.
#
# `pkill -f PATTERN` matches against every process's full command line, and the
# shell that runs the pkill is a process with a command line. When the pattern
# and the thing being started are on the SAME line -- which is the natural way
# to write "restart this" --
#
#     pkill -f 'null-battery watch'; exec .../null-battery watch
#
# then that shell's own command line contains the pattern, pkill SIGTERMs it,
# and the command after the semicolon never runs. Reproduced exactly:
#
#     $ sh -c "pkill -f 'zzq-nulltest-pattern'; echo survived"
#     exit 144            # 128 + SIGTERM, and nothing printed
#
# config/sway/config had that line for null-battery. The warner has therefore
# never started in a real session -- it was written, tested by hand, checked by
# verify/check-battery.sh, and killed by its own restart clause every time the
# compositor read its configuration.
#
# The fix is not a cleverer pattern. It is to do the killing from INSIDE the
# program that is taking over, where the process tree is known: our own pid,
# and every ancestor up to init, are the processes that must survive, because
# our parent is the shell the compositor is holding open on our behalf.
#
# NULL.md 8.6 already records `pkill -f` matching its own invoker. It is quoted
# in this repository's history by somebody who then made the mistake anyway,
# which is the argument for a helper rather than a rule.

# null_only_one <substring of the command line to displace>
#
# Kills every other process whose command line contains the substring, skipping
# ourselves and our ancestors. Plain substring, not a regex: the callers all
# pass literal command lines, and a regex here would be one more thing to get
# subtly wrong.
null_only_one() {
  local pat=$1 pid cmd p
  [ -n "$pat" ] || return 0

  # THE ANCESTOR CHAIN, from PPid in /proc/PID/status rather than field 4 of
  # /proc/PID/stat -- stat's second field is the command name in parentheses
  # and a command name may contain spaces and parentheses, which moves every
  # field after it. status is keyed by name and cannot be miscounted.
  local -A keep=()
  pid=$$
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    keep[$pid]=1
    pid=$(awk '/^PPid:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null)
  done

  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ -n "${keep[$pid]:-}" ] && continue
    cmd=$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null) || continue
    case $cmd in
      *"$pat"*) kill "$pid" 2>/dev/null || true ;;
    esac
  done
  return 0
}
