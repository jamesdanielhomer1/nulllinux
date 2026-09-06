#!/usr/bin/env bash
# THE BOOT MENU DOES NOT COUNT TO FIVE.
#
# Fedora's default is GRUB_TIMEOUT=5 with no timeout style, so the menu is
# drawn and counted down on every single boot. Five seconds, every time.
#
# It was invisible to everything this project measures. systemd-analyze starts
# at the kernel; this happens before it. A whole night of boot-time work --
# udev-settle, firewalld, the netfilter preload, the machine-sync fast path,
# eight seconds saved between them and every one of them measured with
# systemd-analyze -- and the largest single cost was upstream of the ruler.
#
# Measured properly, power-on to ssh answering: 48.2s became 41.6s by changing
# one number.
#
# THE MENU IS NOT GONE. `hidden` means GRUB waits the timeout for a keypress
# rather than drawing the menu at you, and holding Esc or Shift during that
# second still brings it up. That matters more here than on most systems: this
# one has a single ordinary kernel, so the rescue entry is the only fallback
# there is (NULL.md 9.6).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

KS=packaging/nulllinux-install.ks
[ -r "$KS" ] || { note "$KS is gone"; exit 1; }

# 1. The timeout itself. Anything above 2 is a menu somebody watches.
t=$(grep -oE '^bootloader .*--timeout=[0-9]+' "$KS" | grep -oE 'timeout=[0-9]+' | cut -d= -f2)
if [ -z "$t" ]; then
  note "$KS: the bootloader line sets no --timeout, so Fedora's 5s default applies"
  fail=1
elif [ "$t" -gt 2 ]; then
  note "$KS: --timeout=$t means ${t}s of every boot spent in the menu"
  fail=1
else
  note "ok    the boot menu waits ${t}s"
fi

# 2. Hidden, or the timeout is spent staring at a menu regardless.
grep -q 'GRUB_TIMEOUT_STYLE=hidden' "$KS" \
  || { note "$KS: %post does not set GRUB_TIMEOUT_STYLE=hidden -- the menu is drawn and counted down"; fail=1; }

# 3. THE CONFIG HAS TO BE REGENERATED. GRUB_TIMEOUT_STYLE lives in
#    /etc/default/grub and does nothing at all until grub2-mkconfig writes it
#    into grub.cfg. Setting it without regenerating is a file that documents an
#    intention.
grep -q 'grub2-mkconfig' "$KS" \
  || { note "$KS: sets GRUB_TIMEOUT_STYLE without regenerating grub.cfg -- it would have no effect"; fail=1; }

# 4. And %post must say what it ended up with, because a warning nobody prints
#    is a five-second wait nobody notices for another month.
grep -q 'GRUB still waits' "$KS" \
  || { note "$KS: %post does not report or warn about the final timeout"; fail=1; }

# 5. THE ESCAPE HATCH IS DOCUMENTED. Hiding the menu on a machine whose rescue
#    entry is its only fallback is only acceptable if how to reach it is
#    written down where somebody will find it.
grep -qiE 'esc or shift|Esc/Shift|hold (esc|shift)' "$KS" \
  || { note "$KS: hides the menu without saying how to bring it back"; fail=1; }

[ $fail = 0 ] && echo "PASS: the boot menu is quiet, and says how to summon it"
exit $fail
