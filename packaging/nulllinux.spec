# nullLinux -- a desktop in which every surface is one baked artefact.
#
# TWO HALVES, AND THE SPLIT IS FORCED BY HARDWARE.
#
# Everything machine-INDEPENDENT is done here, at build time: the renderer is
# compiled, and the expensive raytraced hero comes in prebuilt (Source1),
# because tracing is 0.39 s a frame on a discrete GPU and 28.27 s a frame on
# software Vulkan -- two minutes against two hours. A virtual machine or a
# headless install cannot be asked to bake its own.
#
# Everything machine-DEPENDENT waits for first boot, because it cannot be known
# before then. The machine profile is generated from the attached display, and
# there is no display in a build chroot; the atlas and the hero are chosen by
# the strike that profile selects. So the package ships every strike's atlas
# (nine, about 400 kB) and the hero for the four bake strikes that real panel
# sizes actually select, and first boot picks.
#
# The target needs NO compiler, NO python, and NO GPU.

%global debug_package %{nil}
%global _prefix /opt

Name:           nulllinux
Version:        0.1.0
Release:        1%{?dist}
Summary:        A desktop where every surface is one baked artefact

# MIT for this project's own code; OFL-1.1 because assets/atlas-*.bin are
# glyph bitmaps derived from Terminus, which is OFL. The field has to be true
# rather than convenient -- rpmlint and Fedora's review both check it.
License:        MIT AND OFL-1.1
URL:            https://github.com/jamesdanielhomer/nulllinux
Source0:        %{name}-%{version}.tar.gz
Source1:        %{name}-prebuilt-%{version}.tar.gz

ExclusiveArch:  x86_64

# Build-time only. None of these are needed on the installed machine.
BuildRequires:  rust
BuildRequires:  cargo
BuildRequires:  systemd-rpm-macros
BuildRequires:  pam-devel

# Runtime. GENERATED from packages/fedora/base.list by bin/null-package, and
# checked by verify/check-package-list.sh.
#
# This comment used to claim the checker alone kept them in step, and there was
# no such file: a comment describing an intention, which is the most expensive
# kind. They drifted -- cava was in the list and not here, and an ISO booted
# into a desktop whose spectrum said "cava did not start". The generator is the
# fix; the checker exists now too, because between an edit to the list and the
# next package build this block says something false, and that is what a reader
# and a distribution packager see.
Requires:       NetworkManager-tui
Requires:       NetworkManager-wifi
Requires:       Thunar
Requires:       amd-gpu-firmware
Requires:       atheros-firmware
Requires:       avahi
Requires:       ax86-terminus-ttf-fonts
Requires:       bc
Requires:       bluez
Requires:       brightnessctl
Requires:       btop
Requires:       bzip2
Requires:       cava
Requires:       cliphist
Requires:       cups
Requires:       cups-filters
Requires:       dosfstools
Requires:       dracut-config-generic
Requires:       dunst
Requires:       exfatprogs
Requires:       fd-find
Requires:       file
Requires:       firefox
Requires:       flatpak
Requires:       foot
Requires:       fwupd
Requires:       fzf
Requires:       git
Requires:       google-noto-emoji-fonts
Requires:       google-noto-sans-fonts
Requires:       google-noto-serif-fonts
Requires:       grim
Requires:       gvfs
Requires:       gvfs-fuse
Requires:       gvfs-mtp
Requires:       gvfs-smb
Requires:       gzip
Requires:       imv
Requires:       iw
Requires:       iwlwifi-dvm-firmware
Requires:       iwlwifi-mld-firmware
Requires:       iwlwifi-mvm-firmware
Requires:       liberation-mono-fonts
Requires:       liberation-sans-fonts
Requires:       liberation-serif-fonts
Requires:       libreoffice-calc
Requires:       libreoffice-gtk3
Requires:       libreoffice-impress
Requires:       libreoffice-writer
Requires:       microcode_ctl
Requires:       mpv
Requires:       nano
Requires:       nftables
Requires:       ntfs-3g
Requires:       pam
Requires:       pipewire
Requires:       pipewire-pulseaudio
Requires:       playerctl
Requires:       plymouth-plugin-two-step
Requires:       polkit
Requires:       power-profiles-daemon
Requires:       qcom-firmware
Requires:       realtek-firmware
Requires:       samba-client
Requires:       sddm
Requires:       slurp
Requires:       sway
Requires:       swayidle
Requires:       swaylock
Requires:       system-config-printer
Requires:       tar
Requires:       terminus-fonts
Requires:       terminus-fonts-console
Requires:       thunar-archive-plugin
Requires:       thunar-volman
Requires:       thunderbird
Requires:       udisks2
Requires:       unzip
Requires:       webkit2gtk4.1
Requires:       wf-recorder
Requires:       wiremix
Requires:       wireplumber
Requires:       wl-clipboard
Requires:       wlsunset
Requires:       wpa_supplicant
Requires:       xarchiver
Requires:       xdg-desktop-portal-gtk
Requires:       xdg-desktop-portal-wlr
Requires:       xfce-polkit
Requires:       xfconf
Requires:       xz
Requires:       zathura
Requires:       zathura-pdf-mupdf
Requires:       zip

