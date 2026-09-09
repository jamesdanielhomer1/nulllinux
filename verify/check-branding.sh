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
echo "== the version that brands is the version that ships (one source)"
# null-brand once hardcoded 0.1.0 while the ISO tools read the spec: each
# consistent with itself, and with each other only until the first bump. The
# package's %post must hand null-brand the version it is installing; and on a
# machine where the package is not installed -- this checkout -- null-brand
# must resolve the spec's number, not a copy of its own.
grep -q 'NULL_VERSION=%{version}.*null-brand apply' "$ROOT/packaging/nulllinux.spec" \
  && ok "the package's %post passes its own version to null-brand" \
  || bad "the package's %post does not pass %{version} to null-brand -- an installed system can brand with a stale version"
resolved=$("$ROOT/bin/null-brand" version 2>/dev/null || true)
from=$("$ROOT/bin/null-brand" report 2>/dev/null | sed -n 's/^ *version *[^(]*(\(.*\))$/\1/p')
if "$ROOT/bin/pkg" is-installed nulllinux >/dev/null 2>&1; then
  want=$("$ROOT/bin/pkg" installed-version nulllinux 2>/dev/null || true)
  want=${want#nulllinux-}; want=${want#*:}; want=${want%%-*}
  if [ -n "$resolved" ] && [ "$resolved" = "$want" ]; then
    ok "null-brand resolves the installed package's version ($resolved, from ${from:-?})"
  else
    bad "null-brand resolves '${resolved:-nothing}' but the installed package is ${want:-?}"
  fi
elif command -v rpmspec >/dev/null 2>&1; then
  want=$(rpmspec -q --qf '%{version}\n' "$ROOT/packaging/nulllinux.spec" 2>/dev/null | head -1)
  if [ -n "$resolved" ] && [ "$resolved" = "$want" ]; then
    ok "null-brand resolves the spec's version ($resolved, from ${from:-?})"
  else
    bad "null-brand resolves '${resolved:-nothing}' but packaging/nulllinux.spec says ${want:-?} (from ${from:-?})"
  fi
else
  ok "(no package installed and no rpmspec here; the version chain is not measured)"
fi

echo
[ $fail = 0 ] && echo "PASS: branding is safe" || echo "FAIL: branding is not safe"
exit $fail
