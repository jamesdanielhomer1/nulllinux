# The hero, recomposed

> Figures below are **as measured on the date given, against the inputs
> stated here**. They are a record of that run, not a claim about the
> system now. Current figures, with their inputs, live in
> [measurements.md](measurements.md) (§10.7).

Settled 2026-08-29 against a reference image of the previous implementation.

| | was | now |
|---|---|---|
| spin `a` | 0.9 | **0.6** |
| inclination | 80° | **70°** |
| inner-edge temperature | 20000 K | **5000 K** |
| ISCO | 2.321 M | 3.829 M |
| horizon | 1.436 M | 1.800 M |
| tone curve | P20 / P99.0 / γ0.6 | **P30 / P99.0 / γ0.8** |
| ink | 20.5% | 22.4% (master), 19.1% (logo) |

## Three composition controls, one of which was not being treated as one

**Inner-edge temperature decides the colour of the entire image**, and it had
been left at a value chosen for the physics rather than the picture. It sets
where the disk sits on the Planckian locus: at 20000 K the inner disk lands at
the blue end of the palette's 1667–25000 K range, which is why the hero read as
blue-white when the reference is gold. At 5000 K the whole disk sits in the
warm half, with white only in the hottest cells.

**Spin is composition too.** It sets how far the shadow is dragged out of round
and how hard the approaching side is beamed. At 0.9 the beaming is strong
enough to gate one half of the disk dark and the shadow is markedly D-shaped;
at 0.6 the shadow is close to round and both halves carry light.

**80° was too edge-on.** A thin disk projects to `cos i`, so 80° gives 0.17 —
thin enough that the two lensed arcs merge and the whole reads as one lopsided
blob with a bite out of the right side. 70° gives 0.34: a broad flat ellipse
with the shadow clearly inside it and the lensed far side separated below.

## What had to be rebuilt, and why not less

The ISCO **moves with spin** — 6 M at `a=0` to about 1.24 M at `a=0.998` — so
the mode ladder was rebuilt for the new spin rather than reused, because every
band radius is derived from it (§3.4.1). Reusing the `a=0.9` table would have
put the bands where they belong on a different black hole.

The tone curve was re-tuned from scratch, as §4.1 requires. It is fitted to a
distribution of emitted intensity, and all three parameters moved that
distribution. The black point went from P20 to P30 and gamma from 0.6 to 0.8;
carrying the old curve over would have left the image at 29.9% ink against a
20% target.

## Previewing

`bake/preview_hero.py` runs the whole chain — trace, downsample, tone curve,
quantise, glyph ramp, raster — for two frames at proxy resolution in about five
seconds. Comparing candidates in radiance would be comparing something nobody
looks at: the quantiser has a tone curve, an ink target and a hysteresis rule,
and it is not a neutral observer.

Two frames rather than one, because the churn statistics are differences
*between* frames and the hysteresis that decides the final glyphs never runs on
a single one. The first version passed one frame and died reporting a statistic
it had no data for.

## Verification

All 11 analytic physics checks pass at the new spin, including the shadow-edge
comparisons at 0.000% error. Loop closure is exact on every derived target:
frame 0 reproduces byte-identically from the final hysteresis state.

Wrap churn stays below the interior maximum on every target — 0.94% against
2.60% on the console grid, 1.09% against 2.34% on the logo — so the loop does
not announce itself at the seam.

## Still open

The reference image has its bright, approaching side on the **left**; this
render has it on the right. The two are mirror images, which is a camera
azimuth of 180° and costs nothing physically — the same reasoning that settled
80° against 100° in §3.5. Not changed without asking, because unlike the
upside-down case there is no independent argument for one side over the other.
