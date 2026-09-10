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
  install|boot|ssh|down|check|wait) ;;
  *) die "usage: vm-iso-install.sh [install|boot|ssh [cmd]|down|check|wait [pid]]" ;;
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

# `wait` IS THE VERB THAT MAKES "DONE" MEAN DONE.
#
# `install` returned as soon as qemu was running, and the build chain printed
# "=== done" -- which read, to me and to anything watching the log, as "the
# machine is installed". It meant "a process was launched". Twice I started a
# second chain on the strength of that word; the second one's install stage
# stopped the first one's guest, in one line of log, and an hour of install
# went in the bin with a 192K disk left behind to show for it.
#
# The console log is not a completion signal either: anaconda's last words look
# much the same whether it finished or hit a traceback.
#
# So ask the machine. And distinguish the two systems that answer on this port:
# `inst.sshd` means the INSTALLER has sshd too, so "ssh connects" is true
# minutes before the install is done. The installed system is the one with no
# /run/install/repo and the nulllinux package on it.
# THE PIDS OF THE GUEST THIS SCRIPT OWNS, by /proc/PID/exe -- which is the real
# identity and is not truncated -- narrowed by cmdline to this script's disk.
# Shared with null_vm_wait so both agree on what "our guest" means.
guest_pids() {
  local p exe
  for p in /proc/[0-9]*; do
    exe=$(readlink -f "$p/exe" 2>/dev/null) || continue
    case "$exe" in */qemu-system-x86_64) ;; *) continue ;; esac
    grep -qa -- "$DISK" "$p/cmdline" 2>/dev/null || continue
    echo "${p#/proc/}"
  done
}

