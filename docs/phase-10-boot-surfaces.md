# Phase 10 — The surfaces before the session

> Figures below are **as measured on the date given, against the inputs
> stated here**. They are a record of that run, not a claim about the
> system now. Current figures, with their inputs, live in
> [measurements.md](measurements.md) (§10.7).

Gate (NULL.md §11 Phase 10): *the machine boots, shows the splash, reaches the
greeter, logs in and locks, without leaving the aesthetic — confirmed on real
boots.*

Run 2026-08-29. **The gate is not met, and cannot be met from inside a running
session.** What follows is everything that could be established without a
reboot, and an exact statement of what is left.

Order is from §11: **console first**, because it is the way back from a broken
graphical login; then the greeter, which the console can rescue; then the
splash, which is the only one that can stop the machine booting at all.

## One tool, four refusals

`bin/null-system` is the only thing in the repository that writes outside it.
Every subcommand reports with no `--apply` and touches nothing, snapshots `/`
before it changes anything, backs up what it replaces to a timestamped path,
and — the part that actually did the work here — **derives from the running
system and refuses when it finds something it did not expect.**

Four refusals fired during this phase. Each of them would have been a boot
failure or a silently wrong surface.

## The console (§9.5)

`ter-118n` — 10×18, the interface strike, giving 192×60 at 1920×1080. The font
is checked to be **≤256 glyphs**: above that the console reallocates the ninth
attribute bit to the glyph index and loses bright backgrounds. It has exactly
256.

`/etc/issue` is **derived from the bake**, through a new `still` backend on the
renderer, rather than written by hand. A hand-written banner is one that goes on
showing last year's hero for ever. Blank rows are trimmed, because `/etc/issue`
prints above the login prompt on every tty and every unused row pushes the
prompt down; the banner is 11 lines.

Applied and verified in place.

## The greeter (§9.7)

SDDM is the enabled display manager, so the greeter is a **theme**, not a
swap. Frames are baked images; the panel is real text in Terminus.

Three things had to be read off the installed system rather than assumed, and
**all three were wrong on the first attempt**:

| assumed | actual |
|---|---|
| `TextField` | `TextBox` — `SddmComponents` has no `TextField` |
| `color` sets the text | `color` is the **background fill**; `textColor` is the text |
| `onAccepted` fires on Enter | there is **no `accepted` signal**; Enter is `Keys.onPressed` |

Each of those made the greeter fail to load, and **each failure was invisible
except on screen**: the process stayed up for its full run, exited 0 on kill,
and logged nothing, because SDDM catches a broken theme and silently falls back
to the stock one. The only reliable check was a screenshot. Two rounds were
spent believing an exit code.

`ter-u18n` is exactly 10px wide, so the box-drawing rules are computed to span
the rows exactly — 31 cells — rather than hand-counted. The first version had a
32-cell top rule and a 29-cell bottom one.

Verified after installation: SELinux labels match the stock theme
(`system_u:object_r:usr_t:s0`), every file is readable **as the `sddm` user**,
and the theme loads from `/usr/share/sddm/themes/nulllinux` — measured, not assumed,
by checking that lit pixels are 3.1% rather than the ~100% of the stock photo
fallback.

## The splash (§9.6) — built, verified, **not committed**

The theme was first written for the `script` module. **`script.so` is not
installed on Fedora** — only `two-step`, `text`, `details` and `tribar` — and
`plymouth-populate-initrd` exits non-zero on a theme whose module is missing.
It was rewritten for `two-step`, which is what the stock themes use and which
animates a numbered frame sequence natively, with no extra package.

`null-system plymouth` now refuses outright if the named module has no `.so`.

**Fonts are not what they look like.** `populate-initrd` installs the named
`Font=` at its real path, but it *also* always installs the bare `fc-match`
default and symlinks **that** to `/usr/share/fonts/Plymouth.ttf` — and it
installs only `label-freetype.so`, which reads exactly that path. So inside the
initramfs the message face is the fontconfig default (`Noto Sans` here) whatever
`Font=` says. Which is precisely why §9.6.1 is right that **the hero must be
images**: the face that draws text there is not one the theme gets to choose.

### Verified without touching the boot path

`null-system plymouth --check` builds a **throwaway** initramfs to `/tmp` and
inspects it. Because `plymouth-populate-initrd` honours `PLYMOUTH_THEME_NAME`
(line 20) and rewrites `plymouthd.conf` *inside the image* from it (lines
535–540), this reproduces exactly what `--apply` would produce while leaving the
live system alone — confirmed afterwards: the admin conf is still stock and the
system default is still `bgrt`.

| | |
|---|---|
| image built | 153 MB |
| theme files in the image | 17 (16 frames + `nulllinux.plymouth`) |
| `two-step.so` in the image | 1 |
| theme the image would boot | `nullLinux` |

The first version of this check looked for `default.plymouth`. **There is no
`default.plymouth` on Fedora**; the daemon reads `Theme=` from `plymouthd.conf`
falling back to `plymouthd.defaults`. A check that reported "17 files present"
while the image still booted `bgrt` would have been worse than no check.

### Why it stops there

§9.6 requires the fallback boot entry to be confirmed **by an actual reboot into
it** before anything touches an initramfs. So `plymouth` refuses to apply
without `--fallback-verified`, which exists only so that the person typing it
is asserting they have done the reboot.

`null-system fallback` reports the entry but does **not** claim it works:

> only one ordinary kernel is installed, so the rescue entry is the ONLY
> fallback. §9.6 assumed several kernels; on this machine it is one.

That is a deviation from the spec's assumption and is recorded as one.

## What is left, and who can do it

Nothing below can be done from inside a running session.

1. **Reboot into the rescue entry once**, and confirm it reaches a shell.
2. `null-system plymouth --apply --fallback-verified`.
3. **Reboot normally** and confirm: splash → greeter → login → lock, without
   leaving the aesthetic.

Until (3) is observed, the Phase 10 gate is **open**.
