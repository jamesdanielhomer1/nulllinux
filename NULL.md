# nullLinux — an operating system from one baked asset

**A complete build specification.** This document is self-contained. Someone
handed only this file and a Fedora 44 machine should be able to build the
system end to end without asking a further question. §0.3 describes the machine
every measurement here was taken on; it is a reference, not a requirement.

Where a decision is open, this document makes it and says why; where a number
must be measured on the machine rather than assumed, it says that too, and
gives the method.

It is a specification, not a tutorial. It states what must be true, how to
verify that it is true, and in what order to make it true. It does not contain
source code, and it deliberately does not describe how any previous version of
this system was implemented — an implementation is an answer to this document,
not an input to it.

---

## 0. Scope

### 0.1 What is being built

**nullLinux**: a Fedora 44 Remix, shipped as an installable ISO, in which every
visible surface is a projection of **one baked artefact**. A physical simulation
is raytraced once, quantised to characters in a bitmap font, and every surface —
wallpaper, screensaver, status bar, side column, menus, boot splash, login
greeter, lock screen, virtual console, terminal chrome, the editor, and the
interiors of third-party applications — is that same artefact resampled onto
whatever cell grid that surface has.

The result is not a colour scheme applied consistently. It is one asset,
rendered many ways.

The name is not decoration. A null geodesic is the path light takes, and the
hero is the object that bends them; the desktop is what is left where the light
does not come back.

**There is one hero and it is called `null`.** An earlier plan had two — `nox`
here and `sol`, a star, on another machine. Per-machine heroes are a good idea
for a desktop belonging to one person and a bad one for a distribution: they
make the identity of the system depend on which box it was installed on, and
they double every asset that has to be baked, shipped and verified. `sol` is
cut, and `nox` is a hostname rather than a hero.

### 0.2 The goal, and how it ends

**To replace the system on `nox` and be the machine somebody uses every day.**

Not a theme, not a configuration applied to somebody else's desktop: a
distribution with its own installer, its own package, its own boot media, and
its own answer for every ordinary thing a person does at a computer.

It is finished when it is installed on real hardware and nothing about using it
sends you back to a terminal to work around it.

### 0.3 The reference machine, and every other machine

`nox` is the machine every measurement in this document was taken on. It is the
REFERENCE, not a requirement, and anything that reads this table as a guarantee
about the hardware is wrong.

| | |
|---|---|
| distribution | Fedora 44, classic rpm/dnf (**not** an ostree/Silverblue variant) |
| package manager | dnf5 |
| init and services | systemd |
| initramfs | dracut |
| bootloader | GRUB2 with Boot Loader Specification entries in `/boot/loader/entries/` |
| model | ThinkPad T480 |
| graphics | Intel, integrated; no discrete GPU |
| panel | 1366x768 — a width that is 2 x 683, and 683 is prime |
| firmware | UEFI, with secure boot enrolled |
| root filesystem | **unencrypted** |

**Any panel, any number of monitors, any machine.** The profile in `machines/`
is GENERATED from the detected output by `machine generate`, never written by
hand, and `nulllinux-machine-sync` re-derives it on any boot where the recorded
hardware and the real hardware disagree.

Three properties change the plan materially if they are wrong, so verify them
rather than assuming:

```
rpm-ostree status        # must FAIL — an ostree variant needs a different §9
lsblk -o NAME,FSTYPE     # no crypto_LUKS anywhere — see §9.6
ls /boot/loader/entries/ # BLS entries, including a *-rescue.conf
```

If the root filesystem is encrypted, §9.6 does not apply as written: the boot
splash acquires a passphrase prompt and the initramfs acquires a
password-agent requirement, and both must be designed before the splash is
attempted. This document assumes no encryption throughout.

### 0.4 What "complete" means

1. Every verifier in §10 runs and passes — on an installed nullLinux, not only
   on the machine that builds it. A check that has only ever run on the build
   host is a check that has not run.
2. Every number quoted anywhere is either derived in this document or was
   measured on a machine, and carries a record of the inputs it was measured
   against (§10.7).
3. The machine boots, unlocks, logs in, runs a working day and locks again
   without any surface departing from §1.2.
4. It is installed on real hardware. Everything before that is evidence about
   a virtual machine, which is a different claim.

### 0.5 What is ours, and what is Fedora's

The base system is Fedora's and stays that way: kernel, systemd, dracut, GRUB,
NetworkManager, PipeWire and WirePlumber, BlueZ, Mesa, and the compositor.
Rewriting those makes the system slower, buggier and less safe, and thins
nothing — `nmcli` and `wpctl` are thin clients to daemons that would have to be
reimplemented wholesale behind them.

Everything ABOVE that line is ours to write, and most of it already is. What
remains third-party, with what replacing it would buy:

| replaced by us | today | why it is worth writing |
|---|---|---|
| picker | `fzf` | 47 call sites, a Go runtime, and we already draw pickers |
| notifications | `dunst` | a layer-shell surface, which we already build |
| terminal | `foot` | `vt.rs` and `pty.rs` are already a terminal core |
| file manager | `thunar` | the last GTK surface, and the hardest to style |
| system monitor | `btop` | we already draw every figure it does |
| network UI | `nmtui` | keep NetworkManager, replace the newt front end |
| mixer UI | `wiremix` | keep PipeWire, replace the front end |
| spectrum | `cava` | an FFT over a capture we can take ourselves |
| screen capture | `grim`, `slurp` | one Wayland protocol each |
| backlight, radios, gamma | `brightnessctl`, `rfkill`, `wlsunset` | sysfs writes and one protocol |
| idle and lock | `swayidle`; our own session-lock client, `swaylock` as fallback (§8.5) | the lock is security-bearing; it draws from the atlas like everything else, and swaylock catches the case it cannot lock |

The measure of success is not the count. It is that the desktop starts fewer
processes, holds less resident memory, and draws every surface from the same
atlas — which is what §1.1 asked for and what a dozen third-party front ends
quietly prevent.

Some things are deliberately NOT ours and never will be: the office suite, the
browser engine, the mail client's protocol stack. Writing those is a different
project.

### 0.6 What is out of scope

**Accessibility.** There is none — no screen reader, no magnifier, no sticky
keys. This is a decision, not an oversight: AT-SPI, which every Linux screen
reader is built on, has no working path on a wlroots compositor, so providing it
would mean either changing compositor or shipping a checkbox that does nothing.
Recorded at James's direction, 2026-09-07.

**Third-party application interiors.** A flatpak is sandboxed and does not see
`/usr/share/themes`, so it arrives in its own colours. §8.10 treats application
interiors as their own tier; this system styles the windows it owns.

### 0.7 How to read this document

Sections §1–§8 are **specification**: what must be true of the finished system.
Section §9 is **integration**: what must be done to Fedora specifically.
Section §10 is **verification**: the checks that decide whether a claim is
true. Section §11 is **order**: the sequence in which to build, with a gate at
the end of each phase. Section §12 is the prohibition list.

Read §1, §10 and §11 before writing anything. §11 exists because several
decisions are cheap to make first and expensive to retrofit, and a builder who
starts at §2 will make all of them wrong.

---

## 1. The thesis

### 1.1 One asset, many projections

Most desktop customisation is a collection of independently authored themes
that happen to share a palette. They drift, because nothing structurally
prevents drift: each surface is a separate artefact maintained by hand, and
consistency is a property of the maintainer's diligence rather than of the
system.

This design inverts that. There is exactly one authored artefact — the hero —
and every surface is a mechanical projection of it. Two projections of one
asset cannot disagree with each other, because there is nothing for them to
disagree about.

Three consequences follow, and they are the entire design:

1. **Everything is text on a cell grid.** Not "styled to resemble a terminal".
   Actual characters, from one font, on one grid, at one of a small set of
   pinned sizes.
2. **Colours are derived, not chosen.** They fall out of the physics of the
   simulated object. No hex value is picked by taste, and the few that must be
   are labelled as chosen rather than dressed up as derived (§4.5).
3. **No surface is ever authored by hand.** If a target needs an asset, that
   asset comes out of the bake pipeline. A hand-authored surface is a surface
   that will drift.

### 1.2 The test for any proposed change

> Could this have come from the asset?

If not, it is decoration, and it does not belong. This test is the arbiter for
every question this document does not explicitly answer. It is what makes
"what should the file manager look like?" a question with a derivable answer
rather than one requiring a ruling.

### 1.3 The invariants

These hold everywhere, on every surface, without exception. A build that
violates one has failed regardless of how it looks.

| # | Invariant |
|---|---|
| I1 | **Text glyphs only.** Block glyphs (`U+2588`, `U+2593`, `U+2592`, `U+2591`), their relatives, and braille are banned from every surface. Density is expressed with a dense *character*, never a filled rectangle. |
| I2 | **One typeface.** A single bitmap font drives the ramp derivation, the renderer's glyph atlas, the console, the terminal and every application's chrome. No second typeface, no icon font, no emoji anywhere in the chrome. |
| I3 | **The void is absent, not dark.** The region representing true emptiness renders as the space character. It is the only true void in the frame and it is what makes the composition read. |
| I4 | **No dithering, ever.** Reaching for a noise mask means the tone curve is wrong (§4.2). |
| I5 | **Never re-simulate to change an appearance.** Colour, tone and quantisation operate on a stored high-dynamic-range intermediate and re-run in seconds (§5). |
| I6 | **The palette is read off the render.** If a colour is not in the image, it is not in the palette (§4.5). |
| I7 | **Derive, never copy.** The glyph ramp, the palette and the mode ladder are computed from first principles against *this* font and *this* physics. A value copied from elsewhere is calibrated to something else. |
| I8 | **A measured claim carries its inputs.** Any performance or coverage figure is stated with what it was measured against, and something must invalidate it when those inputs change (§10.7). |

### 1.4 Definitions

Used precisely throughout.

- **hero** — the simulated object the desktop is derived from. One machine, one
  hero. On this machine the hero is a Kerr black hole (§3.3).
- **cell** — one character position: exactly one glyph and exactly one colour.
  The atomic unit of every surface.
- **strike** — a bitmap font at one specific pixel size. A bitmap font is a set
  of strikes, not a scalable outline; `10x18` and `6x12` are different strikes
  of the same typeface and are treated as different fonts everywhere it
  matters (§2.3).
- **ramp** — the ordered sequence of glyphs used to express luminance, sorted
  by measured ink coverage. Derived per strike (§2.4).
- **ink** — the fraction of a cell's pixels that a glyph lights. An exact
  integer count for a bitmap font.
- **surface** — one independently mapped region of screen: the wallpaper, the
  bar, the column, a menu, the splash.
- **projection** — a mechanical resampling of the hero onto a surface's grid.
- **artefact** — a file the bake produces and a consumer reads.

---

## 2. The medium

Resolution comes from **cell count**, never from subpixel tricks. Everything in
this section is a property of the font and the display, and is settled before
any physics is written.

### 2.1 The scale decision, and why it is made first

A bitmap font exists only at the pixel sizes it ships. Asking for any other
size does not fail — something silently scales it, and a scaled 1-bit bitmap
is precisely the artefact this entire system exists to avoid.

Two consequences dictate the display configuration:

**Set the internal display to scale 1.0.** Do not use fractional scaling.
Under fractional scale a surface is configured in logical pixels while its
buffer is native, every surface must own its buffer and map it through a
viewport to land pixels 1:1, and every surface dimension must be chosen so
that `logical = ceil(native x scale_denominator / scale_numerator)`
round-trips exactly — at 1.5 that constrains every width to a multiple of
three. All of that is avoidable machinery in service of a font that cannot be
scaled anyway.

**Choose legibility with the strike, not with the scale.** The correct
response to "the text is too small" is a larger strike of the same typeface,
which is exact, not a scale factor, which is interpolation. Terminus ships
strikes at 12, 14, 16, 18, 20, 22, 24, 28 and 32 pixels and **nothing above
32**; any other size is silently scaled or silently substituted.

At 1920x1080 and scale 1.0, the resulting grids are:

| strike | cell (px) | grid at 1920x1080 |
|---|---|---|
| ter-u16n | 8 x 16 | 240 x 67 |
| **ter-u18n** | **10 x 18** | **192 x 60** |
| ter-u20n | 10 x 20 | 192 x 54 |
| ter-u22n | 11 x 22 | 174 x 49 |
| ter-u24n | 12 x 24 | 160 x 45 |

**THE GRID MUST FIT. IT DOES NOT HAVE TO DIVIDE.**

An earlier version of this section required both strikes to divide the output
exactly. That is true of 1920x1080 and cannot be true of every panel: 1366x768,
one of the commonest laptop displays ever made, is divided exactly by none of
Terminus's nine strikes, because 1366 = 2 x 683 and 683 is prime. A rule no
hardware can satisfy costs the installation; a dozen pixels behind the frame
cost nothing.

So: the strike is chosen for **legibility first**, with exact division as a
tiebreak, any unreached pixels are **counted and reported**, and `machine
check-grid` asserts the grid fits rather than that it divides. On the reference
panel that is `ter-u16n` at 8x16 — 170 x 48 cells, 6 px unreached.

The strike is not chosen here at all. It is chosen by `machine choose-interface`
from the panel the machine actually has, and re-chosen whenever the hardware
disagrees with the recorded profile. Only one strike is the interface strike on
any given machine.

**A second, smaller strike is used for the bake** (§2.2). These are different
fonts for every purpose in this document.

*Verification.* Confirm the compositor reports scale 1.0 and that no surface
is being resampled, by rendering a known one-pixel-wide vertical rule and
confirming it is one physical pixel wide in a screen capture. A rule that
captures as two pixels, or as two pixels of differing intensity, means
something is scaling.

### 2.2 Two strikes, two jobs

| strike | job | why |
|---|---|---|
| **6 x 12** (`ter-112n`, console PSF) | the **bake**: master resolution, ramp derivation for the artefact, the wallpaper and screensaver | small cells mean more cells for a given pixel area, and cell count is the only resolution this medium has |
| **10 x 18** (`ter-u18n`) | the **interface**: bar, column, menus, terminal, all chrome | legibility at arm's length |

The wallpaper is drawn at the bake strike because it is the artefact at full
size; the chrome is drawn at the interface strike because it is text to be
read. Both are on screen simultaneously and that is correct — they are
different media, not an inconsistency. What is *not* permitted is a third grid
(§12).

### 2.3 A ramp belongs to exactly one strike

**Derive a separate ramp for every strike, and verify each is monotonic.**

This is not a precaution, it is a correctness requirement. Glyph ink coverage
is not proportional between strikes: a glyph that is denser than another at
6x12 can be sparser at 10x18, because each strike is an independently drawn
bitmap rather than a rescaling. A ramp derived at one strike and reused at
another can therefore **run backwards** over part of its range, and every
meter built on it will decrease as its value increases.

The monotonicity check in §10.1 is what catches this, and it must be run
against each strike's own ramp.

### 2.4 Deriving a ramp

A ramp taken from any external source is calibrated to a different font and is
invalid here (I7). Because the font is a bitmap, coverage is an **exact
integer pixel count** and no rasteriser is involved.

**Input:** a PSF2 console font file. The header begins with the four magic
bytes `72 B5 4A 86` — note that as a little-endian 32-bit word this reads
`0x864AB572`, and stating it the other way round is a reliable way to write a
parser that rejects every valid font. Then: version, header size, flags, glyph
count, bytes per glyph, height, width, all little-endian 32-bit. Glyph bitmaps
follow the header, each row padded to a whole number of bytes.

