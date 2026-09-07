#!/usr/bin/env bash
# A LAPTOP WITH NO WIFI CANNOT FIX ITSELF.
#
# Fedora split the wireless firmware out of linux-firmware, and linux-firmware
# does not pull it back in. An install here had 345 firmware files and ZERO
# iwlwifi ones:
#
#     $ ls /lib/firmware/iwlwifi* | wc -l
#     0
#
# So on a ThinkPad T480 -- the machine this is going onto -- the wireless card
# would come up, ask for firmware, and find none. That is the worst shape a
# missing package can take: the thing you need in order to download the fix is
# the thing that is missing.
#
# It was invisible from the package list, which never mentioned firmware, and
# invisible from the kickstart, which says `@core`, `kernel`, `nulllinux` and
# looks complete. It was found by asking a running guest what it actually had,
# which is what verify/in-guest.sh exists for.
#
# TWO QUESTIONS, and the second is the real one:
#
#   IS IT DECLARED?   -- answerable anywhere, including a build host
#   DID THE KERNEL ASK FOR SOMETHING IT DID NOT GET? -- answerable only on the
#                        machine with the hardware, which is the whole point
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

[ -x bin/pkg ] || { note "bin/pkg is gone"; exit 1; }
DECLARED=$(./bin/pkg list-packages base 2>/dev/null | tr ' ' '\n' | sort -u)

# 0. AND THE INSTALLED SET MATCHES THE DECLARED ONE.
#
#    A package list is a statement of intent. What arrived is a different
#    question, and the gap between them is where every finding tonight has
#    lived: tar declared nowhere and absent, unzip present and undeclared,
#    iwlwifi firmware neither. On a machine that IS nullLinux, ask it.
if grep -qiE '^(ID|NAME)=.*null' /etc/os-release 2>/dev/null; then
  absent=""
  for p in $(printf '%s\n' "$DECLARED"); do
    ./bin/pkg installed-version "$p" >/dev/null 2>&1 || absent="$absent $p"
  done
  if [ -n "$absent" ]; then
    note "declared but not installed on this nullLinux machine:$absent"
    fail=1
  else
    note "ok    every declared package is installed on this machine"
  fi
fi

# 1. THE WIFI FAMILIES A LAPTOP ACTUALLY HAS. Each is a separate package
#    precisely because Fedora expects a distribution to choose, and choosing
#    nothing is a choice that shows up as a card with no driver firmware.
for p in iwlwifi-mvm-firmware iwlwifi-dvm-firmware atheros-firmware realtek-firmware; do
  printf '%s\n' "$DECLARED" | grep -qix "$p" \
    || { note "$p is not declared -- that hardware has no firmware here"; fail=1; }
done
[ $fail = 0 ] && note "ok    the wireless firmware families are declared"

# 2. AND THE KERNEL ON THIS MACHINE GOT WHAT IT ASKED FOR.
#
#    "Direct firmware load for X failed" is the kernel saying a driver asked
#    for a file that is not there. On a VM there is usually nothing to report;
#    on metal it is the only test that matters, and it is the reason this check
#    is worth running on the machine rather than about it.
if command -v journalctl >/dev/null 2>&1; then
  missing=$(journalctl -b -k --no-pager 2>/dev/null \
            | grep -oE 'Direct firmware load for [^ ]+ failed|firmware: failed to load [^ ]+' \
            | sed -E 's/Direct firmware load for //; s/firmware: failed to load //; s/ failed//' \
            | sort -u)
  if [ -z "$missing" ]; then
    note "ok    nothing asked for firmware it did not get this boot"
  else
    n=$(printf '%s\n' "$missing" | grep -c .)
    note "$n firmware file(s) a driver asked for and did not get:"
    printf '%s\n' "$missing" | sed 's/^/      /'
    note "      each is a piece of hardware that will not work on this machine"
    fail=1
  fi
else
  note "(no journalctl here; what the kernel asked for cannot be read)"
fi

# 3. AND, WHERE THERE IS WIRELESS HARDWARE, IT HAS A DRIVER BOUND.
#
#    A card with no firmware still appears in lspci; it just never becomes a
#    network interface. So the question is not "is the card here" but "did it
#    become something you can join a network with".
if [ -d /sys/class/net ]; then
  # A GLOB, NOT find. Everything in /sys/class/net is a SYMLINK, and find does
  # not follow one without -L -- so this reported "no wireless interface" on a
  # ThinkPad whose wlp3s0 was up and bound to iwlwifi at the time. A check that
  # cannot see the hardware reports the machine as fine, which is the direction
  # of error that hides things.
  wireless=""
  for d in /sys/class/net/*/; do
    [ -d "$d/wireless" ] && wireless="$wireless $(basename "$d")"
  done
  wireless=${wireless# }
  if [ -n "$wireless" ]; then
    note "ok    wireless present and bound: $wireless ($(for w in $wireless; do
            sed -n 's/^DRIVER=//p' "/sys/class/net/$w/device/uevent" 2>/dev/null; done | tr '\n' ' '))"
  else
    # NOT A FAILURE. A VM has no wifi and neither does a desktop; saying so is
    # different from saying it is broken.
    note "(no wireless interface on this machine; nothing to bind)"
  fi
fi

[ $fail = 0 ] && echo "PASS: the firmware a machine needs is declared, and nothing went without"
exit $fail
