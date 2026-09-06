#!/usr/bin/env bash
# Check the machine the installer just produced, over ssh.
#
# WHY THIS EXISTS. vm-iso-install.sh boots the installer and exits; everything
# after that was checked by hand, differently each time, and the things that
# were not asked about were the things that were wrong. The initramfs was
# host-only for the whole life of the project and no install test noticed,
# because no install test looked.
#
# WHAT IT CANNOT PROVE, said here rather than implied: this is a virtual
# machine. Real firmware, secure boot, a discrete GPU, wifi, suspend, and a
# panel whose EDID is not qemu's are all untested by anything here. A pass
# means the software is right, not that the hardware works.
#
# Report-first in the sense that matters for a check: every assertion prints
# what it actually saw, whether it passed or not, so a failure is diagnosable
# from the output alone rather than by re-running it by hand.
set -uo pipefail
ROOT=${NULL_ROOT:-$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)}
WORK=${NULL_VM_WORK:-/var/lib/nulllinux-test}
PORT=${NULL_VM_PORT:-2223}
KEY="$WORK/id_guest"
WAIT=${NULL_VM_WAIT:-900}

fails=0
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
info() { printf '        %s\n' "$*"; }
head_() { printf '\n== %s\n' "$*"; }

[ -r "$KEY" ] || { echo "no guest key at $KEY -- run vm-iso-install.sh install first" >&2; exit 2; }

g() {  # run a command on the guest, quietly
  ssh -i "$KEY" -o ConnectTimeout=8 -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -p "$PORT" root@localhost "$@" 2>/dev/null
}

# --- wait for it to come up ------------------------------------------------
#
# An install that has not finished and an install that has failed look the
# same from outside, so this says which it gave up on rather than just "no".
head_ "waiting for the installed machine (up to ${WAIT}s)"
deadline=$(( $(date +%s) + WAIT ))
until g true; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo
    echo "  never answered on port $PORT."
    echo "  last of $WORK/install-console.log:"
    tail -15 "$WORK/install-console.log" 2>/dev/null | tr -d '\r' | sed 's/^/    /'
    exit 1
  fi
  sleep 5
done
ok "ssh answers on port $PORT"

# --- it is the thing we built ----------------------------------------------
head_ "identity"
id_line=$(g 'grep -E "^(NAME|VERSION)=" /etc/os-release | tr "\n" " "')
info "$id_line"
case $id_line in
  *nullLinux*) ok "the installed system says it is nullLinux" ;;
  *) bad "os-release does not name nullLinux" ;;
esac
# The symlink trap: /etc/os-release written THROUGH its link edits Fedora's
# file in /usr/lib and leaves the machine claiming to be both.
if [ "$(g 'test -L /etc/os-release && echo link || echo file')" = file ]; then
  ok "/etc/os-release is a real file, not a link into /usr/lib"
else
  bad "/etc/os-release is still a symlink -- branding was written through it"
fi

# --- the package on the machine is the package we published -----------------
head_ "the installed package"
gver=$(g 'rpm -q nulllinux')
info "$gver"
ghash=$(g 'rpm -q --qf "%{SIGMD5}\n" nulllinux')
lhash=$(rpm -q --qf '%{SIGMD5}\n' -p "$ROOT/packaging/repo"/nulllinux-*.rpm 2>/dev/null | head -1)
info "guest $ghash  /  packaging/repo $lhash"
if [ -n "$ghash" ] && [ "$ghash" = "$lhash" ]; then
  ok "the guest installed the package in packaging/repo, not an older one"
else
  bad "the guest's package differs from packaging/repo -- the test proved a stale build"
fi

# --- boot ------------------------------------------------------------------
head_ "boot"
g 'systemd-analyze' | sed 's/^/        /'
if g 'systemctl is-active graphical.target' | grep -qx active; then
  ok "graphical.target is active"
else
  bad "graphical.target is not active -- no greeter"
fi
if g 'systemctl is-active display-manager.service' | grep -qx active; then
  ok "the display manager is running"
else
  bad "the display manager is not running"
fi
if g 'systemctl is-failed --quiet "*"'; then
  info "failed units:"
  g 'systemctl list-units --state=failed --no-legend --plain' | sed 's/^/        /'
  bad "some units failed"