%description
nullLinux is a Fedora Remix whose desktop is not a colour scheme but a
projection. A Kerr black hole is raytraced once, quantised to characters in a
bitmap font, and every surface -- wallpaper, status bar, side column, menus,
boot splash, greeter, lock screen and virtual console -- is that same artefact
resampled onto whatever cell grid that surface has.

The raytraced hero is prebuilt in this package. Nothing on the installed
machine needs a GPU, a compiler or a Python interpreter to draw it.

%prep
%setup -q
# The prebuilt assets are unpacked over the tree rather than beside it, so the
# layout on disk is identical to a tree that built them itself. Nothing
# downstream needs to know which of the two it is looking at.
tar -xzf %{SOURCE1} -C .

%build
# The renderer only. Every asset that could be built here is either already in
# Source1 or is cheap enough to do at first boot.
cargo build --release --manifest-path render/Cargo.toml --offline || \
  cargo build --release --manifest-path render/Cargo.toml

%install
install -d %{buildroot}%{_prefix}/%{name}
# bake/ SHIPS NOW, and that is not an oversight reversed lightly.
#
# It was excluded because an installed machine derived nothing: the package
# carried forty-five quantised grids and picked the nearest. It derives its own
# grid from the master now (bin/null-hero), and the deriver IS bake/ -- so a
# package without it installs a null-hero that calls a script that is not
# there, falls back to a rung, and looks like a working desktop for ever.
#
# This was invisible while testing from a source tree, which is what a build
# host has and an installed machine does not.
cp -a bin lib bake config machines packages verify docs assets NULL.md README.md \
      %{buildroot}%{_prefix}/%{name}/

