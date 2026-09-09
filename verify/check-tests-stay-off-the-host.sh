#!/usr/bin/env bash
# A CHECK MAY NOT DAMAGE THE MACHINE IT IS RUN FROM.
#
# nullLinux is developed on the machine that runs it: the build host (hostname
# `null`, once `nox`) has been nullLinux since 2026-09-08 and is the daily
# driver, so the tree is the live system, not a checkout beside one. Before
# that it ran the system this one replaced. Either way every check runs, by
# default, against somebody's desktop.
#
# Twice in one evening that cost real damage, and neither was the shipped code
# misbehaving -- both were a destructive test with nothing pointing it away from
# the development machine:
#
#   `pkill -x sway`, to clear up a headless instance started for a test, matched
#     the compositor nox was running and ended the session
#   `null-users remove-confirmed james delete`, run expecting a refusal, deleted
#     a real account and its home directory
#
# verify/check-column-zone.sh had already written the rule down: "A check that
# damages the thing it checks is worse than no check: it is a check with a cost
# nobody attributed to it." It was a sentence in one file. This makes it a
# property of the suite.
#
# THE RULE. A check that changes state outside this repository must either
#
#   RESTORE it -- an EXIT trap that puts back what it took down, which is what
#     check-column-zone does with the live column; or
#   REFUSE unless the machine is expendable -- null_only_on_a_test_machine from
#     lib/host.sh, which is true on an installed nullLinux or when somebody has
#     said NULL_TEST_MACHINE=1.
#
# WHAT COUNTS AS CHANGING STATE OUTSIDE THE REPOSITORY: loading a kernel module,
# writing to a block device, killing a process this check did not start,
# useradd/userdel, systemctl, writing outside $TMPDIR and the tree.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

[ -r lib/host.sh ] || { note "lib/host.sh is gone -- there is nothing to point a destructive check away from"; exit 1; }
. lib/host.sh
[ -r lib/source.sh ] || { note "lib/source.sh is gone -- this would read prose as code"; exit 1; }
. lib/source.sh

# 1. THE GUARD ANSWERS HONESTLY ABOUT THIS MACHINE. Behavioural: it must agree
#    with /etc/os-release, and NULL_TEST_MACHINE must be able to override it.
if null_is_nulllinux; then
  grep -qiE '^(ID|NAME|ID_LIKE)=.*null' /etc/os-release \
    && note "ok    this IS a nullLinux machine, and the guard says so" \
    || { note "the guard claims nullLinux and /etc/os-release does not"; fail=1; }
else
  grep -qiE '^(ID|NAME|ID_LIKE)=.*null' /etc/os-release \
    && { note "the guard denies nullLinux and /etc/os-release says otherwise"; fail=1; } \
    || note "ok    this is $(null_host_description), and the guard says so"
fi

( NULL_TEST_MACHINE=1; null_machine_is_expendable ) \
  && note "ok    NULL_TEST_MACHINE=1 makes a machine expendable" \
  || { note "NULL_TEST_MACHINE=1 does not work, so there is no way to opt a scratch box in"; fail=1; }

  # WITHOUT the opt-in, NOTHING is expendable -- not even a nullLinux machine,
  # because the build host is one now and it is the daily driver. This is the
  # property that keeps a destructive test off it.
  ( unset NULL_TEST_MACHINE; null_machine_is_expendable ) \
    && { note "a machine with no NULL_TEST_MACHINE=1 was called expendable -- the daily driver is unprotected"; fail=1; } \
    || note "ok    without NULL_TEST_MACHINE=1 no machine is expendable, daily driver included"

# 2. EVERY DESTRUCTIVE CHECK IS GUARDED OR RESTORES.
#
#    PROSE STRIPPED FIRST, by lib/source.sh. This file's own header names every
#    dangerous verb it looks for; check-firewall.sh greps a kickstart for the
#    string "systemctl enable firewalld.service" and explains in a message why a
#    modprobe must be tolerant. All three read as invocations to a plain grep,
#    and the first version of this check reported all three.
#
#    pkill and killall are here and a bare `kill` is not: killing a pid you
#    started yourself is how a test cleans up after itself, and killing by NAME
#    is how a test ends somebody else's program.
DANGER='modprobe|rmmod|mkfs\.|sfdisk|userdel|useradd|gpasswd|pkill|killall|systemctl (start|stop|restart|enable|disable)|swaymsg reload'

scan() {  # <file> -> 0 if clean or properly guarded, 1 if not
  local f=$1 code hits
  code=$(null_code_only "$f")
  hits=$(grep -oE "$DANGER" <<<"$code" | sort -u | tr '\n' ' ')
  [ -n "${hits// /}" ] || return 0
  if grep -q 'null_only_on_a_test_machine' "$f"; then
    note "ok    $(basename "$f") guards its destructive part (${hits% })"
    return 0
  elif grep -qE "^[[:space:]]*trap .*EXIT" "$f"; then
    note "ok    $(basename "$f") restores what it takes down (${hits% })"
    return 0
  fi
  note "$(basename "$f") runs ${hits}and neither guards nor restores"
  note "      source lib/host.sh and wrap it in null_only_on_a_test_machine"
  return 1
}

for f in verify/check-*.sh verify/vm-*.sh; do
  [ -f "$f" ] || continue
  case $f in verify/check-tests-stay-off-the-host.sh) continue ;; esac
  scan "$f" || fail=1
done

# AND THE SCANNER STILL SEES AN UNGUARDED ONE. Every check in this suite that
# has ever been fooled was fooled while passing, so a scanner that passes
# proves nothing until it has been shown something it must not pass.
probe=$(mktemp --suffix=.sh)
printf '#!/usr/bin/env bash\nmodprobe scsi_debug\nmkfs.exfat /dev/sdz1\n' > "$probe"
if scan "$probe" >/dev/null 2>&1; then
  note "the scanner does not flag a check that modprobes and formats with no guard"
  fail=1
else
  note "ok    the scanner flags an unguarded destructive check"
fi
# and does not flag one that only mentions them
printf '#!/usr/bin/env bash\n# modprobe and mkfs.exfat are what this is about\ngrep -q "systemctl enable foo" x\n' > "$probe"
scan "$probe" >/dev/null 2>&1 \
  || { note "the scanner flags a check that only mentions the dangerous verbs in prose"; fail=1; }
rm -f "$probe"

# 3. AND THERE IS A PLACE TO SEND THEM. A guard that skips everything on the
#    only machine anybody runs is a guard that turns the tests off.
[ -x verify/in-guest.sh ] \
  || { note "verify/in-guest.sh is missing, so the guarded checks have nowhere to run"; fail=1; }
grep -q 'vm-iso-install.sh' verify/in-guest.sh 2>/dev/null \
  || { note "verify/in-guest.sh does not use the ISO-installed guest"; fail=1; }

[ $fail = 0 ] && echo "PASS: a destructive check is pointed at a machine, and it is not this one"
exit $fail
