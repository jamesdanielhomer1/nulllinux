# nullLinux live ISO (NULL.md §0.5).
#
# A LIVE image that also installs, which is the shape every desktop
# distribution ships: you boot it, you look at it, and if you like it you press
# install. Anaconda is on the image for the second half.
#
# THE DESKTOP IS ALREADY BUILT. Nothing here compiles anything or bakes
# anything: the nulllinux package carries the raytraced hero for every strike,
# every atlas, the palette and the palette-derived surfaces, so the image needs
# no GPU, no Rust and no Python beyond what Fedora already ships. That is what
# makes a live image possible at all -- a two-hour bake on first boot is not a
# thing anyone would sit through, and on software Vulkan it does not reliably
# finish.

lang en_GB.UTF-8
keyboard --vckeymap=gb --xlayouts='gb'
timezone Europe/London --utc
selinux --enforcing
firewall --enabled --service=mdns
xconfig --startxonboot
zerombr
clearpart --all
part / --size=8192 --fstype ext4
services --enabled=NetworkManager,sshd --disabled=network
shutdown

# No password. A live image with a root password is a live image with a
# published root password, and this one is meant to be booted by strangers.
rootpw --lock

# THE INSTALL SOURCE. livemedia-creator refuses a kickstart with `repo` lines
# and no `url`: "repo can only be used with the url install method". The url is
# where the base system comes from; the repo lines below add to it.
# A CONCRETE URL, NOT A MIRRORLIST. livemedia-creator does
#   ks.handler.method.url.startswith("file:")
# in creator.py, and --mirrorlist leaves that url as None -- which surfaces as
# "'NoneType' object has no attribute 'startswith'" and no other clue at all.
# The `repo` lines below still use mirrorlists; it is only the install method
# that must be a URL.
# Networking, ACTIVATED. anaconda refuses a url install method without it:
# "The kickstart must activate networking if the url install method is used."
# This is the build-time network, not the installed machine's -- NetworkManager
# owns that once the system is running.
network --bootproto=dhcp --device=link --activate --hostname=nulllinux

url --url=https://download.fedoraproject.org/pub/fedora/linux/releases/$releasever/Everything/$basearch/os/

repo --name=fedora --mirrorlist=https://mirrors.fedoraproject.org/metalink?repo=fedora-$releasever&arch=$basearch
repo --name=updates --mirrorlist=https://mirrors.fedoraproject.org/metalink?repo=updates-released-f$releasever&arch=$basearch
# The local repository holding the package built by bin/null-package. It is
# rewritten by bin/null-iso to the absolute path of packaging/repo.
repo --name=nulllinux --baseurl=file://NULLLINUX_REPO

%packages
@core
@standard
@hardware-support
kernel
dracut-live
dracut-config-generic
memtest86+
syslinux
anaconda
anaconda-install-env-deps
@anaconda-tools
# The desktop itself. Its Requires pull in sway, foot, fzf, thunar and the
# rest, so this one line is the whole desktop.
nulllinux
-@dial-up
-@input-methods
-gfs2-utils
-reiserfs-utils
%end

%post
# The live user. Created here rather than by a %post --nochroot because it must
# exist in the image, not on the build host.
useradd -m -G wheel -s /bin/bash live 2>/dev/null || true
passwd -d live 2>/dev/null || true

# Passwordless sudo for the live user, as every live image does. The account
# has no password at all, so a sudo that PROMPTS is a sudo that can never
# succeed -- which is how the unattended install above would have hung waiting
# for input nobody was there to give.
#
# This is a property of the live session only. An installed system creates its
# own users through the installer and never sees this file.
echo 'live ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/live-nulllinux
chmod 0440 /etc/sudoers.d/live-nulllinux

# Autologin into sway on tty1. A live image that stops at a text prompt has
# failed at the only job a live image has.
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'AUTO'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin live --noclear %I $TERM
AUTO

