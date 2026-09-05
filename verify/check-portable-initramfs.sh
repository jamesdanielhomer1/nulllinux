#!/usr/bin/env bash
# THE DISK HAS TO BOOT IN THE NEXT MACHINE (NULL.md: any hardware).
#
# Fedora's dracut default is hostonly=yes. Three things have to hold for an
# installed disk to be movable, and all three are easy to delete by accident:
# the package, the %post rebuild, and the %post check.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

grep -qx 'dracut-config-generic' packages/fedora/base.list || {
  note "packages/fedora/base.list: dracut-config-generic is gone -- anaconda will build a host-only initramfs"; fail=1; }

grep -q 'hostonly="no"' packaging/nulllinux-install.ks || {
  note "packaging/nulllinux-install.ks: %post no longer writes hostonly=\"no\""; fail=1; }

grep -q 'regenerate-all' packaging/nulllinux-install.ks || {
  note "packaging/nulllinux-install.ks: %post no longer rebuilds the initramfs"; fail=1; }

# The check is the part that matters -- a rebuild that quietly produced a
# host-only image is the failure being guarded against.
grep -q 'may not boot in another machine' packaging/nulllinux-install.ks || {
  note "packaging/nulllinux-install.ks: %post rebuilds but no longer INSPECTS the result"; fail=1; }

grep -q 'cmd_initramfs' bin/null-system || {
  note "bin/null-system: no initramfs subcommand -- nothing can check a running machine"; fail=1; }

# A driver compiled into the kernel is not a missing driver. Getting this wrong
# reports every correct initramfs as broken, which is how it was first written.
grep -q 'modules.builtin' bin/null-system || {
  note "bin/null-system: the initramfs check ignores built-in drivers, so it will cry wolf"; fail=1; }

[ $fail = 0 ] && echo "the installed initramfs is generic, and the install checks it"
exit $fail