Bit 0 of `flags` indicates a Unicode table follows the glyph data, mapping
glyph indices to codepoints. Both strikes in use here set it. Parse it rather
than assuming glyph index equals codepoint — that assumption holds for ASCII
in these files and will not hold for the next font.

**Procedure:**

1. **Count ink.** For every candidate glyph, count lit pixels. A 6x12 cell
   yields an integer in `0..72`; a 10x18 cell an integer in `0..180`.

2. **Reject by class.** Discard block and shade glyphs, box-drawing
   characters, braille, and everything outside printable ASCII. These are
   reserved for chrome (§7) and must never appear as tone.

3. **Reject by directionality.** A strongly directional glyph reads as texture
   rather than as tone, and produces visible grain in flat areas. Compute the
   second moment of the ink distribution about its centroid as a 2x2
   covariance matrix and take the ratio of its eigenvalues.

   Two details are load-bearing and both were found by the check failing:

   - **The cross term is essential.** Using only the variances in x and y
     scores a diagonal stroke as isotropic, because a perfect diagonal has
     equal spread on both axes. The off-diagonal term is what distinguishes it.
   - **Floor both eigenvalues** at the variance a single unit-area pixel
     already possesses, `1/12`. Without the floor every two-pixel glyph is
     exactly collinear, its minor eigenvalue is zero, the ratio is infinite,
     and sparse glyphs such as `.` are wrongly rejected — removing precisely
     the low end of the ramp that the void depends on.

4. **Reject by centroid offset.** Discard glyphs whose ink centroid is far
   from the cell centre. These read as a shifted texture: a field of them
   produces visible ruling because the ink lands on one edge of every cell.

5. **Select for distinct, evenly spaced ink.** Among survivors, choose glyphs
   with **distinct** ink counts, spaced as evenly as the font permits.
   Duplicates render identically and silently shorten the ramp. Where several
   glyphs share an ink count, prefer the most isotropic.

6. **Commit the ramp beside a hash of the font file.** Every downstream stage
   refuses to run when the hash does not match. A font update that changes a
   glyph silently invalidates every baked asset, and this is the only thing
   that notices.

**Expected result at 6x12.** Terminus at this strike admits roughly 16 levels
and this is the font's ceiling, not a chosen target — there are only about
fifteen distinct usable ink counts among the glyphs that survive the filters.
Asking for more silently clamps.

**Two properties of the result that the tone curve must respect:**

- **Peak coverage is well under half.** The densest surviving glyph fills
  roughly 30% of the cell, because Terminus is a thin font. Nothing ever reads
  as solid. Brightness above that ceiling comes from **colour**, not from glyph
  density — which is what makes I1 costless rather than a sacrifice.
- **Coverage steps are uneven and quantised.** Ink is a count over a small
  integer range, so the gaps between adjacent ramp levels differ, and the gap
  between the two sparsest levels is typically several times the average. Use
  the measured coverage of each glyph. **Never assume even spacing**, and never
  assume the ramp index is proportional to luminance.

Record the measured coverage of every ramp glyph alongside the ramp. §4.2
consumes these numbers directly.

### 2.5 Aspect

Cells are 1:2 — twice as tall as wide at both strikes in use. Aspect correction
is exact and automatic if, and only if, downsampling is done correctly:

> **Average each cell's true pixel footprint.** To produce one cell from a
> render, box-average the full 6x12 (or 10x18) block of pixels that cell
> covers.

Never sample one pixel per cell, and never apply a correction factor to
compensate for aspect afterwards. Both are approximations to something that is
exact when done directly.

It follows that a 16:9 region requires `cols = 3.556 x rows`. A cell grid that
is square in cell count is 2:1 in world units, so a target specified as "40x20"
for a 2:1 subject wastes its bottom rows on emptiness; specify targets by the
aspect of the subject, and verify by rendering.

---

## 3. The hero

### 3.1 The artefact contract

A hero is **anything that can produce the following artefacts**. Nothing
downstream may know how they were produced, and nothing downstream may know
what the hero is.

| artefact | content |
|---|---|
| master animation | the full loop at master resolution, as glyph + colour cells |
| logo | a tight crop of the same loop, for small targets |
| still | one frame, for surfaces with no animation path |
| palette | 256 colours derived from the hero's own physics |
| manifest | the hero's name, its temperature range, and the observed temperature at which each semantic role is sampled |

**The glyph ramp is deliberately not in that list.** It is derived from the
font (§2.4) and is identical for every hero. It is a property of the medium,
not of the subject. A hero that shipped its own ramp would be a hero that could
change how every other surface reads.

### 3.2 Enforcing the abstraction

The abstraction is only real if it is checked, and it decays silently. The
requirement is:

> **No file outside the hero's own producer directory may mention the hero's
> nature.** Not in an identifier, not in a namespace string, not in a filename.

This must be a **mechanical check that runs in the verification suite** (§10.6),
not a convention. The failure mode is not dramatic — it is that after some
months the hero is a parameter except for the nine places that assume a disk,
and each is found individually and expensively when a second hero is attempted.

Name surfaces, namespaces and identifiers for their **function**. Prose in
documentation may of course discuss what the hero is.

### 3.3 nox — the physics

A Kerr black hole with a thin accretion disk. Spin `a = 0.6`, prograde, in
units where `M = 1`.

**Coordinates: Kerr–Schild, not Boyer–Lindquist.** Kerr–Schild is
horizon-penetrating and has no coordinate singularity at the horizon. This
eliminates all turning-point sign bookkeeping, which is the single largest
source of defects in geodesic renderers. The inverse metric is a rank-one
update to Minkowski:

```
g^{mu nu} = eta^{mu nu} - f k^mu k^nu

f    = 2 M r^3 / (r^4 + a^2 z^2)
k_mu = ( 1, (r x + a y)/(r^2 + a^2), (r y - a x)/(r^2 + a^2), z/r )

r is the positive root of   r^4 - (rho^2 - a^2) r^2 - a^2 z^2 = 0,
equivalently  r^2 = 1/2 [ (rho^2 - a^2) + sqrt( (rho^2 - a^2)^2 + 4 a^2 z^2 ) ]
with rho^2 = x^2 + y^2 + z^2
```

**Integrate the Hamiltonian form.** It requires only the inverse metric, which
is the cheap object above:

```
dx^mu / d(lambda)  =  g^{mu nu} p_nu
dp_mu / d(lambda)  =  -1/2 ( d_mu g^{alpha beta} ) p_alpha p_beta
```

Use RK4 with an adaptive step near the horizon. Obtain `d_mu g^{alpha beta}` by
central differences on the two cheap scalars `f` and `k` rather than by forming
general Christoffel symbols.

**Termination.** Three conditions, all required:

- horizon: `r < r_+ = M + sqrt(M^2 - a^2)`, which is `1.800000` at `a = 0.6`
- escape: `r > 400 M`
- step budget exhausted

**Step-budget exhaustion is not escape.** Scoring it as escape produces a
plausible image with a subtly wrong shadow edge, and it is invisible without a
test that separates the three outcomes.

**Record every equatorial crossing, not only the first.** Detect sign changes
in `z` between the inner and outer disk radii and interpolate to the crossing.
The second and third crossings are what produce the far side of the disk
arcing over and under the shadow, and that is the entire iconic image. A
renderer that records only first crossings produces a flat annulus with a hole
in it, which looks deliberate and is wrong.

**The disk.** Geometrically thin, optically thick, Shakura–Sunyaev
temperature profile `T(r) proportional to r^(-3/4)`, inner edge at the ISCO.
At `a = 0.6` prograde the ISCO is at `r ≈ 3.83 M` — **not** `6 M`, which is the
Schwarzschild value. The prograde disk therefore reaches far closer in, runs
hotter and orbits faster, and the Doppler asymmetry is correspondingly violent.
That is a feature: it produces strong, unambiguous structure in a medium with
very few tone levels.

**At each crossing**, with the emitter on a prograde circular geodesic:

```
u^t     = (r^{3/2} + a) / sqrt( r^3 - 3 r^2 + 2 a r^{3/2} )
u^phi   =        1      / sqrt( r^3 - 3 r^2 + 2 a r^{3/2} )
Omega   = u^phi / u^t = 1 / ( r^{3/2} + a )

g       = (p . u)_observer / (p . u)_emitter      [observer at rest at infinity]
I_obs   = g^4 * I_emit( T_local )
colour  = blackbody( T_local * g ) -> CIE XYZ -> linear sRGB
```

**The exponent 4 is the most important line in the renderer.** It is why the
approaching limb overwhelms the receding one, and it dominates every downstream
statistic (§4.2).

**Store the observed temperature per cell, not only the colour.** Doppler
shifting a blackbody yields another blackbody at `T_obs = g * T_emit`, so
observed colour is a function of exactly one variable. Carrying `T_obs`
forward means the quantiser never has to invert the Planckian locus out of an
RGB triple, and it is what makes §4.5 tractable.

**Sign convention.** The traced ray is past-directed. Fix which transverse
offset corresponds to the prograde side **by an explicit test**, not by
inspection: getting it backwards mirrors the Doppler asymmetry, puts the bright
limb on the wrong side, and produces an image that looks entirely plausible.

### 3.4 The temporal model

Frames at a fixed rate give an exact loop period. **Every temporal frequency in
the simulation must be an integer multiple of the loop frequency**, or the loop
cannot close without a crossfade — and a crossfade is visible.

**Settled:** 240 frames at 24 fps, giving a loop period of exactly 10.000 s and
`omega_loop = 2 pi / 10`.

Differential rotation and seamless looping are in direct tension, because
orbital angular velocity varies with radius and no global period exists. The
resolution is **spectrally quantised shear**: build the disk pattern as a sum
of azimuthal modes whose temporal frequencies are integers.

```
pattern(r, phi, t) = SUM over k of  A_k(r) * cos( m_k*phi - n_k*omega_loop*t + ph_k )

A_k(r) = amp_k * exp( -(( r - r_k ) / ( w_k * r_k ))^2 )

m_k = azimuthal wavenumber (arm count), integer
n_k = temporal frequency in cycles per loop, integer
```

Each term is periodic over the loop by construction, so the loop closes
exactly.

**Bounds on `n_k`.** With 240 frames the hard Nyquist limit is `n < 120`; above
it the pattern advances more than half a cycle per frame and strobes backwards.
The comfort limit is `n <= 30`, which is at least 8 frames per pattern cycle.
Assert the Nyquist bound at build time.

#### 3.4.1 Place every mode at its exact resonance

**Choose the integers first and let the radius follow.** The tempting order —
pick a radius, then round `n_k` to the nearest integer — puts the rounding
error directly into the shear, leaving the mode rotating at a speed the disk
does not have at the radius it occupies.

The relation inverts exactly. With `q(r)` the number of pattern cycles a ring
completes per loop,

```
q(r) = Omega(r) / Omega(r_out) = ( r_out^{3/2} + a ) / ( r^{3/2} + a )

set q = n/m   =>   r = [ (m/n) ( r_out^{3/2} + a ) - a ]^{2/3}
```

The snap error at the peak of every envelope is then **zero by construction**,
and the only residual is the Keplerian variation across each envelope's own
width — which more, narrower bands reduce.

**Settled anchor:** `r_out = 20 M`. This anchors `n = 1` in the ladder.
Changing `r_out` re-derives every `n_k` and invalidates the loop closure, so it
is not a free parameter after the first bake.

#### 3.4.2 The ladder

Evaluating the inversion above at `r_out = 20`, `a = 0.6`, with arm counts
falling inward, yields twelve bands. **This table is derived, not chosen** —
regenerate it from the formula rather than transcribing it, and have the
generator be the single source of truth consumed by every stage that needs it.

| r/M | m | n | frames/cycle | | r/M | m | n | frames/cycle |
|---|---|---|---|---|---|---|---|---|
| 20.00 | 6 | 6 | 40.0 | | 6.36 | 3 | 16 | 15.0 |
| 15.94 | 5 | 7 | 34.3 | | 5.24 | 2 | 14 | 17.1 |
| 13.44 | 5 | 9 | 26.7 | | 4.37 | 2 | 18 | 13.3 |
| 11.55 | 4 | 9 | 26.7 | | 3.53 | 1 | 12 | 20.0 |
| 9.49 | 4 | 12 | 20.0 | | 2.97 | 1 | 15 | 16.0 |
| 7.78 | 3 | 12 | 20.0 | | 2.36 | 1 | 20 | 12.0 |

The arm ladder is **forced, not chosen**: `n = m*q` must stay at or below 30,
and `q` reaches roughly 20 at the ISCO — so the innermost band can afford
exactly one arm while the outer disk can afford six.

#### 3.4.3 Give the bands a spiral phase

With every `ph_k = 0`, every band crests at the same azimuth at `t = 0`, and
the disk shows a **radial spoke** straight through every annulus. Real
accretion disks do not do this.

Put every crest on a single logarithmic spiral instead:

```
ph_k = - m_k * ln( r_k / r_out ) / tan( pitch ),    pitch = 15 degrees
```

Two things about this are worth stating explicitly:

- **It is free.** Phase does not change frequency, so shear, loop closure and
  churn are all untouched. The only thing it changes is what the frames look
  like.
- **It decides what the *still* frames look like**, and several targets ship
  stills — the logo, the lock screen, the splash. This matters more than its
  cost suggests.

**No whole-frame metric can see this defect.** The spoke is two-sided, so it
cancels in any azimuthal or whole-frame sum; and `g^4` beaming weights one limb
so heavily that whole-frame statistics are dominated by geometry rather than by
the pattern. Verify it by drawing the pattern **face-on, in the disk's own
coordinates, with no camera and no lensing** (§10.2). It is obvious there and
nowhere else.

#### 3.4.4 Taper amplitude outward, gently

`A_k` should fall with radius roughly as `r^-0.45`. The justification is
physical: `T ∝ r^(-3/4)` and Doppler beaming already make the inner disk far
brighter, so the pattern is a *relative* modulation and a mild taper keeps the
eye inward.

Resist a stronger taper. A steep one suppresses the outer bands, which
conceals rather than fixes any error in their placement, and it leaves outer
annuli with no visible motion at all.

**Normalise the SUM, and keep the depth a separate number.** The per-band
amplitudes are relative weights *between* bands. Nothing about them bounds
their total, and where several envelopes overlap they add — so measure the
largest `|Σ bands|` over the disk and divide by it, then apply the modulation
depth once.

This matters far more than it sounds, because **intensity follows as `T⁴`**.
Unnormalised, the summed field here swung ±3.5; at a depth of 0.18 that put the
temperature factor between 0.37 and 1.60, an intensity ratio of **347×** from
the pattern alone. That is not a modulation, it is a **gate**: wherever several
bands happened to align negative the disk went dark, and the render filled with
voids that look like structure and are not. Normalised, the same depth gives
**4.1×**, which reads as texture.

Fold the depth into the emitted amplitudes so every consumer computes
`1 + Σ bands` and nothing else. A depth written separately into each renderer
is two copies of one number, which is the drift §10.3 exists to prevent.

### 3.5 Camera and composition

These are composition choices. They cost nothing physically and they decide
the image.

