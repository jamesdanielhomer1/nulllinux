#!/usr/bin/env python3
"""Every command this desktop invokes must actually exist (NULL.md §10.1).

A key binding naming a command that is not installed FAILS IN SILENCE. The
compositor does not validate exec lines, so the key simply does nothing, and
the only way to find out is to press it and notice nothing happened.

That is not hypothetical: three notification bindings and four component calls
named `makoctl` on a machine that installs `dunst` and has never had mako. The
package list said dunst, in a comment, on the line above. Nothing checked.

ONLY THE BINDINGS ARE SCANNED, and that is a deliberate narrowing.

A scan of the shell components was written first and thrown away. It reported
175 missing commands out of 258 -- `case` labels, prose inside generated files,
and Python embedded in heredocs, all of which begin a line and look exactly
like a command. Filtering got it to 55, still mostly wrong. A checker at that
signal-to-noise ratio teaches people to ignore it, which is worse than not
having one, and this file is not worth more effort than the bug it catches.

The bindings are different: the first word of an exec is unambiguously a
command, includes are followed, and the compositor validates none of it. That
is the case where failure is genuinely silent, so that is the case checked.

For the components, the answer is not a cleverer parser -- it is that they
should GUARD their external calls, as most already do (`command -v x || ...`).
The calls that broke were the ones that did not.
"""

import os
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Shell builtins, keywords and constructs that are not external commands.
NOT_COMMANDS = set("""
if then else elif fi for while until do done case esac in function return
break continue exit local export readonly declare typeset eval exec set unset
shift trap wait source test true false echo printf read cd pwd type command
alias unalias let time select coproc mapfile getopts hash ulimit umask jobs
fg bg kill disown suspend times caller builtin enable help logout shopt
""".split())


def sway_configs(path, seen=None):
    """The config and everything it includes, in sway's own include order."""
    seen = seen if seen is not None else set()
    path = Path(path).resolve()
    if path in seen or not path.is_file():
        return []
    seen.add(path)
    out = [path]
    for line in path.read_text(errors="replace").splitlines():
        m = re.match(r"^\s*include\s+(.+?)\s*$", line)
        if not m:
            continue
        spec = m.group(1).strip("'\"")
        if spec.startswith("$("):          # the distribution's layered include
            continue
        base = path.parent
        import glob as g
        for p in sorted(g.glob(str(base / spec) if not spec.startswith("/") else spec)):
            out.extend(sway_configs(p, seen))
    return out


def commands_from_bindings(paths, variables):
    """First word of every exec, with env assignments and variables resolved."""
    found = {}
    for p in paths:
        for n, line in enumerate(Path(p).read_text(errors="replace").splitlines(), 1):
            m = re.search(r"\bexec(?:_always)?\s+(.+)$", line.strip())
            if not m or line.strip().startswith("#"):
                continue
            rest = m.group(1).strip()
            # `exec sh -c "..."` and pipelines: take the first simple word.
            for token in rest.split():
                if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token):
                    continue                      # env assignment prefix
                for var, val in variables.items():
                    token = token.replace(var, val)
                token = token.strip("'\"")
                if token in ("pkill", "sh", "bash"):
                    break
                found.setdefault(token, []).append(f"{Path(p).name}:{n}")
                break
    return found


def sway_variables(paths):
    v = {}
    for p in paths:
        for line in Path(p).read_text(errors="replace").splitlines():
            m = re.match(r"^\s*set\s+(\$[A-Za-z0-9_]+)\s+(.+?)\s*$", line)
            if m:
                v[m.group(1)] = m.group(2)
    return v


def strip_quotes_and_comments(line):
    out, i, quote = [], 0, None
    while i < len(line):
        c = line[i]
        if quote:
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "'\"":
            quote = c
            i += 1
            continue
        if c == "#" and (not out or out[-1] in " \t;|&("):
            break
        out.append(c)
        i += 1
    return "".join(out)


def main():
    conf = sys.argv[1] if len(sys.argv) > 1 else "/etc/sway/config"
    paths = sway_configs(conf)
    if not paths:
        print(f"cannot read {conf}", file=sys.stderr)
        return 1
    variables = sway_variables(paths)

    bad = 0
    print(f"bindings: {len(paths)} file(s) from {conf}")
    binds = commands_from_bindings(paths, variables)
    for cmd, where in sorted(binds.items()):
        if cmd.startswith("/"):
            ok = os.access(cmd, os.X_OK)
        else:
            ok = shutil.which(cmd) is not None
        if not ok:
            print(f"  MISSING  {cmd:<24} {where[0]}")
            bad = 1
    print(f"  {len(binds)} distinct command(s), "
          f"{'all present' if not bad else 'SOME MISSING'}")

    print()
    print("PASS: every command invoked exists" if not bad
          else "FAIL: a command is invoked that is not installed -- it fails silently")
    return bad


if __name__ == "__main__":
    sys.exit(main())
