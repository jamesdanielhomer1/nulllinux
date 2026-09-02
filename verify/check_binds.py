#!/usr/bin/env python3
"""Audit compositor key bindings (NULL.md §8.3, §10.4).

Fails on any key bound twice, and on any binding without a description.

Two bindings on one key is SILENT -- the last one wins -- and it is the easiest
mistake to make when adding a component. A binding with no description cannot
appear in the generated keys list and cannot be audited.

This parses the configuration and FOLLOWS INCLUDES itself. Asking the
compositor for its configuration text is not enough: measured on this system
that text does not expand includes, and a distribution ships whole files of
bindings behind one -- so an audit built on the query alone reports a clean set
while real bindings sit outside it (§8.1).
"""

import argparse
import glob as globmod
import os
import re
import subprocess
import sys
from pathlib import Path

DESC = "#:"          # the description marker, distinctive enough not to collide

# Modifier spellings sway accepts, normalised to one form so that the same
# chord written two ways compares equal. Without this the duplicate is missed,
# which is the whole point of the check.
MOD_ALIASES = {
    "mod1": "alt", "alt": "alt",
    "mod4": "super", "super": "super", "logo": "super",
    "shift": "shift", "ctrl": "ctrl", "control": "ctrl",
    "mod2": "mod2", "mod3": "mod3", "mod5": "mod5",
}

BIND_RE = re.compile(r"^\s*(bindsym|bindcode)\b(?P<rest>.*)$")
MODE_RE = re.compile(r'^\s*mode\s+(?:--\S+\s+)*"?(?P<name>[^"{]+)"?\s*\{')
SET_RE = re.compile(r"^\s*set\s+(?P<var>\$\w+)\s+(?P<val>.+?)\s*$")
INCLUDE_RE = re.compile(r"^\s*include\s+(?P<what>.+?)\s*$")
# `# --- windows ---`. The sections already exist in the configuration to make
# it readable; reading them here means the key list groups the same way, and
# that grouping cannot drift from the file it describes.
SECTION_RE = re.compile(r"^\s*#\s*-{2,}\s*(?P<name>.+?)\s*-{2,}\s*$")
FLAG_RE = re.compile(r"^--\S+$")


class Binding:
    def __init__(self, chord, command, mode, flags, desc, src, line, section=""):
        self.chord, self.command, self.mode = chord, command, mode
        self.flags, self.desc, self.src, self.line = flags, desc, src, line
        # The `# --- ... ---` heading this binding sits under, and its position
        # in the file, so the list can be grouped in the order it was written
        # rather than alphabetically -- which scatters related keys.
        self.section = section
        self.order = line

    @property
    def key(self):
        # Flags change identity: a press binding and a release binding on the
        # same chord coexist legitimately, so they are different keys here.
        ident = {f for f in self.flags if f in ("--release", "--locked", "--inhibited")}
        return (self.mode, self.chord, "--release" in ident)

    def __repr__(self):
        return f"{self.chord} [{self.mode}] {self.command[:40]}"


def normalise_chord(chord, variables):
    """Resolve variables, sort modifiers, casefold -- so equal chords compare equal."""
    for var, val in variables.items():
        chord = chord.replace(var, val)
    parts = [p.strip() for p in chord.split("+") if p.strip()]
    mods, keys = [], []
    for p in parts:
        low = p.lower()
        (mods if low in MOD_ALIASES else keys).append(MOD_ALIASES.get(low, low))
    return "+".join(sorted(set(mods)) + keys)


def expand_include(spec, base_dir):
    """Resolve one include the way the compositor does.

    Sway passes the argument through the shell, so a distribution can and does
    use command substitution to assemble a layered path list. Reproducing that
    is what makes the audit see what the compositor sees.
    """
    spec = spec.strip().strip("'\"")
    paths = []
    if "$(" in spec:
        try:
            out = subprocess.run(["sh", "-c", f'printf "%s" "{spec}"'],
                                 capture_output=True, text=True, timeout=10).stdout
        except Exception:
            return []
        for token in out.split():
            paths.extend(sorted(globmod.glob(token)))
        return paths
    if not os.path.isabs(spec):
        spec = os.path.join(base_dir, spec)
    return sorted(globmod.glob(spec))


