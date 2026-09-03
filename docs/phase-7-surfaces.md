# Phase 7 — Terminal-adjacent surfaces and the file manager

> Figures below are **as measured on the date given, against the inputs
> stated here**. They are a record of that run, not a claim about the
> system now. Current figures, with their inputs, live in
> [measurements.md](measurements.md) (§10.7).

Gate (NULL.md §11 Phase 7): *each verified by running it and reading the
codepoints, not by reading its configuration.*

Built 2026-08-29.

## Gate evidence

| surface | unrenderable | cells drawn |
|---|---|---|
| shell prompt | **0** | 288 |
| pager (`less`) | **0** | 1 563 |
| diff viewer (`git`) | **0** | 3 291 |
| status (`git status`) | **0** | 509 |

Every one was run on a pseudo-terminal and its output decoded; none was
verified by reading a configuration file. The verifier refuses a count taken
from a screen with nothing on it, and it did so twice during this phase — once
for the pager, which quits immediately on a file that fits one screen, and once
for a prompt that had drawn a single line.

## The file manager

**Thunar**, already installed. §8.7's requirements, stored and read back:

```
default-view       ThunarDetailsView
misc-date-style    THUNAR_DATE_STYLE_YYYYMMDD    (ISO)
misc-single-click  false                          (DOUBLE-click to open)
last-location-bar  ThunarLocationButtons          (breadcrumb)
last-side-pane     ThunarShortcutsPane            (places)
```

And then **run and looked at**, because a stored setting is not evidence:
`app_id='thunar'`, 1920x1044, **1.4% near-white** with the dominant colour our
own background. The stylesheet took.

Identifying the window mattered: the first measurement sampled a *terminal*,
because the tree walk returned the first window with an `app_id` anywhere
rather than the one on the workspace under test (§10.1 rule 5).

## Both §8.10 toolkit traps were live on this machine

**Desktop settings outrank configuration files.** `gsettings` carried
`font-name 'Adwaita Sans 11'` — a value left by a previous desktop. A complete
`settings.ini` would have been applied while its font was silently overridden.
Reconciled rather than assumed.

**`Adwaita-dark` is not a theme here.** `/usr/share/themes` contains only
`Default` and `Emacs`. Naming a theme that does not exist falls back to the
**light** one, silently. The dark variant is the
`gtk-application-prefer-dark-theme` flag, and that is what is set.

**Naming colours is not enough.** The stylesheet declares the theme colour
names *and* names the surfaces — window, headerbar, popover, treeview, entry,
button, sidebar, scrollbar — because the default theme bakes most of its
colours in as literals, and declaring names alone produces stock grey with your
icons and your font, which looks like a partial success and is a total one.

## Two bugs found by running things

**The prompt lost every exit status.** `$?` was read inside a helper, by which
time it was the status of the helper's own first command. Every failure
reported as success. `$?` must be captured on the very first line of the prompt
function — anything before it, even a `local`, replaces it. Now:

```
nox ~/nullLinux (main) $
nox ~/nullLinux (main) 42 $
```

**Asking fontconfig for a size you do not have gets you a different size, not a
scaled one.** `fc-match Terminus:pixelsize=17` returns `ter-u16n` — the 16-pixel
strike. That is a substitution rather than the smearing §9.3 feared, but it is
still silent, and the mitigation is unchanged: every size is pinned to a real
strike, and the terminal pins bold and italic too rather than letting
fontconfig answer with an outline face.

## Joining files that are not ours

`bin/null-join` adds **one line** to `~/.bashrc` and `~/.gitconfig`, guarded by
a marker so a second run is a no-op, backing up first, never overwriting. The
check asks **"is the join still there"** rather than "does our file exist" —
the second is true in every case that matters and in the failure case too.
Verified: git reads the included configuration (`color.diff.frag` → `#b9ccff`,
`log.date` → `iso`).

## What was built

| path | what |
|---|---|
| `config/foot/foot.ini` | terminal; strike pinned, bold and italic pinned too |
| `config/shell/null.sh` | prompt, pager, editor, path |
| `config/shell/colours.sh` | palette roles as shell variables — generated |
| `config/git/config` | diff and status colours — plain git, ASCII only |
| `config/gtk-3.0`, `config/gtk-4.0` | toolkit stylesheet, surfaces named — generated |
| `bin/null-join` | one-line joins with a marker |
| `bin/null-filemanager` | §8.7's settings, applied and checkable |

No add-on diff pager and no `bat`: every popular one defaults to Nerd Font
glyphs or heavy box-drawing this console font does not carry, and the point of
these surfaces is that they draw only what the font has.

## Gate

**MET.**
