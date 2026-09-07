#!/usr/bin/env bash
# A KICKSTART THAT ONLY WORKS ON ONE KIND OF FIRMWARE.
#
# `bootloader --location=mbr` names a place that exists on a BIOS machine and
# not on an EFI one. On EFI, anaconda stops reading the file at that line --
# and everything after it is silently lost.
#
# What that produced, measured on an installed disk:
#
#   before the line   ignoredisk, zerombr, clearpart, autopart -- applied. A
#                     600M ESP, a 2G /boot and a 17.4G /, ext4, no swap.
#   after the line    network --hostname, timezone, keyboard, user -- none. No
#                     /etc/hostname, no /etc/localtime, vconsole.conf still
#                     systemd's fallback, and no account with a shell but root.
#
# The greeter came up saying `localhost` and refused the password, because the
# person it had been asked to create was never created. In the AUTOMATED
# kickstart `rootpw` sits below that line too, so a UEFI install of it makes a
# machine nobody can log into by any means.
#
# nox boots EFI with secure boot enrolled, and every install this project had
# ever done was BIOS. The line had been correct for every machine anybody had
# tried and wrong for the one it is going onto.
#
# THE RULE: nothing in a kickstart may name something only one firmware has.
# anaconda picks the MBR on a BIOS machine and the ESP on an EFI one without
# being told; saying it can only be wrong on one of them.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

[ -r lib/source.sh ] && . lib/source.sh

# 1. NOTHING PINS A BIOS-ONLY BOOTLOADER LOCATION.
#
#    The kickstart is data, not shell, so comments are stripped by hand: a line
#    beginning with # is a comment, and this file's own header quotes the string
#    it looks for.
for ks in packaging/*.ks; do
  [ -f "$ks" ] || continue
  if grep -vE '^\s*#' "$ks" | grep -qE '^bootloader .*--location=(mbr|partition)'; then
    note "$ks pins --location, which exists on one firmware and not the other:"
    grep -nE '^bootloader ' "$ks" | sed 's/^/      /'
    fail=1
  fi
done

# 2. AND NEITHER DOES THE THING THAT WRITES ONE.
if [ -x bin/null-installer ]; then
  if null_code_only bin/null-installer 2>/dev/null | grep -q 'location=mbr'; then
    note "bin/null-installer generates --location=mbr"
    fail=1
  fi
fi

# 3. THE GENERATED FRAGMENT STILL SAYS WHICH DISK TO BOOT FROM. Dropping
#    --location must not drop --boot-drive with it: on a machine with two disks
#    anaconda would otherwise be free to choose the wrong one.
if [ -x bin/null-installer ]; then
  out=$(mktemp)
  disk=$(lsblk -dnpo NAME,SIZE,MODEL,TYPE 2>/dev/null \
         | awk '$NF=="disk" { $NF=""; sub(/[ \t]+$/,""); print }' \
         | grep -vE '^/dev/(zram|nbd|loop|ram|sr|fd)[0-9]' \
         | grep -vE ' 0B( |$)' | awk '{print $1; exit}')
  if [ -n "$disk" ]; then
    printf '1\nh\nu\nU\npw\npw\nEurope/London\ngb\n%s\n' "$disk" \
      | "./bin/null-installer" --generate "$out" --dry-run >/dev/null 2>&1
    if grep -qE '^bootloader .*--boot-drive=' "$out" 2>/dev/null; then
      note "ok    the fragment names a boot drive and no firmware-specific location"
    else
      note "the fragment no longer names --boot-drive:"
      grep -E '^bootloader' "$out" 2>/dev/null | sed 's/^/      /'
      fail=1
    fi
  else
    note "(no disk visible here; the generated bootloader line is not exercised)"
  fi
  rm -f "$out"
fi

# 4. AND THE ANSWERS THAT MATTER MOST DO NOT SIT AT THE BOTTOM.
#
#    This is defence against the same failure in a different disguise. If a
#    later line ever does abort the parse, whatever follows is lost -- so the
#    two answers that decide whether anybody can log in at all should not be
#    the last things in the file. It is a warning, not a failure: the ordering
#    is anaconda's to care about, and this only asks that somebody thought
#    about it.
for ks in packaging/*.ks; do
  [ -f "$ks" ] || continue
  last=$(grep -vE '^\s*#' "$ks" | grep -nE '^(rootpw|user) ' | tail -1 | cut -d: -f1)
  total=$(grep -vE '^\s*#' "$ks" | grep -nE '^%(packages|pre|post)' | head -1 | cut -d: -f1)
  [ -n "$last" ] && [ -n "$total" ] && [ "$last" -gt "$total" ] \
    && note "($(basename "$ks"): rootpw/user appear after the first % section)"
done

[ $fail = 0 ] && echo "PASS: the kickstart does not assume one kind of firmware"
exit $fail