# sway from the login shell, once, on tty1 only. The system-wide configuration
# the package installed is what it reads -- the live user has no ~/.config/sway
# and does not need one, which is the whole point of installing system-wide.
cat >> /home/live/.bash_profile <<'PROF'
if [ -z "$WAYLAND_DISPLAY" ] && [ "$XDG_VTNR" = 1 ]; then
  # AN UNATTENDED INSTALL BEATS THE DESKTOP.
  #
  # Booting with inst.ks= means somebody asked for an installation, not a look
  # around -- and autologin into sway silently won that argument. The image
  # booted to a desktop and the kickstart on it was never read, which is a
  # defect in the image and not merely in a test: `mkksiso` puts inst.ks on
  # every boot entry precisely so an image can install itself, and this made
  # that impossible.
  ks=$(sed -n 's/.*inst\.ks=\([^ ]*\).*/\1/p' /proc/cmdline)
  if [ -n "$ks" ]; then
    # hd:LABEL=X:/path -- the live medium is already mounted, so the path on it
    # is what matters and the label has served its purpose in the initramfs.
    f=${ks##*:}
    for d in /run/initramfs/live /run/install/repo /mnt/install/repo; do
      [ -r "$d$f" ] && { exec sudo liveinst --kickstart="$d$f"; }
    done
    echo "inst.ks=$ks was asked for but $f was not found on the live medium" >&2
    echo "falling through to the desktop" >&2
  fi
  exec sway
fi
PROF
chown live:live /home/live/.bash_profile

# The machine half of the installation runs on the first boot that has a
# display, which for a live image is this one.
systemctl enable nulllinux-firstboot.service 2>/dev/null || true

# An installer that is findable. A live image nobody can install from is a
# demonstration, not a distribution.
mkdir -p /home/live/Desktop
cat > /home/live/Desktop/install-nulllinux.desktop <<'DESK'
[Desktop Entry]
Type=Application
Name=Install nullLinux to this machine
Exec=liveinst
Terminal=true
DESK
chown -R live:live /home/live/Desktop

# ---------------------------------------------------------------------------
# THE GPL SOURCE OFFER, AND THE MANIFEST IT REFERS TO.
#
# This image redistributes binaries under GPL-2.0, GPL-3.0, LGPL and other
# copyleft licences. Distributing those binaries carries an obligation to make
# the CORRESPONDING SOURCE available -- GPLv2 section 3, GPLv3 section 6 --
# and "the source is on the internet somewhere" does not discharge it.
#
# The manifest is generated HERE, inside the image, by asking its own rpm
# database what is installed. That is the only way it can be exactly what
# shipped: a list built beside the image can drift from it, and a list built
# from the kickstart is a list of what was ASKED for rather than what
# dependency resolution actually pulled in.
#
# Versions are recorded in full, with the source package name for each, because
# "corresponding source" means the source for THIS build and not whatever is
# current when someone asks.
mkdir -p /usr/share/nulllinux
{
  echo "nullLinux -- source availability"
  echo "generated $(date -Iseconds) inside the image"
  echo
  echo "This image contains software under the GNU General Public License and"
  echo "other copyleft licences. You are entitled to the corresponding source."
  echo
  echo "WHERE THE SOURCE IS"
  echo
  echo "  Every package below except nulllinux itself comes unmodified from"
  echo "  Fedora. Its source is published as source RPMs at:"
  echo
  echo "    https://dl.fedoraproject.org/pub/fedora/linux/releases/RELEASEVER/Everything/source/tree/"
  echo "    https://dl.fedoraproject.org/pub/fedora/linux/updates/RELEASEVER/Everything/SRPMS/"
  echo "    https://kojipkgs.fedoraproject.org/packages/    (all builds, by name and version)"
  echo
  echo "  Retrieve the exact source for any package here with:"
  echo "    dnf download --source <name>-<version>-<release>"
  echo
  echo "  nulllinux's own source is MIT and is at:"
  echo "    https://github.com/jamesdanielhomer/nulllinux"
  echo
  echo "WRITTEN OFFER"
  echo
  echo "  For three years from the date of this build, the distributor of this"
  echo "  image will provide, on request and for no more than the cost of the"
  echo "  medium and postage, a complete machine-readable copy of the"
  echo "  corresponding source for any GPL-covered package listed below."
  echo
  echo "MANIFEST -- name-version-release.arch  license  source package"
  echo
  rpm -qa --qf '%{name}-%{version}-%{release}.%{arch}\t%{license}\t%{sourcerpm}\n' | sort
} > /usr/share/nulllinux/SOURCES.txt

# The release version is only knowable inside the image, so it is substituted
# here rather than guessed above.
sed -i "s|RELEASEVER|$(rpm -q --qf '%{version}' fedora-release-common 2>/dev/null || echo 44)|g" \
  /usr/share/nulllinux/SOURCES.txt

# Copyleft packages counted separately, so the obligation has a size rather
# than being a general worry.
copyleft=$(rpm -qa --qf '%{license}\n' | grep -icE 'GPL|MPL|EPL|CDDL' || true)
total=$(rpm -qa | wc -l)
echo "" >> /usr/share/nulllinux/SOURCES.txt
echo "$copyleft of $total packages carry a copyleft licence." >> /usr/share/nulllinux/SOURCES.txt

# Findable without a shell. A source offer nobody can locate is not an offer.
ln -sf /usr/share/nulllinux/SOURCES.txt /root/SOURCES.txt 2>/dev/null || true
mkdir -p /home/live && ln -sf /usr/share/nulllinux/SOURCES.txt /home/live/SOURCES.txt 2>/dev/null || true

releasever=$(rpm -q --qf '%{version}\n' fedora-release-common 2>/dev/null | head -1)
cat > /etc/os-release <<OSREL
NAME="nullLinux"
VERSION="0.1.0 (Fedora ${releasever:-44} Remix)"
ID=nulllinux
ID_LIKE=fedora
VERSION_ID=0.1.0
PRETTY_NAME="nullLinux 0.1.0"
ANSI_COLOR="0;38;2;255;120;0"
HOME_URL="https://github.com/jamesdanielhomer/nulllinux"
OSREL
%end
