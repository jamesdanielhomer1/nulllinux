# Phase 9 — The bake

> Figures below are **as measured on the date given, against the inputs
> stated here**. They are a record of that run, not a claim about the
> system now. Current figures, with their inputs, live in
> [measurements.md](measurements.md) (§10.7).

Gate (NULL.md §11 Phase 9): *two independent bakes agree to about three
significant figures on every churn metric. All targets derived. The HDR cell
master is backed up somewhere that is not this machine.*

Run 2026-08-29.

## The bake

240 frames at 640x180 cells, 4x supersampling — 2560x720 = **1,843,200 rays per
frame**, 442 million rays in total. Traced in **77.5 s**, downsampled in 29.1 s.

Settled parameters, from Appendix A and §3.5: `a = 0.9` prograde, inclination
100° (corrected to 80° later in this phase — see “The hero was upside down”), half-width 28 M, ISCO 2.3209, `r_out` 20 M, 12 mode bands from the one
generator.

## The tone curve was re-tuned against real emission

§4.1 says this is not optional and that the placeholder's curve will be wrong.
It was:

| | black | white | gamma | ink | entropy |
|---|---|---|---|---|---|
| placeholder | P10 | P99.5 | 0.6 | 21.3% | 0.366 |
| **real physics** | **P20** | **P99.0** | **0.6** | **20.5%** | **0.367** |

The black point moved a full ten percentiles. `g⁴` beaming concentrates the
light differently, exactly as §4.1 predicts, and a curve carried over would
have sat at 23% ink.

The top-entropy candidate was P10/P99.0 at 22.87%, and it was **not** taken:
§4.2 constrains ink to ≈20% and maximises entropy *subject to that*, so the
right pick is the one nearest the constraint.

## Every target derived, every one closing exactly

| target | grid | ink | entropy | glyph churn | colour churn | loop |
|---|---|---|---|---|---|---|
| master | 640x180 | 20.5% | 0.367 | 6.65% | 11.75% | **exact** |
| target-2 | 320x90 | 21.0% | 0.375 | 6.59% | 12.05% | **exact** |
| target-4 | 160x45 | 22.2% | 0.391 | 6.29% | 12.14% | **exact** |
| tty | 80x24 | 21.9% | 0.388 | 5.18% | 10.83% | **exact** |
| logo | 40x16 | 18.4% | 0.339 | 3.29% | 7.84% | **exact** |

320x90 and 160x45 divide the master and are box-averaged **in the HDR domain**,
before quantisation — glyph indices cannot be averaged, since the mean of `.`
and `@` is not a tone but a different glyph. 80x24 and 40x16 do not divide 180
rows, so both are **re-traced at their own grid** (§5.3).

Colour churn exceeds glyph churn on every target, which is the invariant §4.4
actually states — the ratio itself is content-dependent and is not a target.

**The logo was wrong first.** Framed as a tight crop at 9 M half-width it came
out at **66% ink**: 83% of the frame was disk, the void stopped being empty and
the composition stopped reading. Reframed to the settled 28 M it sits at 18.4%
and the shadow reads. The logo is the hero at logo size, not a close-up of it.

## Reproducibility — bit-identical

Both bakes agree **exactly**, not to three significant figures:

```
5/5 sampled HDR frames bit-identical, worst relative difference 0.000e+00
quantised output identical: md5 b70cbba5..., 2,326,826 bytes both
every churn metric equal to full precision
```

That is a stronger result than the gate asks for, and it tests something
narrower, so §5.6 was amended to say which is which: with **regular-grid**
supersampling nothing in the pipeline is random and bit-identity is the correct
check; with **stochastic** supersampling the three-significant-figure test is.
The original text assumed stochastic sampling that this pipeline does not use.

## A design flaw the second bake exposed

The first bake traced all 240 supersampled frames to disk before downsampling
any of them — **7.1 GB into a 7.8 GB tmpfs**. Bake A fit; bake B did not, and
died with **no output at all**, which is what running out of space looks like.

