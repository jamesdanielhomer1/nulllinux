#!/usr/bin/env bash
# ONE TYPEFACE (NULL.md §2.2, I2).
#
# Terminus, at two strikes and no third grid. That is not a preference: the
# whole system is a grid of cells, every surface is sized in cells, and a
# second family — especially a proportional one — means a surface whose
# columns do not line up with any other surface's.
#
# It is broken the same way the palette is: not by anyone deciding to, but by a
# default left in place. Found by reading, in one evening:
#
#   system/plymouth-theme/nullLinux.plymouth   Font=Cantarell 12
#                                              TitleFont=Cantarell Light 30
#
# and — the part that matters — bake/make_boot_assets.py, which WRITES that
# file, said Cantarell too. Fixing the output alone would have lasted until the
# next bake. Exactly the shape of the gtk-theme-name bug found the same night,
# so this checks generators as well as their products.
#
# WHAT THIS RULE IS NOT ABOUT: fonts for CONTENT. Liberation and Noto are
# declared packages here, and that is not a violation -- §8.10 puts application
# interiors and their content on a different tier from the system's own
# surfaces. A document somebody sends you is in Times New Roman whether this
# system approves or not, and rendering it in Terminus would not be consistency,
# it would be reflowing somebody else's page. The rule is about what nullLinux
# DRAWS; it has no opinion about what nullLinux is asked to display.
#
# So this reads font DECLARATIONS in configuration, not the package list. Every
# one of those still says Terminus.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

# Families that may legitimately appear. Terminus is the typeface; the rest are
# generic CSS/fontconfig keywords that resolve THROUGH fontconfig to Terminus,
# and 'emoji' appears only where something is being switched OFF.
ALLOWED='Terminus|monospace|sans-serif|serif|inherit|initial|unset|none'

# CONFIGURATION ONLY, not code.
#
# The first version searched bake/*.py and bin/* too and reported six false
# positives -- `font = Font(args.font)`, `font-family: {FONT}`,
# `font="$strike.psf.gz"` -- which are variable assignments and paths, not
# declarations of a typeface. A check that cries wolf six times is a check
# people stop reading. Generators are handled separately below, by looking for
# the literal lines they emit.
# assets/prebuilt IS SCANNED, because it is what actually ships.
#
# This read `config system` and nothing else. system/plymouth-theme was fixed
# to say Terminus; assets/prebuilt/boot/plymouth-theme, which is the copy the
# RPM carries and an installed machine boots, still said
#
#     Font=Cantarell 12
#     TitleFont=Cantarell Light 30
#
# The two directories are otherwise byte-identical -- every throbber frame
# matches -- so the prebuilt set was simply generated before the fix and never
# regenerated. The check verified the SOURCE and never the ARTEFACT, which is
# the difference between a system that is correct and one that ships correct.
#
# Found by asking an installed guest what its splash declared, not by reading
# this tree.
FILES=$(find config system assets/prebuilt -type f \
        \( -name '*.ini' -o -name '*.conf' -o -name '*.css' -o -name '*.qml' \
           -o -name '*.plymouth' -o -name 'dunstrc' -o -name 'zathurarc' \
           -o -name 'config' \) 2>/dev/null)

# The declarations this system actually uses, by key. Anything matching these
# and NOT naming an allowed family is a second typeface.
for f in $FILES; do
  while IFS= read -r hit; do
    line=${hit#*:}
    # A comment naming a font is prose, not a declaration.
    case ${line#"${line%%[![:space:]]*}"} in \#*|//*|--*) continue ;; esac
    printf '%s\n' "$line" | grep -qE "$ALLOWED" && continue
    # A value that is a variable, a path or a substitution is not a typeface
    # name -- it is code that resolves to one somewhere else.
    value=${line#*[:=]}
    case ${value#"${value%%[![:space:]]*}"} in
      ''|'$'*|'{'*|'('*|/*|'"'/*|"'"/*|'%'*|'@'*) continue ;;
    esac
    note "$f: $line"
    fail=1
  done < <(grep -nE '^[[:space:]]*(font|Font|TitleFont|font-name|gtk-font-name|font-family|font-bold|font-italic|font-bold-italic|osd-font|sub-font|overlay_font|gtk-font|monospace-font-name|document-font-name)[[:space:]]*[:=]' "$f" 2>/dev/null)
done

if [ $fail = 1 ]; then
  note ""
  note "Each line above names a typeface that is not Terminus. If one is"
  note "genuinely required, add it to ALLOWED here with the reason -- the"
  note "pointer theme is the precedent for a recorded exception (§8.11)."
else
  note "ok    every font declaration names Terminus or a generic that resolves to it"
fi

# THE GENERATORS, SEPARATELY. A generated file can be correct while the thing
# that writes it is not, and the next bake silently undoes the fix.
for gen in bake/make_boot_assets.py bake/export_theme.py; do
  [ -r "$gen" ] || continue
  bad=$(grep -nE '^[A-Za-z]*Font=|font-name=|font-family:' "$gen" 2>/dev/null | grep -vE "$ALLOWED" || true)
  if [ -n "$bad" ]; then
    note "$gen writes a font that is not Terminus:"
    printf '%s\n' "$bad" | sed 's/^/      /'
    fail=1
  else
    note "ok    $gen writes Terminus"
  fi
done

[ $fail = 0 ] && echo "PASS: one typeface, in the files and in what generates them"
exit $fail
