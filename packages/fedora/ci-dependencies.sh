#!/usr/bin/env bash
# Dependencies for verify/source.sh in a disposable Fedora 44 CI container.
set -euo pipefail
dnf -y install git rust cargo clippy gcc pkgconf-pkg-config \
  wayland-devel libxkbcommon-devel pam-devel \
  python3-numpy python3-pillow python3-zstandard \
  terminus-fonts-console ax86-terminus-ttf-fonts findutils diffutils procps-ng
