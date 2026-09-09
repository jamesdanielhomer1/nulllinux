# nullLinux

A Fedora Remix in which every visible surface — the boot splash, the console,
the greeter, the lock screen, the bar, the menus, the file manager, the
browser's own chrome — is a projection of **one baked artefact**: a raytraced
Kerr black hole, `a = 0.9` prograde, rendered once and then drawn everywhere as
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
| **any hardware** | any panel, any number of monitors, any machine. The profile is derived on first boot and re-derived whenever the hardware disagrees with it. |
| **report first** | a tool's default verb changes nothing. Mutation needs an explicit verb, and anything irreversible asks for the thing's own name, typed in full. |
| **every claim measured** | the verify suite is 66 checks, and almost every one exists because something it now catches had already shipped. |

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
    bin/null-prebake          raytrace the hero for every strike (needs a GPU)
    bin/null-package          build the RPM
    bin/null-installer-iso    build the installer medium (Anaconda boot.iso)
    bin/null-iso              build the live medium (livemedia-creator; hours)
    verify/run.sh             the whole verify suite
    verify/in-guest.sh        the same suite, inside a real nullLinux guest

The order is `prebake → package → iso`, and each refuses rather than guesses
when the step before it has not run.

## Where it is

Version **0.1.0**. The installer ISO installs end to end and the installed
system boots to the desktop; the live ISO boots to the desktop; the whole verify
suite passes on the build host and inside an installed guest. What stands between
here and **1.0.0** — chiefly a clean install on real hardware — is written down,
with acceptance criteria, in [`docs/goals.md`](docs/goals.md). Where each claim
was proven, and what has not been, is in [`docs/STATUS.md`](docs/STATUS.md).

## What is here

| | |
|---|---|
| [`NULL.md`](NULL.md) | the specification, and the single source of truth. Self-contained: what must be true, how to verify it, and in what order to build it. The code cites its sections by number. |
| [`docs/design-language.md`](docs/design-language.md) | the design language, distilled: how a surface is allowed to look and to speak. |
| [`docs/goals.md`](docs/goals.md) | the road to 1.0.0 — acceptance criteria — and the scoped work that comes after it. |
| [`docs/STATUS.md`](docs/STATUS.md) | what is verified, where, what is not, and what is deliberately out of scope. |
| [`docs/measurements.md`](docs/measurements.md) | every figure quoted anywhere, with the method that produced it. |
| [`docs/LICENSING.md`](docs/LICENSING.md) | the licences, and why the font-derived assets carry their own. |
| `bin/` | the components: 59 tools, each with one job and a caller. |
| `lib/` | the shared shell: the menu chrome, the surface supervisor, the snapshotter. |
| `verify/` | the checks, and the harnesses that install and drive a guest. |
| `bake/` | the raytracer, the palette derivation, and the exporters that write every app's colours. |
| `render/` | the Rust renderers: the wallpaper, the bar, the column, the tiling layout. |
| `packaging/` | the RPM spec and the kickstarts. |

## Licensing

MIT, and the font-derived assets carry the OFL with them. See
[`docs/LICENSING.md`](docs/LICENSING.md).
