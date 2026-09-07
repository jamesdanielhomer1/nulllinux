# nullLinux

A complete desktop operating system in which every visible surface — the boot
splash, the console, the greeter, the lock screen, the bar, the menus, the file
manager, the browser's own chrome — is a projection of **one baked artefact**: a
raytraced Kerr black hole, `a = 0.9` prograde, rendered once and then drawn as
text.

A Fedora 44 Remix. It installs itself, from its own installer, and asks ten
answers of the person installing it.

## The goal

**To replace the system on `nox` and be the machine somebody uses every day.**

Not a theme, not a rice, not a desktop configuration on top of something else: a
distribution with its own installer, its own package, its own boot media, and
its own answer for every ordinary thing a person does at a computer. It is
finished when it is installed on real hardware and nothing about using it sends
you back to a terminal to work around it.

`nox` is a ThinkPad T480 — 1366x768, UEFI with secure boot, Intel graphics, two
batteries. It currently runs `/opt/rice`, the system this replaces.

## The shape it is meant to have

| | |
|---|---|
| **one asset, many projections** | the hero is baked once, on a machine with a GPU, and ships prebuilt for nine font strikes. No installed machine needs a compiler or a GPU to draw it. |
| **derived, never declared** | the cell grid comes from the panel; the palette from a blackbody locus; the sixteen console slots, GTK, foot, nano and the browser chrome all come from that one palette. No hex is typed by hand. |
| **one typeface, two strikes** | Terminus, at an interface size and a bake size, everywhere from GRUB to the greeter. |
| **any hardware** | any panel, any number of monitors, any machine. The profile is derived on first boot and re-derived whenever the hardware disagrees with it. |
| **report first** | a tool's default verb changes nothing. Mutation needs an explicit verb, and anything irreversible asks for the thing's own name typed in full. |
| **every claim measured** | 57 checks, and almost every one exists because something it now catches had already shipped. |

## Using it

    bin/null-bootstrap            what is missing on this machine, and how to get it
    bin/null-prebake              bake the hero for every strike (needs a GPU)
    bin/null-package              build the RPM
    bin/null-installer-iso        build the installer medium (hours)
    verify/run.sh                 57 checks
    verify/in-guest.sh            the same checks, inside a real nullLinux guest

Installing it on the machine it is for: [`docs/installing-on-nox.md`](docs/installing-on-nox.md).

## What is here

| | |
|---|---|
| [`NULL.md`](NULL.md) | the specification, and the only source. Self-contained: what must be true, how to verify it, and in what order to make it. |
| [`docs/STATUS.md`](docs/STATUS.md) | what is verified, what is not, and what is deliberately out of scope. |
| [`docs/installing-on-nox.md`](docs/installing-on-nox.md) | the runbook for the install that ends the project. |
| [`docs/measurements.md`](docs/measurements.md) | every figure quoted anywhere, with the method that produced it. |
| `bin/` | 54 components. Each is a tool with one job and a caller. |
| `verify/` | the checks, plus the harnesses that install and drive a guest. |
| `bake/` | the raytracer, the palette derivation, and the exporters that write every app's colours. |
| `render/` | the Rust renderers: the wallpaper, the bar, the column, the tiling layout. |
| `packaging/` | the RPM spec and the kickstart. |

## Licensing

MIT, and the font-derived assets carry the OFL with them.
See [`docs/LICENSING.md`](docs/LICENSING.md).