| parameter | value | reasoning |
|---|---|---|
| inclination | **85°** from the spin axis — 5° above the disk plane | Magnitude: at 55° the shadow is buried in a filled ellipse; at 70° the lensed **underside** is only a sliver, because looking down on the disk at 20° elevation hides what passes beneath the shadow. **85° is where the underside becomes a distinct arc below the shadow** and the image reads as a ring around a void rather than a hat on one. 88° closes the ring further and costs disk body; 82° leaves the lower arc partly merged with the near side. Side: the scene is exactly mirror-symmetric about the equatorial plane, so 85° and 95° are the same image flipped top to bottom — and 85° is the one where the lensed far side arcs **over** the shadow, which is how every familiar image of such an object is oriented. 100° was chosen first and read as upside down. Verified rather than assumed: the two renders differ by a relative 0.0000, so this costs nothing physically and is purely composition. **An earlier pass rejected 80° for reading as "one lopsided blob with a bite out of the right side". That judgement was made on a broken image** — the tone curve of the day was blanking a third of the disk (§4.2.1) — and it did not survive re-examination once the exposure was fixed. A composition rejected on a defective render must be re-tried after the defect is fixed. |
| `r_out` | 20 M | anchors the mode ladder (§3.4.1) |
| `a` | 0.6, prograde | §3.3. Spin is a *composition* control as much as a physical one: it sets how far the shadow is dragged out of round and how hard the approaching side is beamed. At 0.9 the beaming is strong enough to gate one half of the disk dark and the shadow is markedly D-shaped. At 0.6 the shadow is close to round and both halves carry light. |
| inner-edge temperature | 5000 K | Decides where the disk sits on the Planckian locus, and therefore the entire colour of the image — this one number is the difference between a warm gold-and-white object and a blue-white one. 20000 K puts the inner disk at the blue end of the palette's range; 5000 K keeps the whole disk in the warm half, with white only at the hottest cells. Choose it by looking, in the final medium. |
| half-width | 32 M | the disk fits with margin at this inclination |

Settle inclination by rendering candidates at proxy resolution and looking at
them, and record the ink fraction of each — a candidate that reads well and
sits near the 20% ink target of §4.2 is the one to take.

**Inclination is a framing control, not only a viewpoint.** It sets how much of
the frame the subject occupies, because a thin disk projects to `cos i`, and
that effect is large enough to dominate the field of view. Measured on this
hero at a fixed half-width of 28 M, the lit fraction of the frame runs:

| inclination | lit cells |
|---|---|
| 70° | 33.4% |
| 82° | 22.7% |
| 85° | 19.7% |
| 88° | 16.8% |

So "the subject is too large" and "the angle is too high above the plane" can be
**one complaint with one fix**. Reach for inclination before reaching for the
field of view, and measure the lit fraction rather than predicting it — this is
the ceiling §4.2.1 says ink is read against.

**Preview in the final medium, not in radiance.** Spin, inclination and inner
temperature all change the raytraced image, but what anyone sees is that image
quantised to a glyph ramp and a palette, and the quantiser is not a neutral
observer — it has a tone curve, an ink target and a hysteresis rule. Judging
these choices on raw radiance is judging something nobody looks at. A preview
that runs the full chain for two frames at proxy resolution costs a few seconds
and is the only comparison worth making. Two frames, not one: the churn
statistics are differences *between* frames, and the hysteresis that decides
the final glyphs never runs on a single one.

**Changing any of these means re-tuning the tone curve (§4.1).** The curve is
fitted to a distribution of emitted intensity; move the spin, the inclination
or the inner temperature and that distribution moves with it.

**Framing is decided the same way, and erring inward is the trap.** Bringing
the camera closer makes the subject larger and the composition worse: at 18 M
half-width the lit ceiling reaches 60% and ink 47%, the frame fills with disk,
and the void stops being empty — which is the whole of §4.2 undone by a single
number. The same mistake reappears at every small target, because a small grid
invites cropping in. It is the wrong instinct: keep the framing and let the
grid shrink.

---

## 4. Tone and colour

The raytrace is physically accurate. The tone curve is an explicit artistic
stage applied afterwards. **Keep the two separate and never smuggle legibility
adjustments into the physics** — a physics stage that has been quietly tuned
for looks cannot be validated against analytic results, and §10.2 depends on
being able to.

### 4.1 The curve

Log-exposure with two **independent, explicit** anchor points:

```
Lb = percentile( luminance over lit cells, 30    )
Lw = percentile( luminance over lit cells, 99.5  )
Lt = clamp( ( log L - log Lb ) / ( log Lw - log Lb ), 0, 1 ) ^ 0.8
```

**Two anchors are required, not one.** A single-parameter family — of the form
`log1p(L/Ls) / log1p(Lw/Ls)` — uses one number as both the toe and the spread,
so crushing the faint halo also compresses the bright core. Separating them is
what makes both controllable. Measured against the alternative at matched ink
coverage, the two-anchor curve spreads cells across the ramp substantially
better; verify this on your own bake rather than taking it on trust, using the
entropy figure defined in §10.3.

**Re-tune the curve whenever the emission model changes.** This is not
optional and it is easy to forget. `g^4` beaming concentrates roughly half of
the total light into the brightest couple of percent of lit cells, so
percentiles calibrated against a placeholder — or against a different
inclination, or a different spin — land somewhere entirely different on real
physics.

### 4.2 Do not maximise ramp usage

Entropy over the ramp is a tempting objective function and it is **wrong**.
Maximising it fills every cell with mid-tones and erases the composition. The
void reads precisely *because* most of the frame is empty.

> **Constrain ink — the non-blank fraction of the frame, target ≈ 20% — and
> maximise entropy subject to that constraint.**

Both numbers are reported by the tuning tool (§10.3) so a candidate curve can
be judged on both at once.

#### 4.2.1 Coverage outranks ink, and this is the trap

**Ink is a whole-frame statistic, and a whole-frame statistic can be satisfied
by deleting part of the subject.** A tuner judging only ink and entropy scores
a well-exposed small subject and a half-erased large one identically, and will
happily return the second.

That is not hypothetical. Judged on ink and entropy alone, this exact sweep
once returned a curve that blanked **a third of the disk** — the entire
receding side, which `g⁴` beaming leaves several times dimmer than the
approaching side — and reported it as the best available candidate. Nothing in
the numbers objected. On screen, a third of the hero was simply missing.

> **Measure coverage: of the cells the render lit, what fraction still carry
> ink. Constrain it hard — near 100% — before ink is considered at all.**

The rule "no tone curve can light a cell the render left empty" was already
written down. Its dual was not, and the dual is the one that bites:

> **No tone curve may blank a cell the render lit.**

**Then read ink as an outcome rather than pulling it as a lever.** With the
subject intact, the ink fraction is decided by *framing*: it is the lit
fraction, less whatever the ramp's own floor removes. If ink is still too high,
the camera is too close and the fix is in §3.5 — move it back. Reaching for the
black point instead trades a composition problem for a deleted hero, and only
the first of those is visible in the numbers.

**Beware a subject with a large intrinsic dynamic range.** Relativistic
beaming spans far more than a glyph ramp, so a global log exposure that flatters
the bright side can put the dim side entirely under the black point. The dim
side is not noise; it is half the object. Check the two halves separately —
their median luminances and their coverage — because a single global figure
averages the failure away.

### 4.3 The split: glyph carries structure, colour carries the remainder

With roughly 16 tone levels the spatial failure mode is **banding** and the
temporal failure mode is **sizzle** — a cell oscillating between two adjacent
ramp glyphs from frame to frame. Both are solved by using the two independent
channels every cell has.

```
step     = quantise( L, ramp )              # glyph carries coarse luminance
residual = L - coverage( step )             # what the glyph over- or under-states
value    = base_value * ( 1 + k * residual) # colour carries the remainder
```

`coverage(step)` is the *measured* ink of that ramp glyph (§2.4), not its index.

### 4.4 Hysteresis

**Change a cell's glyph only when its luminance crosses a ramp boundary by a
margin.** Start the margin at 25% of a step and tune against the churn band in
§10.3.

Hysteresis is stateful across frames, which has two consequences that must be
handled:

- **Iterate the state to a fixed point over the loop before emitting.** The
  hysteresis state at frame 0 depends on frame 239, which depends on frame 0.
  Run the sequence repeatedly until the state stabilises, then emit.
- **Loop closure becomes a hard gate.** Re-quantise frame 0 from the final
  hysteresis state and refuse to emit unless the glyph plane comes back
  byte-identical (§10.3).

Hysteresis is also what makes the frame format compress and the delta renderer
cheap (§5.2), so it pays for itself three times.

**Judge motion by colour churn, not glyph churn.** By design the glyph plane
carries stable structure and the colour plane carries the residual, so colour
churn runs materially higher than glyph churn. A build judged on glyph churn
alone will read as static and be "fixed" by weakening hysteresis, which
reintroduces sizzle.

**The ratio between them is content-dependent and is not a target.** How far
colour churn exceeds glyph churn depends on how the emission model distributes
motion: a subject whose brightness varies gently within a ramp step puts almost
everything in the colour plane, while one with strong structural motion
genuinely moves glyphs. What is invariant is the *direction* — colour churn
above glyph churn — and that the margin is tuned against a band measured on
**this** emission model. Do not tune a stand-in until its ratio matches a
figure taken from different physics; that is fitting the proxy to the wrong
target. Check both, and check that motion is
**spatially distributed** rather than confined to one region — motion in one
patch reads as a still image with a shimmering corner.

### 4.5 The palette is derived, not fitted

**256 entries: 32 temperatures x 8 values, built analytically from the
Planckian locus.**

Do **not** derive it by clustering over the frames. A data-fitted palette
drifts as the object rotates, and the entire point is that the same colours
hold across every surface and every frame.

The analytic construction is valid because of the result in §3.3: Doppler
shifting a blackbody yields another blackbody, so observed chromaticity is a
function of **one** variable. The chromaticity axis is one-dimensional.

```
temperature axis : 32 samples, 1667 K .. 25000 K
                   (the validity window of the standard cubic-spline
                    approximation to the Planckian locus in CIE xy)
value axis       :  8 samples, 0.35 .. 1.0 LINEAR
```

**The value axis is deliberately narrow.** It exists only to carry the residual
between ramp steps (§4.3). In sRGB-encoded terms 0.35 linear is already about
63% — so the darkest palette entry is not dark. This is correct:

> **Darkness comes from sparse glyphs, not from dark colour.**

A palette with a wide value axis will be used to make things dark, and the
result is a muddy frame where the void has stopped being empty.

### 4.6 Semantic roles

Roles are **sampled from the palette at named temperatures**, and the hero's
manifest declares which temperature each role is drawn from. Chrome neutrals
are the *absence* of emission; they are chosen, and they are labelled as
chosen rather than dressed up as derived.

| role | origin |
|---|---|
| void | the event horizon — the space character, no colour at all |
| background | chosen; near-black |
| surface | chosen; a lifted chrome tone, for genuinely raised elements only |
| line | chosen; the rule colour |
| dim | coolest emission |
| error | receding limb |
| warning | mid emission |
| neutral | the solar band, ≈ 5700 K |
| accent | approaching limb |
| highlight | hottest observed |

**Adding a colour means finding it in the render first** (I6).

Two rules that prevent the most common misuse:

- **`surface` is not "the background of a surface".** It is for a raised
  element *inside* one. Using it to make a panel visible produces a large field
  of lifted tone that reads as a different colour against everything beside it.
  If a panel needs to be distinguishable, use a **rule**. Pin this with a test
  that asserts every cell of every surface clears to `background` (§10.4).
- **A label is chrome; a value is data.** Draw section labels in `dim` and
  readings in their temperature-derived role. Colouring a label with its own
  reading's colour makes every label pulse with its number.

### 4.7 Two physical results not to "correct"

- **The hottest regions are genuinely blue, not white.** A blackbody at 25000 K
  is blue. White in such an image is blown-out *exposure*, not chromaticity —
  the disk is actually white where the observed temperature is near solar.
  Keeping this physical yields blue inner, white mid, red outer, which is
  exactly the Doppler asymmetry that should read at a glance.
- **The value axis really is that narrow.** See §4.5.

### 4.8 Colours the physics cannot supply

The Planckian locus is a single curve through orange, white and blue. It
contains **no green, cyan or magenta at any temperature**. A terminal needs six
distinguishable hues or syntax highlighting collapses into two.

Therefore the palette has three tiers, and conflating them would be dishonest:

1. **the render palette** — 256 blackbody entries; physics
2. **locus-derived interface colours** — sampled from the locus; physics
3. **off-locus hues** — green, cyan, magenta, red: **chosen, not physics**

Place tier 3 at lightness and chroma *measured from* the tier 2 anchors so they
sit correctly beside the physical colours, and label them off-locus everywhere
they appear. An honest exception is worth more than a fiction that they were
derived.

---

## 5. The pipeline

### 5.1 Bake once, derive everything

```
  simulation (GPU compute)
        |
        v
  full-resolution HDR frames          keep during development
        |  box-average each cell's pixel footprint
        v
  HDR CELL MASTER  <-------- re-quantise from here, in seconds
        |  tone curve + ramp + colour residual + hysteresis
        v
  quantised master
        |
        +--> wallpaper / screensaver
        +--> login greeter
        +--> boot splash          (reduced frame count)
        +--> console              (small; console font limits)
        +--> logo / still         (tight crop on the void)
```

**Never re-simulate to change an appearance** (I5). Tone, colour and
quantisation all operate on the stored HDR cell master and re-run in seconds.

**Retain the HDR cell master permanently, and back it up.** This is a hard
requirement, not housekeeping. It is what makes the tone curve re-tunable at
zero cost; without it, changing a percentile means a full re-bake and
re-tuning from nothing. At the master grid it is a manageable size — a few
hundred megabytes — and it is the single most valuable output of the whole
pipeline. The full-resolution frames beneath it are large and *are* deletable
once the cell master exists.

### 5.2 Two formats

**The HDR intermediate.** One file per frame. Four channels per cell: linear
RGB plus **observed temperature in Kelvin** (§3.3). Temperature is stored
rather than inferred so the quantiser never inverts the Planckian locus.

**The quantised animation.** One file per target grid:

```
magic + version
cols, rows
frame count
frames per second
ramp length, then the ramp as ASCII bytes in ascending measured coverage
palette length, then the palette as RGB triplets
per frame:
    glyph plane   : cols*rows bytes, each an index into the ramp
    colour plane  : cols*rows bytes, each an index into the palette
```

Compress the payload — large empty regions compress extremely hard. Note that
a palette length of 256 does not fit in a byte; size that field accordingly.

**Terminal and delta backends emit changed cells only.** Hysteresis makes the
overwhelming majority of cells static between frames, so this is an enormous
saving over redrawing.

### 5.3 The resolution ladder

Derive every target from the HDR cell master, with one exception stated below.

| target | grid | note |
|---|---|---|
| master | 640 x 180 | the cell master; 3840 x 2160 px at 6x12 |
| wallpaper, screensaver | 320 x 90 | exactly 1920 x 1080 px at 6x12 |
| login greeter | 320 x 90 | same asset |
| boot splash | 160 x 45 | reduced frame count; initramfs size matters |
| console | 80 x 24 | console font limits |
| logo / still | tight crop | on the void and inner disk |

**Targets whose grid does not divide the master must be re-rendered, not
downsampled.** Two independent reasons:

- **Glyph indices cannot be averaged.** The mean of `.` and `@` is not a tone,
  it is a different glyph. Downsampling must happen in the HDR domain, before
  quantisation, and only when the grid divides evenly.
- **Aspect.** A target with a different aspect ratio to the master needs its
  own camera framing, not a crop of someone else's.

### 5.4 Build the pipeline against a placeholder first

