# Unattended install FROM the live image TO a disk (NULL.md §0.5).
#
# This is the other half of the ISO. nulllinux-live.ks builds an image that
# boots; this one is handed to Anaconda ON that image to put the system on a
# disk and make it boot on its own.
#
# It exists so the installer can be exercised without a spare machine. Every
# step here -- partitioning, the bootloader, the package transaction, first
# boot -- is the same code that runs on real hardware. What a virtual disk
# cannot test is hardware: real firmware, secure boot, a GPU driver, a wifi
# chipset. Those need metal and are not pretended at here.

text

# THE INSTALL SOURCE. A live image installs by copying its own filesystem; an
# Anaconda boot.iso installs by running a package transaction, so it has to be
# told where the packages are. This is the difference that made the live path
# the wrong road: `inst.ks` is designed for THIS kind of medium.
#
# NULLLINUX_REPO is substituted by whoever prepares this kickstart:
#   bin/null-installer-iso  -> file:///run/install/repo/nulllinux, the copy of
#                              the package that travels ON the ISO, so the
#                              desktop and its raytraced hero need no network
#   verify/vm-iso-install.sh -> an http:// URL the guest can reach, so the test
#                              exercises the network path too
# A METALINK, NOT ONE MIRROR, AND NO $releasever OR $basearch HERE.
#
# A single baseurl is a single mirror, so one interrupted transfer ends the
# install: anaconda reported "Failed to download 'kernel-modules-...': No more
# mirrors to try" for a file that was present and answering 200 the moment
# afterwards. The metalink offers over a hundred mirrors and dnf fails over
# between them, which is what makes an install survive a bad connection.
#
# The release number is still written concretely, for the reason below.
#
# Those are dnf's variables and anaconda does not reliably expand them in a
# kickstart `url` line -- the installer reported "Error setting up
# repositories" and set up none of them, which then took Software selection
# down with it. Both URLs are substituted with concrete ones by
# verify/vm-iso-install.sh, which checks they answer 200 before using them.
url --metalink=NULLLINUX_BASEURL
repo --name=updates --metalink=NULLLINUX_UPDATES
repo --name=nulllinux --baseurl=NULLLINUX_REPO

lang en_GB.UTF-8
keyboard --vckeymap=gb --xlayouts='gb'
timezone Europe/London --utc
selinux --enforcing
# THE MACHINE IS FIREWALLED, BY nftables RATHER THAN BY firewalld.
#
# anaconda is told not to configure firewalld, because %post installs the same
# policy as a static nftables ruleset -- default drop, established/related,
# loopback, ICMP, dhcpv6-client, mdns, ssh -- which is what firewalld's public
# zone produced here anyway, and 164ms instead of 3.024s of every boot.
#
# firewalld stays INSTALLED so `systemctl enable --now firewalld` is a one-line
# revert, and %post puts it back if the nftables install does not take.
firewall --disabled
network --bootproto=dhcp --device=link --activate --hostname=nulltest

# THE INSTALL TARGET IS NAMED EXPLICITLY. `clearpart --all` with no --drives
# will take every disk it can see, and on a machine with more than one that is
# how an installer eats something it was not pointed at.
ignoredisk --only-use=vda
zerombr
clearpart --all --initlabel --drives=vda
autopart --type=plain --noswap

# TWO THINGS ABOUT THE BOOTLOADER.
#
# anaconda copies the INSTALLER's console= arguments into the installed
# system's boot entries. The harness boots the installer with
# console=ttyS0,115200 so it can capture the install log, and the installed
# system inherits a serial console it has no reason to have. --append does NOT
# replace them -- it adds to them -- so they are removed in %post, where it can
# be verified rather than assumed.
#
# FIVE SECONDS OF EVERY BOOT WERE SPENT IN A MENU NOBODY ASKED FOR.
#
# Fedora's default is GRUB_TIMEOUT=5 with no timeout style, so the menu is
# displayed and counted down on every single boot. It is invisible to every
# measurement this project has made: systemd-analyze starts at the kernel, and
# this happens before it. Measured properly -- power-on to ssh answering --
# 48.2s became 41.6s by changing this one number.
#
# --timeout=1, with GRUB_TIMEOUT_STYLE=hidden added in %post. Holding Esc or
# Shift during that second still brings the menu up, which matters here more
# than usual: this system has ONE ordinary kernel, so the rescue entry is the
# only fallback (NULL.md 9.6). The menu is not gone, it is quiet.
# NO --location: it is BIOS-only, and on an EFI machine anaconda stops reading
# the file here. `rootpw` and `user` are BELOW this line, so a UEFI install made
# a machine with no user account and no root password -- one nobody can log into
# at all. anaconda chooses the MBR on a BIOS machine and the ESP on an EFI one
# without being told.
bootloader --boot-drive=vda --timeout=1

# A shell in the INSTALLER ENVIRONMENT, which is a different machine from the
# one being installed. With inst.sshd on the command line this is the only way
# to read /tmp/anaconda.log while it is still running -- and reading the log
# rather than guessing is what turned the last three failures into answers.
sshpw --username=root nulltest --plaintext

