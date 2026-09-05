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
    inc && /^  \}/ {inc=0}
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

# 5. The module preload is what made it fast. Without it the ruleset still
#    loads, just back on the critical path -- so this is a warning, not a
#    failure, and it should say which.
[ -r config/modules-load.d/nulllinux-nftables.conf ] \
  || note "(config/modules-load.d/nulllinux-nftables.conf is gone -- still correct, 600ms slower)"

[ $fail = 0 ] && echo "the firewall is default-deny, installed, and has a fallback"
exit $fail