# null_vm_wait [qemu pid]
#
# THE LIVENESS TEST CANNOT BE `pgrep -x qemu-system-x86_64`.
#
# Linux truncates a process's comm to 15 characters (TASK_COMM_LEN). That name
# is 18, so -x compares against "qemu-system-x86" and never matches -- pgrep
# even warns about it on stderr, which is the only reason this was caught:
#
#   pgrep: pattern that searches for process name longer than 15 characters
#          will result in zero matches
#
# `! pgrep ...` would therefore have been true on the first pass of every wait,
# aborting each install with a confident "qemu is gone and nothing is
# installed" while the install ran on perfectly well behind it. A check that is
# always true is not a check; it is the thing this function was written to stop.
#
# So: the pid we launched, when we have it, and otherwise guest_pids() -- which
# reads /proc/PID/exe, the real identity, and is not truncated. stop_guest()
# below already worked this out and says so eighty lines further down. I wrote
# the broken form anyway, above the comment explaining why it is broken.
# null_vm_wait [qemu pid] [mode]
#
# TWO DIFFERENT ENDINGS, AND THEY LOOK THE SAME FROM HERE.
#
#   mode=install  the kickstart finishes with `poweroff`, so the guest STOPS.
#                 qemu exiting is SUCCESS.
#   mode=ssh      the disk has been booted on its own; the machine coming up
#                 and answering is success, and qemu exiting is failure.
#
# This function had one mode and it was the wrong one. It waited for ssh after
# an install and reported, on a completed install that had written 8.5 GB:
#
#   vm-iso-install: qemu is gone and nothing is installed.
#
# It believed a comment eighty lines below -- "the kickstart ends in `reboot`" --
# which packaging/nulllinux-install.ks has not said for some time. Line 118 is
# `poweroff`, and that is the RIGHT ending for a real install: a machine that
# reboots with the stick still in it walks back into the installer. So the
# kickstart was right, the comment was stale, and the check believed the prose.
null_vm_wait() {
  local qpid_watch=${1:-} mode=${2:-ssh}
  local limit=${NULL_VM_WAIT_MINS:-60} waited=0 lastsize=0 stalled=0
  if [ "$mode" = install ]; then
    echo "  waiting for the install to finish and power the guest off (up to ${limit}m)"
  else
    echo "  waiting for the installed machine to answer on :$PORT (up to ${limit}m)"
  fi
  while [ "$waited" -lt $((limit * 60)) ]; do
    local alive=1
    if [ -n "$qpid_watch" ]; then
      kill -0 "$qpid_watch" 2>/dev/null || alive=0
    else
      [ -n "$(guest_pids)" ] || alive=0
    fi
    if [ "$alive" = 0 ]; then
      # THE GUEST STOPPING IS THE SUCCESS SIGNAL OF AN INSTALL, and evidence is
      # required for it rather than taken on trust: a clean power-down in the
      # console AND a disk with a system on it. A guest that died in the first
      # minute leaves neither.
      if [ "$mode" = install ]; then
        local dsz; dsz=$(stat -c %s "$DISK" 2>/dev/null || echo 0)
        if grep -qa -e 'reboot: Power down' -e 'poweroff.target' "$WORK/install-console.log" 2>/dev/null \
           && [ "$dsz" -gt 1000000000 ]; then
          echo "  the install finished and powered the guest off ($((dsz / 1024 / 1024)) MB written)"
          return 0
        fi
        echo >&2
        echo "vm-iso-install: the guest stopped without finishing the install." >&2
        echo "  disk is $((dsz / 1024 / 1024)) MB and the console has no clean power-down." >&2
      else
        echo >&2
        echo "vm-iso-install: qemu is gone and the installed system never answered." >&2
      fi
      echo "  last of $WORK/install-console.log:" >&2
      tail -25 "$WORK/install-console.log" 2>/dev/null | tr -d '\r' | sed 's/^/    /' >&2
      return 1
    fi
    # Through bin/pkg, not `rpm -q`: §9.1 forbids naming a package manager
    # outside the abstraction, and check-package-abstraction caught this line
    # the first time it was written. It is also the better test -- it proves
    # the installed machine's own pkg works, on the installed machine.
    if [ "$mode" != install ] && sshg -o ConnectTimeout=5 \
         'test ! -d /run/install/repo && /opt/nulllinux/bin/pkg is-installed nulllinux' >/dev/null 2>&1; then
      echo "  the installed system is up and has the nulllinux package"
      return 0
    fi
    # WEDGED IS NOT "THE CONSOLE WENT QUIET".
    #
    # The first version of this watched only install-console.log, and failed a
    # perfectly healthy install fifteen minutes in. anaconda stops writing to
    # the serial console once it leaves early boot -- the package phase, which
    # is the longest part by far, goes to its own UI. So the quietest stretch
    # of a working install looked exactly like a hang, and the check aborted
    # the thing it was written to protect. Measured at the time it fired:
    #
    #   console  87742 bytes, untouched for 18 minutes
    #   qemu     83 seconds of CPU in 30 seconds of wall clock (4 vCPUs)
    #   disk     11 MB written in those same 30 seconds, 9.6 GB in total
    #
    # A guest doing that is not wedged. So progress is ANY of three signals
    # moving, and only all three going flat for fifteen minutes is a hang.
    local size cpu dsize now
    size=$(stat -c %s "$WORK/install-console.log" 2>/dev/null || echo 0)
    dsize=$(stat -c %s "$DISK" 2>/dev/null || echo 0)
    cpu=0
    if [ -n "$qpid_watch" ] && [ -r "/proc/$qpid_watch/stat" ]; then
      cpu=$(awk '{print $14+$15}' "/proc/$qpid_watch/stat" 2>/dev/null || echo 0)
    fi
    now="$size:$dsize:$cpu"
    if [ "$now" = "$lastsize" ]; then stalled=$((stalled + 15)); else stalled=0; fi
    lastsize=$now
    if [ "$stalled" -ge 900 ]; then
      echo >&2
      echo "vm-iso-install: no console output, no disk growth and no CPU for 15 minutes -- wedged." >&2
      tail -25 "$WORK/install-console.log" 2>/dev/null | tr -d '\r' | sed 's/^/    /' >&2
      return 1
    fi
    sleep 15; waited=$((waited + 15))
    case $waited in 300|900|1800|2700) echo "    still installing ($((waited / 60))m)" ;; esac
  done
  echo "vm-iso-install: gave up after ${limit}m" >&2
  return 1
}
# `wait [pid]` -- the pid is optional, and re-attaching to an install already
# in flight is exactly when it is wanted: with it, CPU time joins the progress
# signals instead of the check running on disk and console alone.
[ "${1:-install}" = wait ] && { null_vm_wait "${2:-}" "${3:-ssh}"; exit $?; }

