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
# THE NEWEST ISO, not whichever one find happens to name first.
#
# `find ... | head -1` returns directory order, which is arbitrary. With two
# images present it picked the older one twice in a row, so two full install
# attempts tested a stale build and I read the result as a bug in the image
# rather than in the harness.
# THE INSTALLER ISO BY DEFAULT, not the live one.
#
# The live image cannot be driven by a kickstart on Fedora 44 -- liveinst wants
# a browser and a display, and with --text anaconda parses its own
# interactive-defaults.ks rather than the file it was handed. The installer ISO
# boots anaconda directly, which is what inst.ks is designed for.
SRC_ISO=${NULL_ISO:-$(ls -t /var/lib/nulllinux-iso/nulllinux-installer-*.iso 2>/dev/null | head -1)}
[ -n "$SRC_ISO" ] || SRC_ISO=$(find /var/lib/nulllinux-iso -name '*.iso' -printf '%T@ %p\n' 2>/dev/null \
                               | sort -rn | head -1 | cut -d' ' -f2-)
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
  install|boot|ssh|down|check) ;;
  *) die "usage: vm-iso-install.sh [install|boot|ssh [cmd]|down|check]" ;;
esac
# NOT `exec sshg` -- sshg is a shell function, and exec cannot exec a function.
# It failed with "exec: sshg: not found" every time the verb was used, which is
# to say the ssh verb had never once worked.
[ "${1:-install}" = ssh ] && { sshg "${@:2}"; exit $?; }
# `check` is the other half of `install`. This script used to end at "the
# install is unattended and reboots when it finishes", and what happened after
# that was inspected by hand, differently each time -- which is how an
# initramfs that could not boot on other hardware survived every install test
# the project ever ran. Nobody asked it.
[ "${1:-install}" = check ] && exec "$ROOT/verify/vm-post-install.sh"
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
  # THE REPOSITORY MUST BE REACHABLE BY THE GUEST, which means a URL on the
  # host's side of qemu's network and not a path on this filesystem. The whole
  # tree is served from $WORK, so the repo is linked into it.
  ln -sfn "$ROOT/packaging/repo" "$WORK/repo"
  # Concrete URLs, checked before they are used. anaconda does not expand
  # $releasever in a kickstart url line, and the failure it produces --
  # "Error setting up repositories" -- names none of that.
  REL=$("$ROOT/bin/pkg" distro-version 2>/dev/null || echo 44)
  # A SPECIFIC MIRROR, not the redirector.
  #
  # download.fedoraproject.org hands out a random mirror per request, and a bad
  # draw is not a slow install -- it is a FAILED one: anaconda gave up with
  # "Failed to download" on a dozen base packages, all reporting "Interrupted",
  # and the same thing had already killed a multi-hour lorax run. Measured from
  # here, the redirector sustained 185 kB/s and ftp.nluug.nl 832 kB/s on the
  # same 15 MB file. NULL_MIRROR overrides it for a machine somewhere else.
  # METALINKS, so dnf can fail over. Pinning one mirror traded a slow install
  # for a failed one -- see the kickstart's own note.
  BASEURL="https://mirrors.fedoraproject.org/metalink?repo=fedora-$REL&arch=x86_64"
  UPDATES="https://mirrors.fedoraproject.org/metalink?repo=updates-released-f$REL&arch=x86_64"
  for u in "$BASEURL" "$UPDATES"; do
    n=$(curl -sL -m 30 "$u" 2>/dev/null | grep -c "<url")
    [ "${n:-0}" -gt 0 ] || die "metalink $u offered no mirrors"
    echo "  $(echo "$u" | grep -oE 'repo=[^&]*'): $n mirrors"
  done


  # WHICH COPY OF THE PACKAGE THE INSTALL USES.
  #
  # By default the harness serves packaging/repo over HTTP, which exercises the
  # network path. NULL_TEST_EMBEDDED=1 points the kickstart at the copy ON THE
  # ISO instead -- the one a stranger's machine uses, with no repository of ours
  # to reach. That is the path worth proving, because it is the one that cannot
  # be tested by accident: everything works on a build host either way.
  if [ "${NULL_TEST_EMBEDDED:-0}" = 1 ]; then
    NULLREPO="file:///run/install/repo/nulllinux"
    echo "  package source: the copy embedded ON the ISO"
  else
    NULLREPO="http://10.0.2.2:8899/repo"
    echo "  package source: served over HTTP from this host"
  fi

  # & IS NOT A LITERAL IN A SED REPLACEMENT -- it means "everything that
  # matched". A metalink URL contains one, so `repo=fedora-44&arch=x86_64`
  # became `repo=fedora-44NULLLINUX_BASEURLarch=x86_64` and anaconda reported
  # only "Failed to download metadata", naming neither the ampersand nor the
  # placeholder it had just pasted into the middle of the URL.
  esc() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }
  sed -e "s|NULLLINUX_TEST_KEY|$(esc "$(cat "$KEY.pub")")|" \
      -e "s|NULLLINUX_REPO|$(esc "$NULLREPO")|" \
      -e "s|NULLLINUX_BASEURL|$(esc "$BASEURL")|" \
      -e "s|NULLLINUX_UPDATES|$(esc "$UPDATES")|" \
      "$ROOT/packaging/nulllinux-install.ks" > "$KS"

  # NOTHING RUNS WITH A PLACEHOLDER IN IT. The ISO builder already refuses; the
  # harness did not, so it booted a VM for twenty minutes against a URL with
  # NULLLINUX_BASEURL embedded in it before anything complained.
  if grep -q NULLLINUX_ "$KS"; then
    echo "the kickstart still contains a placeholder:" >&2
    grep -n NULLLINUX_ "$KS" | cut -c1-120 >&2
    die "refusing to boot with an unsubstituted kickstart"
  fi
  ksvalidator "$KS" >/dev/null 2>&1 || die "the install kickstart does not validate"

  # THE KERNEL COMMAND LINE, NOT A REBUILT IMAGE.
  #
  # mkksiso rewrites the ISO to carry the kickstart and set inst.ks= on its
  # boot entries. Its output does not boot: same qemu, same moment, the ISO as
  # built reaches the desktop at 80,733 non-black pixels and mkksiso's copy
  # shows zero, for ever. mkksiso is made for Anaconda installer media and this
  # is a live image, which is a different boot path.
  #
  # So the ISO is left ALONE and its own kernel is booted directly with a
  # command line of our choosing. Two things fall out of that and both are
  # improvements: the image under test is byte-identical to the one that would
  # go on a stick, and the kickstart never has to be on the medium at all -- it
  # is fetched over the network qemu already provides, where the host is
  # 10.0.2.2.
  echo "extracting the ISO's own kernel and initrd"
  isomnt=$(mktemp -d)
  mount -o loop,ro "$SRC_ISO" "$isomnt" 2>/dev/null || die "cannot mount $SRC_ISO"
  mkdir -p "$WORK/boot"
  cp "$isomnt/images/pxeboot/vmlinuz"    "$WORK/boot/" 2>/dev/null || { umount "$isomnt"; die "no vmlinuz on the ISO"; }
  cp "$isomnt/images/pxeboot/initrd.img" "$WORK/boot/" 2>/dev/null || { umount "$isomnt"; die "no initrd on the ISO"; }
  umount "$isomnt"; rmdir "$isomnt"
  LABEL=$(blkid -o value -s LABEL "$SRC_ISO" 2>/dev/null)
  [ -n "$LABEL" ] || die "the ISO has no volume label for root=live:CDLABEL to name"
  echo "  label: $LABEL"

  # The kickstart is SERVED, not embedded. 0.0.0.0 rather than 127.0.0.1: the
  # guest reaches the host as 10.0.2.2, and a server bound to loopback is a
  # server the guest cannot see.
  ( cd "$WORK" && exec python3 -m http.server 8899 --bind 0.0.0.0 ) >/dev/null 2>&1 &
  HTTPPID=$!
  # The debugging key, served the same way. The live image only fetches it
  # because the command line below names it; a shipped ISO has no key at all.
  cp "$KEY.pub" "$WORK/testkey.pub"
  echo "  kickstart at http://10.0.2.2:8899/install.ks"
  echo "  debug key at http://10.0.2.2:8899/testkey.pub"

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
if [ "${1:-install}" = install ]; then
  # The ISO is still attached -- root=live:CDLABEL finds the squashfs on it --
  # but the kernel and its command line come from outside it, so the medium is
  # untouched. console=ttyS0 so the install is readable without a screenshot.
  BOOTARGS+=(-cdrom "$SRC_ISO"
             -kernel "$WORK/boot/vmlinuz" -initrd "$WORK/boot/initrd.img"
             -append "inst.ks=http://10.0.2.2:8899/install.ks inst.text inst.notmux inst.sshd inst.stage2=hd:LABEL=$LABEL console=ttyS0,115200 console=tty0")
