#!/usr/bin/env bash
# Every installer that writes system-wide files must refuse to take over a
# machine that already runs a different installation. See bin/null-install.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf "  %s\n" "$*"; }
if ! grep -q 'NULL_REPLACE' bin/null-install; then
  echo "bin/null-install: no takeover guard -- it would silently replace another installation"
  fail=1
fi
# the guard has to come before anything is written
# ANCHOR BOTH ENDS ON CODE.
#
# 'NULL_REPLACE' matched the COMMENT 24 lines above the guard, and the write
# regex missed every heredoc -- `cat > /etc/sway/config <<EOF` among them -- so
# it compared a comment at line 77 against a write at line 337 and left 220
# lines of slack. The guard could have been moved to after /etc/sway/config was
# already overwritten and this would still have passed.
guard=$(grep -n 'NULL_REPLACE:-0' bin/null-install | head -1 | cut -d: -f1)
first_write=$(grep -nE '^\s*(install_|write_|ln -sf|cp .*/etc/|cat >+ *"?/etc/|mkdir -p /etc/)' bin/null-install | head -1 | cut -d: -f1)
if [ -n "$guard" ] && [ -n "$first_write" ] && [ "$guard" -gt "$first_write" ]; then
  echo "bin/null-install: the takeover guard is at line $guard, after the first write at line $first_write"
  fail=1
fi
# THE GUARD HAS TO SEE THE INCLUDE THAT MATTERS.
#
# It took `head -1`, and Fedora's stock sway config opens with
# `include /etc/sway/config.d/*` -- not a checkout, so the guard passed and
# overwrote the installation named on the next line. Disarmed by a line that
# was already there. These fixtures are the shapes a real /etc/sway/config
# takes; the logic below is the guard's, extracted so it can be driven without
# touching /etc.
scan() {  # <file> <ROOT> -> the other checkout, or empty
  local ROOT=$2 other_root="" inc cand
  while read -r inc; do
    inc=${inc#\"}; inc=${inc%\"}
    inc=${inc#\'}; inc=${inc%\'}
    case $inc in */config/sway/config) ;; *) continue ;; esac
    cand=${inc%/config/sway/config}
    [ -n "$cand" ] && [ "$cand" != "$ROOT" ] && [ -d "$cand" ] || continue
    other_root=$cand; break
  done <<EOF
$(grep -oE '^[[:space:]]*include[[:space:]]+\S+' "$1" 2>/dev/null | awk '{print $2}')
EOF
  printf '%s' "$other_root"
}

# The extracted logic must still BE the guard's. If bin/null-install's version
# drifts, this check keeps passing while the real thing is broken.
for token in 'inc=${inc#\"}' 'case $inc in */config/sway/config)' 'other_root=$cand'; do
  grep -qF "$token" bin/null-install \
    || { note "verify and bin/null-install have drifted: '$token' is not in null-install"; fail=1; }
done

# THE TOKENS ARE ALL INSIDE THE LOOP BODY. The regression this file exists for
# -- putting `| head -1` back on the include extraction -- lives OUTSIDE it, so
# every token would still match, all eight fixtures would still pass, and the
# suite would print its reassuring line over a guard that Fedora's stock
# `include /etc/sway/config.d/*` had already disarmed.
if sed -n '/if \[ -r \/etc\/sway\/config \]/,/^fi$/p' bin/null-install | grep -q 'head -'; then
  note "bin/null-install: the include scan is truncated by head -- the stock first include disarms the guard"
  fail=1
fi

t=$(mktemp -d)
other=$(mktemp -d)/rootA; mkdir -p "$other"
case_() {  # <description> <config text> <expected: other|none>
  printf '%b' "$2" > "$t/c"
  got=$(scan "$t/c" /opt/nulllinux)
  want=""; [ "$3" = other ] && want="$other"
  if [ "$got" = "$want" ]; then note "ok    $1"
  else note "$1: expected '${want:-<none>}', got '${got:-<none>}'"; fail=1; fi
}
case_ "a plain include of another checkout is caught"        "include $other/config/sway/config\n" other
case_ "an earlier stock include does not disarm the guard"   "include /etc/sway/config.d/*\ninclude $other/config/sway/config\n" other
case_ "a quoted include is caught"                           "include \"$other/config/sway/config\"\n" other
case_ "a single-quoted include is caught"                    "include '$other/config/sway/config'\n" other
case_ "extra whitespace does not hide it"                    "   include    $other/config/sway/config\n" other
case_ "our own checkout is not a takeover"                   "include /opt/nulllinux/config/sway/config\n" none
case_ "a checkout that no longer exists is not a takeover"   "include /opt/definitely-gone/config/sway/config\n" none
case_ "a commented-out include is ignored"                   "# include $other/config/sway/config\n" none
rm -rf "$t" "$(dirname "$other")"

[ $fail = 0 ] && echo "installers refuse to take over a machine running something else"
exit $fail