# AND ONE CHAIN AT A TIME.
#
# Nothing stopped a second build chain from starting while the first was mid
# install; the newcomer stopped the incumbent's guest and both reported done.
# A lock, taken for the whole install, so the second one says so and stops.
# ANY BACKGROUND PROCESS LAUNCHED WHILE THIS IS HELD MUST CLOSE fd 9 (9>&-):
# fd 9 is not close-on-exec, so a child that outlives this script -- the
# kickstart HTTP server did -- keeps the lock held for ever. Learned the hard
# way; bash does not set cloexec on {var}-allocated fds either, so there is no
# tidier version of this.
if [ "${1:-install}" = install ] || [ "${1:-install}" = boot ]; then
  mkdir -p "$WORK" || die "cannot create the work directory $WORK"
  exec 9>"$WORK/.install.lock" || die "cannot open the install lock"
  if ! flock -n 9; then
    die "another install is already running (lock: $WORK/.install.lock).
  verify/vm-iso-install.sh down   stops it, if you mean to replace it."
  fi
fi
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
  local p exe pids=""
  for p in /proc/[0-9]*; do
    exe=$(readlink -f "$p/exe" 2>/dev/null) || continue
    case "$exe" in */qemu-system-x86_64) ;; *) continue ;; esac
    # THE WHOLE PATH, NOT A SUBSTRING OF IT. "installed.qcow2" is also a
    # substring of "uefi-installed.qcow2", so this stopped the UEFI test guest
    # every time somebody booted this one -- a pattern matching more than it
    # meant, which is the same mistake as `pkill -f` in a different costume.
    grep -qa -- "$DISK" "$p/cmdline" 2>/dev/null || continue
    pids="$pids ${p#/proc/}"
    kill "${p#/proc/}" 2>/dev/null
  done
  [ -n "$pids" ] || return 0

  # AND WAIT FOR IT TO ACTUALLY GO.
  #
  # kill only asks. The next qemu was started immediately after, while the old
  # one still held the ssh forward, and died with
  #
  #   Could not set up host forwarding rule 'tcp::2223-:22'
  #
  # A port is released when the process exits, not when it is signalled.
  local i
  for i in $(seq 1 40); do
    local alive=0 q
    for q in $pids; do [ -d "/proc/$q" ] && alive=1; done
    [ "$alive" = 0 ] && { echo "  stopped the previous guest"; return 0; }
    sleep 0.25
  done
  echo "  the previous guest did not exit; killing it" >&2
  for q in $pids; do kill -9 "$q" 2>/dev/null; done
  sleep 1
}
[ "${1:-install}" = down ] && { stop_guest; echo stopped; exit 0; }

[ -r "$SRC_ISO" ] || die "no ISO -- build one with bin/null-iso"
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -f "$KEY" -C nulllinux-test \
  || die "cannot create the guest key"
[ -s "$KEY.pub" ] || die "the guest public key is missing"