else
  ok "no failed units"
fi

# --- the firewall ----------------------------------------------------------
#
# The whole point of replacing firewalld was to keep the same policy. A test
# that only checks "nftables is active" would pass on an empty ruleset.
head_ "firewall"
if g 'systemctl is-active nftables' | grep -qx active; then
  ok "nftables.service is active"
else
  bad "nftables.service is NOT active"
fi
if g 'systemctl is-enabled firewalld' 2>/dev/null | grep -qx enabled; then
  bad "firewalld is still enabled -- two firewalls, and 3s of boot back"
else
  ok "firewalld is not enabled"
fi
pol=$(g 'nft list chain inet filter input' | grep -oE 'policy [a-z]+' | head -1)
info "input chain: ${pol:-<none>}"
[ "$pol" = "policy drop" ] && ok "input policy is drop" || bad "input policy is '${pol:-missing}', not drop"
pol=$(g 'nft list chain inet filter forward' | grep -oE 'policy [a-z]+' | head -1)
[ "$pol" = "policy drop" ] && ok "forward policy is drop" || bad "forward policy is '${pol:-missing}', not drop"
rules=$(g 'nft list ruleset')
for want in 'ct state established,related accept' 'iif "lo" accept' \
            'meta l4proto ipv6-icmp accept' 'udp dport 5353 accept' 'tcp dport 22 accept'; do
  if printf '%s' "$rules" | grep -qF "$want"; then ok "rule present: $want"
  else bad "rule MISSING: $want"; fi
done

# --- the initramfs ---------------------------------------------------------
#
# The failure this guards against is discovered by the person holding the disk,
# in a different machine, with no way to fix it there.
head_ "initramfs (the disk has to boot in another machine)"
if [ "$(g 'test -e /etc/dracut.conf.d/00-nulllinux-generic.conf && echo yes || echo no')" = yes ]; then
  ok "the hostonly=no drop-in is installed"
else
  bad "no /etc/dracut.conf.d/00-nulllinux-generic.conf -- the next kernel will be host-only"
fi
mods=$(g 'lsinitrd /boot/initramfs-$(uname -r).img | grep -oE "[a-z0-9_-]+\.ko(\.[a-z]+)?$" | sed "s/\.ko.*//" | tr - _ | sort -u')
info "$(printf '%s' "$mods" | grep -c .) modules in the running kernel's initramfs"
for m in sdhci_pci mmc_block megaraid_sas i915 amdgpu nouveau ast; do
  if printf '%s\n' "$mods" | grep -qx "$m"; then ok "driver present: $m"
  else bad "driver MISSING: $m -- this disk would not boot in such a machine"; fi
done
# Kernels accumulate and each generic initramfs is large. A /boot that fills up
# leaves the machine unable to install its next kernel, which is a slow failure.
info "/boot: $(g 'df -h /boot | tail -1')"

# --- the surfaces ----------------------------------------------------------
head_ "surfaces"
sync_line=$(g 'journalctl -b -u nulllinux-machine-sync --no-pager -o cat | tail -2 | tr "\n" " "')
info "${sync_line:-<no machine-sync output>}"
if g 'systemctl is-active nulllinux-machine-sync' | grep -qxE 'active|inactive'; then
  ok "machine-sync ran"
else
  bad "machine-sync did not run"
fi
if [ "$(g 'test -d /var/cache/nulllinux/hero && echo yes || echo no')" = yes ]; then
  ok "the hero cache exists"
  info "$(g 'ls -1 /var/cache/nulllinux/hero/*.cells 2>/dev/null | wc -l') derived grid(s)"
else
  info "no hero cache yet (nothing has needed one)"
fi
# The bake has to be ON the machine, not merely referenced by it.
if [ "$(g 'test -s /opt/nulllinux/assets/prebuilt/master.hero && echo yes || echo no')" = yes ]; then
  ok "the master bake is installed ($(g 'du -h /opt/nulllinux/assets/prebuilt/master.hero | cut -f1'))"
else
  bad "assets/prebuilt/master.hero is missing -- nothing can derive a grid"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "PASS: the installed machine is what the ISO claimed it would be"
else
  echo "$fails check(s) FAILED"
fi
exit $(( fails > 0 ))
