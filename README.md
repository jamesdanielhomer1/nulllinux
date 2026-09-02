# nox

A desktop where every visible surface is a projection of one baked artefact.

**`NULL.md` is the specification and the only source.** It is self-contained:
scope and machine facts, the invariants, the medium, the hero, tone and colour,
the pipeline, the renderer, the chrome, desktop behaviour, Fedora integration,
verification, and a build order with a gate at the end of every phase.

Build progress and the evidence for each gate live in `docs/`.

| | |
|---|---|
| machine | `nox` — Fedora 44, i5-9300H, UHD 630 + GTX 1660 Ti Mobile |
| hero | a Kerr black hole, `a = 0.9` prograde |
| compositor | Sway |
| display | eDP-1, 1920x1080, scale 1.0 |

## Phases

| phase | state | evidence |
|---|---|---|
| 0 — machine facts | **done** | [`docs/phase-0-machine-facts.md`](docs/phase-0-machine-facts.md) |
| 1 — package abstraction, machine profile | **done** | [`docs/phase-1-abstractions.md`](docs/phase-1-abstractions.md) |
| 2 — font, ramp, palette, formats, placeholder | **done** | [`docs/phase-2-medium.md`](docs/phase-2-medium.md) |
| 3 — the renderer | **done** | [`docs/phase-3-renderer.md`](docs/phase-3-renderer.md) |
| 4 — compositor, keys, bind verifier | **done** | [`docs/phase-4-keys.md`](docs/phase-4-keys.md) |
| 5 — the bar, then the column | **done** | [`docs/phase-5-bar-and-column.md`](docs/phase-5-bar-and-column.md) |
| 6 — menus and components | **done** | [`docs/phase-6-menus.md`](docs/phase-6-menus.md) |
| 7 — terminal-adjacent surfaces, file manager | **done** | [`docs/phase-7-surfaces.md`](docs/phase-7-surfaces.md) |
| 8 — the real hero (Kerr raytracer) | **done** | [`docs/phase-8-hero.md`](docs/phase-8-hero.md) |
| 9 — the bake | **substantially done** — off-machine backup outstanding | [`docs/phase-9-bake.md`](docs/phase-9-bake.md) |
| 10 — root-owned surfaces | next | |
