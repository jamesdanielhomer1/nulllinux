# Phase 3 — The renderer

> Figures below are **as measured on the date given, against the inputs
> stated here**. They are a record of that run, not a claim about the
> system now. Current figures, with their inputs, live in
> [measurements.md](measurements.md) (§10.7).

Gate (NULL.md §11 Phase 3): *the placeholder animates as a wallpaper; it
suspends under an opaque window; it stops on display power-off; it drops frame
rate on battery. Its CPU cost is measured by the method of §6.4 and recorded
with its inputs.*

Built 2026-08-29.

## Gate evidence

| requirement | evidence |
|---|---|
| animates as a wallpaper | 97.2% of sampled screen pixels are **exact palette entries** |
| suspends under an opaque window | `drawn=0` with a window visible; 24 fps with none |
| stops on display power-off | **0 draws** in 7 s with the output off (was 24 before the fix) |
| drops rate on battery | 120 → 48 draws over the same window |
| CPU cost | measured below |

## Measured on this machine

`verify/measure-render.sh`, 6 s window, median of 3 runs, load 0.78:

| state | CPU, % of one core | range |
|---|---|---|
| animating | **11.00%** | 10.83–11.17 |
| suspended | **0.17%** | 0.00–0.33 |
| animating, on battery | **5.67%** | 5.50–5.67 |

One scheduler tick is 0.17% over this window, so the suspended figure is **at
the measurement floor** and the honest statement is "at or below 0.17%", not
"0.17%". The animating figure is ~1.4% of total CPU across 8 threads for a
full-screen animated wallpaper, and it is paid only on an empty workspace.

The state is **forced** for each row rather than left to whatever the desktop
was doing (§10.7), through two verification affordances named so they cannot
be mistaken for settings: `RENDER_ASSUME_OCCLUDED` and `RENDER_ASSUME_BATTERY`.
The battery path could not otherwise be exercised on a plugged-in machine, and
a path that is never run is a path that does not work.

## Three findings

**§6.4 was wrong about display power-off.** It said frame callbacks stop when
the output powers down, so a surface suspends "for free". Measured here, the
surface kept receiving callbacks and **kept drawing with the display off** — 24
draws in 6 seconds, burning CPU behind a dark screen where nothing could reveal
it. The renderer now queries the output's power state explicitly and subscribes
to output events. After the fix: 0 draws in 7 seconds. §6.4 corrected.

**Occlusion counting was wrong twice, and both looked like the check being
broken.** First, sway uses the `con` node type for split containers as well as
windows, so a workspace holding one terminal reported two. Second — and this is
the one that cost the most time — counting the whole tree counts windows on
*every* workspace, so the wallpaper suspended permanently even on a bare
desktop. Scoping is now by **visibility**, which includes a shown scratchpad
and excludes a hidden one as the same rule rather than a special case. A
further trap: `get_tree` carries no visibility field on workspace nodes at all;
only `get_workspaces` does, so scoping on the field where it appears absent
would have counted nothing and never suspended. §6.4 corrected.

**Substring matching on someone else's JSON was the wrong instinct**, and I had
written the rule against it myself (§8.10). The first counter matched
`"type": "con"` as text. It is parsed now.

## Verified rather than assumed

- **320×90 cells at 6×12 is exactly 1920×1080 px**, so the wallpaper lands 1:1
  with no scaling — §5.3's arithmetic, confirmed by the rasteriser.
- **The delta property is real**: the terminal backend writes 14.2% of cells
  per frame; the compositor backend touches ~18%. The rest are static because
  of hysteresis, which is what pays for that stage three times over.
- **The bold strike is genuinely distinct**: 251/258 shared glyphs (97.3%) have
  different bitmaps, so §6.2's second atlas earns its bytes. Had it been under
  half, the argument would not have held.

## Traps met, all of which §6.3 predicted

- `buffer.attach_to(surface)`, never `surface.attach(buffer.wl_buffer())`.
- Two shm slots cycled by hand; `canvas()` refusing a slot the compositor still
  holds is what makes the cycle safe.
- The first draw happens on the initial configure, not before it.

And one the specification did not predict but §8.6 describes in another
context: `pkill -f render` matched the measuring shell's own command line and
killed it. Matching must be on the executable, not the command line.

## Gate

**MET.**
