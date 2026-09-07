# Status

Where nullLinux is against the goal in `NULL.md` §0.2 — *replace the system on
`nox` and be the machine somebody uses every day.*

Figures and their inputs: [measurements.md](measurements.md). The install
itself: [installing-on-nox.md](installing-on-nox.md).

---

## The verdict, in one paragraph

**Designed further than it is proven.** The design language is finished and
unusually complete: sixteen surfaces, from the boot splash to the browser's own
chrome, all generated from one palette and one typeface. The feature coverage is
broad enough for an ordinary working day. What it has not had is a run of
ordinary use on real hardware — and every time something has been *watched*
rather than read, it has found a defect that had already shipped. The remaining
risk is not missing features. It is the things believed to work that nobody has
yet seen work.

---

## Verified, and where

A claim is only as good as the machine it was proven on. **Nothing below was
proven on metal.**

| | proven on | evidence |
|---|---|---|
| one command takes stock Fedora 44 to a working desktop | clean VM | `null-bootstrap`, reached on the fourth attempt |
| the ISO boots and installs unattended | VM, BIOS | `verify/vm-iso-install.sh` |
| the ISO boots under **UEFI**, and under UEFI with **secure boot** | VM, OVMF | reaches our installer; shim and GRUB load signed |
| our own installer asks ten answers and installs from them | VM, BIOS and UEFI | 1042 packages, 6.2 GB written |
| **every answer takes** — hostname, user, timezone, keymap | VM, UEFI | read back off the installed disk |
| declining writes nothing | VM | the `%include` of a file never written stops anaconda |
| the installed disk boots alone and reaches the desktop | VM | greeter shows the typed hostname; login reaches bar, column, hero, audio |
| a panel it has never seen derives its own grid | VM at 1366x768 | `MISMATCH` → re-select → 170 x 48 cells, 6 px unreached |
| the **rescue entry** boots to a running system | VM | `systemctl is-system-running` → `running` |
| the **boot splash draws** | VM | 23 theme files in the live image; the hero on `#05060a` |
| **suspend and resume** | VM, qemu S3 | same `boot_id`, same compositor pid |
| the whole suite passes **on nullLinux** | ISO-installed guest | `verify/in-guest.sh`, 57 checks |
| offline install — no repository of ours reachable | VM | the package comes from the medium |
| idle at 1% of one core across three outputs | VM | sway 0.7%, everything else under 0.2% |
| boot 26.8s → 17.1s, plus 5s of GRUB menu upstream of the ruler | VM | [measurements.md](measurements.md) |

## Not done

| | |
|---|---|
| **metal** | the largest unknown by far. Real firmware, a real panel's EDID, wifi *association* rather than firmware merely being present, the dock, the trackpoint, two batteries with one removable while the machine runs |
| **an off-machine copy** | still nothing off this disk. `null-backup` now carries the repository as well as the master, and both halves were proven by restoring them — but no drive is attached and there is no remote, so the copy does not exist. A precondition, not a task — see below |
| **mail and office ON A MACHINE** | Thunderbird and LibreOffice are declared, styled and checked — on the host. Neither has been seen on an installed machine, and both are things that can only finally be judged by eye |
| **the bake end to end, and its cost** | it runs; the whole-pipeline figure has not been retaken since the machine became a T480, which cannot run it at all |

## Deliberately not in scope

- **Accessibility.** None, at James's direction (2026-09-07), and it could not
  be bolted on regardless: AT-SPI has no working path on a wlroots compositor,
  so it would mean changing compositor or shipping a checkbox that does nothing.
  `NULL.md` §0.6.
- **Third-party application interiors.** A flatpak is sandboxed and does not see
  `/usr/share/themes`. This system styles the windows it owns.
- **Flathub.** `flatpak` is declared; no remote is added. §9.1 makes adding one
  a deliberate, recorded decision, and it is one command.
- **Per-machine heroes.** `sol` is cut. One hero, `null`, for the distribution.

---

## Before nullLinux goes on nox

**The project has to exist somewhere else first.** No remote; the only copy is
on `nvme0n1`, which the install wipes — along with `assets/prebuilt/`
(generated, not committed) and `/var/lib/nulllinux-iso`.

    git remote add origin <somewhere> && git push -u origin main
    bin/null-backup /run/media/<a drive>

`null-backup` refuses a destination on this machine's own disk. That is the
right refusal and also why it has never run: nothing removable has been
attached.

**The splash is applied on the metal, not by the installer.** It rewrites an
initramfs, and this system has one ordinary kernel, so the rescue entry is the
only way back. Confirm that entry boots first, then
`null-system plymouth --apply --fallback-verified`, which reads the rebuilt
image back and restores the previous theme if the new one is not in it.

---

## The pattern behind every defect found so far

This is the most useful thing in this document.

**Nothing here has ever been wrong in a way that reading it would reveal.** Every
defect found has been a gap between what a file says and what a machine does,
and each was obvious within seconds of watching the machine:

| looked correct everywhere | what the machine did |
|---|---|
| `plymouth-set-default-theme` → `nullLinux`, `plymouthd.conf` → `Theme=nullLinux`, 22 theme files on disk, `--check` → "image will boot theme: nullLinux" | the initramfs it actually booted contained **zero** of them, and the screen showed Fedora's default |
| `config/sway/idle.conf` carries `before-sleep '… null-lock'` | `swayidle` was never started, so **no installed machine has ever locked** |
| `bootloader --location=mbr` — valid kickstart, install completes | on EFI anaconda **stopped reading the file at that line**: no user, no root password |
| `xarchiver` declared, themed, in the file manager's menu | no `tar`, so "Extract here" did nothing |
| `check-one-typeface` passes | it read the source; the *shipped* theme asked for Cantarell |
| `null-battery` written, hand-tested, covered by its own check | its compositor line killed the shell that started it, so it never ran |

The countermeasures are structural now, not resolutions:

- `verify/in-guest.sh` runs the suite **inside a real nullLinux machine**. Six
  checks went red the first time, every one of them a check that had only ever
  run on the machine it was written on.
- `verify/check-tests-stay-off-the-host.sh` refuses any check that modprobes,
  formats, useradds, pkills or systemctls without guarding or restoring — after
  two tests damaged the development machine in one evening.
- Checks read the **artefact**: the built ISO, the live initramfs, the installed
  disk — not the source that was supposed to produce it.
- `lib/source.sh` exists because prose fooled a check eight times.

57 checks, up from 24 when the plan was written. Almost every one added since
exists because something it now catches had already shipped.

---

## Known deviations, and two ways to misread this system

- **One ordinary kernel**, so the rescue entry is the sole fallback (§9.6
  assumes several). Recorded rather than worked around.

- **A screenshot taken by the host is not what a person sees.** qemu's
  `screendump` misreads a framebuffer whose width is not 4-aligned: at 1366 it
  returns the desktop sheared, colour-separated and with rows dropped, which
  looks exactly like a broken renderer. `grim`, from inside the compositor,
  showed the same desktop perfect. When the two disagree, the compositor is
  right.

- **`@` is the top of the ramp**, and Terminus draws it as a box containing a
  box. At high load the CPU meter and the CORES bars fill with it, and it reads
  as a missing glyph. It is not: the glyph on screen matches the atlas's U+0040
  at 128 of 128 pixels. Every ramp glyph is present in every strike's atlas —
  checked for all three, on the build host and again on the guest.
