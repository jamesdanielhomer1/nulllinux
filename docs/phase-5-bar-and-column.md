# Phase 5 — The bar, then the column

> Figures below are **as measured on the date given, against the inputs
> stated here**. They are a record of that run, not a claim about the
> system now. Current figures, with their inputs, live in
> [measurements.md](measurements.md) (§10.7).

Gate (NULL.md §11 Phase 5): *exclusive-zone transitions measured against a real
tiled window at every width, with the window resizing rather than being
covered, and the zone correctly released on unmap. The coverage verifier
reports a count for every candidate program, and every hosting decision cites
it.*

Built 2026-08-29, in the order §11 gives: the bar, then the coverage verifier,
then the column as terminal → pseudo-terminal → exclusive zone → keyboard.

## Gate evidence — zone transitions against a real tiled window

| state | workspace rect |
|---|---|
| no column | `x=0 1920x1080` |
| column up, **not hosting** | `x=0 1920x1080` — claims nothing |
| hosting keys, 65 cells = 650 px | **`x=650 1270x1080`** |
| hosting monitor, 82 cells = 820 px | **`x=820 1100x1080`** |
| closed | `x=0 1920x1080` |
| column process gone | `x=0 1920x1080` — released on unmap |

The window resizes beside the column at every width and is never covered. A
column up merely because the desktop is bare claims nothing, which is the
distinction §7.3 draws.

## The bug that made the zone look broken

The first run applied the zone correctly — the log showed 650, 820, 0 — while
the workspace never moved. The cause was mine and §6.3 states it:

> A surface must not have a buffer attached between asking for a new size and
> the compositor confirming it.

`apply_geometry` set the size and committed, then `draw` attached a buffer of
the **new** width to a surface still configured at the **old** one. The
compositor is entitled to reject that, and the symptom is an exclusive zone
that appears never to have been applied. Nothing is drawn now until the
configure confirming the requested width arrives.

Worth recording that the first *measurement* was wrong too: it looked for a
window with an `app_id`, on a workspace where the test's own window had not
appeared. The workspace rect is the right thing to watch, and it is what showed
the bar's zone working in the first place.

## The column

`src/vt.rs` is a terminal emulator sized to the measured subset (§10.5), not to
a standards document. **10 tests**, each pinning a property that breaks a real
program when got wrong:

- **HVP and CUP are the same function.** btop emits only `f`, never `H`.
- **SGR 22 clears bold without touching colour.** btop emits it over a thousand
  times a screen; collapsing it into `0` turns the display the wrong colour.
- **Deferred wrap.** Wrapping eagerly at the last column puts the next
  character on the wrong row and scrolls a screen that should not.
- **Autowrap off overwrites the last column.** fzf turns it off precisely to
  write there. *The first version of this test asserted the wrong behaviour* —
  `abcdef` in four columns ends `abcf`, not `abcd` — and the code was right.
- **Unknown sequences are skipped whole**, never printed.
- **A one-row terminal does not panic**, and resize clips rather than reflows.
- **Line feed at the bottom scrolls** — implemented although nothing measured
  needs it, because a terminal that mishandles it will one day be handed a
  program that uses one.

`src/pty.rs` opens the pty and hands the slave to `Command` as all three
streams, taking the controlling terminal in one `pre_exec`. **4 tests**,
including the one that matters:

> **An unrelated child must not hold the terminal open.** If the slave is
> inheritable, any long-lived process spawned afterwards keeps the column's
> terminal open: the hosted program exits, the master never reports
> end-of-file, and the column keeps a finished menu on screen for ever.

Verified at 1, 2, 4 and 8 test threads, because in a previous build this
surfaced only above three — the worst way for it to surface.

## Costs, measured

| surface | CPU, % of one core |
|---|---|
| wallpaper, animating | 11.00% (range 10.83–11.17) |
| wallpaper, suspended | at or below the 0.17% floor |
| bar | 0.62% (range 0.62–0.75) |

The bar was redrawing on **every wakeup** — ~74 draws/second for a readout that
moves once a second, because the poll returns as soon as the compositor answers
our own commit. It redraws on change now: ~1.7/s.

And §7.2's own warning landed: `wireless_quality()` spawns a subprocess,
because this machine has no free file to read it from, and it was being called
per draw. Caching at 30 s moved the bar from 0.75% to 0.62%.

## Outstanding

- **Hosted programs keep their own colours.** The VT passes SGR through, so
  btop draws in btop's palette rather than this system's. §7.6 wants a
  generated theme; that is not built yet.
- **fzf's remaining glyph** is one braille spinner frame during a slow list.
  §7.4's fix is upstream: build slow lists into a variable so the picker never
  enters its loading state.
- **Hardware-key readouts** still outstanding from Phase 4, closing in Phase 6.

## Gate

**MET.**
