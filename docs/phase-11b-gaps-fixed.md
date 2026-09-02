# The gaps, and where they came from

> Figures below are **as measured on the date given, against the inputs
> stated here**. They are a record of that run, not a claim about the
> system now. Current figures, with their inputs, live in
> [measurements.md](measurements.md) (§10.7).

Reported on screen: the hero "has gaps still", and should be neither too noisy
nor too fast. Three separate causes, none of which any existing metric could
see.

## 1. A third of the disk was being deleted by the tone curve

`--black-pct 30` is a percentile **of lit cells**, so it blanked 30% of them
outright. Measured on the frames it was tuned against:

| | |
|---|---|
| frame lit at all | 33.6% |
| of the disk, carrying ink | **67%** |
| left third of the frame, blank | **94%** |
| interior holes (speckle) | 15 cells |

So the gaps were not speckle — they were one contiguous region: the **receding
side**. `g⁴` beaming leaves it 4.8× dimmer than the approaching side (median
luminance 0.0027 against 0.0129), and a global log exposure spanning 260×
cannot hold both ends.

**The tuner had no way to object.** It scored ink and entropy, and ink is a
whole-frame statistic: a well-exposed small subject and a half-erased large one
score identically. It returned the curve that deleted a third of the hero and
reported it as best.

The rule *"no tone curve can light a cell the render left empty"* was already
in §4.2. Its dual was not, and the dual is the one that bites:

> **No tone curve may blank a cell the render lit.**

Coverage is now a hard constraint checked before ink, and ink is read as an
outcome. With the subject intact, ink is decided by *framing* — so if it is
still high, the camera is too close and the fix is §3.5, not the black point.

Measured on the same frames, the honest curve was **better on every axis**
except the one being optimised: 98.9% coverage and the highest ramp entropy in
the sweep, against 67% and a lower entropy.

## 2. Three of the twelve modes were modulating empty space

`MODES` was a hand-written table from when `a = 0.9` put the ISCO at 2.32 M. At
`a = 0.6` the ISCO is 3.829 M — and three bands sat at 2.48, 3.08 and 3.63 M,
**inside the inner edge**, where there is no material at all.

They were also the three fastest, turning once every 0.50, 0.67 and 0.83
seconds. So the noisiest, fastest thing on screen was a pattern applied to a
hole.

The ladder is derived from its constraints now and tracks the spin.

## 3. "Too fast" needed a bound Nyquist does not give

Nyquist says what can be **sampled** without strobing. It says nothing about
what can be **watched** without shimmering, and those are different questions.
A band turns once every `LOOP_PERIOD · m / n` seconds; the old ladder's inner
bands turned in half a second.

`MIN_REVOLUTION_S = 2.0` is the new, separate bound. Physically the shear
really is faster inward and this does not pretend otherwise — it says that
where the disk turns faster than the eye can follow, carrying **no** mode is
more honest than carrying an aliased one. The inner disk is smooth for the same
reason the frame rate is finite.

Arms falling 6 → 1 inward is now enforced rather than preferred: as a tie-break
it lost to whichever radius landed nearest the target, which put six arms back
into the middle of a falling sequence.

## Result

| | before | after |
|---|---|---|
| bands | 12 (3 inside the ISCO) | 7, all in real material |
| fastest revolution | 0.50 s | **2.00 s** |
| disk covered | 67% | **99%** |
| glyph churn | 0.87–1.38 %/frame | **0.51–0.99 %/frame** |
| colour churn | 3.19–4.86 %/frame | **3.02–4.58 %/frame** |
| ink | 19–23% | 28–35% |

**Calmer and more complete at once.** Ink rose because the subject came back;
churn fell because the fastest modes were the ones that had no business
existing. The two are not in tension here, which is why the old numbers looked
acceptable while the picture did not.

Loop closure stays exact on every target — frame 0 reproduces byte-identically
from the final hysteresis state — and wrap churn stays below the interior
maximum everywhere, so the seam does not announce itself.

All 11 analytic physics checks still pass.
