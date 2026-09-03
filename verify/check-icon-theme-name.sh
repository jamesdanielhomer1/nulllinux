#!/usr/bin/env bash
# One spelling of the icon theme, everywhere (NULL.md §8.10).
#
# GTK resolves gtk-icon-theme-name against the DIRECTORY NAME in
# /usr/share/icons -- not against the Name= field inside index.theme -- and the
# lookup is case-sensitive. A name that does not resolve does not error: GTK
# falls back to its default icon set and says nothing.
#
# This project had THREE answers at once. null-install created
# /usr/share/icons/nulllinux, the dconf default said 'nullLinux', and both
# settings.ini files said 'Adwaita'. The result was that the icon theme this
# system bakes from its own asset was used by nothing, on every machine, and
# the only reason it surfaced is that bin/null-toolkit checks a name against
# the disk before writing it -- and null-toolkit had no caller.
#
# So this compares the four places structurally, with no installed system
# needed, and it is the directory name that all of them must equal.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
cd "$ROOT"
fail=0

# The name null-install actually creates -- the authority, since it is the
# directory GTK will look for.
dir=$(grep -oE '/usr/share/icons/[A-Za-z0-9._-]+' bin/null-install | sort -u)
n=$(printf '%s\n' "$dir" | grep -c .)
if [ "$n" -ne 1 ]; then
  echo "  FAIL  bin/null-install installs $n different icon directories:"
  printf '%s\n' "$dir" | sed 's/^/          /'
  fail=1
fi
want=$(basename "$(printf '%s\n' "$dir" | head -1)")
printf '  %-34s %s\n' "directory null-install creates" "$want"

same() { # <label> <value>
  printf '  %-34s %s' "$1" "$2"
  if [ "$2" = "$want" ]; then echo; else echo "   <- does not match '$want'"; fail=1; fi
}

same "dconf default (null-install)"  "$(grep -oP "^icon-theme='\K[^']+" bin/null-install | head -1)"
same "bin/null-toolkit ICON_THEME"   "$(grep -oP '^ICON_THEME=\K.*' bin/null-toolkit | head -1)"
for f in config/gtk-3.0/settings.ini config/gtk-4.0/settings.ini; do
  same "$f" "$(grep -oP '^gtk-icon-theme-name=\K.*' "$f" | head -1)"
done

# The Name= inside index.theme is not what GTK looks up, but a theme whose
# internal name differs from its directory is confusing to every chooser that
# does read it -- so it is reported, and required to agree too.
idx=assets/prebuilt/theme/icons/index.theme
if [ -r "$idx" ]; then
  same "$idx Name=" "$(grep -oP '^Name=\K.*' "$idx" | head -1)"
else
  printf '  %-34s %s\n' "$idx" "(not built here; skipped)"
fi

echo
if [ $fail = 0 ]; then
  echo "PASS: the icon theme has one name -- $want"
else
  echo "FAIL: a name that does not resolve falls back silently; they must agree"
fi
exit $fail
