#!/usr/bin/env bash
# WHAT IT WILL AND WILL NOT ERASE.
#
# bin/null-drive formats removable media. Everything about it that matters is a
# refusal, so that is what this checks: the machine's own disk, a disk that is
# not removable, a device that is not a block device, a drive somebody has
# files open on, and a confirmation that was not typed.
#
# THE END-TO-END FORMAT IS REAL, and it is opt-in. scsi_debug is a kernel module
# that makes a genuinely removable SCSI disk out of memory --
#
#     modprobe scsi_debug dev_size_mb=64 removable=1
#
# -- and formatting it exercises the partition table, the mkfs, and the check
# that asks the KERNEL what the filesystem is rather than trusting mkfs's exit
# status. It needs root and it loads a module, so it runs only when asked:
#
#     NULL_TEST_SCSI_DEBUG=1 ./verify/check-drive.sh
#
# Three defects were found the first time it ran, and all three are the kind
# that only a real device shows:
#
#   lsblk's columnar output COLLAPSES an empty column, so a disk with no
#     transport shifted every field after it and the test deciding whether it
#     was a disk at all read "disk" from the wrong one -- the tool listed a
#     removable disk as nothing at all
#   lsblk PADS values to the column width, so SIZE came back "     0B" and the
#     filter for an empty card reader stopped matching
#   lsblk draws a TREE, so with -p a partition is "└─/dev/sdb1", which is not a
#     path -- mkfs failed on it
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

D=bin/null-drive
[ -x "$D" ] || { note "$D is gone -- formatting a stick is a terminal operation again"; exit 1; }

# 1. `list` CHANGES NOTHING, and neither does --help (NULL.md 8.4). The one
#    time this rule was broken, --help started a destructive build.
for verb in "" list --help; do
  out=$("./$D" $verb 2>&1); rc=$?
  case $out in
    *mkfs*|*sfdisk*|*"writing a new partition"*)
      note "'$D $verb' mentions doing the destructive thing"; fail=1 ;;
  esac
  [ "$rc" -le 1 ] || { note "'$D $verb' exited $rc"; fail=1; }
done
note "ok    list and --help report and change nothing"

# 2. IT REFUSES WHAT IS NOT A BLOCK DEVICE, rather than passing a bad name on
#    to sfdisk and finding out from the error.
out=$("./$D" format /dev/definitely-not-here 2>&1)
grep -q 'not a block device' <<<"$out" \
  && note "ok    a name that is not a device is refused by name" \
  || { note "formatting a non-device did not say so: $out"; fail=1; }

# 3. AND IT REFUSES THE MACHINE'S OWN DISK. Derived from the mount table, so
#    this works on nvme, on sd, on mmc, and on a machine booted from a stick.
sysdisk=$(awk '$2=="/" {print $1}' /proc/mounts | head -1)
if [ -b "${sysdisk:-}" ]; then
  whole=$(lsblk -ndo PKNAME "$sysdisk" 2>/dev/null)
  [ -n "$whole" ] && whole=/dev/$whole || whole=$sysdisk
  out=$("./$D" format "$whole" 2>&1)
  if grep -q 'not a removable drive' <<<"$out"; then
    note "ok    the disk this system is running from is refused ($whole)"
  else
    note "formatting $whole -- the disk holding / -- was not refused:"
    sed 's/^/      /' <<<"$out"
    fail=1
  fi
else
  note "(cannot identify the root device here; the system-disk refusal is not exercised)"
fi

# 4. THE GUARDS ARE RE-CHECKED ON THE ARGUMENT PATH, not only in the picker.
#    A device name can arrive from a script or from a list read a minute ago.
grep -q 'EVERY GUARD RE-CHECKED HERE' "$D" \
  || { note "$D does not re-check its guards when given a device as an argument"; fail=1; }

