#!/usr/bin/env bash
# Install the ISO onto a blank disk, in a virtual machine, unattended.
#
# WHY NOT ON REAL HARDWARE. The only machine that could take this image is the
# machine the work lives on, reached over the network from another country.
# Installing there would repartition the disk, destroy the tree, and -- if the
# bootloader went wrong -- leave no way back in. Irreversible in the direction
# that matters.
#
# A blank virtual disk exercises THE SAME INSTALLER. Anaconda partitions,
# writes a bootloader, runs the package transaction and reboots into the
# result. Every step that can be wrong in software is wrong here too.
#
# WHAT THIS CANNOT TEST, and only metal can: real firmware and secure boot, a
# discrete GPU's driver, a wifi chipset, suspend and resume, and a panel whose
# EDID is not qemu's. Those stay open and the report says so rather than
# implying an install has been proved on hardware.
set -uo pipefail
ROOT=${NULL_ROOT:-$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)}
WORK=${NULL_VM_WORK:-/var/lib/nulllinux-test}
SRC_ISO=${NULL_ISO:-$(find /var/lib/nulllinux-iso -name '*.iso' 2>/dev/null | head -1)}
KS_ISO="$WORK/nulllinux-autoinstall.iso"
DISK="$WORK/installed.qcow2"
KEY="$WORK/id_guest"
KS="$WORK/install.ks"
PORT=${NULL_VM_PORT:-2223}
MEM=${NULL_VM_MEM:-4096}

die() { echo "vm-iso-install: $*" >&2; exit 1; }
sshg() { ssh -i "$KEY" -p "$PORT" -o StrictHostKeyChecking=no \
             -o UserKnownHostsFile=/dev/null -o ConnectTimeout=4 root@127.0.0.1 "$@"; }

case "${1:-install}" in
  install|boot|ssh|down) ;;
  *) die "usage: vm-iso-install.sh [install|boot|ssh [cmd]|down]" ;;
esac
[ "${1:-install}" = ssh ] && exec sshg "${@:2}"
# STOPPING THE GUEST, MATCHED ON THE EXECUTABLE, NOT THE COMMAND LINE.
#
# bin/null-column says this in §8.6 and I fell into it anyway, three times in
# one session: `pgrep -f "qemu.*installed.qcow2"` matches ANY process whose
# command line mentions that string -- including the shell running this script,
# which then kills itself. The exe check is exact and cannot match a shell.
# Matched on /proc/PID/exe AND the disk this script owns.
#
# `pgrep -x qemu-system-x86_64` does not work: Linux truncates a process's comm
# to fifteen characters (TASK_COMM_LEN is 16, including the terminator), so the
# name is "qemu-system-x86" and an exact match on the full name never fires.
# That is why stale guests kept holding the forwarded port after a "kill".
#
# The exe symlink is the real identity and is not truncated. The cmdline test
# then narrows it to the guest this script started, so a qemu somebody else is
# running is left alone.
stop_guest() {
  local p exe
  for p in /proc/[0-9]*; do
    exe=$(readlink -f "$p/exe" 2>/dev/null) || continue
    case "$exe" in */qemu-system-x86_64) ;; *) continue ;; esac
    grep -qa "installed.qcow2" "$p/cmdline" 2>/dev/null && kill "${p#/proc/}" 2>/dev/null
  done
}
[ "${1:-install}" = down ] && { stop_guest; echo stopped; exit 0; }

[ -r "$SRC_ISO" ] || die "no ISO -- build one with bin/null-iso"
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -f "$KEY" -C nulllinux-test
mkdir -p "$WORK"

if [ "${1:-install}" = install ]; then
  sed "s|NULLLINUX_TEST_KEY|$(cat "$KEY.pub")|" \
      "$ROOT/packaging/nulllinux-install.ks" > "$KS"
  ksvalidator "$KS" >/dev/null 2>&1 || die "the install kickstart does not validate"

  # mkksiso embeds the kickstart AND sets inst.ks= on the boot entries, so the
  # image boots straight into an unattended install. The shipping ISO is not
  # modified: this writes a second one.
  echo "embedding the kickstart"
  rm -f "$KS_ISO"
  mkksiso --ks "$KS" "$SRC_ISO" "$KS_ISO" >"$WORK/mkksiso.log" 2>&1 \
    || { echo "mkksiso failed:"; tail -12 "$WORK/mkksiso.log"; exit 1; }
  echo "  $(du -h "$KS_ISO" | cut -f1)"

  # A BLANK disk every time. Installing over a previous install tests upgrade,
  # not installation, and hides bugs that only appear on an empty machine --
  # which is the only kind anyone installs onto.
  rm -f "$DISK"
  qemu-img create -q -f qcow2 "$DISK" 20G || die "cannot create the disk"
  echo "  blank disk: 20G"
fi

echo
echo "booting (install console -> $WORK/install-console.log)"
stop_guest
BOOTARGS=(-drive file="$DISK",if=virtio,format=qcow2)
# `once=d` and not `d`: the kickstart ends in `reboot`, and with a permanent
# CD-first order that reboot walks straight back into the live image and
# installs again, forever. `once` means the CD is used for this boot only, so
# the machine comes up on what was just installed -- which is the thing being
# tested.
[ "${1:-install}" = install ] && BOOTARGS+=(-cdrom "$KS_ISO" -boot once=d) || BOOTARGS+=(-boot c)

setsid qemu-system-x86_64 -enable-kvm -m "$MEM" -smp 4 \
  "${BOOTARGS[@]}" \
  -netdev user,id=n0,hostfwd=tcp::"$PORT"-:22 -device virtio-net-pci,netdev=n0 \
  -display none -serial file:"$WORK/install-console.log" \
  -monitor unix:"$WORK/install-monitor",server,nowait \
  >/dev/null 2>&1 &

echo "  qemu started; the install is unattended and reboots when it finishes"
