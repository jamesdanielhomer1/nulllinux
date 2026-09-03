# Licensing

**Not legal advice.** These are the facts as they stand in the tree, recorded
so that a decision about them is made deliberately rather than discovered.

## Your own copyright

Copyright is **automatic**. Under the Berne Convention -- and UK law, s.11
CDPA 1988 -- it exists from the moment an original work is fixed. Nothing is
applied for, registered or claimed. If you authored and directed this work, it
is yours by default.

Two things that could change that, and only you can say:

- **Employment.** Work made in the course of employment belongs to the employer
  by default (UK: s.11(2) CDPA). If any of this was written on someone's time,
  that is worth checking before publishing.
- **Authorship.** Much of this code was written by an assistant at your
  direction. Anthropic's terms assign output to the user, so this is a
  practical non-issue for licensing, but it is a fact rather than a nothing.

## Does it need a licence?

**No -- but the absence of one means "all rights reserved".** Publishing
without a licence gives nobody the right to copy, modify or redistribute it.
For a private test bench that is fine. The moment an ISO is handed to someone
else, the licence is what makes their copy lawful.

The chosen licence is **MIT** (see LICENSE).

## What is NOT yours to license, and travels under its own terms

**The font, and the atlases derived from it.** Terminus is **OFL-1.1**, and
`assets/atlas-*.bin` are glyph bitmaps read out of the Terminus PSF files by
`bake/bake_atlas.py`. The ramps in `assets/ramp-*.json` are measurements of
that font's ink coverage. OFL explicitly permits bundling a font into a
software release, but the derived material is OFL material: the licence text
must travel with it, and the Reserved Font Name rules apply to anything that
calls itself a font.

The `.cells` files are a different case -- they hold glyph INDICES and colour,
not bitmaps -- so the hero itself is your work quantised against a measurement
of someone else's font.

**Everything in the ISO.** The image is an aggregate of the Fedora package set:
roughly 259 GPL-2.0-or-later, 147 MIT, 138 LGPL-2.1-or-later, 66 OFL-1.1, 66
BSD-3-Clause and 64 GPL-3.0-or-later packages at last count. Aggregation is
what a distribution is and is fine; **redistributing GPL binaries carries a
source-availability obligation**, which Fedora meets by publishing its source
repositories and which a remix meets by pointing at them.

**The name.** "Fedora" is a Red Hat trademark. A derivative may describe itself
as a **Fedora Remix** under Red Hat's trademark guidelines; it may not call
itself Fedora, and the guidelines are worth reading before publishing.

## What the package declares

`packaging/nulllinux.spec` says `License: MIT AND OFL-1.1`, which is the
accurate SPDX expression for a binary package containing MIT code of yours and
font-derived assets under OFL. `rpmlint` and Fedora's review process both care
about this field being true rather than convenient.

## Before publishing anywhere

- [ ] Confirm no employment claim on the work.
- [x] Ship the OFL-1.1 text alongside the atlases (`licenses/OFL.txt`, taken
      from `terminus-fonts` itself: Copyright (C) 2020 Dimitar Toshkov Zhekov,
      **Reserved Font Name "Terminus Font"**). The reserved name matters: a
      modified font may not use it, which is a reason not to describe the
      atlases as a font.
- [ ] Point at Fedora's source repositories for the GPL packages in the ISO.
- [ ] Read Red Hat's Fedora Remix trademark guidelines.
- [ ] Get real advice if any of this is going somewhere that matters.
