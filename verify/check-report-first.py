#!/usr/bin/env python3
"""The report-first promise, enforced structurally (NULL.md §8.4, §11 Phase 12).

Components that promise to change nothing until told are checked by READING
THE TEXT of their reporting paths and failing if a mutating command appears in
one. A promise kept by remembering is not a promise; it is a habit, and habits
are what a refactor at midnight quietly breaks.

The reporting path is every function named report_*. Anything that mutates
lives elsewhere and is reachable only behind an explicit flag.

This checker is deliberately noisy about its own limits: if it cannot find a
function's end it FAILS rather than passing silently, because a checker that
quietly examines nothing is worse than no checker -- it reports success.
"""

import re
import sys
from pathlib import Path

# Commands that change the machine. Matched as whole words at a command
# position, so "du" does not trip "dd" and a comment mentioning rm is ignored.
# NO PACKAGE MANAGER IS NAMED HERE, and that is not an oversight.
#
# §9.1 already guarantees that exactly one component may name one, enforced by
# verify/check-package-abstraction.sh. So any reporting path that touched
# installed state would have to go through the abstraction, and checking the
# abstraction's mutating verbs covers the case completely. Naming the manager
# would put a second copy of "which manager is this machine using" into a
# checker -- which is the coupling §9.1 exists to prevent, added by the file
# that polices a different rule. That is exactly what the first version did,
# and the abstraction check failed it.
#
# Metadata refresh is not a mutation for this purpose either: §8.4 makes
# "refreshing metadata and reporting" the sanctioned default, and requires
# checking a catalogue's freshness before trusting its verdict.

MUTATORS = [
    r"fwupdmgr\s+(update|install|activate|downgrade|clear-results)",
    r"fc-cache",                       # no dry run exists; asking IS doing
    r"rm", r"mv", r"cp", r"install", r"truncate", r"dd", r"shred",
    r"mkdir", r"rmdir", r"ln", r"touch", r"chmod", r"chown", r"chgrp",
    r"sed\s+-i", r"tee",
    r"systemctl\s+(start|stop|restart|enable|disable|mask|unmask)",
    r"btrfs\s+subvolume\s+(create|delete|snapshot)",
    r"git\s+(commit|push|checkout|reset|clean|rm|add)",
    r"kill", r"pkill", r"killall",
    r"gsettings\s+set", r"dconf\s+write",
    r"setfont", r"localectl\s+set", r"hostnamectl\s+set",
    r"plymouth-set-default-theme", r"dracut",
    r"swaymsg",                        # issues compositor commands
]
# `pkg` is the package abstraction: its read verbs are safe, its others are not.
# The abstraction's mutating verbs, which is the complete set of ways a
# reporting path could change installed state without naming a manager.
MUTATORS.append(r"(?:\"?\$\{?PKG\}?\"?|bin/pkg)\s+"
                r"(install|install-list|remove|remove-orphans|upgrade|clean-cache)(?![-\w])")

MUT_RE = re.compile(r"(?:^|[|;&(]|\$\()\s*(?:sudo\s+|doas\s+)?(" + "|".join(MUTATORS) + r")\b")
# A redirection that writes to a real file. /dev/null and friends are not writes.
REDIR_RE = re.compile(r"(?<![0-9<>])>>?\s*(?!\s*[&|])(?!/dev/(null|stderr|stdout|fd/))(\S+)")


VAR_ONLY = re.compile(r"^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$")


def strip_noise(line):
    """Remove comments and prose inside quotes, but KEEP a quoted command word.

    A mutating word inside a message string is prose, not an action, and
    flagging it trains people to ignore the checker.

    But a quoted VARIABLE is not prose -- `"$PKG" upgrade` is a command, and
    the quotes are there because that is how you write it safely. Dropping the
    whole quoted span deleted the command name, so the rule that looks for the
    package abstraction could never fire; `"$PKG" install` appeared to be
    caught only because a generic `install` rule happened to match the
    argument. A checker passing by coincidence is a checker not checking.

    So a double-quoted span that is exactly one variable expansion is kept, and
    everything else quoted is dropped.
    """
    out, i = [], 0
    while i < len(line):
        c = line[i]
        if c in "'\"":
            j = i + 1
            while j < len(line) and line[j] != c:
                j += 1
            span = line[i + 1:j]
            if c == '"' and VAR_ONLY.match(span):
                out.append(span)          # a command, not a message
            i = j + 1
            continue
        if c == "#" and (not out or out[-1] in " \t;|&("):
            break
        out.append(c)
        i += 1
    return "".join(out)


def functions(text, path):
    """Every `name() {` ... `}` block, relying on the closing brace at column 0.

    That is a convention, not shell syntax, so it is CHECKED: a function whose
    end cannot be found is an error, never a skip.
    """
    found = {}
    lines = text.split("\n")
    for i, line in enumerate(lines):
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{\s*$", line)
        if not m:
            continue
        for j in range(i + 1, len(lines)):
            if lines[j] == "}":
                found[m.group(1)] = (i + 1, lines[i + 1:j])
                break
        else:
            raise SystemExit(
                f"{path}: cannot find the end of {m.group(1)}() -- this checker "
                f"relies on a closing brace at column 0. Refusing to pass "
                f"without having checked it.")
    return found


def check(path, required):
    text = Path(path).read_text()
    funcs = functions(text, path)
    reporters = {n: v for n, v in funcs.items() if n.startswith("report_")}
    problems = []

    missing = [c for c in required if f"report_{c}" not in reporters]
    if missing:
        problems.append(f"no reporting path for required channel(s): {', '.join(missing)}")

    for name, (start, body) in sorted(reporters.items()):
        for k, raw in enumerate(body):
            line = strip_noise(raw)
            if not line.strip():
                continue
            m = MUT_RE.search(line)
            if m:
                problems.append(f"{name}() line {start+k+1}: mutating command "
                                f"'{m.group(1).strip()}'  |  {raw.strip()[:70]}")
            r = REDIR_RE.search(line)
            if r:
                problems.append(f"{name}() line {start+k+1}: writes to "
                                f"'{r.group(2)}'  |  {raw.strip()[:70]}")
    return reporters, problems


def main():
    targets = {
        "bin/null-update": ["packages", "orphans", "cache", "firmware", "fonts"],
    }
    if len(sys.argv) > 1:
        targets = {sys.argv[1]: []}

    bad = 0
    for path, required in targets.items():
        reporters, problems = check(path, required)
        print(f"{path}: {len(reporters)} reporting path(s) -- "
              f"{', '.join(sorted(reporters))}")
        for p in problems:
            print(f"  FAIL {p}")
        if problems:
            bad = 1
        else:
            print("  ok: no reporting path mutates the machine")
    return bad


if __name__ == "__main__":
    sys.exit(main())
