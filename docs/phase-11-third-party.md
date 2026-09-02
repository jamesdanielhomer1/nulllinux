# Phase 11 — Third-party applications

> Figures below are **as measured on the date given, against the inputs
> stated here**. They are a record of that run, not a claim about the
> system now. Current figures, with their inputs, live in
> [measurements.md](measurements.md) (§10.7).

Gate (NULL.md §11 Phase 11): *the font substitution probe discriminates and
shows the intended font. Deslopping is default-deny. Empty states carry the
hero, drawn as text.*

Run 2026-08-29.

## The font probe, and the claim it disproved

§8.10 said a bitmap-only font **will not render in a browser engine, at any
size**. That is not what happens here, and the truth is harder to catch.

`verify/check-font-substitution.py` measures a sample string under the intended
family plus two controls — a **bogus** family, which cannot exist and therefore
*is* the fallback, and a family **known to differ**, which fails the probe
itself if everything measures alike.

| engine | Terminus (.otb bitmap) | Liberation Mono | bogus |
|---|---|---|---|
| Pango | 240 px, resolved `Terminus` | 300 px | 340 px, resolved `Noto Sans` |
| WebKit | 240 px, ink 1390 | 288 px, ink 1632 | 335 px, ink 2026 |
| Gecko (screenshot) | 236 px, ink 640 | 287 px | 368 px, ink 2070 |

Both engines render it, distinctly from the fallback. What they do instead is
**scale** it: swept across 9–16 pt the widths came out exactly proportional —
180, 200, 220, 240, 260, 280, 320 px — so at any size that is not one of
Terminus's nine strikes the text is a scaled bitmap, which is the one thing
this design exists to avoid (§9.3), while every query still reports the
intended family.

Hence `ax86-terminus-ttf-fonts`: the same design as an outline build, same 4.49
series, main Fedora repository, OFL-1.1.

**Width alone could not have caught this.** The bitmap and the outline build
have *identical* advance widths — both 240 px — because they are the same
design. They differ only in ink: 1390 against 960. So the probe was extended to
**draw** and compare a signature of the rendered pixels; §8.10 is amended to
require it.

## Toolkit class

The stylesheet already named the surfaces explicitly (§8.10's first trap). The
second trap was live and waiting: **desktop-settings keys outrank configuration
files**, and `monospace-font-name` was still holding `Adwaita Mono 11` — a font
this system never chose — while `settings.ini` said Terminus and was perfectly
correct.

`bin/null-toolkit` owns those keys. It reports first, writes only with
`--apply`, and **reads every key back afterwards**, because a set that did not
take is precisely the failure being guarded against.

Third trap: naming a theme that is not installed falls back to a built-in light
palette *silently*, so every name is checked against the disk before it is
written and a missing one is a refusal.

## The pointer (§8.11)

An honest exception, chosen and recorded rather than defaulted. Of what is
installed, Bluecurve and oxygen are period pieces with gradients and colour and
AdwaitaLegacy is the softer pre-2023 bitmap set; **Adwaita** is the current
vector set, flat and near-monochrome, and the closest available to a shape with
no opinion. It is not derived from the hero and does not pretend to be.

## Icons, generated

Thunar with the toolkit theme applied looked right in every respect except the
icons, which were stock blue and green and read as borrowed.

`bake/make_icons.py` applies §8.11's three rules in order over 715 SVGs and 51
PNGs:

1. **Substitute the exact colours.** 21 hued colours — the folder blues, the
   semantic amber, red and green — mapped by what they *mean*, 4,443
   occurrences. Nearest-match would have produced elements that are *almost*
   right, which reads worse than something plainly different.
2. **Ask what is left.** Every colour in the output is enumerated and checked
   against the palette. **Remainder: 0.**
3. **Recolour the rest by luminance.** Lightness preserved on linearised
   channels; hue discarded entirely, since "take its hue away" is the
   instruction; ties broken toward the least saturated candidate.

Written to the user's own icon directory: no root, and it survives an update of
the set it derives from.

## Web class

**Deslopping is default-deny**, and the first attempt proved why that needs
care: hiding `#nav-bar > *` left a browser with **no chrome at all**, because
the address bar is not a child of the toolbar but of a customization target
inside it. Default-deny has to be applied at each level with the container
allowed back by name. Fixed, and verified by screenshot — back, forward and the
address bar, nothing else.

**The empty state carries the hero, drawn as text.** `bake/make_web.py` renders
one frame through the same still path as `/etc/issue`, converts the truecolour
escapes to spans, and serves it as the home and new-tab page. Drawn as text
from the same crop, so it arrives on the page's own background rather than
sitting on it like a sticker.

The first version showed literal `[0m` throughout: the converter matched only
the colour escapes, and the resets came through as text because ESC is
non-printing and the bracket is not.

`bin/null-firefox` joins rather than overwrites (§9.8): `chrome/` is ours and is
symlinked, while `user.js` may hold the user's own preferences, so our block is
written **between markers** and rewritten in place on every run.

## Both failures here were invisible except on screen

The chrome disaster and the escape residue both produced a process that started
cleanly, exited 0 and logged nothing. This is the third time in two phases that
an exit code has agreed with a broken result — after the greeter's silent
fallback in Phase 10. Screenshot, or do not claim it works.
