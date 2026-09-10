#!/usr/bin/env bash
# Install nullLinux into a CLEAN Fedora, in a virtual machine (NULL.md §0.5).
#
# THE POINT IS THAT THIS MACHINE IS NOT A TEST. nox has had every package
# installed on it by hand over days, has a machine profile that was written
# before the generator existed, and has assets baked in a dozen separate runs.
# Everything works here for reasons that have nothing to do with the installer.
#
# So the installer is proved somewhere it has never been: a stock Fedora cloud
# image, booted once, given the tree and one command.
#
# It leaves the host alone. Everything lives under $WORK, the guest talks to
# nothing but the host's ssh port, and the image is a copy-on-write overlay so
# the downloaded base is never written to.
set -uo pipefail
ROOT=${NULL_ROOT:-$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)}
WORK=${NULL_VM_WORK:-/var/lib/nulllinux-test}
BASE="$WORK/fedora44-clean.qcow2"
DISK="$WORK/guest.qcow2"
SEED="$WORK/seed.iso"
KEY="$WORK/id_guest"
PORT=${NULL_VM_PORT:-2222}
MEM=${NULL_VM_MEM:-4096}
CPUS=${NULL_VM_CPUS:-4}

die() { echo "vm-install: $*" >&2; exit 1; }

# STOPPING THE GUEST WITHOUT STOPPING OURSELVES.
#
# This was `pkill -f "qemu.*$DISK"`, and on an evening when $DISK was
# interactive.qcow2 it killed the shell that ran it -- four commands in a row
# came back 144, which is 128 plus SIGTERM. The pattern matched the invoking
# command line, exactly as NULL.md 8.6 says it will.
#
# Anchored on the BINARY instead: a process is qemu because /proc/PID/exe says
# so, and the disk is confirmed from its argument vector. Neither can be true
# of a shell.
stop_guest() {
  local p exe pid
  for p in /proc/[0-9]*; do
    exe=$(readlink -f "$p/exe" 2>/dev/null) || continue
    case $exe in *qemu-system-*) ;; *) continue ;; esac
    grep -qa -- "$DISK" "$p/cmdline" 2>/dev/null || continue
    pid=${p#/proc/}
    kill "$pid" 2>/dev/null || true
  done
}
[ -r "$BASE" ] || die "no base image at $BASE"

case "${1:-run}" in
  up|run) ;;
  ssh)    exec ssh -i "$KEY" -p "$PORT" -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null root@127.0.0.1 "${@:2}" ;;

  down)   stop_guest; echo "guest stopped"; exit 0 ;;
  clean)  stop_guest; rm -f "$DISK" "$SEED"; echo "guest and seed removed"; exit 0 ;;
  *)      die "usage: vm-install.sh [run|ssh [cmd]|down|clean]" ;;
esac

mkdir -p "$WORK"

# A key, not a password: the guest is reached only over the host's loopback,
# and a password would have to be written down somewhere to be used.
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -f "$KEY" -C nulllinux-test

# cloud-init's seed. Built with xorriso rather than cloud-localds, because
# cloud-utils is one more package on the host for something that is two files
# and a filesystem label.
SEEDDIR=$(mktemp -d)
cat > "$SEEDDIR/meta-data" <<META
instance-id: nulllinux-test
local-hostname: nulltest
META
cat > "$SEEDDIR/user-data" <<USER
#cloud-config
users:
  - name: root
    ssh_authorized_keys:
      - $(cat "$KEY.pub")
ssh_pwauth: false
disable_root: false
# Growing the root filesystem matters: the image is 5G and the bake needs room.
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
USER
xorriso -as mkisofs -quiet -output "$SEED" -volid cidata -joliet -rock \
        "$SEEDDIR/user-data" "$SEEDDIR/meta-data" || die "could not build the seed"
rm -rf "$SEEDDIR"

# Copy-on-write, so the downloaded base is never modified and a failed run is
# thrown away by deleting one file.
rm -f "$DISK"
qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$DISK" 20G || die "could not create the overlay"

echo "booting a clean Fedora 44 (${MEM}M, ${CPUS} cpu, ssh on :$PORT)"
stop_guest
setsid qemu-system-x86_64 \
  -enable-kvm -m "$MEM" -smp "$CPUS" \
  -drive file="$DISK",if=virtio,format=qcow2 \
  -drive file="$SEED",if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$PORT"-:22 -device virtio-net-pci,netdev=n0 \
  -display none -serial file:"$WORK/console.log" \
  >/dev/null 2>&1 &

printf 'waiting for ssh'
for i in $(seq 1 90); do
  if ssh -i "$KEY" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
         -o ConnectTimeout=2 -o BatchMode=yes root@127.0.0.1 true 2>/dev/null; then
    echo " up after ${i}s"; exit 0
  fi
  printf '.'; sleep 2
done
echo
die "the guest never answered ssh -- see $WORK/console.log"
