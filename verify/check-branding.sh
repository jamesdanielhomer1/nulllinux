#!/usr/bin/env bash
# Branding must not break the system it brands.
#
# The first attempt at this wrote "> /etc/os-release", which is a symlink into
# /usr/lib/os-release, so it silently rewrote a file owned by
# fedora-release-identity-basic; and it set ID=nulllinux, which made bin/pkg
# look for packages/nulllinux/ and fail on every branded machine.  Both are
# checked here against fixtures, so neither can come back.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
fail=0
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }

echo "== branding does not break package selection (§9.1)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf 'NAME="nullLinux"\nID=nulllinux\nID_LIKE=fedora\n' > "$tmp/branded"
printf 'NAME="Fedora Linux"\nID=fedora\n'                 > "$tmp/plain"

plain=$(NULL_OS_RELEASE="$tmp/plain"   "$ROOT/bin/pkg" list-packages base 2>/dev/null | wc -l)
brand=$(NULL_OS_RELEASE="$tmp/branded" "$ROOT/bin/pkg" list-packages base 2>/dev/null | wc -l)
[ "$plain" -gt 0 ] || bad "unbranded resolves no packages at all"
if [ "$plain" = "$brand" ]; then
  ok "branded and unbranded both resolve $plain packages"
else
  bad "branding changes the package list: $plain unbranded, $brand branded"
fi

echo
echo "== branding never writes through the /etc/os-release symlink"
# The link target belongs to the distribution.  Assert the tool replaces the
# link rather than following it -- statically, since running apply needs root.
if grep -q 'rm -f /etc/os-release' "$ROOT/bin/null-brand" &&
   grep -qB2 'cat > /etc/os-release' "$ROOT/bin/null-brand"; then
  ok "null-brand removes the symlink before writing"
else
  bad "null-brand may write through the symlink into /usr/lib"
fi
if grep -rn '> */etc/os-release' "$ROOT/packaging"/*.ks 2>/dev/null | grep -v null-brand; then
  bad "a kickstart writes /etc/os-release directly instead of using null-brand"
else
  ok "no kickstart writes /etc/os-release directly"
fi

echo
echo "== null-brand reports without mutating (§8.4)"
before=$(readlink /etc/os-release 2>/dev/null; cat /etc/os-release 2>/dev/null | md5sum)
"$ROOT/bin/null-brand" report >/dev/null 2>&1
after=$(readlink /etc/os-release 2>/dev/null; cat /etc/os-release 2>/dev/null | md5sum)
[ "$before" = "$after" ] && ok "report left /etc/os-release untouched" \
                         || bad "report CHANGED /etc/os-release"

echo
echo "== ID_LIKE is stated, so downstream tools still see fedora"
grep -q 'ID_LIKE=' "$ROOT/bin/null-brand" && ok "null-brand emits ID_LIKE" \
                                          || bad "null-brand omits ID_LIKE"

echo
[ $fail = 0 ] && echo "PASS: branding is safe" || echo "FAIL: branding is not safe"
exit $fail