if [ "${1:-install}" = install ]; then
  # Serve a dedicated public tree. $WORK also contains the private SSH key,
  # disks and logs, none of which belongs in the HTTP server's document root.
  PUBLIC=$(mktemp -d "$WORK/public.XXXXXX") || die "cannot create the public staging directory"
  HTTPPID=""
  cleanup_http() {
    if [ -n "$HTTPPID" ]; then
      kill "$HTTPPID" 2>/dev/null || true
      wait "$HTTPPID" 2>/dev/null || true
    fi
    rm -rf -- "$PUBLIC"
  }
  trap cleanup_http EXIT
  mkdir -p "$PUBLIC/repo" || die "cannot stage the public repository"
  cp -a "$ROOT/packaging/repo/." "$PUBLIC/repo/" || die "cannot copy the repository"
  if find "$PUBLIC" -type l -print -quit | grep -q .; then
    die "the public repository contains a symlink outside the staged files"
  fi
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
      "$ROOT/packaging/nulllinux-install.ks" > "$KS" || die "cannot write the install kickstart"

  # NOTHING RUNS WITH A PLACEHOLDER IN IT. The ISO builder already refuses; the
  # harness did not, so it booted a VM for twenty minutes against a URL with
  # NULLLINUX_BASEURL embedded in it before anything complained.
  if grep -q NULLLINUX_ "$KS"; then
    echo "the kickstart still contains a placeholder:" >&2
    grep -n NULLLINUX_ "$KS" | cut -c1-120 >&2
    die "refusing to boot with an unsubstituted kickstart"
  fi
  ksvalidator "$KS" >/dev/null 2>&1 || die "the install kickstart does not validate"
  cp "$KS" "$PUBLIC/install.ks" || die "cannot stage the install kickstart"
  cp "$KEY.pub" "$PUBLIC/testkey.pub" || die "cannot stage the guest public key"

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

  # QEMU user networking reaches the host loopback through 10.0.2.2.
  # Limit the server to loopback and the dedicated public staging directory.
  # 9>&- CLOSES THE LOCK FD. Without it this server -- which outlives the install
  # script -- inherits fd 9 and holds the install flock for ever, refusing every
  # later boot/install with "another install is already running". That happened.
  ( exec python3 -m http.server 8899 --bind 127.0.0.1 --directory "$PUBLIC" ) >"$WORK/http.log" 2>&1 9>&- &
  HTTPPID=$!
  # AND IT DIES WITH THE INSTALL. It serves the kickstart and the repo for the
  # duration of anaconda's run, then it is done -- but nothing killed it, so it
  # (and port 8899) leaked after every install. That is the same server whose
  # inherited fd held the flock; closing the fd stopped the lock leak, this stops
  # the process leak. A trap, so it goes on success, error and interrupt alike.
  sleep 0.2
  kill -0 "$HTTPPID" 2>/dev/null || die "the test HTTP server did not start (see $WORK/http.log)"
  # The debugging key, served the same way. The live image only fetches it
  # because the command line below names it; a shipped ISO has no key at all.
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
# `once=d` and not `d`: the kickstart ends in `poweroff` now, but `once` is kept
# because it is the property that matters -- a medium that stays first in the
# boot order sends any later reboot back into the installer. Was `reboot`, and
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

  # THE PANEL IS A PARAMETER, because "any panel" is the promise and every guest
  # this harness has ever booted was qemu's default 1280x800.
  #
  #   NULL_VM_XRES=1366 NULL_VM_YRES=768 verify/vm-iso-install.sh install
  #
  # 1366x768 is nox, the machine this is going onto: a width that is not a
  # multiple of four, which is exactly the kind of panel a grid derived from
  # cell sizes can be wrong about. Nothing here had ever booted at one.
  #
  # A CAUTION FOR ANYONE READING A SCREENSHOT OF ONE. qemu's own `screendump`
  # misreads a framebuffer whose width is not 4-aligned: at 1366 it returns an
  # image sheared diagonally with the colour channels separated, which looks
  # exactly like a serious rendering fault and is not. Take the picture from
  # INSIDE the compositor instead --
  #
  #   verify/vm-iso-install.sh ssh 'sudo -u null XDG_RUNTIME_DIR=/run/user/1000 \
  #     WAYLAND_DISPLAY=wayland-1 grim /tmp/shot.png'
  #
  # -- which showed the same desktop drawn perfectly.
  DISPLAYARGS=()
  if [ -n "${NULL_VM_XRES:-}" ] && [ -n "${NULL_VM_YRES:-}" ]; then
    DISPLAYARGS=(-vga none -device "virtio-vga,xres=$NULL_VM_XRES,yres=$NULL_VM_YRES,id=vga0")
    echo "  panel: ${NULL_VM_XRES}x${NULL_VM_YRES}"
  fi
setsid qemu-system-x86_64 -enable-kvm -cpu host -m "$MEM" -smp 4 \
  "${BOOTARGS[@]}" \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$PORT"-:22 -device virtio-net-pci,netdev=n0 \
  -audiodev none,id=snd0 -device ich9-intel-hda -device hda-output,audiodev=snd0 \
  "${DISPLAYARGS[@]}" \
  -display none -serial file:"$WORK/install-console.log" \
  -monitor unix:"$WORK/install-monitor",server,nowait \
  9>&- >"$WORK/qemu.log" 2>&1 &
qpid=$!

# "qemu started" WAS A CLAIM, NOT A CHECK.
#
# qemu's own stderr went to /dev/null and nothing looked at whether it was
# still running, so an install that died on its command line -- a port already
# bound, a missing file, an unsupported device -- printed "qemu started; the
# install is unattended" and left a blank disk behind. That happened: a run
# reported success, and half an hour later there was no VM, an empty console
# log, and no record anywhere of why it had gone.
sleep 3
if ! kill -0 "$qpid" 2>/dev/null; then
  echo >&2
  echo "vm-iso-install: qemu exited immediately -- $WORK/qemu.log:" >&2
  sed 's/^/  /' "$WORK/qemu.log" >&2
  exit 1
fi
if [ "${1:-install}" = install ]; then
  echo "  qemu started (pid $qpid); the install is unattended and powers the guest off when it finishes"
else
  echo "  qemu started (pid $qpid); booting the installed disk"
fi
if [ "${1:-install}" = install ]; then
  echo
  null_vm_wait "$qpid" install || exit 1
  echo
  echo "  the disk is installed. Boot it with:  verify/vm-iso-install.sh boot"
  echo
  echo "  now:  verify/vm-iso-install.sh check"
fi
