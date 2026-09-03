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

bootloader --location=mbr --boot-drive=vda

rootpw --plaintext nulltest
user --name=null --groups=wheel --password=nulltest --plaintext

services --enabled=NetworkManager,sshd
reboot

%packages
@core
kernel
nulllinux
%end

%post
# The firstboot unit does the machine half -- profile, strike, hero -- on the
# first boot that has a display. Enabled here because the package's %post ran
# inside the installer's chroot, where enabling can be lost.
systemctl enable nulllinux-firstboot.service 2>/dev/null || true

# A way in, for a test that has no console. Not a thing a real image would do.
mkdir -p /root/.ssh && chmod 700 /root/.ssh
cat > /root/.ssh/authorized_keys <<'KEYS'
NULLLINUX_TEST_KEY
KEYS
chmod 600 /root/.ssh/authorized_keys
%end