**Every hard problem in this system except the physics lives downstream of the
simulation.** Hysteresis tuning, the frame format, delta rendering, the splash
budget, the console font, occlusion pausing, the atlas, every surface.

So build all of it against a cheap analytic stand-in that emits the *same* HDR
intermediate — a rotating textured annulus with a crude one-sided brightness
asymmetry and a fake radial warp standing in for lensing. It must use the
**same mode sum** (§3.4) so that loop behaviour is real.

Two rules about the placeholder:

- **Nothing downstream may be able to tell it is a placeholder.** If any
  consumer needs to know, the artefact contract (§3.1) is wrong.
- **It is not physically meaningful and must never be treated as such.** It
  needs only the right shape, dynamic range and temporal statistics to exercise
  tone mapping and hysteresis honestly. In particular, a tone curve tuned on
  the placeholder **will be wrong** for real physics (§4.1).

When the real simulation lands it drops into a pipeline that is already fully
validated, and the long bake happens once, with confidence.

### 5.5 Running the bake on this machine

The simulation is a GPU compute workload, not a CPU job: the master grid at
adequate supersampling is on the order of eight million rays per frame, times
240 frames.

**Target Vulkan compute via a portable GPU abstraction**, so the same code runs
on both adapters in this machine. Develop and correctness-test against the
**integrated** GPU at proxy resolution — it is slow but present and needs no
driver decisions — and run the real bake on the **discrete** GPU. Provide an
explicit adapter-selection flag; do not rely on default adapter ordering.

**The open-source NVIDIA Vulkan driver is sufficient.** A discrete Turing part
exposed through Mesa's Vulkan implementation is a fully capable compute device
and is roughly an order of magnitude faster than the integrated GPU here. Do
not assume the proprietary driver is required; verify which adapters are
actually present before deciding:

```
vulkaninfo --summary        # confirm a discrete adapter appears
```

**Expect single-precision only.** Both adapters here have weak double
precision. Three consequences, all of which must be designed in rather than
discovered:

- The null-condition tolerance loosens to roughly `1e-5`. A tolerance of
  `1e-8` is unreachable in single precision and a test asserting it will fail
  for the wrong reason.
- **Re-project the momentum onto the null cone periodically** — every dozen or
  so steps — rather than trusting drift to stay bounded. This is cheaper and
  far more robust than shrinking the step size.
- **The finite-difference step must scale with position.** A fixed absolute
  step that is adequate near the horizon falls below single-precision epsilon
  at large radius, and the difference degenerates into rounding noise.

**Reduce phases before scaling by 2π.** Computing `cos(m*phi - n*2*pi*t)`
directly is not bit-exact at `t = 1` for large `n*2*pi` in single precision,
and the loop then fails to close by a small but non-zero amount. Take the
fractional part of `n*t` first; then `t = 1` reproduces `t = 0` exactly.

**Iterate the physics at proxy resolution** — roughly a quarter of the master
grid — for look tests, and use heavy supersampling for the final bake only.
Edges alias badly into a glyph grid, and the photon ring and disk edges are the
worst offenders.

**Expect the full bake to take on the order of a quarter of an hour** on the
discrete adapter at high supersampling. Measure it; do not quote this figure
as a result.

### 5.6 Reproducibility

**Run the bake twice and compare.** A single run gives no evidence that the
result is reproducible, and this is a pipeline with a stateful quantiser and a
compute shader. It is cheap, and it is the only way to distinguish a real
change from run-to-run variation later.

**What "agreement" means depends on whether the pipeline is deterministic, and
that is worth deciding deliberately rather than discovering.**

*With regular-grid supersampling* — a fixed pattern of sub-samples per cell —
nothing in the pipeline is random and two bakes must be **bit-identical**. That
is a stronger result than agreeing to a few significant figures, but it tests
something narrower: it proves the pipeline is reproducible, not that a noisy
estimator has converged. Take it, and say which of the two you have.

*With stochastic supersampling* — jittered sample positions — the bakes will
not be bit-identical, and the right check is that every churn metric agrees to
about three significant figures, differing only at the floating-point noise
floor.

Regular-grid is the better default here: the subject is smooth apart from the
disk edge and the photon ring, both of which supersampling resolves without
jitter, and determinism makes every later comparison exact.

### 5.7 Derived files are not committed

Any file that can be regenerated from a committed source is **not** committed.
Committing a derived file lets it drift from its source, and that drift is
silent.

The rule has a precondition that must be tested: **regeneration must be
byte-identical**. If it is not, the file is not derived, it is authored, and it
must be committed and treated as a source.

The regeneration tool must rebuild any derived file that is **missing or older
than its source**. Rebuilding only when missing is a defect: after a re-bake
every derived file is present and stale, which is exactly the drift this rule
exists to prevent.

**A DISTRIBUTION SHIPS THEM ANYWAY.** The rule above is about history, not
about what reaches a user's disk. The ISO must contain a working desktop for
hardware that may have no GPU to bake with and no reason to wait, so the bake
runs ONCE on the build host and its output travels inside the package as
`Source1`. Those artefacts are still derived, still rebuildable
byte-identically, and still absent from git — which is the whole of the rule.

`.gitignore` carries the list, and says why for each entry. The prebuilt hero
for nine strikes is 13 MB; an RPM that reached git once was 8.9 MB, larger than
every source file in this repository put together; and 88 MB of lorax solver
output reached it another time. A built artefact in history is the same mistake
at three different sizes.

---

## 6. The renderer

One renderer draws every surface this system owns. It is the reason the
surfaces cannot disagree.

### 6.1 Requirements

- **No GPU.** A cell grid at the bake strike is exactly the panel resolution;
  drawing it means blitting glyph bitmaps from a pre-baked atlas into a shared
  memory buffer. This needs no accelerated context, no video decode path, and
  costs a small fraction of a core. Introducing a GPU context here buys nothing
  and adds a large dependency surface.
- **A glyph atlas baked from the same font file** the ramp was derived from,
  keyed by the same hash (§2.4).
- **Delta updates.** Touch only cells that changed. Hysteresis makes this the
  overwhelming majority-static case.
- **Multiple backends**, at minimum: a terminal backend writing escape
  sequences to standard output; a compositor surface backend; and a
  rasterising backend that writes an image file. The rasterising backend is
  not a debug convenience — it is how the boot splash and every still are
  produced (§9.6), and routing them through the same code path is what
  guarantees they agree with the wallpaper.

### 6.2 The atlas holds everything the font has

**Bake every codepoint the font defines**, not a hand-listed set of the
characters this system's own chrome happens to draw.

The temptation is to bake ASCII plus the two dozen box-drawing and marker
glyphs the interface uses. That is the correct set for a surface whose content
you write, and the wrong set for a surface that hosts somebody else's program
(§7.4). A console-strike Terminus file defines on the order of 256 codepoints;
baking all of them costs a few kilobytes and removes an entire class of defect.

**Bake a bold strike as a second atlas.** Terminus ships a genuinely different
bold bitmap at the same cell size — the great majority of glyphs differ, not
merely in colour. Hosted terminal programs emit bold heavily, and the usual
substitute for a bold face, brightening the foreground, **collides with this
palette**, where brightness already means a reading is high. A cell whose glyph
is missing from the bold strike falls back to the regular one, degrading in
weight rather than in content.

**Keep a required-glyph list that fails the build loudly.** Baking everything
the font has must not mean that a missing glyph the chrome depends on is
discovered as a hole on screen.

### 6.3 Surfaces

Every surface this system owns is a compositor layer surface. Requirements
that apply to all of them:

- **Own the buffer at native resolution.** With scale 1.0 (§2.1) this is
  direct. Never submit a buffer for the compositor to scale.
- **Disable geometry animation on the surface.** A compositor that animates a
  layer surface's geometry will spend a few hundred milliseconds scaling the
  buffer into a box that is not its size during every resize. For a window
  that is a nice touch; for a cell-exact bitmap grid it is visible corruption.
- **Release an exclusive zone before the surface goes.** Otherwise the surface
  vanishes and the windows stay squashed beside something that is no longer
  there.
- **Hide a layer surface by DESTROYING it, not by attaching a null buffer.**
  The null-buffer route works exactly once and is a dead end for anything that
  has to come back, because two rules meet head-on: a compositor will not
  configure a surface that is not on screen, and it rejects a buffer attached
  against a stale configure serial. So the surface waits for a configure that
  can never arrive, and forcing the attach earns `wrong configure serial` and
  the client is killed. Both were measured here, in that order.

  Show and hide are therefore **create and destroy**. A freshly created surface
  goes through the ordinary path — initial commit with no buffer, wait for the
  configure, then attach — which is the one sequence that is known to work.

  A consequence worth stating: any state gate written as *"do nothing until
  configured"* must sit **after** the create, not before it. Put it at the top
  of the loop and the surface is never created, so a configure never arrives,
  so the gate never opens.
- **A re-shown surface needs a fresh configure before a buffer may be
  attached.** Drawing immediately after a remap is a protocol error that kills
  the client.
- **Buffer pools need more than one buffer.** A pool holding exactly one buffer
  must grow it on every frame while the compositor still holds the previous
  one. Cycle a small number of slots, each tagged with the content generation
  it holds, and copy only the rows a slot is missing.

### 6.4 Cost, and what to measure

Always-animating a full-screen surface must be justified by measurement, and
the measurement must be the right one.

**Measure the renderer's own CPU time.** Do not measure battery draw: the
battery on this class of machine frequently exposes only current and voltage
rather than power, that reading is the *charge* current while on mains, and
the kernel's energy counters are root-only for security reasons. CPU time
needs no privileges, isolates this process from everything else on the
machine, and is not confounded by screen brightness or charge state.

**Required power behaviour**, not optional given a permanently animating
wallpaper:

- **Suspend when occluded.** Subscribe to the compositor's event stream and
  stop drawing when an opaque window covers the output.
- **Count windows; do not watch for fullscreen.** On a tiling compositor a
  single tiled window fills the output without ever entering fullscreen mode —
  which is the common case, so a fullscreen-only check suspends almost never.
  Ask the compositor how many windows are on the active workspace.
- **Count the windows that are VISIBLE, and be precise about both words.**
  Two errors here are easy and both present as the check being broken rather
  than as the count being wrong.

  *Counting the wrong nodes.* A compositor typically uses one node type for
  split containers as well as for windows, so counting node types over-counts —
  a workspace holding a single terminal reports two. Count nodes the compositor
  has a **process** for.

  *Counting the wrong scope.* Only windows on a visible workspace occlude
  anything. Walking the whole tree counts every other workspace's windows too,
  and the surface then suspends permanently on a bare desktop. Equally, a
  filter over "real" workspaces silently drops scratchpad and other special
  workspaces, whose identifiers sit outside the normal range — and a shown
  scratchpad window covers the output like any other. Scope by **visibility**,
  which includes a shown scratchpad and excludes a hidden one as the same rule
  rather than as a special case.
- **Stop on display power-off, and ask rather than assume.** It is tempting to
  believe the compositor stops sending frame callbacks when the output powers
  down, so a surface suspends for free. **Do not rely on it** — measured on
  this system, a layer surface kept receiving callbacks and kept drawing with
  the display off, which is exactly the cost this rule exists to prevent, spent
  behind a dark screen where nothing can reveal it. Query the output's power
  state explicitly and subscribe to output events so a change is noticed.
- **Reduce the frame rate on battery.** Choose a divisor of the frame count so
  the loop still closes.

**Do not assume an occluded surface keeps receiving frame callbacks.** Some
compositors deliver them at refresh rate whatever is on top, and throttling is
then the only concern. Others stop entirely once a surface is not being
composited — and a draw loop driven *only* by callbacks then **deadlocks**: no
callback means no draw, no draw means no commit, and no commit means no further
callback. The surface never wakes, even when it becomes visible again.

Measured here: a surface started while occluded never drew at all, while the
same binary started on a bare workspace worked and survived being covered and
uncovered. The difference is only *when* it started, which is the worst kind of
difference to debug.

So a surface must have **its own wakeup** — a wait with a timeout — and treat
frame callbacks as an optimisation that makes it responsive rather than as the
thing that drives it. Throttle when occluded; never depend on being woken.

**Draw only when something has changed.** This is the single most repeated
defect in this system, and every surface has had it. Drawing on each pass of
the event loop commits; the compositor answers; the wait returns immediately;
round it goes. Measured here: the bar at ~74 draws a second for a readout that
moves once a second, the column at **75% of a core sitting perfectly still**,
and the wallpaper the same once its loop was rewritten to poll. Three surfaces,
three different routes, one defect.

The fix is always the same shape: a flag set by the things that actually change
the picture, and an early return when it is clear. Idle cost then goes to zero,
and motion costs only while something is moving.

**A frame costs a buffer and a commit whatever its size.** This is the single
most important cost fact in the system, and it is counter-intuitive: a tiny
animated crop at 24 fps can cost more than a large static surface, because the
cost is per-frame overhead rather than per-pixel work. Two corollaries:

- Run small animated elements at a low frame rate; a divisor of the frame
  count keeps the loop closed.
- Before optimising the drawing, measure it. Layout and blit for a full column
  are typically microseconds — far below the per-frame overhead — so effort
  spent making the layout faster is usually wasted.

### 6.5 An overlay that takes the keyboard is a lockout

The screensaver is a full-screen overlay that must be dismissed by any input.
Taking exclusive keyboard interactivity is correct — the dismissing keystroke
must not also be typed into whatever had focus — but it means this process
holds the only keyboard the user has. Four rules follow, and all four are
required:

- **No input path, no map.** Bind the input seat *before* the surface, and
  refuse to map an overlay whose dismissal path does not exist.
- **Pointer entry is not activity.** A pointer surface reports entry the
  instant the surface appears under a resting cursor. Treat that as the
  baseline and require motion of at least two cells; a resting optical mouse
  emits a pixel of jitter.
- **Dismiss on press, not on release.** A key still held when the overlay maps
  delivers its *release* to the new surface. Dismissing on release kills the
  screensaver on its way in.
- **A short grace window** — about half a second — covers whatever else fires
  on map.

Verify all four against the running compositor, not by reasoning.

---

## 7. The chrome

Everything in this section is drawn in the same font, on the same grid, from
the same palette. This section is the answer to "what should *anything* look
like", and it is what makes a themed third-party application read as part of
the desktop rather than as a recoloured stranger.

### 7.1 Rules

- **Text glyphs only** (I1). If an area must read as dense it uses a dense
  *character*. A meter is a run of ramp glyphs against a dotted track, never a
  filled rectangle. Use `·` rather than a space for an empty track, or the
  meter has no readable extent.
- **One background.** A single near-black everywhere. The lifted `surface` tone
  is for genuinely raised elements only (§4.6).
- **A control is a mark and a rule, not a box.** The live control takes ink and
  gets a rule under it. Do not draw buttons as filled or outlined rectangles: a
  toolbar of eleven boxes is the failure mode this rule exists to prevent.
- **Words, not pictograms.** Where a control has a readable label available,
  use the **word**. Replacing an icon set with punctuation produces a second
  icon set that is *less* legible than the first — a pair of angle brackets
  does not say "repeat" to anyone who has not been told, and two controls that
  both land on `x` is a vocabulary admitting it ran out.
- **Where a pictogram is unavoidable, it is a glyph** rendered from the font's
  own bitmap. A hand-drawn polygon is a second visual language however
  carefully its stroke width is matched.
- **A row that already says what it is does not need a mark too.** Labelled
  rows lose their icons; unlabelled controls keep them.