def parse(path, variables=None, seen=None, mode="default"):
    """Parse one config file and everything it includes."""
    variables = {} if variables is None else variables
    seen = set() if seen is None else seen
    path = os.path.realpath(path)
    if path in seen:
        return []
    seen.add(path)

    out = []
    try:
        raw_lines = Path(path).read_text(errors="replace").splitlines()
    except OSError as e:
        raise SystemExit(f"cannot read {path}: {e}")

    # Join backslash continuations BEFORE parsing. Without this a continuation
    # is read as a binding of its own, and the audit reports collisions between
    # fragments of single commands -- noise that would train a reader to ignore
    # the check, which is worse than not having it.
    lines, buf = [], ""
    for ln in raw_lines:
        if ln.rstrip().endswith("\\"):
            buf += ln.rstrip()[:-1] + " "
        else:
            lines.append(buf + ln)
            buf = ""
    if buf:
        lines.append(buf)

    pending_desc = None
    section = ""
    mode_stack = [mode]
    i = 0
    while i < len(lines):
        raw = lines[i]
        line = raw.rstrip()
        stripped = line.strip()

        if stripped.startswith(DESC):
            pending_desc = stripped[len(DESC):].strip()
            i += 1
            continue
        m = SECTION_RE.match(stripped)
        if m:
            # Must be tested before the generic comment skip below, which would
            # otherwise swallow it -- a heading is a comment.
            section = m.group("name")
            i += 1
            continue
        if stripped.startswith("#") or not stripped:
            i += 1
            continue

        m = SET_RE.match(line)
        if m:
            variables[m.group("var")] = m.group("val").strip()
            i += 1
            continue

        m = INCLUDE_RE.match(line)
        if m:
            for p in expand_include(m.group("what"), os.path.dirname(path)):
                out.extend(parse(p, variables, seen, mode_stack[-1]))
            i += 1
            continue

        m = MODE_RE.match(line)
        if m:
            mode_stack.append(m.group("name").strip())
            i += 1
            continue

        if stripped == "}" and len(mode_stack) > 1:
            mode_stack.pop()
            i += 1
            continue

        m = BIND_RE.match(line)
        if m:
            rest = m.group("rest").strip()
            toks = rest.split()
            flags = []
            while toks and FLAG_RE.match(toks[0]):
                flags.append(toks.pop(0))

            # Block form:  bindsym --flags {  KEY cmd  ...  }
            if toks and toks[0] == "{":
                i += 1
                while i < len(lines) and lines[i].strip() != "}":
                    inner = lines[i].strip()
                    if inner.startswith(DESC):
                        pending_desc = inner[len(DESC):].strip()
                    elif inner and not inner.startswith("#"):
                        parts = inner.split(None, 1)
                        if len(parts) == 2:
                            out.append(Binding(
                                normalise_chord(parts[0], variables), parts[1],
                                mode_stack[-1], flags, pending_desc, path, i + 1,
                                section))
                            pending_desc = None
                    i += 1
                i += 1
                continue

            if len(toks) >= 2:
                out.append(Binding(
                    normalise_chord(toks[0], variables), " ".join(toks[1:]),
                    mode_stack[-1], flags, pending_desc, path, i + 1, section))
            pending_desc = None
            i += 1
            continue

        pending_desc = None
        i += 1
    return out


def audit(binds, require_desc=True):
    problems = []
    by_key = {}
    for b in binds:
        by_key.setdefault(b.key, []).append(b)

    for key, group in sorted(by_key.items(), key=lambda kv: str(kv[0])):
        if len(group) > 1:
            problems.append(
                f"KEY BOUND {len(group)} TIMES: {group[0].chord} in mode {group[0].mode!r}\n" +
                "\n".join(f"    {os.path.basename(b.src)}:{b.line}  {b.command[:60]}" for b in group) +
                "\n    (the compositor keeps the LAST one, silently)")

    if require_desc:
        undesc = [b for b in binds if not b.desc]
        if undesc:
            problems.append(
                f"{len(undesc)} BINDING(S) WITHOUT A DESCRIPTION "
                f"(cannot appear in the keys list, cannot be audited):\n" +
                "\n".join(f"    {os.path.basename(b.src)}:{b.line}  {b.chord}" for b in undesc[:12]) +
                ("\n    ..." if len(undesc) > 12 else ""))
    return problems


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("config")
    ap.add_argument("--no-require-description", action="store_true")
    ap.add_argument("--list", action="store_true")
    # A COUNT, not a line count of --list. The rollback in bin/null-link used
    # to count lines of --list, which meant a change to that list's FORMATTING
    # changed the number it compared against a safety threshold. Adding section
    # headings inflated it from 74 to 87 -- so the guard that exists to catch a
    # configuration that lost its bindings would have been reading a number
    # inflated by decoration.
    ap.add_argument("--count", action="store_true",
                    help="print only how many bindings were parsed")
    args = ap.parse_args()

    binds = parse(args.config)
    if args.count:
        print(len(binds))
        return 0

    if args.list:
        # Width is driven by content, not by a padded column that is almost
        # always the same word: the mode is shown only when it is not the
        # default, so the pick-list width the column needs is set by real rows.
        width = max((len(b.chord) for b in binds), default=10)

        # GROUPED BY SECTION, in the order the configuration writes them.
        #
        # Sorted alphabetically by chord, related keys scatter: screen
        # recording lands between two window-focus bindings because both start
        # with `alt`. The sections already exist in the configuration to make
        # it readable, so they are read from there rather than invented here --
        # a list of groups maintained in this file would be a second opinion
        # about what belongs together, and it would go stale.
        order, groups = [], {}
        for b in binds:
            name = b.section or "other"
            if name not in groups:
                groups[name] = []
                order.append(name)
            groups[name].append(b)

        rule = "\u2500"
        first = True
        for name in order:
            rows = sorted(groups[name], key=lambda b: (b.mode, b.order))
            if not first:
                print()
            first = False
            label = name.upper()
            print(f"{label} {rule * max(2, width + 24 - len(label))}")
            for b in rows:
                mode = "" if b.mode == "default" else f"[{b.mode}] "
                print(f"  {b.chord:<{width}}  {mode}{b.desc or '(no description)'}")
        return 0

    problems = audit(binds, require_desc=not args.no_require_description)
    srcs = {os.path.basename(b.src) for b in binds}
    print(f"{len(binds)} bindings across {len(srcs)} file(s): {', '.join(sorted(srcs))}")
    if problems:
        print()
        for p in problems:
            print("  " + p.replace("\n", "\n  "))
        return 1
    print(f"PASS: no key bound twice; every binding described")
    return 0


if __name__ == "__main__":
    sys.exit(main())