rootpw --plaintext nulltest
user --name=null --groups=wheel --password=nulltest --plaintext

services --enabled=NetworkManager,sshd,power-profiles-daemon
# POWEROFF, NOT REBOOT.
#
# The install is driven by booting the installer's kernel directly, and qemu
# ignores the boot order when it is given -kernel -- so a reboot walks straight
# back into the installer and starts again. That is not hypothetical: a
# completed install was destroyed that way, the second run wiping the disk it
# had just filled and getting to 45% of the download before it was stopped,
# leaving a system with no bootloader.
#
# Powering off ends the guest cleanly, so the harness knows the install is done
# and can boot the disk on its own terms.
poweroff

%packages
@core
kernel
# One line for the whole desktop: its Requires pull in sway, foot, fzf, thunar
# and the rest, and the package carries the raytraced hero prebuilt.
nulllinux
%end

%post
# The machine-sync unit does the machine half -- profile, strike, hero -- on the
# first boot that has a display. Enabled here because the package's %post ran
# inside the installer's chroot, where enabling can be lost.
systemctl enable nulllinux-machine-sync.service 2>/dev/null || true

# THE FIRST BOOT HAS TO REACH THE DESKTOP, not the one after it.
#
# null-install enables sddm and sets graphical.target, but it runs from
# nulllinux-machine-sync at multi-user -- by which point boot has already gone
# past where a display manager would have started. So the first boot after an
# install came up on a text console and only the SECOND showed the desktop,
# which is not a thing anyone would forgive an installer for.
#
# Neither enabling a unit nor setting the default target needs a display, so
# both belong here, in the installed system, before it has ever booted.
systemctl enable sddm.service 2>/dev/null || true
systemctl set-default graphical.target 2>/dev/null || true

# THE INSTALLER'S SERIAL CONSOLE IS NOT THE INSTALLED SYSTEM'S.
#
# anaconda copies its own console= arguments into the boot entries it writes.
# `bootloader --append` adds to them rather than replacing them, so they are
# taken out here and the result is checked.
#
# WHY IT MATTERS, STATED HONESTLY: one install hung at initrd-switch-root --
# no output, no ssh, zero disk I/O over twenty seconds of qemu blockstats --
# and removing exactly these two arguments from that disk, changing nothing
# else, took it from hung to a login screen in 32 seconds. A later identical
# install then booted fine WITH them. So this is a race that a serial console
# makes reachable, not a deterministic failure, and removing the console the
# installed system never asked for is worth doing on its own terms.
if command -v grubby >/dev/null 2>&1; then
  grubby --update-kernel=ALL --remove-args="console=ttyS0,115200 console=tty0" 2>/dev/null || true
  if grubby --info=DEFAULT 2>/dev/null | grep -q "console=ttyS0"; then
    echo "nullLinux: WARNING -- could not remove the installer's serial console" >&2
  fi
fi

# THE MENU IS QUIET, NOT GONE.
#
# `bootloader --timeout=1` above sets GRUB_TIMEOUT. The STYLE has no kickstart
# directive, so it is set here: hidden means GRUB waits the timeout for a key
# instead of drawing the menu and counting down at it.
#
# Holding Esc or Shift during that second still shows the menu, and that is
# the documented way to reach the rescue entry -- which on this system is the
# only fallback there is.
if [ -w /etc/default/grub ]; then
  grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub \
    && sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub \
    || echo 'GRUB_TIMEOUT_STYLE=hidden' >> /etc/default/grub
  if command -v grub2-mkconfig >/dev/null 2>&1; then
    for cfg in /boot/grub2/grub.cfg /boot/efi/EFI/fedora/grub.cfg; do
      [ -f "$cfg" ] && grub2-mkconfig -o "$cfg" >/dev/null 2>&1
    done
  fi
  # AND CHECK IT, because a menu that still counts to five is the whole point.
  t=$(sed -n 's/^GRUB_TIMEOUT=//p' /etc/default/grub | tail -1)
  s=$(sed -n 's/^GRUB_TIMEOUT_STYLE=//p' /etc/default/grub | tail -1)
  echo "nullLinux: GRUB timeout ${t:-unset}, style ${s:-unset}"
  case "${t:-5}" in 0|1|2) ;; *) echo "nullLinux: WARNING -- GRUB still waits ${t}s at every boot" >&2 ;; esac
fi

# THE FIREWALL, AS RULES RATHER THAN AS A DAEMON THAT GENERATES THEM.
#
# firewalld sat on the ordering chain to the greeter and spent 3.024s of every
# boot emitting the same 366 lines of nftables. `null-system firewall` installs
# those rules statically -- same policy, 164ms -- and moves the netfilter module
# loading to sysinit, where nothing is waiting for it.
#
# It parses the ruleset before installing it and inspects the loaded result
# afterwards, so a %post that succeeds means a machine with a firewall rather
# than a machine with a config file. If it does not succeed, firewalld goes
# back on: this system is never left with neither.
if [ -x /opt/nulllinux/bin/null-system ]; then
  /opt/nulllinux/bin/null-system --apply firewall 2>&1 | sed 's/^/nullLinux: /'
  if ! systemctl is-enabled nftables.service >/dev/null 2>&1; then
    echo "nullLinux: WARNING -- nftables did not take; restoring firewalld" >&2
    systemctl enable firewalld.service 2>/dev/null || true
  fi
