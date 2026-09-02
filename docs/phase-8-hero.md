# Phase 8 — The real hero

> Figures below are **as measured on the date given, against the inputs
> stated here**. They are a record of that run, not a claim about the
> system now. Current figures, with their inputs, live in
> [measurements.md](measurements.md) (§10.7).

Gate (NULL.md §11 Phase 8): *every analytic check passes; the accelerated
implementation is cross-validated against the reference on all three levels.*

Built 2026-08-29. The placeholder is now redundant.

## Analytic validation — 11 of 11

Run **before** any long bake, as §11 requires.

| check | result |
|---|---|
| horizon radius, a=0 and a=0.9 | `2.0000000000`, `1.4358898944` |
| inverse metric → Minkowski as 2M/r | deviation·r/2M = 1.0000 at both r=100 and r=1000 |
| H = 0 at emission | max \|H\| = 3.3e-16 |
| **Schwarzschild shadow** | **5.1962 vs 3√3 = 5.1962 — 0.000%** |
| **Kerr a=0.9 prograde shadow edge** | **2.8444 vs analytic 2.8444 — 0.000%** |
| **Kerr a=0.9 retrograde shadow edge** | **6.8323 vs analytic 6.8323 — 0.000%** |
| shadow asymmetry, and which side is prograde | prograde(+y) 2.844 < retrograde 6.832 |
| null condition along every geodesic | max \|H\| = 1.3e-12 (FP32 budget 1e-5) |
| step-budget exhaustion is not escape | 24 exhausted, 0 wrongly escaped |
| every equatorial crossing recorded | 509 rays hit the disk; 24 crossed twice, 1 three times |
| lensing off vs on | flat captures 14 (straight lines predict 12); lensed captures 38 |

## Three of these caught real errors, and two were in the tests

**The sign convention was backwards.** §3.3 says to fix which transverse offset
is prograde *by an explicit test, not by inspection*, because getting it
backwards mirrors the Doppler asymmetry and produces an image that looks
entirely plausible. The suite measured `6.8323` where it expected `2.8444` —
both values exactly right, only the labels swapped. **+y is the prograde side**,
and `kerr.PROGRADE_SIGN` now records that as a measured fact.

**"Lensing off" meant spin zero, which is still Schwarzschild and still bends
light.** The check was vacuous. Disabling lensing means `f = 0` — genuinely flat
spacetime and straight lines — and the corrected check predicts from geometry
how many rays should be captured (12) and finds 14, against 38 with lensing on.

**The crossing test never bent rays back through the plane.** It fired
near-parallel rays from off-axis; multiple crossings need the real near-edge-on
camera. With it, 24 rays cross twice and one three times — the far side of the
disk arcing over and under the shadow, which is the entire iconic image.

## Cross-validation — all three levels

| level | result | §10.2 expected |
|---|---|---|
| hit geometry | **100.00%**, 0 of 1920 cells differ | exact agreement |
| luminance | median **0.304%**, p95 0.81% | sub-percent median |
| temperature | median **0.000%**, p95 0.00% | sub-percent median |
| **quantised glyphs** | **99.74% identical**; 5 differ by ONE adjacent ramp level; **0 by more** | near-total, differences of one level |

FP32 WGSL produces the same ASCII as FP64 numpy. The third level is the one
that matters, because it is what reaches the screen.

## Throughput

| grid | per frame |
|---|---|
| 160x45 | 0.00 s |
| 320x90 | 0.01 s |
| 640x180 | 0.03 s |

Discrete against integrated at 320x90: **0.01 s vs 0.11 s**, about 11x. §5.5
predicted the discrete adapter would be roughly an order of magnitude faster
through the open-source driver, and it is.

The speed was checked rather than believed: at 640x180 the frame is 25.5% lit
with temperatures spanning 2398–24992 K, so it is real content; and **no ray
hits the step cap** — most escape quickly, so wall-clock is nowhere near
rays × max_steps.

## What was built

| path | what |
|---|---|
| `bake/kerr.py` | Kerr-Schild metric, Hamiltonian geodesics, closed-form results |
| `bake/validate.py` | the analytic suite |
| `bake/render_kerr.py` | the reference renderer → HDR intermediate |
| `bake/gpu/src/kerr.wgsl` | the compute shader |
| `bake/gpu/src/main.rs` | host, with explicit adapter selection |
| `bake/crossvalidate.py` | the three-level comparison |

The mode ladder is passed to the shader from the **one generator**, never
transcribed: three copies of a table drift and only one of them is the physics.

## Gate

**MET.**
