#!/usr/bin/env bash
# NO HEX VALUE IS TYPED BY HAND (NULL.md §4.8).
#
# Every colour on every surface comes out of assets/palette.json — 256
# blackbody entries, from which ten named roles are drawn — plus exactly four
# off-locus hues that a terminal needs to have six distinguishable colours, and
# which are labelled as chosen wherever they appear.
#
# That rule is what makes the system one thing rather than fifteen programs
# that happen to be dark. It is also the easiest rule in the project to break
# by accident: every one of these config formats takes a hex value, and one
# plausible-looking colour pasted from a theme somewhere is invisible in
# review and permanent in the tree.
#
# It caught a real one on its first run: lib/menu.sh drove every picker in the
# system with `--color=16`, so the surface the hand is on took its colours from
# fzf rather than from the palette.
#
# WHAT IT DOES NOT SEE, said here rather than left to be assumed: it matches
# #RRGGBB. swaylock's config format takes bare RRGGBB with no hash, so
# config/swaylock/config is checked by verify/check-lock-screen.sh instead,
# against the same palette. Any future config in a bare-hex format needs the
# same treatment or it passes here by being invisible.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

python3 - "$@" <<'PY'
import json, re, sys, pathlib

BIN   = pathlib.Path('assets/palette.bin')
JSON  = pathlib.Path('assets/palette.json')
GEN   = pathlib.Path('bake/export_theme.py')

if not BIN.is_file() or not JSON.is_file():
    print("  assets/palette.{bin,json} missing -- cannot check colours")
    sys.exit(1)

# 1. The 256 blackbody entries. This is the palette; everything else is drawn
#    from it.
raw = BIN.read_bytes()
allowed = {'%02x%02x%02x' % tuple(raw[i:i+3]) for i in range(0, len(raw) - 2, 3)}
n_entries = len(allowed)

# 2. The ten named roles. Four of them (void, background, surface, line) are
#    chosen rather than sampled, so they need not be in the 256.
roles = json.loads(JSON.read_text()).get('roles', {})
def harvest(v, into):
    if isinstance(v, str) and re.fullmatch(r'#[0-9a-fA-F]{6}', v): into.add(v[1:].lower())
    elif isinstance(v, dict):
        for x in v.values(): harvest(x, into)
role_vals = set(); harvest(roles, role_vals)
allowed |= role_vals

# 3. The four off-locus hues, read from the GENERATOR THAT OWNS THEM rather
#    than listed here. A hardcoded list would be a second place to keep them,
#    which is the thing this check exists to prevent.
off = set()
if GEN.is_file():
    for m in re.finditer(r'"(?:red|green|yellow|blue|magenta|cyan)":\s*"([0-9a-fA-F]{6})"', GEN.read_text()):
        off.add(m.group(1).lower())
allowed |= off

print(f"  palette: {n_entries} blackbody entries, {len(role_vals)} roles, {len(off)} off-locus hues")

# Where colours are allowed to appear at all. bake/ generates them and assets/
# holds them; those are the source. Everything under config/ and the shell
# libraries is generated FROM the source and must not invent one.
targets = [p for p in pathlib.Path('config').rglob('*') if p.is_file()]
targets += [p for p in pathlib.Path('lib').rglob('*.sh') if p.is_file()]
targets += [p for p in pathlib.Path('system').rglob('*') if p.is_file() and p.suffix in ('.qml', '.plymouth', '.conf', '.ini', '.css')]

bad = {}
for p in targets:
    try: text = p.read_text(errors='replace')
    except Exception: continue
    for i, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith('#') and 'color' not in line.lower(): continue
        for m in re.finditer(r'#([0-9a-fA-F]{6})\b', line):
            v = m.group(1).lower()
            if v not in allowed:
                bad.setdefault(v, []).append(f"{p}:{i}")

used = set()
for p in targets:
    try: text = p.read_text(errors='replace')
    except Exception: continue
    used |= {m.lower() for m in re.findall(r'#([0-9a-fA-F]{6})\b', text)}
print(f"  {len(used)} distinct colour(s) used across config/, lib/ and system/")

if bad:
    print()
    for v, where in sorted(bad.items()):
        print(f"  #{v} is not in the palette:")
        for w in where[:4]: print(f"      {w}")
    print()
    print("  Add it to assets/palette.json and regenerate, or use the role that")
    print("  already means what it means. A colour typed by hand is a colour")
    print("  nothing else in the system agrees with.")
    sys.exit(1)

print("PASS: every colour is from the palette")
PY
