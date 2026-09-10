#!/usr/bin/env python3
"""Render one frame of the nullLinux hero logo to a truecolor ANSI block for
fastfetch (NULL.md's one identity: the same hero everything else draws).

The colours are the cells' OWN palette -- the derived blackbody ramp -- so the
logo is not hand-coloured and tracks the render pipeline. Output is committed as
config/fastfetch/logo.txt; regenerate it here if the hero is ever re-baked:

    python3 bake/make_fastfetch_logo.py assets/logo.cells config/fastfetch/logo.txt
"""
import struct, subprocess, sys, pathlib

FRAME = 0  # fixed, so the committed logo is deterministic

def load(path):
    d = pathlib.Path(path).read_bytes()
    if d[:4] != b"RCEL":
        sys.exit(f"{path}: not a cells file")
    o = 4
    _version, cols, rows, frames, _fps = struct.unpack_from("<5H", d, o); o += 10
    rl = d[o]; o += 1
    ramp = d[o:o+rl].decode("latin1"); o += rl
    (pl,) = struct.unpack_from("<H", d, o); o += 2
    palette = [tuple(d[o+3*i:o+3*i+3]) for i in range(pl)]; o += pl*3
    (raw_len,) = struct.unpack_from("<Q", d, o); o += 8
    planes = subprocess.run(["zstd", "-d", "-c"], input=d[o:],
                            stdout=subprocess.PIPE, check=True).stdout
    if len(planes) != raw_len or len(planes) != cols*rows*2*frames:
        sys.exit(f"{path}: plane size mismatch")
    return cols, rows, frames, ramp, palette, planes

def render(cols, rows, ramp, palette, planes, frame):
    n = cols*rows
    g = planes[frame*n*2 : frame*n*2+n]
    c = planes[frame*n*2+n : frame*n*2+2*n]
    grid = [[(ramp[g[y*cols+x]], palette[c[y*cols+x]]) for x in range(cols)]
            for y in range(rows)]
    # Trim fully-blank rows top and bottom, and the common left margin, so the
    # logo sits tight against the info panel rather than in a box of spaces.
    def blank_row(r): return all(ch == ' ' for ch, _ in r)
    while grid and blank_row(grid[0]):  grid.pop(0)
    while grid and blank_row(grid[-1]): grid.pop()
    left = min((next((x for x, (ch, _) in enumerate(r) if ch != ' '), cols)
                for r in grid), default=0)
    lines = []
    for r in grid:
        r = r[left:]
        while r and r[-1][0] == ' ':  # trailing spaces need no colour
            r = r[:-1]
        s = "".join(f"\033[38;2;{c[0]};{c[1]};{c[2]}m{ch}" for ch, c in r)
        lines.append(s + "\033[0m")
    return "\n".join(lines) + "\n"

def main():
    if len(sys.argv) != 3:
        sys.exit("usage: make_fastfetch_logo.py <logo.cells> <out.txt>")
    cols, rows, frames, ramp, palette, planes = load(sys.argv[1])
    art = render(cols, rows, ramp, palette, planes, min(FRAME, frames-1))
    out = pathlib.Path(sys.argv[2])
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(art)
    print(f"wrote {out} ({art.count(chr(10))} lines) from frame {FRAME} of {sys.argv[1]}")

if __name__ == "__main__":
    main()