- **Frames are box-drawing.** Square corners for persistent surfaces, rounded
  for transient ones. Line art is not a filled square.
- **Tabular numerals wherever digits change in place.**
- **One word per thing, everywhere.** If the network is `NET` on one surface
  and `NETWORK` on another and `LINK` in a third, a missing reading prints
  three different ways and none of them is searchable. Fix the vocabulary once
  and use one renderer for "no reading" — the token, the unit and the
  alignment — so a column keeps its shape when a sensor is absent.
- **One quantity, one number, one place.** Do not show two measurements of the
  same quantity side by side. A connected network's signal read from the
  driver's live link quality and read from the last scan are both true, differ
  by a wide margin, and appear on screen as a contradiction with nothing
  explaining it. Decide which measurement a surface is showing and show only
  that one.
- **One size, written one way, everywhere.** Tools report in a mix of binary
  and decimal multiples and differing precision. Convert at the boundary where
  a value enters the system, and render every size through a single formatter,
  so the same quantity never appears in two notations.
- **Readouts are named for what they are.** No invented vocabulary. A name
  that must be explained is not legible, whatever it maps to; a label that
  fires on memory pressure but reads as "disk" is simply wrong. The one place
  physics vocabulary is permitted is where the subject genuinely *is* the
  rendered object — the hero's own spin, innermost orbit and beaming law are
  called those things because that is what they are.

### 7.2 The bar

A persistent horizontal strip, its own layer surface, drawn by this system's
renderer rather than by a general-purpose bar toolkit.

**The reason is measurable, not aesthetic.** A general-purpose toolkit brings
its own text stack, its own cell metrics and its own idea of what an icon is;
at minimum it will put a second grid on screen, and typically a third when a
tray draws raster pixmaps. Verify the claim rather than asserting it: capture
the screen and autocorrelate the ink profile of each surface. Every surface
must resolve to the same cell pitch.

Requirements:

- It reserves exclusive space and is always mapped.
- Readouts are **name + dot leader + value**, so a row reads as one thing
  rather than two columns floating apart.
- Section labels live in the top rule itself rather than costing a row.
- **One sleep, every source.** No polling loop: a single wait serves the
  compositor connection, the event streams it subscribes to, its child
  processes and the next second boundary. Read cheap values on a wakeup that
  is already happening.
- **Any descriptor added to a wait set needs an end-of-file check.** A
  descriptor whose writer has exited reports hangup on every call regardless of
  the requested event mask, the timeout stops applying, and the surface spins
  at 100% of a core. This is the single most expensive defect class in an
  event-driven surface and it has no symptom other than heat.
- **Do not subscribe to an event stream that your own queries appear in.**
  Querying an audio daemon in response to an audio-daemon event makes the query
  itself an event and the surface feeds its own storm.
- **Prefer a file the system already writes over a subprocess.** Spawning a
  process once a second to read a value costs more than the surface it feeds.
  Where this system owns the only thing that changes a value, have that thing
  record it, and stat the record.
- **At most one animated projection of the hero on screen at a time.** A
  moving strip above a column of instruments is decoration competing with
  readouts, and it costs a buffer and a commit per frame (§6.4) for something
  nobody is reading. Where a surface carries a crop of the hero, hold a still
  and let the wallpaper own the motion. If two surfaces are arranged so that
  one is visible exactly when the other is not, they may hand the animation
  between them — but that must be a property of the arrangement, not a thing
  each surface decides for itself.

### 7.3 The column

The most important component and the one most likely to be got wrong.

A vertical layer surface that **is a terminal**. It hosts real programs on a
pseudo-terminal rather than reimplementing them, and it paints their screen
into its own cells with its own atlas and its own palette.

> **Pressing a key does not open a window beside the column. The column
> *becomes* that thing, and pressing again puts it back.**

This is the whole design, and the tempting intermediate is a trap: a floating
window positioned exactly where the column is, so that it *looks* like the
column was replaced. It is a second surface with its own font resolution, its
own background and its own border, sitting on top of one that unmapped
underneath — and the rule that positions it survives long after the illusion is
abandoned, opening things **invisibly behind** the column. Do not build it.

**Requirements:**

- **It reserves exclusive space whenever it is on screen and there is something
  it could cover** — so windows resize rather than being covered. On a bare
  desktop it claims nothing, because there is nothing to make room against.

  Stating this as "while pinned or hosting" is the obvious formulation and it
  is **wrong**, in a way that only shows during motion. The column retracts
  exactly when a window has appeared and it is neither pinned nor hosting — so
  under that rule the entire retract plays with a zone of zero, and for its
  whole duration the column sits **on top of** the very window it is getting
  out of the way of. Tie the zone to the animated width instead and the window
  grows as the column shrinks, never overlapped at any frame.
- **And when it is neither pinned nor hosting, and the desktop is NOT bare, it
  is not on screen at all.** This is the other half of the same sentence and it
  is easy to omit, because omitting it produces a surface that looks correct in
  every state you think to check. A permanently mapped column that claims no
  zone does not sit beside the windows — it sits **on top of them**: the
  compositor gives the window the full output, the window believes it has the
  full output, and a strip of it is simply hidden. Nothing reports this. The
  window geometry is right, the exclusive zone is right, and the screen is
  wrong.

  The three states are therefore: **hosting or pinned** — mapped, claiming its
  width; **desktop bare** — mapped, claiming nothing, because there is nothing
  to cover; **anything else** — unmapped.
- **A small number of widths**, each justified by a measurement: one for the
  instrument column, one wide enough for the longest pick-list row, one wide
  enough for the most demanding hosted program. Determine the last by
  bisection — a monitor program typically refuses to draw below a floor that
  depends on which panels it shows.
- **A terminal emulator implementing a measured subset.** Do not implement a
  terminal from a standards document; implement it against what the programs
  you host were **observed** to emit, and record that measurement (§10.5).
- **What it does not implement, it must skip whole.** The state machine
  consumes an unrecognised sequence rather than printing its bytes. This single
  property is what keeps a surprise from becoming confetti on screen.
- **Implement the scrolling machinery even if nothing measured needs it.** A
  terminal that silently mishandles a line feed at the bottom of a region will
  one day be handed a program that uses one.
- **The picture and the click cannot be allowed to disagree.** Have layout
  return rows tagged with what activating them does; have drawing paint that
  list and hit-testing index it, so the row you see and the row that acts are
  the same object. The classic defect in a hand-rolled panel is that the two
  drift.
- **Nothing costs a subprocess until it is opened.** A closed panel runs no
  queries.
- **The column fills itself.** Give the sections with no natural length the job
  of absorbing the remainder, and fail a test on any run of more than a few
  blank rows. A large void above a bottom-pinned element reads as a surface
  that failed to finish drawing.
- **Take the keyboard only while hosting.** A readout column that holds focus
  is a trap — every keystroke meant for the terminal beside it goes nowhere.
- **Drop any chord carrying the compositor's modifier** in the key encoder, so
  that if the compositor ever stops consuming its own bindings first, a
  workspace switch cannot be typed into a hosted program.
- **The client owns key repeat.** The compositor states a rate and a delay once
  and then says nothing more; every repeat is the client's own timer, and the
  wait timeout must end when the next repeat is due.
- **Backspace is `0x7f`, not `0x08`.** Settled by what the programs read;
  sending `0x08` leaves a filter you cannot clear.

**Pseudo-terminal handling**, three requirements that each fail in a way that
looks like a different bug:

- **Take the controlling terminal in the child, after the fork, before the
  exec.** Without it: window-resize signals are never delivered so resizing
  does nothing, interrupt is never delivered, and closing the master does not
  hang the child up — so quitting a menu leaves the program running for ever
  with nowhere to draw.
- **Both pseudo-terminal descriptors must be close-on-exec.** The master is
  obvious. The **slave** is the subtle one: every *other* process this system
  spawns inherits it, so an unrelated long-lived child holds the menu's
  terminal open, the hosted program exits, the master never reports
  end-of-file, and the column keeps a finished menu on screen for ever. Use the
  atomic duplicate-with-flag operation rather than duplicating and then setting
  the flag, which leaves a window for a concurrent fork.
- **Detach cleanly when launching an application from a hosted menu.** A
  backgrounded session-leader launch returns before the detach lands, and
  redirecting only the output streams leaves standard input on the
  pseudo-terminal, so the new session leader adopts it as a controlling
  terminal and dies with the menu.

**A character the font cannot draw must be replaced with a visible one.** Some
hosted topics render text this system does not author — application names,
clipboard contents — and will eventually meet a character the font has never
heard of. Substituting a blank is wrong: it reads as the program having printed
nothing, which is indistinguishable from a bug. Substitute a visible marker,
use the same marker everywhere, and note that a single-width font cannot
represent a double-width character at all — a wide character occupies two cells
in the hosting program's own column arithmetic, so even a placeholder box
desynchronises the layout against where that program believes things are. This
is a limit of the medium, not a defect to fix: no size of this typeface has
CJK, kana, hangul or emoji, and none ever will.

**What the column will and will not host is decided by measurement, not
taste.** Run each candidate on a pseudo-terminal of exactly the size the column
would give it and count the codepoints the atlas cannot draw (§10.5). A program
needing glyphs the font does not have is either **redrawn from its own data
source** in this system's chrome, or not hosted. **Prefer redrawing**: a status
program is usually a formatter over a query you can run yourself, and redrawing
it removes a dependency as well as a glyph problem.

A count taken from a screen with nothing on it is not evidence. Say so in the
record rather than reporting a zero.

### 7.4 Menus

Every menu is one filter-picker hosted in the column: name, dot leaders, value,
and a dim context line under the prompt stating the one thing that topic can
say for itself.

**Audit the picker's own default glyphs by running it and reading the
codepoints.** A filter program will draw block characters for its pointer, its
selection marker, its scrollbar, its **gutter** — the empty column beside every
non-current line, which therefore draws on every visible row at once — and, the
one that hides longest, its **loading spinner**, which is frequently braille and
sometimes has no option to change it. For the spinner the fix is upstream:
build slow lists into a variable so the picker never enters its loading state.

A comment listing which defaults were fixed is not a check. The gutter is
exactly the one such a comment omits.

**Turn the picker's own border off inside the column**, which has already drawn
a frame; leave it on anywhere the surface has no chrome of its own.

### 7.5 The on-screen display

A key that changes something invisible must say what it changed it to,
especially one that repeats.

Use the notification daemon rather than adding a fourth layer surface, with a
**stack tag** so repeats replace rather than accumulate. Draw the meter with the
same ramp everything else uses. **Do not pass the daemon's own progress-bar
hint** — that draws a filled rectangle (I1).

### 7.6 Terminal-adjacent surfaces

The shell prompt, the pager and the diff viewer are looked at more than any
window. They are chrome: they belong in the palette and they are ASCII-only.

These tools default to icon-font glyphs and powerline separators, which are
pictograms from private-use codepoints that this font does not have and cannot
have. Some of them **compile their theme into a cache and read only from it**,
so writing a theme file is not enough and the build step can fail silently.
Verify by running them and reading the codepoints, never by reading the config.

---

## 8. What the desktop does

§7 says what things look like. This says what exists and how it behaves. A
build that follows §7 alone produces a handsome shell with most of the desktop
missing.

### 8.1 Choosing the compositor

Required capabilities, all of them hard requirements:

| requirement | why |
|---|---|
| a layer-shell protocol with exclusive zones | every surface this system owns (§6.3) |
| tiling by default | §8.2 |
| a subscribable event stream for workspace and window state | occlusion (§6.4) and surface arbitration |
| the ability to recover the bindings it actually loaded | the duplicate-key verifier (§10.4) |
| no unrequested animation of layer-surface geometry | §6.3 |
| runs on Fedora from packaged builds | §9.1 |

**Settled choice: Sway.** Verified against all six on this machine at Phase 0.
It is packaged for Fedora, it is wlroots-based so the layer-shell protocol is
native rather than an extension, it tiles by default, its IPC accepts event
subscriptions, and it does not animate layer-surface geometry at all — which
makes the fifth requirement vacuous rather than merely satisfied.

**Hyprland is not packaged for Fedora and must not be used here.** Only its
supporting libraries are in the repositories; the compositor itself would come
from a third-party repository, and §9.1 forbids a core component depending on
that tier. A compositor is the most core dependency there is.

**The fourth requirement is satisfied differently, and the difference is worse
than it first appears.** Sway does not expose a parsed list of bindings over
its IPC. It exposes configuration text — but **measured on this system, that
text does NOT expand `include` directives.** A distribution's default
configuration commonly ships whole files of bindings behind an include, so an
audit built on that text alone reports a clean set while real bindings sit
outside it, unaudited and free to collide.

So the audit must **resolve includes itself**: parse the configuration file,
follow every include the way the compositor does, and audit the union. Verify
this property on whatever compositor is in use rather than assuming either
behaviour — plant a binding in an included file and see whether the query
returns it.

Do not depend on a specific configuration-language feature of the compositor —
those change between releases. Verify every dispatcher and rule signature you
rely on against the running compositor, and confirm the *effect*, not the
return status. A configuration call that reports success and does nothing is
this project's most frequent failure (§10.7).

### 8.2 Window management

**Tiling, and nothing spawns floating.** Not "few things": the default is that
a new window takes its place in the layout, and the exceptions are enumerated
here in full.

1. A **modal dialog** owned by a window that is already tiled. It is gone in
   seconds and tiling it reflows the layout twice for something that was never
   a pane.
2. **Always-on-top video**, where being above everything else is the entire
   feature.

That is the whole list. In particular, do not add a rule that positions a
window where the column is (§7.3).

If something must be centred, centre it in the area **left over after the
column's reserved zone**, not on the output.

### 8.3 The keys

**One modifier plus the first letter of the thing**, wherever the letter is
free.

- **Every binding carries a human description.** A binding with no description
  cannot appear in the generated keys list and cannot be audited.
- **The keys list is generated from the live bindings**, so it cannot drift
  from the configuration.
- **A verifier reads the live bindings back and fails on any key bound twice**
  (§10.4). This is not optional. Two bindings on one key is silent — the last
  one wins — and it is the easiest mistake to make when adding a component.
- **Hardware keys that change something invisible must show a readout** (§7.5).

### 8.4 The components

Described by what they do. Which program provides each is a local decision, and
§7.3 gives the test for whether it is hosted or redrawn.

| component | what it is for |
|---|---|
| run | launch an installed application |
| find | locate a file anywhere on disk |
| settings | the scattered knobs, in one panel |
| network | join and inspect wireless networks |
| bluetooth | power, scan, pair, connect, forget |
| audio | choose the output; per-application volume |
| monitor | processes, load, temperature |
| player | what is playing, and its transport |
| calendar | the month, and anything with a date attached |
| clipboard | history, re-copy |
| capture | stills and recordings |
| packages | install, remove, search |
| update | every update channel on the machine, and their state |
| power | the session verbs |
| storage | map and unmap network storage |
| keys | every binding, read live |

Six of these carry rules that are not obvious.

**find is not a filter over a list.** The list is the whole disk, and building
it up front costs seconds before the first keystroke. **Turn the picker's own
matcher off** and re-run the file finder on every keystroke instead. Show
results **relative to the search root** — absolute paths spend a third of every
row on the same prefix and then truncate the part that identifies the file.
Opening a directory means opening *at* it; opening a file means opening the
file manager with that file **selected**, which is a different verb from
opening the file.

