# Omarchy alignment: bindings, menu, layouts, files

> Figures below are **as measured on the date given, against the inputs
> stated here**. Current figures live in [measurements.md](measurements.md).

Run 2026-08-30, on request: adopt Omarchy's bindings and menu, drop the layouts
this desktop does not use, and give the file manager a key.

Omarchy's own configuration was read from its repository — `config/hypr/`,
`default/hypr/bindings/`, `bin/omarchy-menu` — rather than recalled. Recalling
a binding set is how you end up with muscle memory that is *nearly* right.

## Bindings

`config/sway/bindings.conf`, 74 bindings, none bound twice, every one carrying a
description so it can appear in the live key list and be audited (§8.3).

The bindings that were this system's own are gone. **Two exceptions, both
stated in the file:**

- **Hardware keys.** Volume, brightness and the microphone belong to the
  machine, not to a desktop, and Omarchy's own set is the same idea.
- **The column.** It is this desktop's one structural difference from Omarchy,
  so it takes `super+shift+space` — Omarchy's *toggle the top bar* — because
  that is the nearest thing Omarchy has to it.

**Where Omarchy names a Hyprland-only concept there is no binding**, rather
than an approximation on the same key: window groups, pseudo tiling and monitor
scaling cycles have no sway equivalent, and a key that does something *nearly*
like the muscle memory expects is worse than one that does nothing.

## Layouts

Two: **dwindle** (§8.2) and **fullscreen**. No key produces stacking or tabbed.

## The menu bindings had never worked

The column hosted exactly **two** topics — `monitor` and `keys`. Every other
topic reached a `_ => return` arm and did nothing at all, so `super+m`,
`super+i` and `super+f` had been opening nothing, silently, since Phase 6.

**A dispatch whose default case returns is one that fails in silence**, and no
check caught it: the menu-coverage verifier runs each topic in its own pty, so
it proved the topics *draw* while saying nothing about whether anything could
*reach* them.

The column now hosts any topic. The topic arrives over a socket, so it is
validated — lower-case and dashes, at most 32 characters — before it goes near
a shell.

## The menu

28 topics, following Omarchy's tree. **27 draw clean; the 28th is `monitor`,
which sends an IPC message and draws in the column rather than in a pty, and is
recorded with that reason rather than dropped.**

Deliberately absent, with the reason in the file:

| left out | why |
|---|---|
| icons, colour pickers | removed on request — and impossible here, one glyph ramp and one derived palette |
| themes, fonts, backgrounds | **nothing to pick.** The palette is derived from the Planckian locus, the ramp from the font's measured ink coverage, and the background *is* the hero. A font picker would be a control that breaks the system it appears in |
| the other distribution's package entries | packages go through `bin/pkg` (§9.1), and naming another manager would itself break that rule |

### §8.4's component list is now 13 of 16

Present: run, find, settings, network, bluetooth, audio, monitor, capture,
update, storage, keys, packages (as install/remove), power (as system).

**Absent: player, calendar, clipboard.**

## The file manager, both halves

§8.7 found by measurement that a file manager is a *window*, not a column. The
request was for it in the sidebar *and* as capable as Explorer. Those are two
jobs, so there are two things, and the menu says which is which:

- **window** — Thunar on Omarchy's `super+shift+f`: details view, ISO dates,
  double-click to open.
- **sidebar** — `null-browse`, one filter-picker like every other topic.
- **storage** — `null-storage` maps network drives through **gvfs**: no root,
  visible in the file manager's sidebar immediately, and unmappable without
  wedging every process that touches the path, which a dead fstab CIFS mount
  does. It offers the server's own share list rather than asking you to type
  one.

### Hosting a foreign file manager found a real terminal bug

Trying a third-party TUI in the column exposed this: **`ESC ( B` is three bytes
and the escape handler consumed only the `(`**, so the `B` fell through and was
printed as text. ncurses emits that sequence constantly, so hosted output came
out sprayed with stray capital Bs and its columns pushed out of line —
`2688B`, `B1B 2 3 4 5 6 7 8 B~`. The "skip whole" property the file claims for
unimplemented sequences was not true of this one. Fixed, with a test covering
every designator form.

The listing still would not draw afterwards, because the column's terminal
implements the escape subset that was **measured** as needed (§6.2) and a
foreign TUI is entitled to use anything. Growing the terminal to chase one
program would have been the wrong trade, so the browser is built from the
primitive this system already renders correctly.

## The update topic was slow and slightly dishonest

It took 2.7 s to open, and it claimed "up to date" against a catalogue of
unknown age. §8.4 already requires checking a catalogue's freshness before
trusting its verdict — a rule that had been applied to firmware and not to
packages. It now reports the catalogue's age and stops forcing a 1.6-second
metadata refresh nobody asked for.
