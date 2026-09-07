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
  # Lines that REMOVE a superseded name are not lines that install one, and
  # null-install has to name the old spelling in order to delete it. Excluded
  # by the word `legacy`, and checked separately below that the only thing it
  # ever removes is the lowercase form of the current name -- so this exclusion
  # cannot be used to smuggle in a second install path.
  dirs=$(sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//' bin/null-install \
         | grep -v legacy \
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

echo "== what is removed as superseded is only the old spelling"
legacy_line=$(grep -n 'for legacy in' bin/null-install | head -1)
if [ -z "$legacy_line" ]; then
  echo "  (nothing is removed as superseded)"
else
  bad=0
  for d in $(printf '%s' "$legacy_line" | grep -oE '/usr/share/(themes|icons)/[A-Za-z0-9._-]+'); do
    base=$(basename "$d")
    want=$(printf '%s' "$base" | tr 'A-Z' 'a-z')
    # The current name lowercased -- nothing else may be deleted from a
    # directory full of other people's themes.
    if [ "$base" = "$want" ] && [ "$(printf 'nullLinux' | tr 'A-Z' 'a-z')" = "$base" ]; then
      echo "  ok    removes $d (the old lowercase spelling)"
    else
      echo "  FAIL  removes $d, which is not this project's superseded name"
      bad=1; fail=1
    fi
  done
  [ $bad = 0 ] || true
fi
echo

# A settings.ini that is installed NOWHERE is how the third answer hid: it can
# say anything, for years, and nothing reads it. If it is worth keeping in the
# tree it is worth installing.
# THE GREETER AND THE SPLASH, which were the third and fourth surfaces to get
# this wrong. sddm looks its theme up by DIRECTORY NAME and plymouth resolves
# <name> to themes/<name>/<name>.plymouth -- so the directory, the file and the
# call all have to agree. They did not: the greeter installed to
# themes/nulllinux while Current= said nullLinux, so sddm fell back to its own
# default and a machine booting to the wrong login screen looks exactly like a
# machine booting to the right one.
. lib/source.sh
echo "== the greeter and the splash agree with themselves"
gr_dir=$(grep -oE '/usr/share/sddm/themes/[A-Za-z0-9._-]+' bin/null-system \
         | grep -v nulllinux | sort -u | head -1)
gr_sel=$(grep -oP 'Current=\K[A-Za-z0-9._-]+' bin/null-system | head -1)
# THE THEME'S OWN DIRECTORY, not the first themes/ path in the file.
#
# This took the alphabetically first /usr/share/plymouth/themes/<x> string that
# was not `nulllinux`. bin/null-system then gained a SECOND such path -- a
# `default.plymouth` symlink, because that is what dracut resolves the theme
# through -- and `default.plymouth` sorts before `nullLinux`, so this check
# began reporting that the theme directory was called "default.plymouth" and
# that all four of the places naming it disagreed. Four false failures from one
# correct line.
#
# The directory is the one with a matching .plymouth file inside it, which is
# what plymouth itself requires, so that is what is looked for.
pl_dir=$(null_code_only bin/null-system \
         | grep -oE '/usr/share/plymouth/themes/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.plymouth' \
         | sed 's|/[^/]*\.plymouth$||' | grep -v nulllinux | sort -u | head -1)
[ -n "$pl_dir" ] || pl_dir=$(null_code_only bin/null-system \
         | grep -oE '/usr/share/plymouth/themes/[A-Za-z0-9._-]+' \
         | grep -vE 'nulllinux|\.plymouth$' | sort -u | head -1)
# THE COMMAND, not every mention of it. null-system names this tool five
# times: a `command -v` guard, a reporting line whose `2>/dev/null` a loose
# pattern read as a theme called "2", two comments, and one actual invocation.
# Comments and `say` lines are stripped, and what is left must be a bare call.
pl_set=$(sed -e 's/[[:space:]]#.*$//' -e '/^[[:space:]]*#/d' -e '/say /d' bin/null-system \
         | grep -oP '^\s*plymouth-set-default-theme \K[A-Za-z][A-Za-z0-9._-]*' | head -1)
pl_file=$(grep -oP 'outdir / "\K[A-Za-z0-9._-]+(?=\.plymouth")' bake/make_boot_assets.py | head -1)
pl_img=$(grep -oP 'ImageDir=/usr/share/plymouth/themes/\K[A-Za-z0-9._-]+' bake/make_boot_assets.py | head -1)

same2() {  # <label> <value> <want>
  printf '  %-38s %s' "$1" "${2:-(unset)}"
  if [ "${2:-}" = "$3" ]; then echo; else echo "   <- not '$3'"; fail=1; fi
}
want_gr=$(basename "${gr_dir:-none}")
printf '  %-38s %s\n' "sddm theme directory" "$want_gr"
same2 "sddm Current=" "$gr_sel" "$want_gr"

want_pl=$(basename "${pl_dir:-none}")
printf '  %-38s %s\n' "plymouth theme directory" "$want_pl"
same2 "plymouth-set-default-theme" "$pl_set" "$want_pl"
same2 "the .plymouth file's name" "$pl_file" "$want_pl"
same2 "ImageDir inside it" "$pl_img" "$want_pl"
echo

echo "== settings.ini reaches the machine"
if grep -q 'etc/xdg/gtk-\$v/settings.ini' bin/null-install; then
  echo "  ok    null-install installs /etc/xdg/gtk-{3.0,4.0}/settings.ini"
else
  echo "  FAIL  config/gtk-*/settings.ini is installed nowhere -- it can say"
  echo "        anything and nothing will read it, which is how this broke"
  fail=1
fi

echo
# THE GENERATOR THAT OWNS THESE FILES MUST AGREE WITH THEM.
#
# bake/export_theme.py OVERWRITES config/gtk-{3.0,4.0}/settings.ini, and it
# wrote gtk-theme-name=Default while the committed files said nullLinux. This
# check only ever inspected the output, so it passed -- right up until somebody
# ran the bake, at which point GTK fell back to its built-in light palette with
# nothing said. Checking the file without checking what writes the file is how
# a check outlives the thing it was protecting.
for key in gtk-theme-name gtk-icon-theme-name; do
  gen=$(grep -oE "^$key=.*" bake/export_theme.py | head -1 | cut -d= -f2)
  com=$(grep -oE "^$key=.*" config/gtk-3.0/settings.ini | head -1 | cut -d= -f2)
  printf '  %-38s %s' "export_theme.py $key" "${gen:-(absent)}"
  if [ -z "$gen" ]; then
    printf "   <- the generator does not write it\n"; fail=1
  elif [ "$gen" = "$com" ]; then
    printf '\n'
  else
    printf "   <- committed settings.ini says '%s'\n" "$com"; fail=1
  fi
done

if [ $fail = 0 ]; then
  echo "PASS: every theme has one name, and every place that names it agrees"
else
  echo "FAIL: a name that does not resolve falls back silently; they must agree"
fi
exit $fail