**settings owns nothing.** Every row reads from, and writes to, whatever
already owns that setting — the backlight, the night-light daemon, the audio
daemon, the notification daemon, the network daemon, the idle daemon. There is
no local copy of any value, so nothing can drift. It **loops and re-reads**
rather than exiting on a pick, because hardware keys and timers move these
behind its back, and a panel showing what it last wrote is worse than no panel.

**A row whose hardware is absent is not drawn.** A backlight row on a machine
with no backlight is a permanent complaint about a missing feature. Detect by
probing the hardware at runtime, never by a build-time flag.

**update reports before it acts.** With no argument it changes nothing, so the
safe thing is also the shortest thing to type. Make that promise structural:
have the verification suite read the text of each channel's reporting path and
fail if a mutating command appears in it. Cover at minimum packages, orphaned
packages, package cache, firmware and font caches.

- **Firmware is the one channel that does not act by default.** Everything else
  is undone by reinstalling a package; a bad flash is undone by buying a
  motherboard. Refreshing metadata and reporting is the default; writing to a
  device requires an explicit flag, and the "run everything" verb skips it.
- **Check a catalogue's freshness before reporting its verdict.** A firmware
  tool comparing devices against metadata it has never downloaded will report
  "no updates available", which is indistinguishable from good news and is not.
  An enabled remote that has never been fetched, or is older than its own
  refresh interval, means the honest answer is *no metadata*, in the fault
  colour.
- **A tool with no dry run cannot be asked.** A font cache builder that
  rebuilds whatever it finds stale answers the question by doing the thing.
  Compare modification times instead.

**capture is both halves in one place** — stills and recordings, on one key
each, with the recording key toggling. A recording you cannot see is the
failure mode: a screen recorder draws nothing and makes no sound, so starting
one must raise a notification that persists until it stops, and stopping one
must name the file. Send the recorder an **interrupt**, not a terminate: many
finalise the container on interrupt and truncate on terminate, and a truncated
recording will not play.

**packages offers explicitly-installed packages for removal**, not the full
installed set — offering the latter invites removing a dependency by hand. Run
the detail query as a preview of the highlighted row rather than building
descriptions for the whole repository up front.

### 8.5 The idle ladder

Five stages, in order, each with its own timeout:

```
dim  ->  screensaver  ->  lock  ->  screen off  ->  suspend
```

**The screensaver stage exists to be cheap to walk back into.** It is the hero,
full screen, dismissed by the first real input, and it sits one stage *before*
the lock precisely so that a machine you walked away from for two minutes costs
a keystroke rather than a password.

**The lock must stop the screensaver first**, since a lock surface renders
above every layer surface and would otherwise leave it animating, unseen, at
full frame rate.

**The ordering is an invariant and nothing enforces it for you.** Set the lock
later than the screen-off and the lock never observably fires: the display went
dark first and you return to an unlocked machine. Any tool that edits one stage
must drag the later ones with it and say that it did.

**Identify stages by what they do, not by their timeout or their configuration
key.** Every stage typically has the same key and only the numbers differ.

On a machine with no battery the ladder does not end in suspend.

### 8.6 The screensaver, and occlusion inverted

The screensaver is the wallpaper: same asset, same renderer, same atlas, same
delta blit. Only two things differ — its layer and its dismissal.

**Occlusion logic inverts on an overlay.** The wallpaper suspends when a window
covers it, which on a tiling compositor means "any window on this workspace".
Reusing that logic unchanged on an overlay surface freezes the screensaver on
every workspace that has a window open, which is nearly all of them — because
the overlay sits *above* every window, so what covers the background says
nothing about what covers it. Make the overlay layer imply forced animation as
a property of the surface, decided in one place, rather than a flag the caller
must remember.

**Stop the right process.** The wallpaper and the screensaver are the same
binary on the same asset, so matching on the process name kills the desktop
background too. Write a process-id file and confirm the identity of the process
before signalling it, because process ids are recycled.

### 8.7 The file manager

**A window, not a column.** It is a thing you resize, drag out of, and put
beside another window, and a narrow strip that holds the keyboard can do none
of that. Hosting one in the column is a mistake worth not repeating.

Required behaviour, because these are the differences people actually feel:

- **Details view by default** — name, size, type, date — with ISO dates.
- **Double-click to open.** Single-click-to-open is the default in several
  toolkits and it is the one setting that makes a file manager feel unlike
  every other desktop.
- A **path breadcrumb**, and a places sidebar.
- Its own search is usually poor; the **find** component covers it. Searching
  *is* a pick, so that half belongs in the column even though the file manager
  does not.

### 8.8 The editor

Whatever is chosen must **say how to leave it**. That is the whole requirement
and it is not a joke: it is the property deciding whether the machine is usable
by someone who did not configure it.

Set it as the system editor everywhere, so that the version-control system, the
privileged-edit wrapper and anything reading the environment all agree.

### 8.9 Network storage

Mapping a share is a component, not a one-off command.

- **Automount, never a plain boot-time mount.** A laptop's server is absent
  more often than present; a normal entry is tried at boot, blocks while it
  times out, and drops the machine to an emergency shell. Mount on first
  access, and unmount when idle so a suspended machine is not holding a dead
  connection.
- **Test the mount by hand first and record only what worked.** A stored entry
  that does not work fails at some later moment nobody is watching.
- **Credentials go in a root-only file.** The mount table is world-readable by
  design. Never put a password in it, and never pass one as a command argument
  — that puts it in the process list for the same audience.
- **Guard the mount table.** Anything rewriting it wholesale must refuse a
  result that has lost the root filesystem's own line, and must refuse a result
  that has lost more than the single line being removed. Test against an empty
  file, a file with the root line deleted, and a truncated file; all three must
  be refused, and a valid table must be accepted. This is the one component
  that can make the machine unbootable while appearing to have worked.

### 8.10 Third-party applications

Two classes, and the distinction decides the whole approach.

**Toolkit applications.** Theme the *toolkit*, not the application: one
stylesheet dresses every application built on it. Three traps, all silent:

- **Declaring theme colour names is not enough.** A default theme compiled from
  a stylesheet language bakes most of its colours in as literals, so declaring
  the *names* changes only the parts that still reference them — producing an
  application in the stock grey with your icons and your font, which looks like
  a partial success and is a total one. **The surfaces must be named
  explicitly.**
- **Desktop-settings keys outrank configuration files** wherever both exist. A
  configuration file can be applied in full while its font is silently
  overridden by a value left in the settings database by a previous desktop.
- **Naming a theme or a platform plugin that is not installed falls back to a
  built-in light palette, silently.** Check which plugins actually exist on the
  machine before naming one. Note also that a "dark" variant is frequently a
  *flag* rather than a theme name, and naming it as a theme falls back to the
  light one.

**Web applications.** Anything built on a browser engine is styled by injecting
a stylesheet, and two facts dominate:

- **A bitmap font is not safe in a browser engine, and the engine does not
  report what it did.** Measure before believing either the optimistic or the
  pessimistic story. The blunt version of this rule — that such a font simply
  will not render — is **not what was observed here**: an OpenType-wrapped
  bitmap build rendered in both engines tested, distinctly from the fallback.
  What they did instead is worse to detect. They **scaled it**: advance widths
  came out exactly proportional to the requested size, so at any size that is
  not one of the font's real strikes the text is a scaled bitmap — the one
  thing this design exists to avoid — while every query still reports the
  intended family. So the requirement stands and the reason is sharper: either
  pin every size to a real strike, or use an **outline** build of the same
  design. Prefer the outline build wherever the size is not yours to fix.
- **Class names are hashed per build.** Key selectors on semantic handles —
  accessibility labels, test ids, data attributes — never on hashed classes,
  and never on a substring match against them. A substring net over someone
  else's hashed names catches whatever they happened to name that way; a rule
  matching "empty" will find the placeholder inside a text composer as readily
  as an empty state.

**Verify the font substitution with a discriminating probe.** Measure the
advance width of a glyph under each candidate family, and include (a) a
deliberately bogus family name and (b) a family known to differ. If the bogus
name measures the same as your font, you are looking at the fallback; if
*everything* measures the same, the probe is broken. Beware your own
stylesheet: a project-wide important rule will silently win against the probe
and make every family measure identical for entirely the wrong reason.

**Width alone is not enough.** A bitmap build and an outline build of the same
design have the *same metrics*, so they measure identically and differ only in
what is painted — and metrics are exactly what an engine can read from a font
it cannot draw with. So the probe must also **draw**, and compare a signature
of the rendered pixels. Where the engine exposes the family it resolved to,
ask for that as well; where it does not, the pixels are the only truth
available.

For both classes, **deslopping is default-deny**: hide the container and allow
back the few things wanted. The alternative is playing whack-a-mole with
someone else's release cycle.

**An application's empty states are where the hero belongs.** A "no results"
pane is the one place inside somebody else's program with room for the asset
and nothing of theirs to fight, and it is what makes a themed application read
as part of the desktop. **Draw it as text** — the same cells, from the same crop
— not as an image, or it arrives with its own background and sits on the
surface like a sticker.

### 8.11 The pointer, and the icon problem

**The pointer** is on screen more constantly than any other element and is the
last thing anyone remembers. There is no way to derive a cursor theme from the
asset, so this is an honest exception: choose the least-wrong existing set and
record that it was chosen. Do not leave it at the toolkit default and call the
desktop finished.

**Icons** are demanded by applications this system would rather not have them
in. The theme is generated, so:

- **Recolour an existing set by substitution, not by nearest match.** Icon sets
  are typically a small number of shapes in a small number of exact colours;
  find those colours and swap them for the palette's own. Picking the nearest
  shipped colour from a fixed list is how a desktop ends up with one element
  that is *almost* the right colour, which reads worse than something plainly
  different.
- **Find the remainder by asking what is left.** After substituting the obvious
  colours, enumerate what colours remain in the generated set. Anything not in
  the palette is a substitution you missed.
- **Recolour the rest by luminance**: keep each colour's lightness, take its
  hue away, quantise onto the palette. One rule handles thousands of files
  where a lookup table handles none.
- **Draw chrome marks as font glyphs**, rendered from the font's own bitmap.
- **Blank the icons on rows that already carry a label.**
- Write the generated theme into the user's own icon directory, which needs no
  root and survives an update of the set it derives from.
- **Expect the icon names not to be the standard ones.** Desktop environments
  ship prefixed sets; read the names out of the binary if an override does
  nothing.

---

## 9. Integration with Fedora

Everything above is distribution-independent by design. This section is the
part that is not, and it is deliberately confined to one place.

### 9.1 The package abstraction

**Exactly one component may name a package manager.** Everything else asks
that component for verbs:

```
install        remove         upgrade        search
what-is-orphaned              what-owns-this-file
refresh-metadata              list-explicitly-installed
```

Package **lists** are per-distribution data files, because the names genuinely
differ between distributions and no abstraction can fix that.

On this machine the manager is **dnf5**. Note that its command-line behaviour
and output format differ from its predecessor in ways that break naive parsing;
prefer machine-readable output where offered, and pin the behaviour with a test
against captured real output rather than against an assumption.

Fedora-specific mappings the abstraction must provide:

| verb | Fedora mechanism |
|---|---|
| what-owns-this-file | query the RPM database by file path |
| what-is-orphaned | the package manager's own unneeded/leaf query |
| list-explicitly-installed | the user-installed set, not the full installed set |
| refresh-metadata | an explicit metadata refresh, distinct from an upgrade |

**Anything not in the distribution's own repositories is a separate, clearly
marked tier**, and must never be a hard dependency of a core component.
Third-party repositories are a deliberate, recorded decision each time.

**Verify before assuming a package name.** Rather than transcribing package
names from anywhere, ask the machine what provides the file you need:

```
dnf provides '*/ter-u18n.psf.gz'
dnf provides '*/vulkaninfo'
```

This is the only reliable way to bridge naming differences between
distributions, and it is a one-line habit.

### 9.2 SELinux

**Fedora enforces SELinux by default.** This is the largest behavioural
difference from a permissive distribution for a project that installs files into system
locations, and it produces a failure mode this system is already prone to: a
thing that reports success and does nothing.

Rules:

- **Files placed into system directories must carry the correct label.**
  Copying a file into a system path preserves the *source* label rather than
  acquiring the destination's, so a file installed by copy can be present,
  correct and unreadable by the service that needs it. Restore the default
  context on anything installed into a system location, as an explicit step in
  the installer.
- **Check the audit log before concluding a service is misconfigured.** A
  denial is silent from the service's point of view; it will simply behave as
  though the file were absent. Make "look for denials" the first diagnostic
  step for anything root-owned that does not take effect, not the last.
- **Do not disable enforcement to make something work.** If a component
  requires it, that component is wrong. Adjust the label or the policy.
- **Custom systemd units and user services** need the same treatment.

**Add SELinux to the standing list of silent-failure mechanisms** in §10.7.
It belongs in exactly the same category as a compiled-in theme literal or a
settings key outranking a configuration file.

### 9.3 Fonts on Fedora

Two Fedora-specific facts about fontconfig, both of which must be verified
rather than assumed, because the shipped configuration varies by release and by
what has been installed.

**Bitmap fonts may be rejected outright.** Fedora ships several mutually
exclusive fontconfig fragments controlling this, available but not necessarily
active. Determine the state on the actual machine:

```
ls -l /etc/fonts/conf.d/ | grep -i bitmap
ls    /usr/share/fontconfig/conf.avail/ | grep -i bitmap
```

If a "no bitmaps" fragment is linked into the active directory, **this entire
design cannot work until it is unlinked** and the corresponding "yes bitmaps"
fragment is linked in its place. Nothing will report an error; the font will
simply never resolve.

*Verification, and the only one that counts:*

```
fc-match Terminus            # must resolve to a Terminus file, not a fallback
fc-match 'Terminus:pixelsize=18'
```

A result naming any other family means the font is not available to any
application that goes through fontconfig, whatever `fc-list` says.

**Bitmap scaling may be enabled.** A fragment that scales bitmap fonts to
requested sizes is frequently active. It is *worse* than an outright rejection
for this design, because it means asking for a size with no matching strike
succeeds and silently returns an interpolated bitmap (§2.1). Either remove it
or — better, because it is robust to the configuration changing — **pin every
size to a real strike** and verify the resulting cell metrics by measurement.

**A browser engine needs an outline build** (§8.10). The console and X11
builds of Terminus are bitmap-only and will not render there at any size.
Obtain an outline redraw of the same design, install it as a user font, and
verify with the discriminating probe in §8.10 — not by reading a computed style.

### 9.4 Root-owned changes

Console font, login theme, boot splash, kernel command line: each is a
**separate, reversible, deliberately invoked subcommand**. None is ever part of
a bulk install.

Requirements for every one of them:

- **Report first.** With no argument, print every change and touch nothing.
  Acting requires an explicit flag.
- **Back up what is replaced**, to a timestamped location, with a documented
  way to restore.
- **Derive from the running system**, not from a document. Read the current
  state, print what was derived, and refuse on anything unexpected.
- **Refuse rather than guess.** A refusal that turns out to be over-cautious
  costs a minute. The alternative costs a boot.
- **Take a filesystem snapshot first.** The root filesystem here is btrfs, so a
  read-only snapshot is effectively instantaneous, costs nothing until blocks
  diverge, and is a complete rollback path for anything in this section. Take
  one immediately before any root-owned change, name it for the change, and
  record how to roll back to it.

  This is a genuine advantage of the filesystem and it should be exploited
  rather than left as a property nobody uses. It does **not** replace the
  fallback boot entry (§9.6): a snapshot is reachable only from a system that
  boots, so it covers a bad *configuration* and not a bad *initramfs*. The two
  guards are for different failures and both are required.