# THE BUILD HOST'S MACHINE PROFILE DOES NOT TRAVEL.
#
# `machines/<hostname>.conf` is GENERATED from the hardware, and `bin/machine`
# selects one BY HOSTNAME. Shipping the build host's meant that an installed
# machine which happened to share its name -- and nox, the machine this is
# going onto, is exactly that -- would find a profile matching itself and use
# geometry measured on somebody else's panel instead of deriving its own.
#
# The directory ships; its contents do not. The profile is derived on the first
# boot that has a display, which is the only way it is ever right.
rm -f %{buildroot}%{_prefix}/%{name}/machines/*.conf
# The bake's own working directories are not shipped: hundreds of megabytes of
# HDR frames whose only purpose was to be packed into assets/prebuilt/master.hero.
rm -rf %{buildroot}%{_prefix}/%{name}/bake/out \
       %{buildroot}%{_prefix}/%{name}/bake/frames \
       %{buildroot}%{_prefix}/%{name}/bake/gpu/target \
       %{buildroot}%{_prefix}/%{name}/bake/__pycache__
install -d %{buildroot}%{_prefix}/%{name}/render/target/release
for b in column bar dwindle render lock; do
  [ -x render/target/release/$b ] && \
    install -m 0755 render/target/release/$b %{buildroot}%{_prefix}/%{name}/render/target/release/
done

# THE SESSION-LOCK CLIENT'S PAM STACK MUST SHIP.
#
# Its PAM handle names the service "null-lock". With no /etc/pam.d/null-lock the
# handle resolves to /etc/pam.d/other, which on Fedora denies every request -- so
# the locker would refuse every password and the machine could never be unlocked
# by its own screen lock. null-lock's handshake still reports LOCKED, so it would
# not fall back to swaylock either: it would just hold, unpassable.
install -D -m 0644 config/pam.d/null-lock \
  %{buildroot}%{_sysconfdir}/pam.d/null-lock

# The build tree is not shipped: it is 400 MB of object files and is exactly
# the kind of thing that makes a package larger than the thing it installs.
rm -rf %{buildroot}%{_prefix}/%{name}/render/target/debug

install -D -m 0644 packaging/nulllinux-machine-sync.service \
  %{buildroot}%{_unitdir}/nulllinux-machine-sync.service

# THE SESSION ENTRY HAS TO BE IN THE PACKAGE.
#
# It was not, and null-install found it missing and said so -- into /dev/null,
# because null-machine-sync discards its output. So a fresh install had the
# greeter offering Fedora's Sway, exactly as before the entry was written, and
# nothing anywhere reported it. It is installed under %{_prefix}/%{name} rather
# than straight into /usr/share/wayland-sessions because null-install rewrites
# its Exec path from $ROOT before placing it.
install -D -m 0644 packaging/nulllinux-session.desktop \
  %{buildroot}%{_prefix}/%{name}/packaging/nulllinux-session.desktop

# The netfilter preload unit, placed and enabled by null-system firewall for
# the same reason: it belongs to the firewall, not to the package.
install -D -m 0644 packaging/nulllinux-netfilter-modules.service \
  %{buildroot}%{_prefix}/%{name}/packaging/nulllinux-netfilter-modules.service

%post
%systemd_post nulllinux-machine-sync.service
# Enabled rather than run. Generating a machine profile needs a display, and
# there is no display in the chroot an ISO is built in -- so the machine half
# of the installation happens on the first boot that has one.
systemctl enable nulllinux-machine-sync.service >/dev/null 2>&1 || :

# THE UNIT WAS RENAMED (nulllinux-firstboot -> nulllinux-machine-sync), and a
# rename is not a rename to systemd: upgrading leaves the old unit's enable
# symlink behind, pointing at a unit file this package no longer ships. That
# is a failed unit on every boot afterwards. Clean it up explicitly -- once,
# harmlessly, for ever.
if systemctl list-unit-files nulllinux-firstboot.service >/dev/null 2>&1; then
  systemctl disable --now nulllinux-firstboot.service >/dev/null 2>&1 || :
fi
rm -f /etc/systemd/system/multi-user.target.wants/nulllinux-firstboot.service
systemctl daemon-reload >/dev/null 2>&1 || :

# Branding belongs to the package, not to one image's kickstart: an installer
# ISO, a live image and a plain `dnf install nulllinux` must all end up saying
# the same thing.  It only rewrites /etc, never the fedora-release-owned file
# in /usr, and %postun on final removal puts the distribution's own back.
#
# THE VERSION IS HANDED OVER, not looked up. This package IS the version the
# machine is getting, so it says so: null-brand once carried its own copy of
# the number, which agreed with this file exactly until the first bump.
NULL_VERSION=%{version} %{_prefix}/%{name}/bin/null-brand apply >/dev/null 2>&1 || :

%preun
%systemd_preun nulllinux-machine-sync.service

%postun
# $1 is the number of copies left after this transaction: 0 on removal, 1 on
# upgrade.  Un-branding during an UPGRADE would leave the machine as Fedora
# with nullLinux installed, so only do it when the package is really going.
if [ "$1" = 0 ] && [ -x %{_prefix}/%{name}/bin/null-brand ]; then
  %{_prefix}/%{name}/bin/null-brand revert >/dev/null 2>&1 || :
fi

%files
# BOTH licences ship. The OFL text has to travel with the font-derived
# atlases; shipping only MIT would be shipping OFL material without its terms.
%license LICENSE
%license licenses/OFL.txt
%doc README.md
%{_prefix}/%{name}
%{_unitdir}/nulllinux-machine-sync.service
%config(noreplace) %{_sysconfdir}/pam.d/null-lock

%changelog
* Thu Sep 03 2026 nullLinux <noreply@anthropic.com> - 0.1.0-1
- First package. Ships the raytraced hero prebuilt for the four bake strikes
  real panels select, and every strike's atlas, so no installed machine needs
  a GPU or a compiler.
