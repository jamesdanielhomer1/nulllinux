#!/usr/bin/env python3
"""Glyph coverage of a hosted program (NULL.md §10.5, §7.3).

The verifier that decides what the column may host. What it will and will not
host is decided by MEASUREMENT, not taste: a program needing glyphs the font
does not have is either redrawn from its own data source in this system's own
chrome, or not hosted.

Runs the program on a pseudo-terminal of exactly the size the column would give
it, with a realistic terminal type and colour environment, and counts the
codepoints the atlas cannot draw.

A zero taken from a screen with nothing on it is NOT a result, and this says so
rather than reporting it as one.
"""

import argparse
import collections
import errno
import fcntl
import json
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time
from pathlib import Path

ATLAS_MAGIC = b"RATL"

# Escape-sequence shapes, so the terminal subset can be reported rather than
# guessed at. This is the measurement §7.3 asks for: implement against what the
# programs were OBSERVED to emit, not against a standards document.
CSI = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")
OSC = re.compile(rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
ESC_SIMPLE = re.compile(rb"\x1b[@-Z\\-_]")


def atlas_codepoints(path):
    d = Path(path).read_bytes()
    if d[:4] != ATLAS_MAGIC:
        raise SystemExit(f"{path}: not an atlas")
    g = lambda o: struct.unpack_from("<H", d, o)[0]
    tbl = g(44)
    cps = set()
    o = 46
    for _ in range(tbl):
        cp, _idx = struct.unpack_from("<IH", d, o)
        cps.add(cp)
        o += 6
    return cps


def run_on_pty(argv, cols, rows, seconds, env_extra=None):
    """Run argv on a pty of exactly (cols, rows) and capture what it emits."""
    pid, fd = pty.fork()
    if pid == 0:
        env = dict(os.environ)
        env.update({
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "LINES": str(rows), "COLUMNS": str(cols),
        })
        # Several programs rewrite their own configuration on exit. If that
        # directory is a link into the repository they will edit it, so it is
        # redirected to a scratch copy (§10.5).
        env.update(env_extra or {})
        try:
            # execvpE, not execvp. The plain form IGNORES the environment we
            # just built, so TERM would be inherited and XDG_CONFIG_HOME would
            # never reach the child -- which is how a program came to read its
            # real configuration while this tool reported it had been given a
            # scratch one. The environment was constructed and discarded.
            os.execvpe(argv[0], argv, env)
        except Exception:
            os._exit(127)

    # Set the window size on the master BEFORE the program draws, or it sizes
    # itself to a default and the measurement is of the wrong screen.
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    buf = bytearray()
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if not r:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError as e:
            if e.errno in (errno.EIO,):
                break
            raise
        if not chunk:
            break
        buf.extend(chunk)

    try:
        os.kill(pid, signal.SIGTERM)
        time.sleep(0.15)
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        pass
    os.close(fd)
    return bytes(buf)


def analyse(raw, atlas_cps):
    forms = collections.Counter()
    for m in CSI.finditer(raw):
        forms[("CSI", m.group()[-1:].decode("latin1"))] += 1
    for _ in OSC.finditer(raw):
        forms[("OSC", "")] += 1
    for m in ESC_SIMPLE.finditer(raw):
        forms[("ESC", m.group()[-1:].decode("latin1"))] += 1

    text = OSC.sub(b"", raw)
    text = CSI.sub(b"", text)
    text = ESC_SIMPLE.sub(b"", text)
    text = re.sub(rb"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", b"", text)

    printable = collections.Counter()
    for ch in text.decode("utf-8", "replace"):
        if ch in ("\n", "\r", "\t"):
            continue
        printable[ch] += 1

    missing = collections.Counter()
    for ch, n in printable.items():
        if ord(ch) not in atlas_cps and ch != "�":
            missing[ch] += n

    scroll_ops = sum(v for (k, f), v in forms.items()
                     if (k, f) in (("CSI", "S"), ("CSI", "T"), ("CSI", "L"), ("CSI", "M"))
                     or (k, f) in (("ESC", "D"), ("ESC", "M")))
    return {
        "bytes": len(raw),
        "distinct_escape_forms": len(forms),
        "escape_forms": sorted(f"{k}{f}" for (k, f) in forms),
        "scroll_ops": scroll_ops,
        "printable_cells": sum(printable.values()),
        "unrenderable": missing,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--atlas", default="assets/atlas-interface.bin")
    ap.add_argument("--cols", type=int, required=True)
    ap.add_argument("--rows", type=int, required=True)
    ap.add_argument("--seconds", type=float, default=2.0)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--label", default=None)
    ap.add_argument("command", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    cmd = [c for c in args.command if c != "--"]
    if not cmd:
        raise SystemExit("give a command to run")

    cps = atlas_codepoints(args.atlas)
    scratch = Path("/tmp/null-coverage-config")
    scratch.mkdir(parents=True, exist_ok=True)
    raw = run_on_pty(cmd, args.cols, args.rows, args.seconds,
                     {"XDG_CONFIG_HOME": str(scratch)})
    r = analyse(raw, cps)
    label = args.label or cmd[0]

    if args.json:
        out = dict(r)
        out["unrenderable"] = {f"U+{ord(c):04X}": n for c, n in r["unrenderable"].items()}
        out["label"] = label
        print(json.dumps(out, indent=2))
        return 0

    total_missing = sum(r["unrenderable"].values())
    print(f"{label}  at {args.cols}x{args.rows}, {args.seconds}s")
    print(f"  bytes emitted        {r['bytes']}")
    print(f"  distinct escapes     {r['distinct_escape_forms']}  ({', '.join(r['escape_forms'][:14])})")
    print(f"  scroll operations    {r['scroll_ops']}")
    print(f"  printable cells      {r['printable_cells']}")
    print(f"  UNRENDERABLE         {len(r['unrenderable'])} distinct, {total_missing} cells")
    for ch, n in r["unrenderable"].most_common(12):
        print(f"      U+{ord(ch):04X} {ch!r}  x{n}")

    if r["printable_cells"] < 50:
        print("\n  NOTE: almost nothing was drawn. A zero taken from a screen with")
        print("  nothing on it is not evidence, and this row says so rather than")
        print("  claiming a result (§10.5).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