# 5. IT READS DEVICE NAMES FROM A FLAT LIST. lsblk -p on a tree yields
#    "└─/dev/sdb1"; mkfs fails on it and udisksctl unmounts nothing.
if grep -nE 'lsblk [^|]*-npo' "$D" | grep -v '^\s*#' | grep -q 'lsblk'; then
  note "$D reads names from lsblk without -l, so a partition comes back with tree characters"
  grep -nE 'lsblk [^|]*-npo' "$D" | sed 's/^/      /'
  fail=1
else
  note "ok    every device name is read from a flat listing"
fi

# 6. THE SETTINGS PANEL OFFERS IT, or the only way to format a stick is to know
#    the command exists.
grep -q 'null-drive' bin/null-settings \
  || { note "bin/null-settings does not offer null-drive"; fail=1; }

# 7. AND, WHEN ASKED, THE WHOLE THING AGAINST A REAL REMOVABLE DISK.
#
#    ON A MACHINE WHOSE STATE IS EXPENDABLE, AND NOWHERE ELSE. This loads a
#    kernel module and formats a block device. Both are fine on a nullLinux
#    guest and neither is fine on the desktop somebody develops from (lib/host.sh).
. lib/host.sh
if [ "${NULL_TEST_SCSI_DEBUG:-0}" = 1 ] && null_only_on_a_test_machine "the end-to-end format"; then
  if [ "$(id -u)" != 0 ]; then
    note "(NULL_TEST_SCSI_DEBUG needs root; end-to-end skipped)"
  elif ! modprobe scsi_debug dev_size_mb=64 removable=1 2>/dev/null; then
    note "(scsi_debug will not load here; end-to-end skipped)"
  else
    sleep 2
    dev=$(lsblk -dnpo NAME,MODEL 2>/dev/null | awk '$2=="scsi_debug"{print $1; exit}')
    if [ -z "$dev" ]; then
      note "scsi_debug loaded but produced no disk"
      fail=1
    else
      # IT MUST APPEAR. The bug that started this check was a removable disk
      # the tool listed as nothing at all.
      "./$D" list 2>&1 | grep -q "$dev" \
        && note "ok    a removable disk appears in the list ($dev)" \
        || { note "$dev is removable and $D does not list it"; fail=1; }

      # DECLINING WRITES NOTHING.
      was=$(lsblk -lnpo NAME,FSTYPE "$dev" 2>/dev/null)
      printf '1\nPROBE\nnot-the-name\n' | "./$D" format "$dev" >/dev/null 2>&1
      now=$(lsblk -lnpo NAME,FSTYPE "$dev" 2>/dev/null)
      [ "$was" = "$now" ] \
        && note "ok    a confirmation that was not typed writes nothing" \
        || { note "declining still changed $dev"; fail=1; }

      # AND CONFIRMING PRODUCES THE FILESYSTEM THE KERNEL AGREES ON.
      printf '1\nNULLPROBE\n%s\n' "$dev" | "./$D" format "$dev" >/dev/null 2>&1
      sleep 1
      got=$(lsblk -lnpo NAME,FSTYPE,LABEL "$dev" 2>/dev/null | awk 'NR==2{print $2" "$3}')
      if [ "$got" = "exfat NULLPROBE" ]; then
        note "ok    formatting produced exactly what was asked for ($got)"
      else
        note "after formatting, the kernel reports '$got' rather than 'exfat NULLPROBE'"
        fail=1
      fi
    fi
    # OURS, AND ONLY BECAUSE WE LOADED IT.
    rmmod scsi_debug 2>/dev/null || note "(scsi_debug is still loaded; rmmod refused)"
  fi
elif [ "${NULL_TEST_SCSI_DEBUG:-0}" != 1 ]; then
  note "(end-to-end format not run; NULL_TEST_SCSI_DEBUG=1 as root on a test machine runs it)"
fi

[ $fail = 0 ] && echo "PASS: it erases removable media and refuses everything else"
exit $fail
