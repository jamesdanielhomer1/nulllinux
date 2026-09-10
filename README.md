# nullLinux

A Fedora Remix in which every visible surface — the boot splash, the console,
the greeter, the lock screen, the bar, the menus, the file manager, the
browser's own chrome — is a projection of **one baked artefact**: a raytraced
Kerr black hole, `a = 0.6` prograde, rendered once and then drawn everywhere as
text.

It is a whole distribution, not a theme laid over someone else's desktop: its
own installer, its own package, its own boot media, and its own answer for every
ordinary thing a person does at a computer. It installs itself and asks ten
questions of whoever is installing it.

## The shape it has

| | |
|---|---|
| **one asset, many projections** | the hero is raytraced once, on a machine with a GPU, and ships prebuilt for every font strike a real panel selects. No installed machine needs a compiler or a GPU to draw it. |
| **derived, never declared** | the cell grid comes from the panel; the palette from a blackbody locus; the sixteen console slots, GTK, foot, nano and the browser chrome all come from that one palette. No hex is typed by hand. |
| **one typeface, two strikes** | Terminus, at an interface size and a bake size, everywhere from GRUB to the greeter. |
| **hardware-derived layout** | the profile comes from the attached displays and is regenerated when the hardware changes. The current package targets Fedora 44 on x86_64; hardware acceptance remains part of the release gates. |
| **report first** | a tool's default verb changes nothing. Mutation needs an explicit verb, and anything irreversible asks for the thing's own name, typed in full. |
| **layered verification** | source regressions, numerical comparisons, live Wayland checks and disposable installed-system tests cover different parts of the release. Results and remaining acceptance work are recorded separately. |

## The desktop

A tiling Wayland session (sway), with this project's own renderers drawing the
wallpaper, the bar, and a **column** — a single layer-shell strip that becomes
whatever you summon into it: the app launcher, the settings panel, the network
and audio pickers, the activity monitor. Every menu is one filter-picker. A
control is a mark and a rule, not a box.

Everything an ordinary day needs is reachable without dropping to a terminal:
launch and switch apps, files and network drives, the clipboard, a browser and
mail, screenshots and recording, accounts, the system language, default
applications, brightness and power and the radios, locking and idle and suspend.

## Building it

    bin/null-bootstrap        what is missing on this machine, and how to get it
    bin/null-build            build the renderer, master and derived assets
    bin/null-prebake          prepare every shipped strike from the HDR master
    bin/null-package          build the RPM
    bin/null-installer-iso    build the installer medium (Anaconda boot.iso)
    bin/null-iso              build the live medium (livemedia-creator; hours)
    bash verify/source.sh     source tests and production renderer build (CI)
    verify/run.sh             installed-system checks; read testing.md first
    verify/in-guest.sh        the same suite, inside a real nullLinux guest

The order is `build → prebake → package → iso`. A restored master can replace
the main raytrace. Vulkan compute (including software Vulkan), Rust and the
bake dependencies are needed on the build machine. See
[`docs/testing.md`](docs/testing.md) for the separate source, artifact and
installed-system checks, and the bake provenance requirements.

## Where it is

Version **0.1.0**, undergoing stabilization toward **1.0.0**. The current code
review found defects beyond the historical VM acceptance results. Its fixes and
fresh evidence are recorded in [`docs/review-1.0.md`](docs/review-1.0.md).
Release criteria, including a cold install on real hardware and visual
acceptance, remain in [`docs/goals.md`](docs/goals.md). Historical results are
kept separately in [`docs/STATUS.md`](docs/STATUS.md).

## What is here

| | |
|---|---|
| [`NULL.md`](NULL.md) | the specification, and the single source of truth. Self-contained: what must be true, how to verify it, and in what order to build it. The code cites its sections by number. |
| [`docs/design-language.md`](docs/design-language.md) | the design language, distilled: how a surface is allowed to look and to speak. |
| [`docs/goals.md`](docs/goals.md) | the road to 1.0.0 — acceptance criteria — and the scoped work that comes after it. |
| [`docs/STATUS.md`](docs/STATUS.md) | what is verified, where, what is not, and what is deliberately out of scope. |
| [`docs/measurements.md`](docs/measurements.md) | every figure quoted anywhere, with the method that produced it. |
| [`docs/LICENSING.md`](docs/LICENSING.md) | the licences, and why the font-derived assets carry their own. |
| `bin/` | the desktop, system and build commands. |
| `lib/` | shared menus, session ownership, desktop-entry parsing, battery readings and snapshots. |
| `verify/` | the checks, and the harnesses that install and drive a guest. |
| `bake/` | the raytracer, the palette derivation, and the exporters that write every app's colours. |
| `render/` | the Rust wallpaper, bar, column, lock screen and tiling layout. |
| `packaging/` | the RPM spec and the kickstarts. |

## Licensing

MIT, and the font-derived assets carry the OFL with them. See
[`docs/LICENSING.md`](docs/LICENSING.md).
