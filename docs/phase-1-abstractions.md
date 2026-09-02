# Phase 1 — The package abstraction and the machine profile

> Figures below are **as measured on the date given, against the inputs
> stated here**. They are a record of that run, not a claim about the
> system now. Current figures, with their inputs, live in
> [measurements.md](measurements.md) (§10.7).

Gate (NULL.md §11 Phase 1): *a component exists that answers every verb in
§9.1 without any other component naming the package manager, and a structural
check enforces that.*

Built 2026-08-29.

## Why these two, first

NULL.md §11 puts them before everything because both are cheap now and
expensive later: every component written before them names a package manager
and hard-codes a display geometry, and they are then found one at a time over
the following months. Nothing else exists yet, so there is nothing to retrofit.

## What was built

| path | what it is |
|---|---|
| `bin/pkg` | the package abstraction — the **only** component that may name a package manager |
| `lib/pkg/dnf5.sh` | the Fedora backend, selected by discovery |
| `packages/fedora/base.list` | per-distribution package names, each with its reason |
| `bin/machine` | machine identity, output geometry, and **runtime** hardware probes |
| `machines/nox.conf` | this machine's profile |
| `verify/check-package-abstraction.sh` | the structural check the gate requires |
| `verify/selftest-package-abstraction.sh` | proof the structural check can fail |
| `verify/run.sh` | runs every verifier |

## §9.1 verb coverage — all confirmed by running them

| verb | result |
|---|---|
| `search` | OK |
| `what-owns-this-file` | `/usr/bin/sway` → `sway-1.11-3.fc44.x86_64` |
| `what-is-orphaned` | OK — 0 orphans |
| `list-explicitly-installed` | OK — 262 packages (the user-installed set, not all installed) |
| `refresh-metadata` | OK — distinct from upgrade |
| `upgrade-available` | OK — non-mutating, none pending |
| `is-installed` | OK — and discriminates: a bogus name exits 1 |
| `install` / `remove` / `upgrade` | present; refuse empty arguments |
| `install-list` | present; refuses an unknown list |
| unknown verb | refused |

## Design decisions worth recording

**The distribution is discovered, not assumed.** `bin/pkg` scans `lib/pkg/`
and takes the first backend whose `backend_detect` succeeds. Adding a
distribution means adding one file and changing nothing else anywhere.

**The exemption from the structural check is narrow and explicit** —
`bin/pkg`, `lib/pkg/`, `packages/`, and the checker itself. An exemption
expressed as a broad pattern is an abstraction that has already gone. Markdown
is exempt because prose may discuss package managers.

**The checker had to be exempt from itself.** It must name the managers in
order to search for them. This is listed as a path rather than worked around,
because the alternative — assembling the names from fragments so the literal
never appears — is cleverness that the next reader has to decode.

**The machine profile deliberately carries no hardware capability.** §0.2
requires components to degrade by *absence of hardware, discovered at
runtime*. A profile declaring `has_battery = true` would be a second source of
truth that goes stale, and a row that checks a flag rather than the hardware
is a row that lies. `machine probe <capability>` looks at the machine:
battery, mains, backlight, lid, wireless, bluetooth, discrete-gpu — all seven
present here.

**Grids are derived, never stored.** `interface_cols` and the rest are computed
from the geometry and the strike's cell size. A grid written down in two places
is a grid that will eventually disagree with itself. Confirmed on this machine:

```
interface  10x18 px  ->  192 x 60 cells, exact
bake        6x12 px  ->  320 x 90 cells, exact
```

The bake grid is exactly §5.3's wallpaper target, which is the arithmetic
working out rather than a coincidence — 6x12 into 1920x1080.

**The profile fails loudly on a missing key** rather than returning empty. A
geometry that silently becomes zero is worse than a stopped program.

**Selection is by hostname with an explicit override** (`$NULL_MACHINE`), per
§0.2. Both paths verified, including that an unknown machine is refused loudly.
This is the first thing that depends on the Phase 0 hostname change.

## Gate

**MET.** All §9.1 verbs answerable; no other component names a package
manager; the structural check enforces it; and the check is proven able to
fail by planting a real violation, confirming it is caught, and confirming it
clears when removed (§10.1 rule 3).