fi

# THE INITRAMFS MUST BE GENERIC, AND THAT MUST BE CHECKED HERE.
#
# dracut-config-generic is in %packages, which SHOULD make the image anaconda
# builds generic already. Should: kernel-install runs from the kernel's
# posttrans, and nothing orders that after dracut-config-generic lands. So
# rebuild, then look inside the result -- because the failure this prevents is
# a machine that will not boot after the disk is moved, discovered by the
# person holding the disk.
#
# Measured cost of a generic initramfs on the test install: 45 MB -> 219 MB,
# and 0.66s of boot. Measured cost of a host-only one, moved: it does not boot.
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/00-nulllinux-generic.conf <<'DRACUT'
# nullLinux: this disk has to boot in whatever machine it is moved to, so the
# initramfs carries every driver rather than the ones the installing machine
# happened to use. See `null-system initramfs`.
hostonly="no"
DRACUT

# THE BOOT SPLASH, BAKED IN (confirmed on metal, so no longer deferred to a
# manual `null-system plymouth --apply`).
#
# Set the theme and the default.plymouth symlink dracut's plymouth module reads
# BEFORE the regenerate below, so the theme lands in the initramfs in the same
# rebuild and the splash draws from the very first boot. null-system's plymouth
# verb is the running-machine twin of this -- it rebuilds only the running kernel
# and confirms the rescue entry first; a fresh install regenerates every kernel,
# and the read-back further down is the safety net.
PLYMOUTH_SPLASH=
_theme=/opt/nulllinux/system/plymouth-theme
if command -v plymouth-set-default-theme >/dev/null 2>&1 && [ -f "$_theme/nullLinux.plymouth" ]; then
  rm -rf /usr/share/plymouth/themes/nullLinux
  cp -a "$_theme" /usr/share/plymouth/themes/nullLinux
  command -v restorecon >/dev/null 2>&1 && restorecon -RF /usr/share/plymouth/themes/nullLinux 2>/dev/null || true
  plymouth-set-default-theme nullLinux
  # plymouth-set-default-theme writes plymouthd.conf and stops; dracut resolves
  # the theme through this symlink, whose absence once produced an initramfs that
  # named nullLinux but contained none of its files (see null-system).
  ln -sfn /usr/share/plymouth/themes/nullLinux/nullLinux.plymouth \
          /usr/share/plymouth/themes/default.plymouth
  PLYMOUTH_SPLASH=nullLinux
  echo "nullLinux: boot splash set; baking it into every initramfs"
else
  echo "nullLinux: WARNING -- plymouth theme missing; no boot splash" >&2
fi

# PLYMOUTH_THEME_NAME is not optional here: without it dracut can build an image
# whose plymouthd.conf says nullLinux while the theme's files are absent -- the
# exact failure null-system was written around.
PLYMOUTH_THEME_NAME="$PLYMOUTH_SPLASH" dracut --force --regenerate-all >/dev/null 2>&1 || \
  echo "nullLinux: WARNING -- dracut --regenerate-all failed" >&2

for img in /boot/initramfs-*.img; do
  case $img in *rescue*) continue ;; esac
  mods=$(lsinitrd "$img" 2>/dev/null | grep -oE '[a-z0-9_-]+\.ko(\.[a-z]+)?$' | sed 's/\.ko.*//' | tr - _ | sort -u)
  miss=""
  for m in sdhci_pci mmc_block megaraid_sas i915 amdgpu; do
    printf '%s\n' "$mods" | grep -qx "$m" || miss="$miss $m"
  done
  if [ -n "$miss" ]; then
    echo "nullLinux: WARNING -- $img is host-only, missing:$miss" >&2
    echo "nullLinux: this disk may not boot in another machine" >&2
  fi
done

# AND CONFIRM THE SPLASH IS ACTUALLY IN THE IMAGE, not merely named in the
# config -- read the artefact (§10.1). Named-but-absent falls back to grey dots,
# which is the failure this whole block exists to prevent.
if [ -n "$PLYMOUTH_SPLASH" ]; then
  for img in /boot/initramfs-*.img; do
    case $img in *rescue*) continue ;; esac
    n=$(lsinitrd "$img" 2>/dev/null | grep -c 'themes/nullLinux/' || true)
    if [ "${n:-0}" -gt 0 ]; then
      echo "nullLinux: splash present in $(basename "$img"): $n theme files"
    else
      echo "nullLinux: WARNING -- $(basename "$img") names the splash but carries NONE of its files" >&2
    fi
  done
fi

# A way in, for a test that has no console. Not a thing a real image would do.
mkdir -p /root/.ssh && chmod 700 /root/.ssh
cat > /root/.ssh/authorized_keys <<'KEYS'
NULLLINUX_TEST_KEY
KEYS
chmod 600 /root/.ssh/authorized_keys
%end