The driver's own docstring already claimed the full-resolution frames are never
kept. It now works in chunks of 24 frames, bounding the working set to about
**700 MB** regardless of frame count.

## Outstanding

**The off-machine backup of the HDR cell master is NOT done.** The USB SSD is
not attached, and there is nowhere else off this machine to put it. The gate is
therefore **not fully met**, and that is recorded rather than glossed.

What has been done: the master was moved off `/tmp` — a **tmpfs**, which a
reboot would have destroyed, and §5.1 makes retaining it a hard requirement —
to `/root/nulllinux-hdr-master`, 423 MB on the btrfs root, with a
`MANIFEST.sha256` of all 240 frames so a later restore can be checked.

## A measurement hazard, met the hard way

Several display verifications in this phase measured **the lock screen**. The
idle ladder built in Phase 6 fired after 300 s of an unattended session, and a
lock surface renders above every layer surface — so every capture succeeded,
looked plausible, and was of the wrong thing. The clock in the bar not
advancing between two captures is what finally showed it.

Then, reaching for the obvious fix, **killing the lock client left the
session-lock protocol held** and the compositor fell back to a blank refusal
screen. My own plan records that scar for a different compositor; it applies
here too. Recovery is to start a fresh lock client, not to kill one.

Both are now in §10.7: stop the idle ladder before a measurement pass and say
so, verify a capture is live before trusting it, and never kill a lock client
to see the desktop.

## Corrected after review: the inclination was upside down

Reviewed on screen, 100° read as upside down, and it was. §3.5 had picked it as
"a composition choice that costs nothing physically" — true, and that cuts both
ways: 80° and 100° are the same image flipped, so there was nothing to lose by
taking the one that reads correctly.

At 100° the lensed far side arcs **under** the shadow. Every familiar image of
such an object has it arcing **over**, which is 80°. Verified rather than
assumed: the two renders differ by a relative **0.0000** after a vertical flip,
so the change is purely composition.

The master was re-baked and every target re-derived. The metrics are unchanged,
as a mirror image's must be: ink 20.5%, entropy 0.367, loop closure exact.

**And the reflex to fix it by moving the camera closer was wrong.** At 18 M
half-width the lit ceiling reaches 60% and ink 47% — the frame fills with disk
and the void stops being empty, which is §4.2 undone by one number. It is the
same mistake the logo made. §3.5 now records it, because a small grid keeps
inviting it.

## Corrected after review: the pattern was gating the disk, not modulating it

Reviewed on screen and reported as chaotic, with random voids in the disk. It
was, and the cause was arithmetic rather than taste.

The per-band amplitudes are relative weights *between* bands. Nothing bounded
their **sum**, and where several envelopes overlap they add — so the summed
field swung **±3.5**. At a modulation depth of 0.18 that put the temperature
factor between 0.37 and 1.60, and because **intensity follows as `T⁴`** that is
an intensity ratio of **347×** from the pattern alone.

That is not a modulation, it is a gate: wherever bands aligned negative the
disk went dark, and the render filled with voids that look like structure and
are not.

Normalising the sum and applying the depth once gives **4.1×**, which reads as
texture. The depth is now folded into the emitted amplitudes so every consumer
computes `1 + Σ bands` — it had been a bare `0.18` written into *both*
renderers, which is two copies of one number.

The effect on churn is the clearest evidence of what was wrong:

| | before | after |
|---|---|---|
| glyph churn / frame | 6.65% | **1.55%** |
| colour churn / frame | 11.75% | **5.54%** |
| glyphs differing over a quarter loop | — | 7.8% |

The old figure was mostly **flicker** — cells gating on and off — not motion.
The new one is stable structure that accumulates 7.8% of changed glyphs over
sixty frames, which is the split §4.4 asks for: glyphs carry structure, colour
carries the residual.

## Gate

**NOT MET** — the off-machine backup is outstanding. Everything else is done:
both bakes bit-identical, all five targets derived with exact loop closure, and
the curve re-tuned against real emission.
