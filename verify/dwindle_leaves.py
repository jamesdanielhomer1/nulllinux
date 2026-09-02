#!/usr/bin/env python3
"""Leaf rectangles of one workspace, from the compositor (NULL.md §8.2).

A separate file rather than an inline heredoc: a heredoc IS the script's
standard input, so a command piped into `python3 - <<EOF` has its pipe
silently replaced by the heredoc and the script reads its own source as data.
"""
import json
import subprocess
import sys

ws = sys.argv[1]
tree = json.loads(subprocess.run(["swaymsg", "-t", "get_tree"],
                                 capture_output=True, text=True, check=True).stdout)


def find(v):
    if v.get("type") == "workspace" and str(v.get("name")) == ws:
        return v
    for k in ("nodes", "floating_nodes"):
        for c in v.get(k) or []:
            r = find(c)
            if r:
                return r
    return None


leaves = []


def walk(v):
    if v.get("pid"):
        leaves.append(v["rect"])
        return
    for k in ("nodes", "floating_nodes"):
        for c in v.get(k) or []:
            walk(c)


w = find(tree)
if w:
    walk(w)

for r in leaves:
    print("  %dx%d at %d,%d" % (r["width"], r["height"], r["x"], r["y"]))
if leaves:
    ar = [max(r["width"], r["height"]) / max(1, min(r["width"], r["height"]))
          for r in leaves]
    print("  worst aspect ratio %.2f:1" % max(ar))
else:
    print("  none")
