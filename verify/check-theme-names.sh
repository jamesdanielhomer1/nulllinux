#!/usr/bin/env bash
# One spelling per theme, everywhere (NULL.md §8.10).
#
# GTK looks a theme up by its DIRECTORY NAME -- in /usr/share/themes for the
# GTK theme, /usr/share/icons for the icon theme -- and the lookup is
# case-sensitive. A name that does not resolve does not error: GTK falls back
# to its own default and says nothing.
#
# BOTH of this project's themes were broken this way, independently, and for
# the whole life of the project:
#
#   icons  installed to  nulllinux, the settings key said nullLinux, and both
#          settings.ini files said Adwaita -- three answers.
#   gtk    installed to  nulllinux, the settings key said nullLinux, and both
#          settings.ini files said Default -- three answers again, so the
#          stylesheet that themes the file manager and every menu was loaded
#          by nothing.
#
# Neither was noticed because bin/null-toolkit -- the one thing that checks a
# name against the disk before writing it -- had no caller, and because the
# settings.ini files were installed NOWHERE, so a third contradictory answer
# sat in the tree with no consequence at all.
#
# So this compares every place a theme is named, structurally, needing no
# installed system. The directory null-install creates is the authority,
# because that is the name GTK will look for.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
cd "$ROOT"
fail=0

check_theme() {  # <label> <install-dir-prefix> <settings.ini key> <dconf key> <null-toolkit var>
  local label=$1 prefix=$2 inikey=$3 dconfkey=$4 tkvar=$5
  echo "== $label"

  local dirs n want
  # Comments are stripped first. The comment in null-install that explains
  # this very bug names the OLD path, and flagging that would mean the fix
  # cannot be described where it happened.
  dirs=$(sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//' bin/null-install \
         | grep -oE "$prefix/[A-Za-z0-9._-]+" | sort -u)
  n=$(printf '%s\n' "$dirs" | grep -c .)
  if [ "$n" -ne 1 ]; then
    echo "  FAIL  bin/null-install installs $n different directories under $prefix:"
    printf '%s\n' "$dirs" | sed 's/^/          /'
    fail=1
  fi
  want=$(basename "$(printf '%s\n' "$dirs" | head -1)")
  printf '  %-38s %s\n' "directory null-install creates" "$want"

  same() {
    printf '  %-38s %s' "$1" "${2:-(unset)}"
    if [ "${2:-}" = "$want" ]; then echo; else echo "   <- not '$want'"; fail=1; fi
  }
  same "dconf default (null-install)" "$(grep -oP "^$dconfkey='\K[^']+" bin/null-install | head -1)"
  same "bin/null-toolkit $tkvar"      "$(grep -oP "^$tkvar=\K.*" bin/null-toolkit | head -1)"
  local f
  for f in config/gtk-3.0/settings.ini config/gtk-4.0/settings.ini; do
    same "$f" "$(grep -oP "^$inikey=\K.*" "$f" | head -1)"
  done
  echo
}

check_theme "the GTK theme"  "/usr/share/themes" gtk-theme-name  gtk-theme  GTK_THEME
check_theme "the icon theme" "/usr/share/icons"  gtk-icon-theme-name icon-theme ICON_THEME

# A settings.ini that is installed NOWHERE is how the third answer hid: it can
# say anything, for years, and nothing reads it. If it is worth keeping in the
# tree it is worth installing.
echo "== settings.ini reaches the machine"
if grep -q 'etc/xdg/gtk-\$v/settings.ini' bin/null-install; then
  echo "  ok    null-install installs /etc/xdg/gtk-{3.0,4.0}/settings.ini"
else
  echo "  FAIL  config/gtk-*/settings.ini is installed nowhere -- it can say"
  echo "        anything and nothing will read it, which is how this broke"
  fail=1
fi

echo
if [ $fail = 0 ]; then
  echo "PASS: every theme has one name, and every place that names it agrees"
else
  echo "FAIL: a name that does not resolve falls back silently; they must agree"
fi
exit $fail
