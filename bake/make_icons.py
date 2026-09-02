#!/usr/bin/env python3
"""Generate an icon theme from the palette (NULL.md §8.11).

Icons are demanded by applications this desktop would rather not have them in,
so the theme is GENERATED rather than chosen, by three rules in order:

1. SUBSTITUTE THE EXACT COLOURS, not the nearest ones. An icon set is a small
   number of shapes in a small number of exact colours. Finding those colours
   and swapping them is how the hued ones -- the folder blue, the warning
   amber -- land on the palette colour that MEANS the same thing. Picking the
   nearest shipped colour instead is how a desktop ends up with one element
   that is *almost* right, which reads worse than something plainly different.

2. ASK WHAT IS LEFT. After the substitutions, enumerate the colours still in
   the output. Anything not in the palette is a substitution that was missed,
   and the report says so rather than leaving it to be noticed on screen.

3. RECOLOUR THE REST BY LUMINANCE. Keep each colour's lightness, take its hue
   away, quantise onto the palette. One rule handles seven hundred files where
   a lookup table handles none.

Written into the user's own icon directory: no root, and it survives an update
of the set it derives from.
"""

import argparse
import colorsys
import json
import re
import shutil
import struct
from collections import Counter
from pathlib import Path

HEX = re.compile(r"#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b")


def load_palette(pal_bin, pal_json):
    raw = Path(pal_bin).read_bytes()
    entries = [struct.unpack_from("BBB", raw, i * 3) for i in range(len(raw) // 3)]
    roles = {k: v["hex"] for k, v in json.loads(Path(pal_json).read_text())["roles"].items()}
    return entries, roles


def rgb(h):
    h = h.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def hexs(t):
    return "#%02x%02x%02x" % t


def luma(c):
    # Relative luminance on linearised channels: the perceptual lightness that
    # must survive the recolouring, not the arithmetic mean of the bytes.
    def lin(v):
        v /= 255.0
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = c
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


def chroma(c):
    return colorsys.rgb_to_hls(*[v / 255 for v in c])[2]


class Quantiser:
    """Nearest luminance; among equals, the least saturated.

    "Take its hue away" is the instruction, so hue is not a term in the
    distance at all -- it is discarded, and the tie is broken towards the
    flattest candidate at that lightness.
    """

    def __init__(self, entries):
        self.table = [(luma(e), chroma(e), e) for e in entries]
        self.cache = {}

    def __call__(self, c):
        if c in self.cache:
            return self.cache[c]
        target = luma(c)
        best = min(self.table, key=lambda t: (round(abs(t[0] - target), 4), t[1]))
        self.cache[c] = best[2]
        return best[2]


def build_substitutions(roles):
    """The exact colours, mapped by what they MEAN.

    These are the hued ones -- the set's brand blues, and its semantic amber
    and red. Greys carry no meaning to preserve and are left to the luminance
    rule, which handles them better than any table would.
    """
    a, hi, w, e, n = (roles["accent"], roles["highlight"], roles["warning"],
                      roles["error"], roles["neutral"])
    return {
        # the folder / selection blues, light to dark
        "#afd4ff": hi, "#a4caee": hi, "#c0d5ea": hi, "#c0c6d6": hi,
        "#99c1f1": a, "#62a0ea": a, "#438de6": a, "#3584e4": a,
        "#1c71d8": a, "#1a5fb4": roles["line"], "#919fba": a,
        # semantic
        "#f6d32d": w, "#f8e45c": w, "#e5a50a": w, "#ff7800": w,
        "#e01b24": e, "#c01c28": e, "#f66151": e,
        "#33d17a": n, "#2ec27e": n, "#26a269": n,
    }


def recolour_text(s, subs, quant, seen):
    def repl(m):
        h = "#" + m.group(1).lower()
        c = rgb(h)
        seen[h] += 1
        if h in subs:
            return subs[h]
        return hexs(quant(c))
    return HEX.sub(repl, s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default="/usr/share/icons/Adwaita")
    ap.add_argument("--out", default=str(Path.home() / ".local/share/icons/nulllinux"))
    ap.add_argument("--palette-bin", default="assets/palette.bin")
    ap.add_argument("--palette-json", default="assets/palette.json")
    args = ap.parse_args()

    entries, roles = load_palette(args.palette_bin, args.palette_json)
    quant = Quantiser(entries)
    subs = {k: v for k, v in build_substitutions(roles).items()}
    palette_hexes = {hexs(e) for e in entries} | {v.lower() for v in roles.values()}

    src, out = Path(args.source), Path(args.out)
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)

    seen = Counter()
    n_svg = n_png = 0

    for f in src.rglob("*"):
        if f.is_dir() or "cursors" in f.parts:
            continue
        rel = f.relative_to(src)
        dst = out / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        if f.suffix == ".svg":
            dst.write_text(recolour_text(f.read_text(errors="replace"), subs, quant, seen))
            n_svg += 1
        elif f.suffix == ".png":
            from PIL import Image
            im = Image.open(f).convert("RGBA")
            px = im.load()
            w, h = im.size
            for y in range(h):
                for x in range(w):
                    r, g, b, al = px[x, y]
                    if al == 0:
                        continue
                    hx = hexs((r, g, b))
                    seen[hx] += 1
                    nr, ng, nb = rgb(subs[hx]) if hx in subs else quant((r, g, b))
                    px[x, y] = (nr, ng, nb, al)
            im.save(dst)
            n_png += 1
        elif f.name == "index.theme":
            t = f.read_text(errors="replace")
            t = re.sub(r"^Name=.*$", "Name=nullLinux", t, count=1, flags=re.M)
            t = re.sub(r"^Inherits=.*$", "Inherits=Adwaita,hicolor", t, count=1, flags=re.M)
            if "Inherits=" not in t:
                t = t.replace("Name=nullLinux", "Name=nullLinux\nInherits=Adwaita,hicolor", 1)
            dst.write_text(t)

    # Rule 2: ask what is left. Every colour that reached the output is either
    # a substitution target or a palette entry; anything else is a miss.
    produced = set()
    for f in out.rglob("*.svg"):
        produced |= {"#" + m.group(1).lower() for m in HEX.finditer(f.read_text(errors="replace"))}
    stray = sorted(c for c in produced if c not in palette_hexes)

    print(f"  source      {src}")
    print(f"  written     {out}")
    print(f"  svg {n_svg}, png {n_png}")
    print(f"  distinct source colours: {len(seen)}")
    print(f"  exact substitutions applied: "
          f"{sum(v for k, v in seen.items() if k in subs)} occurrences over "
          f"{sum(1 for k in seen if k in subs)} colours")
    if stray:
        print(f"  REMAINDER NOT IN PALETTE: {len(stray)}")
        for c in stray[:12]:
            print(f"    {c}")
    else:
        print("  remainder not in palette: 0")
    return 1 if stray else 0


if __name__ == "__main__":
    raise SystemExit(main())