else
  BOOTARGS+=(-boot c)
fi

# The server stays up for the guest to fetch from.
  # A SOUND CARD, so audio is testable at all.
  #
  # Without one /dev/snd holds only seq and timer, PipeWire has nothing to
  # attach to, and every audio surface reports a failure that is really the
  # harness having no hardware. That is why "audio has never worked" was in the
  # status notes for weeks: it had never been given anything to work with.
  #
  # hda-OUTPUT, not hda-duplex: with a null audiodev the duplex device hangs the
  # guest at switch-root -- ten minutes, no ssh, no further console output --
  # and playback alone is enough, because cava reads the monitor of a sink.
  #
  # -cpu host, NOT qemu's default.
  #
  # The default model is "QEMU Virtual CPU version 2.5+", which has no SSE4.2
  # and is therefore below x86-64-v2 -- the baseline Fedora builds numpy for.
  # numpy would not import, so the machine could not derive its own hero, and
  # the failure looked like a defect in this project rather than in the harness.
  # Any machine this decade is v2 or better; the VM should not be the exception.
setsid qemu-system-x86_64 -enable-kvm -cpu host -m "$MEM" -smp 4 \
  "${BOOTARGS[@]}" \
  -netdev user,id=n0,hostfwd=tcp::"$PORT"-:22 -device virtio-net-pci,netdev=n0 \
  -audiodev none,id=snd0 -device ich9-intel-hda -device hda-output,audiodev=snd0 \
  -display none -serial file:"$WORK/install-console.log" \
  -monitor unix:"$WORK/install-monitor",server,nowait \
  >/dev/null 2>&1 &

echo "  qemu started; the install is unattended and reboots when it finishes"
if [ "${1:-install}" = install ]; then
  echo
  echo "  when it comes up:  verify/vm-iso-install.sh check"
fi
