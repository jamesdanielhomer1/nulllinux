#!/usr/bin/env bash
# Run the checks on nullLinux, not on the machine that builds it.
#
# The development machine is somebody's desktop. Since 2026-09-08 it IS the
# product -- nullLinux, converted in place, the daily driver -- and this tree is
# its live system, not a checkout beside one; before that it ran the system
# nullLinux replaced. Either way, a check that touches
# anything outside the repository is aimed at somebody's desktop unless
# something points it somewhere else. Twice in one evening that cost real
# damage: a session ended by a `pkill -x sway` meant for a test instance, and an
# account and its home directory deleted by a verb that was supposed to refuse.
#
# This is the somewhere else. It copies the WORKING TREE -- not the installed
# package, so uncommitted changes are what gets tested -- into a nullLinux guest
# and runs the suite there, opting the guest in with NULL_TEST_MACHINE=1 because
# guest is a real, disposable test machine (a nullLinux daily driver is not).
#
#   verify/in-guest.sh                     the whole suite
#   verify/in-guest.sh check-drive.sh      one check
#   verify/in-guest.sh -- <command>        anything, in the guest
#
# The guest is the one verify/vm-iso-install.sh builds and keeps: an ISO
# install, with the test ssh key the kickstart carries for exactly this and
# which is stripped from shipped media.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd); cd "$ROOT"

VM="$ROOT/verify/vm-iso-install.sh"
[ -x "$VM" ] || { echo "in-guest: $VM is missing" >&2; exit 1; }

# WHERE IT LANDS IN THE GUEST. Not /usr/nulllinux: that is the installed
# package, and overwriting it would mean the next check ran against a tree
# somebody's session is also using. A separate directory, so what is tested and
# what is running are never the same files.
DEST=/root/nulllinux-under-test

say() { printf '  %s\n' "$*"; }

guest() { "$VM" ssh "$@"; }

# 1. IS THERE A GUEST? Reported, not assumed -- and the message says the one
#    command that makes one, because "connection refused" does not.
if ! guest true >/dev/null 2>&1; then
  echo "in-guest: no nullLinux guest is answering." >&2
  echo >&2
  echo "  Boot the one that is already installed:" >&2
  echo "      verify/vm-iso-install.sh boot" >&2
  echo "  Or install a fresh one from the current ISO (long):" >&2
  echo "      verify/vm-iso-install.sh install" >&2
  exit 1
fi

# 2. AND IS IT ACTUALLY nullLinux? A guest that is something else would run the
#    suite and mean nothing by it.
if ! guest 'grep -qiE "^(ID|NAME)=.*null" /etc/os-release' >/dev/null 2>&1; then
  echo "in-guest: the guest answering is not nullLinux:" >&2
  guest 'grep PRETTY_NAME /etc/os-release' 2>&1 | sed 's/^/    /' >&2
  exit 1
fi
say "guest: $(guest '. /etc/os-release; echo "$PRETTY_NAME"' 2>/dev/null)"

# 3. THE WORKING TREE, INCLUDING WHAT IS NOT COMMITTED. The point of running in
#    a guest is to test the change you just made; sending HEAD would test the
#    change before it.
#
#    Built artefacts travel too -- render/target holds the binaries several
#    checks run -- but nothing else large: .git is the tree's history and the
#    guest has no use for it.
say "copying the working tree to $DEST"
guest "rm -rf $DEST && mkdir -p $DEST" >/dev/null 2>&1
# UNPACKED BY WHATEVER THE GUEST HAS. The first version piped tar to tar and
# died with "tar: command not found" -- nullLinux did not ship tar. That is
# fixed (it is declared now, and xarchiver needed it more than this does), but
# a test runner that only works against a guest new enough to have the fix is a
# test runner that cannot test the fix. python3 is in the package list for the
# bake and is on every one of these images.
if guest 'command -v tar' >/dev/null 2>&1; then
  unpack="tar -C $DEST -xf -"
else
  unpack="python3 -c \"import tarfile,sys; tarfile.open(fileobj=sys.stdin.buffer, mode='r|').extractall('$DEST')\""
  say "the guest has no tar; unpacking with python3"
fi
tar -C "$ROOT" -cf - \
    --exclude=.git \
    --exclude='render/target/debug' \
    --exclude='packaging/rpmbuild/BUILD*' \
    . 2>/dev/null | guest "$unpack" || {
  echo "in-guest: copying the tree failed" >&2; exit 1; }

# 4. THE GUEST'S OWN MACHINE PROFILE.
#
#    A profile is DERIVED from the hardware, and lives at machines/<hostname>.conf
#    -- so a tree copied from the build host has nox's profile and not the
#    guest's, and two checks fail with "no profile for 'nulltest'". That is not
#    a defect in either machine; it is a tree that has never met this hardware.
#
#    Generated rather than copied from the installed package, because generating
#    is what an installed machine does on first boot and doing the same thing
#    here tests that path as a side effect.
if ! guest "[ -r $DEST/machines/\$(hostname).conf ]" >/dev/null 2>&1; then
  say "deriving the guest's machine profile"
  guest "cd $DEST && ./bin/machine generate" 2>&1 | sed 's/^/    /'
fi

# 5. RUN IT THERE.
if [ "${1:-}" = "--" ]; then
  shift
  guest "cd $DEST && NULL_TEST_MACHINE=1 $*"
  exit $?
fi

if [ $# -gt 0 ]; then
  rc=0
  for c in "$@"; do
    case $c in verify/*) c=${c#verify/} ;; esac
    say "running $c in the guest"
    guest "cd $DEST && NULL_TEST_MACHINE=1 ./verify/$c" || rc=1
  done
  exit $rc
fi

say "running the whole suite in the guest"
guest "cd $DEST && NULL_TEST_MACHINE=1 ./verify/run.sh"
