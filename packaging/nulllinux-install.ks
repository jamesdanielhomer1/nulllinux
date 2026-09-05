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
firewall --enabled --service=mdns
network --bootproto=dhcp --device=link --activate --hostname=nulltest

# THE INSTALL TARGET IS NAMED EXPLICITLY. `clearpart --all` with no --drives
# will take every disk it can see, and on a machine with more than one that is
# how an installer eats something it was not pointed at.
ignoredisk --only-use=vda
zerombr
clearpart --all --initlabel --drives=vda
autopart --type=plain --noswap

# THE INSTALLED SYSTEM'S KERNEL ARGUMENTS ARE SET HERE, NOT INHERITED.
#
# anaconda copies the INSTALLER's console= arguments into the installed
# system's boot entries. The harness boots the installer with
# console=ttyS0,115200 so it can capture the install log -- and the installed
# system then inherited a serial console it has no reason to have.
#
# That is not cosmetic. With plymouth's graphical plugin present, a serial
# console hangs the boot at initrd-switch-root: no further output, no ssh, and
# zero disk I/O -- verified by querying qemu's blockstats twice twenty seconds
# apart. Removing exactly those two arguments from the boot entry and nothing
# else took the same disk from hung to a login screen in 32 seconds.
#
# It went unnoticed because it only appears once plymouth has a graphical
# plugin to load, which it did not until plymouth-plugin-two-step was added.
bootloader --location=mbr --boot-drive=vda --append="rhgb quiet"

# A shell in the INSTALLER ENVIRONMENT, which is a different machine from the
# one being installed. With inst.sshd on the command line this is the only way
# to read /tmp/anaconda.log while it is still running -- and reading the log
# rather than guessing is what turned the last three failures into answers.
sshpw --username=root nulltest --plaintext

rootpw --plaintext nulltest
user --name=null --groups=wheel --password=nulltest --plaintext

services --enabled=NetworkManager,sshd
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

# A way in, for a test that has no console. Not a thing a real image would do.
mkdir -p /root/.ssh && chmod 700 /root/.ssh
cat > /root/.ssh/authorized_keys <<'KEYS'
NULLLINUX_TEST_KEY
KEYS
chmod 600 /root/.ssh/authorized_keys
%end
