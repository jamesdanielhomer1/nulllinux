#!/usr/bin/env python3
"""Bake a glyph atlas from a PSF2 strike (NULL.md §6.2).

Bake EVERY codepoint the font defines, not a hand-listed set of the characters
this system's own chrome happens to draw. That is the correct set for a surface
whose content you write, and the wrong set for a surface that hosts somebody
else's program. Baking everything costs a few kilobytes and removes an entire
class of defect.

The atlas is keyed by the same font hash the ramp is (§2.4), so a font change
invalidates both together rather than leaving them disagreeing.

A REQUIRED list is still enforced: baking everything must not mean that a
glyph the chrome depends on goes missing and is discovered as a hole on screen.
"""

import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fontlib import Font

ATLAS_MAGIC = b"RATL"
VERSION = 1

# Glyphs the chrome cannot do without. Box drawing for frames (§7.1), the
# dotted track for meters, and the markers. If any is missing the bake FAILS
# rather than quietly producing a hole.
REQUIRED = (
    [chr(c) for c in range(0x20, 0x7F)] +
    list("─│┌┐└┘├┤┬┴┼")   # frames are box-drawing, square corners for persistent surfaces
    + list("·•")           # the empty meter track is a dot, not a space: a space has no extent
    + list("←→↑↓")
)


def bake(font, required=REQUIRED):
    """Return (codepoints sorted, bitmap bytes, missing required)."""
    cps = sorted(font.cp_to_index)
    missing = [c for c in required if ord(c) not in font.cp_to_index]

    # One byte per pixel. The renderer blits these directly; bit-unpacking per
    # pixel at 24 fps would be work done for no saving, and the whole atlas is
    # tens of kilobytes either way.
    data = bytearray()
    for cp in cps:
        for row in font.bitmap(font.cp_to_index[cp]):
            data.extend(bytes(row))
    return cps, bytes(data), missing


def write_atlas(path, font, cps, data):
    out = bytearray()
    out += ATLAS_MAGIC
    out += struct.pack("<HHHH", VERSION, font.width, font.height, len(cps))
    out += bytes.fromhex(font.sha256)          # 32 bytes, keys the atlas to the font
    out += struct.pack("<H", len(cps))
    for i, cp in enumerate(cps):
        out += struct.pack("<IH", cp, i)
    out += data
    Path(path).write_bytes(bytes(out))
    return len(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--font", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--compare", help="another strike to diff against (e.g. the bold)")
    args = ap.parse_args()

    font = Font(args.font)
    cps, data, missing = bake(font)

    if missing:
        print(f"FAIL: {len(missing)} required glyph(s) absent from {args.font}:")
        print("  " + " ".join(f"U+{ord(c):04X}({c})" for c in missing))
        return 1

    size = write_atlas(args.out, font, cps, data)
    print(f"atlas: {len(cps)} codepoints at {font.width}x{font.height}")
    print(f"  font {Path(font.path).name}  sha256 {font.sha256[:16]}...")
    print(f"  all {len(REQUIRED)} required glyphs present")
    print(f"  -> {args.out} ({size} bytes)")

    if args.compare:
        other = Font(args.compare)
        shared = [c for c in cps if c in other.cp_to_index]
        differ = sum(1 for c in shared if font.bitmap(font.cp_to_index[c]) != other.bitmap(other.cp_to_index[c]))
        print(f"\n  vs {Path(other.path).name}: {differ}/{len(shared)} shared glyphs have "
              f"DIFFERENT bitmaps ({differ/len(shared)*100:.1f}%)")
        if differ < len(shared) * 0.5:
            print("  NOTE: fewer than half differ -- this is not a genuinely distinct weight,")
            print("  and §6.2's argument for a second atlas does not hold for this pair.")
        else:
            print("  -> a genuinely distinct weight, so a second atlas earns its bytes (§6.2).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
