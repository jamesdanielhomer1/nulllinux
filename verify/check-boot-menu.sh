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

# 6. AND THE DEFAULT ENTRY INSTALLS, rather than verifying the medium first.
#
#    lorax writes set default="1", which is "Test this media & install" -- a
#    full read of 1.2 GB before anything starts. Fair for a scratched disc,
#    poor as the first thing a person meets. The check stays as entry 1.
grep -q "set default=" bin/null-installer-iso \
  || { note "bin/null-installer-iso does not set the default boot entry -- the ISO verifies 1.2 GB before installing"; fail=1; }
grep -q "'set default=\"0\"'" bin/null-installer-iso \
  || { note "bin/null-installer-iso does not select entry 0 (Install)"; fail=1; }

# 7. AND THE MEDIUM'S OWN MENU, which is a different menu nobody had looked at.
#
#    Everything above is about the menu an INSTALLED machine draws. The ISO has
#    its own, three copies of it in fact -- /boot/grub2/grub.cfg for BIOS,
#    /EFI/BOOT/grub.cfg and /EFI/BOOT/BOOT.conf for UEFI -- and lorax writes
#    `set timeout=60` into all of them.
#
#    Sixty seconds of countdown, watched, before an install begins. Seen on the
#    first UEFI boot this project ever did:
#
#        The highlighted entry will be executed automatically in 46s.
#
#    The same judgement this file already applies to the installed system, not
#    applied to the medium that installs it.
grep -q "set timeout=60' 'set timeout=5'" bin/null-installer-iso \
  || { note "bin/null-installer-iso does not shorten the medium's own 60s menu"; fail=1; }

#    MEASURED ON THE ARTEFACT, where there is one. -R claims to rewrite every
#    grub.cfg on the medium; this reads them back rather than believing it.
iso=$(ls -t /var/lib/nulllinux-iso/nulllinux-installer-*.iso 2>/dev/null | head -1)
if [ -n "$iso" ] && [ "$(id -u)" = 0 ] && command -v mount >/dev/null 2>&1; then
  m=$(mktemp -d)
  # A TRAP, because a check that leaves a mount behind has changed the machine
  # it ran on (verify/check-tests-stay-off-the-host.sh).
  trap 'umount "$m" 2>/dev/null; rmdir "$m" 2>/dev/null' EXIT
  if mount -o loop,ro "$iso" "$m" 2>/dev/null; then
    n=0 bad=0
    while IFS= read -r cfg; do
      n=$((n+1))
      t=$(sed -n 's/^[[:space:]]*set timeout=\([0-9]*\).*/\1/p' "$cfg" | head -1)
      d=$(sed -n 's/^[[:space:]]*set default="\([0-9]*\)".*/\1/p' "$cfg" | head -1)
      [ "${t:-99}" -le 5 ] 2>/dev/null || { note "${cfg#$m} waits ${t}s"; bad=1; }
      [ "${d:-9}" = 0 ] || { note "${cfg#$m} defaults to entry ${d} rather than Install"; bad=1; }
    done < <(find "$m" \( -iname 'grub.cfg' -o -iname 'BOOT.conf' \) 2>/dev/null)
    if [ "$n" = 0 ]; then
      note "(no grub config found on $iso)"
    elif [ "$bad" = 0 ]; then
      note "ok    all $n boot config(s) on the medium: entry 0, 5s or less"
    else
      fail=1
    fi
    umount "$m" 2>/dev/null
  else
    note "(could not mount $iso; the medium's own menu is not measured)"
  fi
  rmdir "$m" 2>/dev/null
  trap - EXIT
else
  note "(no built ISO, or not root; the medium's own menu is not measured)"
fi

[ $fail = 0 ] && echo "PASS: the boot menu is quiet, and says how to summon it"
exit $fail