### 9.5 The console

The virtual console font is set through the system's vconsole configuration and
applied by regenerating the initramfs. Use the font's console build directly.

**Stay at or below 256 glyphs.** Beyond that the console loses bright
background colours, because the ninth bit is reallocated from the attribute to
the glyph index. Verify on hardware, not in a virtual machine.

The console banner is a derived asset like every other still (§5.7). A
hand-committed banner is a banner that will still show the placeholder hero a
year after the real one was baked.

### 9.6 The boot splash

**There is no disk encryption on this machine** (§0.2), so the splash is a
theme, a package and a kernel command-line flag. It owns no password prompt and
requires no initramfs restructuring.

**Fedora specifics.** The initramfs generator is dracut, the bootloader
configuration is Boot Loader Specification entries, and kernel arguments are
edited with the distribution's kernel-argument tool rather than by hand-editing
generated files.

```
splash                       # the kernel argument the splash requires
```

**The fallback boot path already exists, and must be verified rather than
built.** Fedora keeps several kernels installed and generates a rescue entry:

```
ls /boot/loader/entries/     # expect a *-rescue.conf plus one per kernel
```

This is a genuine advantage over a single-image boot setup. It is not a licence
to skip the check:

> **Confirm by rebooting into a fallback entry before changing any initramfs.**
> A verified fallback is the difference between a mistake costing a reboot and
> a mistake costing a live USB.

**Regenerate only the running kernel's initramfs**, leaving at least one other
kernel's untouched, so a bad image is one boot-menu selection away from
recovery rather than a reinstall. Regenerating all of them at once removes the
fallback you just verified.

**The splash must not be the only thing on screen.** A splash hiding a boot
that has stalled is a machine that looks dead. Confirm the key that reveals
boot messages still works, on a real boot.

**Test on real boots, not in a virtual machine.** Everything specific to this
component — the font situation, the framebuffer handover, the timing — differs.

#### 9.6.1 The splash draws no text

This is the most important requirement in the section and it is
counter-intuitive.

**A splash theme's text primitive renders with the theme's general font
setting, not its monospace setting.** A theme naming only the monospace font
leaves the general one empty; the initramfs generator's hook resolves the empty
name through font matching, which returns **whatever the system's default
proportional font is**, and installs that into the initramfs. The result is
several hundred columns of ASCII art drawn in a proportional face: every row a
different width, and art that turns to noise.

Naming the bitmap font explicitly instead is a *gamble*, not a fix: it resolves
to a bitmap face, and the exact cell grid this system guarantees everywhere
else would then depend on a size negotiation happening correctly inside an
initramfs. Additionally, a text primitive typically takes **one colour for a
whole string**, so the hero would be drawn flat while every other surface draws
it on the temperature ramp.

**Therefore the splash draws no text at all.** Rasterise the frames to images
through the same rendering path that draws the wallpaper (§6.1), so the splash
cannot disagree with the rest of the system about what the hero looks like. A
small number of frames at reduced resolution is a modest number of kilobytes —
comparable to, or smaller than, the string data it replaces — and it carries
the full per-cell colour.

**Name a font anyway, for messages — and understand that it does not choose
the face.** The instinct is that a theme drawing no text should name no font.
That is wrong, and wrong in a way worth stating precisely, because it is the
same mechanism as the failure above.

The initramfs hook installs the named font at its real path, but it *also*
**always** resolves font matching with an empty pattern and installs whatever
that returns, symlinked to a fixed filename — and it installs only the label
plugin that reads **exactly that fixed filename**. So:

- a proportional font reaches the initramfs whether or not the theme names one;
- the face that draws text there is the system default, **whatever the theme
  says**;
- naming a font therefore governs the *size* and the later real-root phase, and
  nothing else.

This is the strongest form of the argument for images: the face that would draw
the hero as text is not one the theme is able to choose. Messages must still be
drawn — a stalled boot has to stay readable — so name a font for them, and note
in the theme that it is for messages only.

**Verify the module exists before naming it.** Splash systems ship several
rendering modules and a distribution may not install the scriptable one; the
initramfs generator exits non-zero on a theme whose module is absent. Choose the
module that is present and animates a numbered frame sequence natively — a
frame sequence is all this needs. The installer must **refuse a theme whose
module has no library on the system**, and list the ones that do.

**Subsampling a perfect loop still loops perfectly.** Taking every Nth frame is
safe; it plays faster, which does not matter for a splash.

The frames are derived and are not committed (§5.7), and the installer must
**refuse to install a theme whose frames are missing** rather than leaving a
black screen that looks like a boot failure.

#### 9.6.2 Seeing it without rebooting

The splash daemon can be run against a spare virtual console for iteration.
Run it from a console other than the compositor's — it wants exclusive display
control and the compositor is holding it. This shortens the loop enormously,
but it does **not** replace a real boot test.

**Better: build a throwaway initramfs and inspect it.** Generate an image to a
temporary path rather than the boot path, and check that the theme files *and*
the theme's module are inside it. If the generator accepts the theme name as an
environment variable and writes the daemon's configuration into the image from
it, this reproduces exactly what the real run would produce while leaving the
boot path untouched — confirm afterwards that the live configuration is
genuinely unchanged.

Check **which theme the image would boot**, not merely that the files are
present. A report of "all files installed" beside an image that still boots the
old theme is worse than no report. Find out how the daemon actually selects a
theme on this distribution rather than assuming a well-known filename; the
obvious one may not exist at all.

### 9.7 The login greeter

**First establish which greeter is actually enabled.** Fedora's headline
edition ships one that is not readily themeable to a cell grid, but other
installations — a tiling-compositor spin in particular — already run a greeter
whose theming model *is* a document you control. If so this is a **theme**, not
a swap, and swapping anyway is gratuitous risk. Check before planning.

Where a swap is genuinely needed it is a deliberate, reversible root-owned
change (§9.4): install the replacement, disable the existing one, enable the
replacement, and **verify it starts before rebooting into it**.

The greeter takes frames as data and real text. Compose its panel from the same
elements as every other panel so that unlocking and logging in look like one
system.

**Read the toolkit's component names and property semantics off the installed
module.** Greeter toolkits are small, version-dependent, and not the standard
widget set: the component may be named differently from the obvious one, a
property named for a colour may set the *background* rather than the text, and
the expected signal may not exist at all. Every one of those is a plausible
guess and a wrong one.

**Verify by looking at it.** A greeter that cannot load its theme typically
catches the failure and **falls back to the stock theme**: the process stays
up, exits cleanly, and logs nothing. Exit status and an empty log are therefore
consistent with total failure. Capture the screen. A cheap machine check is
that the fallback is usually a photograph and this design is nearly black, so
the fraction of lit pixels separates them decisively.

**Then verify it as the greeter's own user.** A theme copied into a system path
keeps the *source* directory's security label rather than acquiring the
destination's, so it can be present, correct, and unreadable by the account
that needs it (§9.2). Restore the context and confirm the files are readable as
that user.

If the panel is framed with rules, compute their width from the cell metrics
rather than counting characters by hand, so the rules span the rows exactly.

Have a way back. A greeter that fails to start is a machine with no graphical
login, and the way out is a virtual console — which is why §9.5 comes first in
the build order.

### 9.8 Joining files that are not yours

Shell profile, version-control configuration, browser profile: these hold the
user's own settings.

**Add one line** pointing at a file this system owns, guarded by a marker so a
second run is a no-op, backing up first. **Never overwrite.**

The corresponding installer check is phrased as **"is the join still there"**,
not "does our file exist". The second is true in every case that matters and
in the failure case too.

### 9.9 Linking

Symlink configuration into place; back up anything real already there.

**Link directories only where the whole directory belongs to this system.**
Where an application also writes its own state into that directory, link the
individual files instead, or the application's first write either fails or
lands in your repository.

**The link set is not a snapshot.** A list of files to link, written once, will
silently omit every component added afterwards — with the symptom that a new
tool simply does not exist as far as the desktop is concerned. Derive the set,
or test that every executable this system ships is reachable.

**Nothing may be invoked by bare name.** A name resolves through an interactive
shell's search path and through nothing the compositor starts. Components must
invoke their siblings by resolved path.

**Roll back automatically.** After linking, reload the compositor, count the
described bindings, and restore the backup if the count collapses. A
configuration that fails to parse leaves a desktop with no keys at all, and the
user's only input device is the one that just stopped working.

---

## 10. Verification

### 10.1 The method

This is more important than any individual decision in this document.

**The recurring failure in a project of this shape has exactly one form: a
configuration that is read in full, reported as read, and silently ignored.**
It appears in file managers, editors, browser engines, toolkits, icon sets,
terminal tools that cache their themes, security policy, and font
substitution. In every case the program starts cleanly and the setting does
nothing.

Therefore:

1. **Run it and look.** An exit status of zero is not evidence. A theme file
   present on disk is not evidence. The render is the evidence.
2. **Probe with something unmistakable.** When an override appears not to work,
   replace it with something impossible to miss. If *that* does not show up
   either, the mechanism is wrong, not the value.
3. **Check that the probe can fail.** A measurement where every candidate
   returns the same answer usually means the measurement is broken. Include a
   deliberately bogus input and confirm it differs.
4. **Beware your own overrides.** A project-wide important rule will silently
   win against your own measurement probe.
5. **Identify the thing you are measuring.** More than one window of the same
   application can be on screen. Capture by process id, not by guessing.
6. **Record the number next to the thing it measures**, and re-measure when its
   inputs change (§10.7).
7. **Prefer deleting.** A themed program nobody opens is upkeep with no reader.
   A feature that looks like another system's without doing what that system
   does with it is a sticker, not a feature.
8. **A success can be reported as a failure, too.** Under a shell configured to
   fail on any pipeline member's error — which every script here should be — a
   consumer that exits as soon as it has its answer causes its producer to die
   of a broken pipe, and that becomes the status of the whole pipeline. The
   faster the match, the more certain the "failure". A check written this way
   reports *not found* precisely **because it found something**, and it will do
   so in the component that decides whether a saved network needs a password as
   readily as in a font check. Let the producer finish, or discard its output
   without closing the pipe early.

### 10.2 Simulation checks

All analytic, all cheap, and all to be run **before** any long bake.

| check | expected |
|---|---|
| horizon radius at `a = 0` and `a = 0.9` | `2.000000` and `1.435890` — these validation cases stay at `a = 0.9` whatever the hero uses, because they are checks against published analytic values, not renders |
| inverse metric at large radius | approaches Minkowski as `2M/r` |
| Hamiltonian at emission | zero to machine precision |
| Schwarzschild shadow radius, spin disabled | `3*sqrt(3) M = 5.196152` |
| Kerr prograde and retrograde photon-orbit impact parameters at `a = 0.9` | evaluate the analytic photon-orbit relation and require agreement |
| null condition along every geodesic | below the single-precision tolerance of §5.5 |
| camera centring | the shadow centred to sub-pixel |
| lensing off, then on | a plain ellipse, then the far side visible **above and below** the shadow |
| shadow shape at `a = 0.9` | flattened on the prograde side into the characteristic asymmetric form |

**Expect most of the defects these find to be in the tests, not the
renderer.** Comparing a geometric offset against a conserved-quantity ratio
when the two differ by a factor that tends to one only at infinity; evaluating
the null condition on rays already inside the horizon, where the metric
function diverges; scoring step-budget exhaustion as escape; searching a
parameter window that does not contain the answer; and reading a
Doppler-brightened limb as a camera misalignment — every one of these produces
an image that *looks* fine, which is the entire argument for analytic checks
over eyeballing.

**Measure geometry, not brightness.** Whether the camera is aimed correctly is
answered by a disk-hit mask. It is not answered by luminance, because beaming
makes one limb cross any display threshold and the other not.

**Check the mode ladder face-on, in the disk's own coordinates**, with no
camera and no lensing (§3.4.3). Report the amplitude-weighted circular
resultant of the crest azimuth over radius: 1.0 is a perfect spoke and 0 is
crests spread over every azimuth. Nothing else sees this.

**Cross-validate any accelerated implementation against a slow, obviously
correct reference.** This is the entire reason to write the slow one. Compare
on three levels — which rays strike the disk (expect exact agreement),
luminance and temperature (expect sub-percent medians), and the **quantised
glyphs** (expect near-total agreement, with the few differences being a single
adjacent ramp level). The third is the one that matters, because it is what
reaches the screen.

### 10.3 Pipeline checks

**A cross-validation must pin the scene on both sides.** Two implementations of
one simulation are only comparable if they are simulating the same thing, and
"the same thing" is a dozen numbers. If either side is allowed to supply its
own value for any of them, the comparison silently becomes a comparison of two
different scenes — and it will report the *implementation* as broken, which is
the most expensive possible wrong answer, because it sends you into the code
that is correct.

This happened here. The accelerated tracer carried compiled-in defaults for
spin, inclination, inner radius and inner temperature; the cross-validation
passed none of them; and after the hero was recomposed the reference ran at
`a = 0.6` while the shader ran at `a = 0.9`. The report read *"the shader does
not match the reference"*, with a 79% median luminance error. The shader was
correct throughout.

Two rules follow, and the second is the one with teeth:

> **One module owns the settled scene, and every consumer — including the
> checkers — takes it from there.**
>
> **A scene parameter has no default. A missing one is an error, not a
> plausible number.** A default is a second source of truth wearing a
> convenience disguise, and it fails silently by construction: the run
> succeeds, the numbers look reasonable, and they describe something else.

The same reasoning applies to any hand-maintained table of derived constants —
see §3.4, where a mode ladder written for one spin was still being used after
the spin changed, placing three of its bands inside a region with no material
in it.

- **Ramp monotonicity** in measured coverage, **per strike** (§2.3).
- **Font hash guard** trips when the font file changes (§2.4).
- **Loop closure, exact.** Re-quantise frame 0 from the final hysteresis state
  and require a byte-identical glyph plane. Refuse to emit otherwise.
- **Loop closure, perceptual.** The transition from the last frame back to the
  first must not read as a seam. Compare the wrap transition's churn against
  the interior **maximum**, not the interior median: churn varies by a factor
  of several across the loop by design as the mode ladder beats in and out of
  phase, so a median comparison flags a provably closed loop. A scale-free
  ratio against the maximum leaves headroom and still catches a real seam.
- **Both churn metrics inside a band, not under a ceiling.** Too high means
  hysteresis is too weak and the render sizzles; too low means the image is
  static.
- **Churn is spatially distributed**, not clumped (§4.4).
- **Ink fraction and ramp entropy** reported together for any candidate tone
  curve (§4.2).
- **The mode ladder has exactly one source.** Every consumer — the simulation,
  the placeholder, the checks — must read the same generated table, and a test
  must assert they agree. Three copies of a table drift, and only one of them
  is the physics.
- **Refactors of a shipped bake are checked, not assumed.** Re-run the previous
  configuration through the new path and require the quantised output to be
  byte-identical.

### 10.4 Desktop checks

- **Binding audit.** Parse the configuration the compositor will actually load
  — **following includes yourself** (§8.1) — and fail on any key bound twice
  and on any binding lacking a description.

  Three details decide whether this catches anything:

  * **Normalise the chord before comparing.** Modifier order and case vary, so
    the same binding written two ways compares unequal and the duplicate is
    missed. Sort the modifiers and case-fold.
  * **Scope by mode.** The same key in two different binding modes is not a
    collision; treating it as one makes the check cry wolf and it gets ignored.
  * **Flags change identity.** A press binding and a release binding on the
    same chord coexist legitimately.

  Validate the checker against a planted duplicate and against a configuration
  that does not parse: both must fail, or the check is vacuous. Run it before
  every reload, because a duplicate is silent — the last binding wins — and a
  reload is when it becomes real.
