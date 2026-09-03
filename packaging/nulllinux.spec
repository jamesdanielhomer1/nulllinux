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

License:        MIT
URL:            https://github.com/jamesdanielhomer/nulllinux
Source0:        %{name}-%{version}.tar.gz
Source1:        %{name}-prebuilt-%{version}.tar.gz

ExclusiveArch:  x86_64

# Build-time only. None of these are needed on the installed machine.
BuildRequires:  rust
BuildRequires:  cargo
BuildRequires:  systemd-rpm-macros

# Runtime. Kept in step with packages/fedora/base.list by
# verify/check-package-list.sh, so the two cannot drift.
Requires:       ax86-terminus-ttf-fonts
Requires:       bluez
Requires:       brightnessctl
Requires:       btop
Requires:       cava
Requires:       cliphist
Requires:       dunst
Requires:       fd-find
Requires:       firefox
Requires:       foot
Requires:       fwupd
Requires:       fzf
Requires:       git
Requires:       grim
Requires:       iw
Requires:       playerctl
Requires:       slurp
Requires:       sway
Requires:       terminus-fonts
Requires:       terminus-fonts-console
Requires:       thunar
Requires:       webkit2gtk4.1
Requires:       wf-recorder
Requires:       wl-clipboard
Requires:       wlsunset
Requires:       xfconf

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
cp -a bin lib config machines packages verify docs assets NULL.md README.md \
      %{buildroot}%{_prefix}/%{name}/
install -d %{buildroot}%{_prefix}/%{name}/render/target/release
for b in column bar dwindle render; do
  [ -x render/target/release/$b ] && \
    install -m 0755 render/target/release/$b %{buildroot}%{_prefix}/%{name}/render/target/release/
done

# The build tree is not shipped: it is 400 MB of object files and is exactly
# the kind of thing that makes a package larger than the thing it installs.
rm -rf %{buildroot}%{_prefix}/%{name}/render/target/debug

install -D -m 0644 packaging/nulllinux-firstboot.service \
  %{buildroot}%{_unitdir}/nulllinux-firstboot.service

%post
%systemd_post nulllinux-firstboot.service
# Enabled rather than run. Generating a machine profile needs a display, and
# there is no display in the chroot an ISO is built in -- so the machine half
# of the installation happens on the first boot that has one.
systemctl enable nulllinux-firstboot.service >/dev/null 2>&1 || :

%preun
%systemd_preun nulllinux-firstboot.service

%files
%license LICENSE
%doc README.md
%{_prefix}/%{name}
%{_unitdir}/nulllinux-firstboot.service

%changelog
* Wed Sep 03 2026 nullLinux <noreply@anthropic.com> - 0.1.0-1
- First package. Ships the raytraced hero prebuilt for the four bake strikes
  real panels select, and every strike's atlas, so no installed machine needs
  a GPU or a compiler.
