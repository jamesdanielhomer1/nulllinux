#!/usr/bin/env bash
# THE CONSOLE'S SIXTEEN COLOURS ARE OURS.
#
# Before the greeter appears, on every tty, and any time the desktop fails to
# start, the virtual console used the kernel's built-in palette -- the bright
# primaries every Linux machine has had since 1992 -- in a system whose entire
# colour set is a blackbody curve. The one surface guaranteed to be seen on
# every boot, and the only one still wearing somebody else's colours.
#
# The console and the terminal must agree. They are the same sixteen slots
# doing the same job a few inches apart, and a person who notices they differ
# is right to.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

VT=config/vconsole/vtrgb
FOOT=config/foot/foot.ini

[ -r "$VT" ]   || { note "$VT is gone -- the console keeps the kernel's colours"; exit 1; }
[ -r "$FOOT" ] || { note "$FOOT is gone"; exit 1; }

# 1. setvtrgb's format is exact: three lines of sixteen comma-separated
#    decimals, reds then greens then blues. A file it will not parse is a
#    console that silently keeps the old palette.
lines=$(grep -c . "$VT")
[ "$lines" = 3 ] || { note "$VT has $lines non-empty lines; setvtrgb needs exactly 3"; fail=1; }
n=1
while read -r row; do
  [ -n "$row" ] || continue
  count=$(printf '%s' "$row" | tr ',' '\n' | grep -c .)
  [ "$count" = 16 ] || { note "$VT line $n has $count values, not 16"; fail=1; }
  printf '%s' "$row" | tr ',' '\n' | while read -r v; do
    case $v in ''|*[!0-9]*) echo bad ;; *) [ "$v" -le 255 ] || echo bad ;; esac
  done | grep -q bad && { note "$VT line $n has a value that is not 0-255"; fail=1; }
  n=$((n + 1))
done < "$VT"

# 2. THE SAME SIXTEEN AS THE TERMINAL, slot for slot. Both are generated from
#    assets/palette.json by bake/export_theme.py; this is what catches one of
#    them being edited by hand afterwards.
python3 - "$VT" "$FOOT" <<'PY' || fail=1
import re, sys
vt, foot = sys.argv[1], sys.argv[2]
text = open(foot).read()
order = [f'regular{i}' for i in range(8)] + [f'bright{i}' for i in range(8)]
want = []
for k in order:
    m = re.search(rf'^{k}=([0-9a-fA-F]{{6}})', text, re.M)
    if not m:
        print(f"  {foot} has no {k}"); sys.exit(1)
    h = m.group(1)
    want.append((int(h[0:2],16), int(h[2:4],16), int(h[4:6],16)))
rows = [l.strip().split(',') for l in open(vt) if l.strip()]
if len(rows) != 3:
    print(f"  {vt}: expected 3 rows"); sys.exit(1)
bad = 0
for i, w in enumerate(want):
    got = tuple(int(rows[c][i]) for c in range(3))
    if got != w:
        print(f"  slot {i} ({order[i]}): terminal {w}, console {got}")
        bad = 1
sys.exit(bad)
PY
[ $fail = 0 ] && note "ok    all 16 console slots are identical to the terminal's"

# 3. THE GENERATOR OWNS IT. A hand-edited vtrgb survives until the next bake
#    and then silently reverts -- which is how the GTK theme name and the
#    plymouth font both went wrong.
grep -q 'config/vconsole/vtrgb' bake/export_theme.py \
  || { note "bake/export_theme.py does not write $VT -- it would be lost on the next bake"; fail=1; }

# 4. IT HAS TO BE SET WHERE EVERY CONSOLE WILL SEE IT.
#
#    setvtrgb changes the console it is handed, and each virtual console takes
#    its palette from the KERNEL DEFAULTS when it is allocated -- so a tty
#    somebody switches to later is created with the old colours. A unit running
#    setvtrgb at boot reported success and changed nothing anyone would go on
#    to look at; the screenshot proved it. vt.default_red/grn/blu set the
#    defaults themselves, from the first console the kernel makes.
grep -q 'vt.default_red' bin/null-install \
  || { note "bin/null-install does not set vt.default_red -- consoles allocated later keep the kernel's colours"; fail=1; }
grep -q 'grubby --info=DEFAULT' bin/null-install \
  || { note "bin/null-install sets the argument without checking it landed -- grubby exits 0 on a good deal more than it should"; fail=1; }
# A REAL INVOCATION, NOT PROSE. The first version of this grep matched the
# `say` line in null-install that EXPLAINS why setvtrgb is not used -- the
# fourth time tonight a check has been fooled by a comment. Comment lines and
# say/echo strings are stripped before looking.
if sed -e 's/[[:space:]]*#.*//' -e 's/^[[:space:]]*\(say\|echo\)[[:space:]].*//' bin/null-install \
   | grep -qE '(^|[;&|(]|[[:space:]])setvtrgb[[:space:]]'; then
  note "bin/null-install runs setvtrgb, which only affects consoles that already exist"
  fail=1
else
  note "ok    the palette is set on the kernel command line, where every console sees it"
fi

# 5. THE FONT STAYS OPT-IN. A console font over 256 glyphs loses bright
#    backgrounds (§9.5), so it is a deliberate `null-system tty` and must not
#    be quietly folded into the install alongside the colours.
grep -q 'consolefonts' bin/null-install \
  && { note "bin/null-install now sets a console FONT -- that is the risky half and belongs in null-system tty"; fail=1; }

[ $fail = 0 ] && echo "PASS: the console wears this system's colours, and the terminal agrees"
exit $fail