- **Background uniformity.** Every cell of every surface, with each panel open
  in turn, clears to `background` (§4.6).
- **Row geometry.** Every row of a fixed-width surface is exactly the surface's
  width, and closing rules are correct, re-checked at several heights including
  degenerate ones. A one-row surface must not crash — verify it.
- **Degradation order.** A surface too short for everything drops readouts
  before it drops session actions. A power menu you cannot reach is worse than
  a temperature you cannot see.
- **Every glyph drawn is in the atlas**, and no banned glyph appears anywhere
  (I1).
- **Parsers against real captured output**, including hostile cases: a network
  name containing the delimiter, a blank name, a name containing shell
  metacharacters. For anything passed to a shell, have a **real shell** echo
  the arguments back and assert they arrive as one argument, rather than
  inspecting the quoted string.
- **Hardware-absent rows are not drawn** (§8.4).

### 10.5 Glyph coverage of hosted programs

The verifier that decides §7.3, and the one to build earliest.

**Run each candidate program on a pseudo-terminal of exactly the size the
column would give it**, with a realistic terminal type and colour environment,
and count the codepoints the atlas cannot draw. Set the window size on the
terminal before starting the program. Redirect the program's configuration
directory to a copy — several rewrite their own configuration on exit, and if
that directory is a link into your repository they will edit it.

Record, per program: bytes emitted over a fixed interval, the number of
distinct escape forms, whether it scrolls, whether it wraps, and the
unrenderable count. That record is the specification for the terminal subset
(§7.3) and the justification for every hosting decision.

**A zero taken from a screen with nothing on it is not a result.** Say so.

**Count the programs you refuse to host, too.** The count is precisely the
evidence for why they are refused.

### 10.6 Structural checks

- **Hero abstraction** (§3.2): no mention of the hero's nature outside its
  producer directory. Mechanical, and in the suite.
- **Report-first promise** (§8.4): the reporting path of each update channel
  contains no mutating command.
- **Derived-file regeneration is byte-identical** (§5.7).
- **Every shipped executable is reachable** after linking (§9.9).
- **Paths and identifiers with two ends are defined once.** Any control channel,
  lock file or socket path named in two places is a defect waiting to happen;
  assert that the second place does not name it.

### 10.7 Measurements go stale

**Every performance number in this system is conditional on inputs that can
change without anyone noticing.** This is not hypothetical: adding a single
audio-spectrum dependency can multiply a status surface's cost several-fold,
and the documented figure will remain in place, honest when it was taken and
wrong from that day on.

Requirements:

- **State what a measurement was taken against**, next to the measurement.
- **Take the median of several runs and report the range.** A single sample of
  a sub-1%-of-a-core figure is worth about as much as a coin toss. Where a
  10 ms scheduler tick is the same size as the thing being measured, use a
  window long enough to resolve it, and say what the floor is.
- **Refuse to report a process that died as a flawless zero.** A binary that
  exits on startup burns no CPU at all.
- **Force the state being measured.** A measurement that depends on what the
  desktop happened to be doing is not a measurement: provide flags that pin a
  surface visible or hidden, or a workspace emptying mid-sample will silently
  change what was measured.
- **Stop the idle ladder before a measurement pass, and say that you did.** An
  unattended machine locks itself, and a lock surface renders **above every
  layer surface** — so a screen capture taken after the lock reads the lock
  screen, not the surface under test. It does not look like an error: the
  capture succeeds, the image is plausible, and every measurement from that
  point is of the wrong thing. Verify a capture is live before trusting it, by
  checking that something known to change — a clock — actually changes between
  two of them.
- **Never kill a lock client to end a test.** Destroying it without unlocking
  leaves the session-lock protocol held, and the compositor falls back to a
  blank refusal screen that only a fresh lock client and a real password will
  clear. Start another lock client to recover; do not reach for it as a way to
  see the desktop.
- **On a loaded machine, measure paired A/B rather than absolutes.** Under load
  the spread swamps the signal — the same binary in the same state can differ
  twofold seconds apart. Alternate old and new run by run and report both
  columns. If every column overlaps every other, that *is* the result: nothing
  regressed, and no absolute figure from that session belongs in a table.
- **Re-measure after installing anything a surface reads from**, and make that
  a step in the package abstraction rather than a matter of memory.

---

## 11. Build order

Each phase ends in something runnable, and in a gate. **Do not begin a phase
until the previous gate is met.** The order is not a preference: several
decisions are cheap now and expensive to retrofit, and every one of them is
placed as early as it can be.

The shape to notice: **you are on your daily driver at the end of Phase 5, with
a placeholder hero.** Phases 8 and 9 swap in the real one and change nothing
downstream. If they do change something downstream, the artefact contract
(§3.1) is wrong and that is the finding.

### Phase 0 — Machine facts

Verify §0.2 in full. Establish the display scale (§2.1), confirm the font
resolves through fontconfig (§9.3), confirm the boot entries and rescue entry
exist (§9.6), confirm SELinux state (§9.2), confirm which GPU adapters are
present (§5.5).

**Gate.** Every item in §0.2 confirmed on the machine, in writing, with the
command that confirmed it. Any deviation resolved or its consequence recorded
before proceeding.

### Phase 1 — The two abstractions

**The package abstraction (§9.1) and the machine profile (§0.2), first.** Both
are cheap now and expensive later: every component written before them will
name a package manager and hard-code a display geometry, and you will find them
again one at a time over the following months.

**Gate.** A component exists that answers every verb in §9.1 without any other
component naming the package manager, and a structural check enforces that.

### Phase 2 — Font, ramp, palette, formats, placeholder

Install the font. Derive a ramp per strike (§2.4, §2.3). Derive the palette
(§4.5). Define both formats (§5.2). Build the placeholder hero (§5.4).

**Gate.** Ramps reproducible and monotonic per strike; the font hash guard
trips on a swapped font; a placeholder animation exists and its frame 0 is
reproduced byte-identically from the final hysteresis state.

### Phase 3 — The renderer

The terminal backend first — it is the easiest to eyeball. Then the compositor
surface backend with the atlas blit, delta updates and the power behaviour
(§6.4). Then the rasterising backend.

**Gate.** The placeholder animates as a wallpaper; it suspends under an opaque
window; it stops on display power-off; it drops frame rate on battery. Its CPU
cost is measured by the method of §6.4 and recorded with its inputs.

### Phase 4 — The compositor, the keys, and the binding verifier

Tiling policy (§8.2), the key set (§8.3), and the duplicate-binding verifier.

**Build the verifier before the keys**, so it is never retrofitted onto a set
that already contains a collision.

**Gate.** The verifier passes, is validated against a planted duplicate, and
every binding carries a description. The generated keys list is read live.

### Phase 5 — The bar, then the column

The bar first. Then the column, in the order: terminal emulation,
pseudo-terminal, exclusive zone, keyboard.

**Build the glyph-coverage verifier (§10.5) alongside the column**, because it
is what decides everything the column may host — and build it before deciding
anything.

**Gate.** Exclusive-zone transitions measured against a real tiled window at
every width, with the window resizing rather than being covered, and the zone
correctly released on unmap. The coverage verifier reports a count for every
candidate program, and every hosting decision cites it.

### Phase 6 — Menus and components

Menus (§7.4), then the components of §8.4. **Settings, find and the idle ladder
first** — they are the ones used daily.

**Gate.** Every menu topic audits at zero unrenderable codepoints, or is
explicitly not hosted with its count recorded as the reason. The idle ladder's
stage ordering is enforced by the tool that edits it.

### Phase 7 — Terminal-adjacent surfaces and the file manager

The prompt, the pager, the diff viewer (§7.6); the file manager (§8.7). These
are what you look at; do them before anything else in §8.10.

**Gate.** Each verified by running it and reading the codepoints, not by
reading its configuration.

### Phase 8 — The real hero

Build the simulation. Validate against §10.2 **before** any long run. Tune the
disk model and camera at proxy resolution (§3.5).

**Gate.** Every analytic check passes; the accelerated implementation is
cross-validated against the reference on all three levels (§10.2).

### Phase 9 — The bake

Full-resolution run. Re-tune the tone curve **against the real emission**
(§4.1) — this is not optional and the placeholder's curve will be wrong. Derive
every target. Retain and back up the HDR cell master (§5.1).

**Run the bake twice and compare** (§5.6).

**Gate.** Two independent bakes agree to about three significant figures on
every churn metric. All targets derived. The HDR cell master is backed up
somewhere that is not this machine.

### Phase 10 — Root-owned surfaces

**Console first** (§9.5), because it is the way back from a broken graphical
login. Then the greeter (§9.7). Then the splash (§9.6).

**Verify the fallback boot entry by actually rebooting into it before anything
touches an initramfs.** Nothing automated substitutes for this, and no
structural check should be allowed to read as if it had: a tool may report that
the entry exists, names an initramfs that exists, and has a plausible size, and
must then say plainly that this is *not* the check being asked for.

**Do not assume there are several kernels.** A freshly installed machine, or
one that has not yet taken a kernel update, may have exactly one — in which
case the rescue entry is the *only* fallback and the instruction below to leave
another kernel's initramfs untouched has nothing to apply to. Count them,
report the count, and record the shortfall as a deviation rather than papering
over it. The rescue entry is a genuine fallback: it has its own initramfs, its
own kernel image and its own boot entry, and regenerating the running kernel's
image does not touch it.

**Gate.** The machine boots, shows the splash, reaches the greeter, logs in and
locks, without leaving the aesthetic — confirmed on real boots. A stalled boot
is still readable. At least one bootable entry's initramfs remains untouched —
another kernel's where one exists, the rescue entry's where it does not.

**This gate cannot be closed from inside a running session.** Everything up to
it can be: the console can be applied and read, the greeter can be started
against the installed theme and photographed, and the splash can be verified by
building a throwaway initramfs (§9.6.2). Build all of that, then state exactly
which steps remain and who must perform them, rather than reporting the phase
complete.

### Phase 11 — Third-party applications

Toolkit class before web class (§8.10).

**Gate.** The font substitution probe discriminates and shows the intended
font. Deslopping is default-deny. Empty states carry the hero, drawn as text.

### Phase 12 — Maintenance

The update component (§8.4), and the standing measurement discipline (§10.7).

**Gate.** The report-first promise is enforced structurally. Every measured
claim in the delivered documentation states its inputs.

### Phase 13 — The second hero, elsewhere

**This is the phase that proves the parameterisation, and it does not happen on
this machine.** The second hero belongs on the second machine, on a profile
that shares nothing with this one except the pipeline.

**Anything that breaks there is a coupling that should not have existed**, and
finding it is the entire point of doing it. Feed every such finding back into
§3.2's mechanical check.

---

## 12. Never

- Never use block or shade characters, or braille, on any surface.
- Never copy a glyph ramp; it is calibrated to another font.
- Never reuse a ramp across strikes without re-deriving and re-checking
  monotonicity.
- Never dither.
- Never let the void be anything but the space character.
- Never add a second typeface, an icon font, or emoji to the chrome.
- Never put a third cell grid on screen.
- Never author a target by hand instead of deriving it from the bake.
- Never quantise to glyphs inside the simulation.
- Never sample one pixel per cell; always average the full cell footprint.
- Never maximise ramp usage.
- Never let a hero's nature appear outside its own producer directory.
- Never trust a configuration that reports success without looking at the
  result.
- Never let a window spawn floating, and never position one where the column
  is.
- Never let a component keep its own copy of a setting something else owns.
- Never rewrite the mount table without checking the result still mounts root.
- Never name a package manager outside the one component allowed to.
- Never regenerate every initramfs at once.
- Never quote a measurement without the inputs it was taken against.

---

## Appendix A — Settled parameters

Everything fixed by this document, in one place. Changing any of these
invalidates the bake and requires re-deriving what depends on it.

Three tone-curve rows below say *re-tuned per emission model* rather than
carrying a number. That is deliberate and it is not an omission: §4.1 requires
the curve to be re-tuned whenever the emission model changes, because `g⁴`
beaming redistributes the light so drastically that percentiles calibrated
against anything else land somewhere entirely different. A number here would be
read as settled and would be wrong for every model but the one it came from.

| parameter | value | fixed by |
|---|---|---|
| display scale | 1.0 | §2.1 |
| bake strike | Terminus 6 x 12 (console PSF) | §2.2 |
| interface strike | Terminus 10 x 18 | §2.2 |
| master grid | 640 x 180 cells | §5.3 |
| master render | 3840 x 2160 px | §5.3 |
| frames | 240 | §3.4 |
| frame rate | 24 fps | §3.4 |
| loop period | exactly 10.000 s | §3.4 |
| metric | Kerr, `a = 0.6`, prograde | §3.3 |
| ISCO | `r ≈ 3.829 M` (moves with spin — 6 M at `a=0` to ≈1.24 M at `a=0.998`) | §3.3 |
| horizon | `r_+ = 1.800000 M` | §3.3 |
| intensity law | `I_obs = g^4 I_emit` | §3.3 |
| mode anchor `r_out` | 20 M | §3.4.1 |
| mode bands | 12, arms 6 -> 1 inward | §3.4.2 |
| Nyquist bound on `n` | `n < 120`; comfort `n <= 30` | §3.4 |
| spiral pitch | 15° | §3.4.3 |
| amplitude taper | `r^-0.45` | §3.4.4 |
| inclination | 85° from the spin axis | §3.5 |
| disk half-width | 32 M | §3.5 |
| inner-edge temperature | 5000 K | §3.5 |
| tone black point | re-tuned per emission model — see §4.1 | §4.1 |
| tone white point | re-tuned per emission model — see §4.1 | §4.1 |
| tone gamma | re-tuned per emission model — see §4.1 | §4.1 |
| ink target | ≈ 20% of cells non-blank | §4.2 |
| hysteresis margin | 25% of a ramp step, as a STARTING point; tuned against the measured churn band | §4.4 |
| palette | 32 temperatures x 8 values = 256 | §4.5 |
| temperature range | 1667 K .. 25000 K | §4.5 |
| value range | 0.35 .. 1.0 linear | §4.5 |
| dithering | none, ever | I4 |

## Appendix B — Measurements to take on this machine

Values this document deliberately does **not** assert, because they must be
measured here. Record each with the method and the inputs (§10.7).

| measurement | method | used by |
|---|---|---|
| derived ramp and per-glyph coverage, per strike | §2.4 | §4.3 |
| ramp length actually achieved | §2.4 | §4.1 |
| peak ink coverage | §2.4 | §4.2 |
| wallpaper CPU cost, animating and occluded | §6.4 | the always-animate justification |
| bar and column CPU cost, per state | §6.4, §10.7 | §7.2, §7.3 |
| bake wall-clock, per frame and total | §5.5 | Phase 9 planning |
| unrenderable codepoint count, per hosted program | §10.5 | §7.3 |
| terminal escape subset actually emitted | §10.5 | §7.3 |
| minimum width of the most demanding hosted program | bisection | §7.3 |
| churn, glyph and colour, per frame | §10.3 | §4.4 |
| ink fraction and ramp entropy of the chosen curve | §10.3 | §4.1 |
| inclination candidates and their ink fractions | §3.5 | §3.5 |
