#!/usr/bin/env bash
# THE MACHINE IS NEVER LEFT WITH NO FIREWALL.
#
# firewalld was replaced with a static nftables ruleset to get 3 seconds of
# boot back. That is only a good trade while the ruleset is actually there and
# actually says what firewalld said. Four ways it could quietly stop being
# true, and a check for each.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

RULES=config/nftables/nulllinux.nft

[ -r "$RULES" ] || { note "$RULES is gone -- the install would have no ruleset"; exit 1; }

# 1. It has to parse. nft is not always present on a build host, so this is
#    checked when it can be and said plainly when it cannot.
if command -v nft >/dev/null 2>&1; then
  nft -c -f "$RULES" >/dev/null 2>&1 || { note "$RULES does not parse"; fail=1; }
else
  note "(nft not installed here; syntax unchecked)"
fi

# 2. Default deny, on input AND forward. A ruleset that loads and accepts
#    everything is worse than no ruleset, because it looks like protection.
for chain in input forward; do
  awk -v c="$chain" '
    $0 ~ "chain "c" *\\{" {inc=1}
    inc && /policy drop;/ {ok=1}
    inc && /^[[:space:]]*\}/ {inc=0}
    END {exit ok?0:1}' "$RULES" \
    || { note "$RULES: chain $chain does not have policy drop"; fail=1; }
done

# 3. Dropping ICMPv6 breaks IPv6 outright -- neighbour discovery and path-MTU
#    both ride on it. This is the rule most likely to be deleted by someone
#    tightening things up.
grep -q 'meta l4proto ipv6-icmp accept' "$RULES" \
  || { note "$RULES: ICMPv6 is not accepted -- IPv6 will not work"; fail=1; }
grep -q 'ct state established,related accept' "$RULES" \
  || { note "$RULES: no established/related rule -- nothing this machine starts will get a reply"; fail=1; }

# 4. The install has to put it in place, and has to put firewalld back if it
#    could not. Losing either half is how a machine ends up with neither.
grep -q 'null-system --apply firewall' packaging/nulllinux-install.ks \
  || { note "packaging/nulllinux-install.ks: %post no longer installs the ruleset"; fail=1; }
grep -q 'systemctl enable firewalld.service' packaging/nulllinux-install.ks \
  || { note "packaging/nulllinux-install.ks: no fallback -- a failed nftables install leaves no firewall"; fail=1; }
grep -q 'cmd_firewall' bin/null-system \
  || { note "bin/null-system: no firewall subcommand"; fail=1; }

# 5. nft is the firewall. It must be a declared dependency and not a thing that
#    arrives because firewalld drags it in through four levels of Requires --
#    which is how it got here, and which breaks the moment anyone removes the
#    firewalld we stopped using.
./bin/pkg list-packages base 2>/dev/null | tr ' ' '\\n' | grep -qx 'nftables' \
  || { note "packages/fedora/base.list: nftables is not declared -- /usr/sbin/nft arrives only via firewalld"; fail=1; }

# 6. The module preload is what made it fast. Without it the ruleset still
#    loads, just back on the critical path -- so this is a warning, not a
#    failure, and it should say which.
[ -r packaging/nulllinux-netfilter-modules.service ] \
  || note "(packaging/nulllinux-netfilter-modules.service is gone -- still correct, 600ms slower)"
grep -q 'ExecStart=-' packaging/nulllinux-netfilter-modules.service 2>/dev/null \
  || { note "the netfilter preload does not tolerate a failed modprobe -- it would fail the boot as /etc/modules-load.d did"; fail=1; }

# 7. `nft -c` NEEDS A KERNEL, and the install runs where there is not one.
#
#    It opens a netlink socket to nf_tables rather than merely parsing, so in
#    anaconda's %post chroot it fails with "Unable to initialize Netlink
#    socket: Protocol not supported". Reading that as a bad ruleset made the
#    first install fall back to firewalld. The two cases must stay
#    distinguishable, so this drives cmd_firewall with a stub nft that fails
#    each way and checks it reacts differently.
stub=$(mktemp -d)
printf '#!/bin/sh\necho "src/mnl.c:66: Unable to initialize Netlink socket: Protocol not supported" >&2\nexit 1\n' > "$stub/nft"
printf '#!/bin/sh\necho "x.nft:12:3-8: Error: syntax error, unexpected string" >&2\nexit 1\n' > "$stub/nft-bad"
chmod +x "$stub/nft" "$stub/nft-bad"

out=$(PATH="$stub:$PATH" ./bin/null-system firewall 2>&1)
if printf '%s' "$out" | grep -q 'cannot validate here'; then
  note "ok    a chroot with no netlink is reported as unverifiable, not as a bad ruleset"
else
  note "bin/null-system: a netlink failure is treated as a parse error -- %post will fall back to firewalld"
  fail=1
fi

cp "$stub/nft-bad" "$stub/nft"
out=$(PATH="$stub:$PATH" ./bin/null-system firewall 2>&1); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'does not parse'; then
  note "ok    a real syntax error still refuses"
else
  note "bin/null-system: a syntax error in the ruleset no longer refuses (exit $rc)"
  fail=1
fi
rm -rf "$stub"

[ $fail = 0 ] && echo "the firewall is default-deny, installed, and has a fallback"
exit $fail
