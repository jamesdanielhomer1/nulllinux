# Phase 2 — Font, ramp, palette, formats, placeholder

> Figures below are **as measured on the date given, against the inputs
> stated here**. They are a record of that run, not a claim about the
> system now. Current figures, with their inputs, live in
> [measurements.md](measurements.md) (§10.7).

Gate (NULL.md §11 Phase 2): *ramps reproducible and monotonic per strike; the
font hash guard trips on a swapped font; a placeholder animation exists and its
frame 0 is reproduced byte-identically from the final hysteresis state.*

Built 2026-08-29.

## Gate evidence

| requirement | result |
|---|---|
| ramp reproducible | re-derivation is **byte-identical** |
| monotonic, bake strike | ` .^<+=*cn3wUyH0@` — 16 levels, peak coverage 0.3056 |
| monotonic, interface strike | ` .<+=rvcnhem8B$@` — 16 levels, peak coverage 0.2278 |
| font hash guard | **trips** on a swapped font; passes when unchanged (it discriminates) |
| placeholder animation | 240 frames, 320x90 |
| loop closure | frame 0 reproduces **byte-identically** from the final hysteresis state |

## §2.3 confirmed by measurement, not assumed

The specification claims a ramp belongs to exactly one strike. On this font
that is now demonstrated: the bake ramp re-measured at 10x18 has **two
inversions** —

```
'3' coverage 0.1500  ->  'w' coverage 0.1444     RUNS BACKWARDS
'y' coverage 0.1611  ->  'H' coverage 0.1611     ties
```

A meter built on the reused ramp would decrease as its value rose.
`verify/check-cross-strike-ramp.sh` asserts the inversion still exists, so if
a font update ever makes the rule vacuous on this font, that is noticed rather
than silently assumed.

## Filter thresholds were swept, not guessed

The anisotropy and centroid thresholds decide which glyphs read as tone rather
than as texture. Both were set by sweeping and judging the resulting ramp:

| anisotropy | centroid | levels | step evenness (CV) | ramp |
|---|---|---|---|---|
| 5.0 | 0.30 | 16 | 0.422 | `' .^<+=*cn3wUyH0@'` |
| 8.0 | 0.35 | 16 | **0.340** | `' .,^"<+=cJ3wyH0@'` |

**The evenness-optimal setting was rejected.** It reaches a better CV only by
admitting `,`, `"` and `J` — glyphs the filter exists to exclude, which sit off
centre or read as strokes and will show as grain in flat areas. That is
optimising the metric at the expense of the thing the metric proxies for, which
is the same trap §4.2 describes for ramp entropy. Taken: anisotropy ≤ 5.0,
centroid ≤ 0.30.

The eigenvalue floor matters exactly as §2.4 says. Each lit pixel contributes
the second moment of a unit square, 1/12, on the diagonal; without it every
two-pixel glyph is exactly collinear, its minor eigenvalue is zero, and `.` is
rejected — removing the low end of the ramp the void depends on.

## Palette

256 entries, 32 log-spaced temperatures x 8 linear values, built analytically
from the Planckian locus over 1667–25000 K. **§4.7 confirmed:** the hottest
entry is `#a5beff`, genuinely blue; the solar band at 5663 K is `#ffefe6`,
white. Blue inner, white mid, red outer — the Doppler asymmetry reading at a
glance, from physics rather than choice.

Out-of-gamut chromaticities are lifted toward the achromatic axis rather than
clipped, because clipping a negative channel is a hue shift and it would
quietly desaturate the two ends that carry the asymmetry.

## The ink ceiling is a composition problem, not a curve problem

First quantise gave **8.0% ink** against §4.2's ~20% target. Sweeping the tone
curve could not fix it, and the reason is worth recording:

> Only **12.2%** of cells had non-zero luminance at all. No tone curve can
> light a cell the render left empty.

That is a ceiling set by framing, not by exposure. The placeholder was reframed
from 28 M to 20 M half-width, lifting the lit ceiling to 24%, after which the
curve lands ink at **21.3%**. `bake/tune.py` now reports the ceiling alongside
every candidate and says so explicitly when the target is above it, so the next
person does not spend the same hour on the wrong dial.

The real hero stays at §3.5's 28 M. The stand-in is framed tighter because its
crude radial warp does not spread light the way real lensing does; this is a
property of the stand-in, not a disagreement with §3.5.

## Two corrections to the specification

**§4.4 overstated the churn ratio.** It said colour churn runs "roughly an
order of magnitude" above glyph churn. Measured here across hysteresis margins
0.00–0.80, the ratio ranges 1.83–3.13 and never approaches ten. The original
figure describes one emission model, not a law: how far colour churn exceeds
glyph churn depends on how the subject distributes motion. §4.4 now states the
invariant — colour churn *above* glyph churn — and warns against tuning a
stand-in until its ratio matches a number taken from different physics.

**Appendix A listed tone-curve values as settled.** It now says *re-tuned per
emission model* for the black point, white point and gamma, with the reason:
§4.1 already requires re-tuning whenever the emission model changes, so a
number in the settled table would be read as fixed and would be wrong for every
model but the one it came from. The placeholder runs at P10 / P99.5 / γ0.6,
which is not what real physics will want.

**§2.4's PSF2 magic was ambiguous.** The bytes on disk are `72 B5 4A 86`; read
as a little-endian word that is `0x864AB572`. Stating it the other way round
builds a parser that rejects every valid font. Corrected, along with a note to
parse the Unicode table rather than assume glyph index equals codepoint.

## Measured on this machine

| quantity | value |
|---|---|
| placeholder render, 240 frames at 320x90 | 4.9 s |
| quantise, 240 frames | 4.2 s |
| ink fraction | 21.3% |
| ramp entropy | 0.366 |
| glyph churn | 5.91%/frame |
| colour churn | 11.58%/frame |
| wrap vs interior-max glyph churn | ratio 0.54 (scale-free, §10.3) |
| compression | 13,824,000 → 469,497 bytes (29.4x) |

Regeneration of the quantised placeholder is **byte-identical**, which is the
precondition §5.7 sets for leaving a derived file out of git. It is therefore
gitignored rather than committed.

## Gate

**MET.**
