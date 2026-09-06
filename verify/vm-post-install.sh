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
warn() { printf '  ????  %s\n' "$*"; }
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
# THROUGH bin/pkg, NOT rpm (NULL.md 9.1). The guest has the same tool at the
# same path, so the same verb answers on both sides.
gver=$(g '/opt/nulllinux/bin/pkg installed-version nulllinux')
info "$gver"
ghash=$(g '/opt/nulllinux/bin/pkg installed-id nulllinux')
lhash=$("$ROOT/bin/pkg" file-id "$(ls -1 "$ROOT/packaging/repo"/nulllinux-*.rpm 2>/dev/null | head -1)" 2>/dev/null)
info "guest ${ghash:-<unreadable>}  /  packaging/repo ${lhash:-<unreadable>}"
# A MISSING ANSWER IS NOT A WRONG ANSWER.
#
# The guest runs the bin/pkg it was installed with. Ask it for a verb added
# after that build and it says nothing -- which is not the same as saying the
# package is stale, and reporting it as such sends you looking for a
# packaging bug that is not there. It happened on the first run of this.
if [ -z "$ghash" ]; then
  warn "the guest's bin/pkg did not answer 'installed-id' -- it predates the verb."
  warn "  Cannot compare; this says nothing either way about which build is installed."
elif [ -z "$lhash" ]; then
  warn "no readable package in packaging/repo to compare against"
elif [ "$ghash" = "$lhash" ]; then
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

# --- the session the greeter offers ----------------------------------------
#
# THIS SECTION EXISTS BECAUSE THE CHECK DID NOT HAVE IT.
#
# packaging/nulllinux-session.desktop was written, null-install was taught to
# place it, and the spec never shipped it -- so a fresh install had a greeter
# offering Fedora's "Sway" exactly as before, with no session environment set
# at all. null-install said "no ... -- skipping" and null-machine-sync sent
# that to /dev/null. Everything above still passed.
head_ "the session"
if [ "$(g 'test -r /usr/share/wayland-sessions/nulllinux.desktop && echo yes || echo no')" = yes ]; then
  ok "the greeter offers a nullLinux session"
  info "$(g 'grep -h "^Exec=" /usr/share/wayland-sessions/nulllinux.desktop')"
  # And it must run OUR wrapper. An entry that execs sway is Fedora's entry
  # with our name on it, and sets none of the environment.
  if g 'grep -q "^Exec=.*/bin/null-session" /usr/share/wayland-sessions/nulllinux.desktop'; then
    ok "it runs bin/null-session, so the session environment is set"
  else
    bad "the session entry does not run bin/null-session -- no GTK_THEME, no Qt theme, no portal"
  fi
else
  bad "no /usr/share/wayland-sessions/nulllinux.desktop -- the greeter offers Fedora's Sway"
fi

# --- what a person opens ---------------------------------------------------
#
# A desktop that cannot open a screenshot it just took is not finished. Each of
# these is a role bin/null-open offers; a role with nothing behind it fails at
# the moment somebody uses it, which is the worst moment to find out.
head_ "opening things"
for pair in "image:imv" "pdf:zathura" "video:mpv" "archive:xarchiver" "editor:nano"; do
  role=${pair%%:*}; prog=${pair##*:}
  if [ "$(g "command -v $prog >/dev/null && echo yes || echo no")" = yes ]; then
    ok "$role: $prog is installed"
  else
    bad "$role: $prog is NOT installed -- null-open would find nothing"
  fi
done
# And their configuration has to be where each program looks, which is a
# different path for nearly every one of them.
for f in /etc/zathurarc /etc/imv_config /etc/mpv/mpv.conf /etc/xdg/foot/foot.ini /etc/xdg/dunst/dunstrc; do
  if [ "$(g "test -r $f && echo yes || echo no")" = yes ]; then ok "config in place: $f"
  else bad "MISSING: $f -- that program runs in its own colours"; fi
done

# --- privileged actions ----------------------------------------------------
head_ "asking for a password"
if [ "$(g 'command -v /usr/libexec/xfce-polkit >/dev/null && echo yes || echo no')" = yes ]; then
  ok "a polkit agent is installed"
else
  bad "no polkit agent -- every privileged action fails with no prompt at all"
fi
if [ "$(g 'command -v swaylock >/dev/null && echo yes || echo no')" = yes ]; then
  ok "swaylock is installed, so the screen can be locked"
else
  bad "swaylock is NOT installed -- the screen cannot be locked"
fi

# --- the surfaces ----------------------------------------------------------
head_ "surfaces"
sync_line=$(g 'journalctl -b -u nulllinux-machine-sync --no-pager -o cat | tail -2 | tr "\n" " "')
info "${sync_line:-<no machine-sync output>}"
# "inactive" IS ALSO WHAT A UNIT THAT DOES NOT EXIST REPORTS.
#
# A Type=oneshot unit that ran and exited is inactive, so the check has to
# tolerate that -- but systemctl prints inactive for a unit that was never
# enabled, never started, or is not installed at all, and the exit status is
# swallowed by the pipe. The only states that failed this were failed and
# activating, and failed is already caught by the no-failed-units check above.
# So it asserted the strongest property in this file while testing nothing.
ms=$(g 'systemctl show -p LoadState -p Result --value nulllinux-machine-sync' | tr '\n' ' ')
info "machine-sync: ${ms:-<no answer>}"
case $ms in
  "loaded success "*|"loaded success") ok "machine-sync is installed and ran to success" ;;
  "not-found"*)  bad "nulllinux-machine-sync is not installed on the guest" ;;
  *)             bad "machine-sync did not run cleanly: ${ms:-<no answer>}" ;;
esac
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
