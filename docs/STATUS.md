# Status

Where nullLinux is against the goal in `NULL.md` §0.2. The acceptance criteria
for **1.0.0** are in [goals.md](goals.md); the figures behind any number here are
in [measurements.md](measurements.md).

---

## Current stabilization review — 11 September 2026

The review of baseline
`1cbc7817b0d08d6d20414b7d266cfc41a803ed7e` found release blockers despite the
historical acceptance results below. The fixes and fresh source, numerical,
Wayland and build evidence are in [review-1.0.md](review-1.0.md). Run the tiers in
[testing.md](testing.md); a source check cannot replace an installed-image test.
The distribution version is now 1.0.0 for the Try / Install release. Final
artifact checks and incomplete real-hardware coverage are stated in the review;
historical results below are not new hardware certification.

## Historical baseline evidence (through 9 September 2026)

The following records describe earlier builds and the in-place daily driver.
They are retained as project history and must be revalidated for the changed
release artifacts; references to "this session" below refer to those earlier
runs, not the current stabilization review.

## Verified, and where

A claim is only as good as the machine it was proven on. Metal below means the
in-place daily driver; a cold **ISO install** on metal is still to come.

| | proven on | evidence |
|---|---|---|
| one command takes stock Fedora 44 to a working desktop | clean VM | `null-bootstrap` |
| the installer ISO boots and installs unattended | VM, BIOS and UEFI | `verify/vm-iso-install.sh` |
| the ISO boots under UEFI, and UEFI with secure boot | VM, OVMF | shim and GRUB load signed |
| our own installer asks ten answers and installs from them | VM | ~1040 packages written; every answer read back off the disk |
| the installed disk boots alone to the desktop | VM, and metal | greeter → bar, column, hero, audio |
| **the whole front end works without a terminal** | metal + guest | this session: the launcher launches apps that stay open; the settings panel adds and manages accounts; images and PDFs open in imv and zathura; the system language and default applications are settable; keyboard and pointer settings work for an ordinary user; the menu is ten findable entries |
| **the installer ISO rebuilt from HEAD installs end to end** | VM | a cold VM install boots `nullLinux 0.1.0` carrying every fix from this session (`null-locale`, `null-defaults`, the mime registry, the RPM Firefox and mpv, the network-drive packages) |
| **the live ISO boots to the desktop** | VM | autologin into the themed session (sddm stands down on the live boot); not a greeter it cannot pass |
| **both boot menus name the product** | both ISO artefacts | entry 0, 5 s, "nullLinux 0.1.0" — not Fedora's release number |
| a panel it has never seen derives its own grid | VM at 1366×768 | `MISMATCH` → re-select → 170×48 cells |
| the rescue entry boots to a running system | VM | `systemctl is-system-running` → `running` |
| the boot splash draws | VM | the hero on `#05060a` in the live image |
| suspend and resume | VM, qemu S3 | same `boot_id`, same compositor pid |
| the whole suite passes on nullLinux | ISO-installed guest | `verify/in-guest.sh` |
| offline install — no repository of ours reachable | VM | the package comes from the medium |
| document fonts resolve | installed VM | `fc-match`: Times→Liberation Serif, Arial→Liberation Sans, Courier→Liberation Mono |
| the machine powers off cleanly at 2%, and the warning is true | installed VM | UPower resolves `critical-action: PowerOff` itself |
| the source exists off this machine | GitHub | pushed after every commit; the HDR master is a release asset, restore proven from GitHub alone |
| the firewall takes on a fresh install | ISO-installed guest | nftables active, firewalld disabled, input policy drop |
| the boot splash is in the installed initramfs | ISO-installed guest | 23 nullLinux theme files; default theme nullLinux |

## Not done — the road to 1.0.0

The full list, with how each closes, is [goals.md](goals.md). In short:

| | |
|---|---|
| **a cold ISO install on metal** | the largest unknown: real firmware and a real panel's EDID, wifi association, suspend/resume on metal, the dock, the trackpoint, two batteries. The off-machine copy now exists, so nox can be wiped and restored — this needs a spare disk (or wiping nox itself) |
| **mail and office seen by eye** | Thunderbird and LibreOffice are installed and their pieces verified; the chrome can be shown in a guest but is finally judged on a screen |

## Known limitations of choices made

- **No hibernate.** Swap is zram — compressed RAM — so there is nowhere to write
  a hibernation image. Suspend-to-RAM works and is tested. The consequence is
  real on a laptop: if the batteries run flat while suspended, unsaved work is
  gone. `null-battery` says so at 5% in those words, and UPower falls back from
  its configured HybridSleep to `PowerOff` on its own. Adding hibernate means a
  swap partition at least the size of RAM — scoped as post-1.0 in [goals.md](goals.md).

## Deliberately not in scope

- **Accessibility.** None, at James's direction (2026-09-07); AT-SPI has no
  working path on a wlroots compositor, so it would mean changing compositor or
  shipping a checkbox that does nothing. `NULL.md` §0.6.
- **Third-party application interiors.** A flatpak is sandboxed and does not see
  `/usr/share/themes`. This system styles the windows it owns.
- **Flathub by default.** `flatpak` is declared; no remote is added. §9.1 makes
  adding one a deliberate, recorded decision — post-1.0, and one command.
- **Per-machine heroes.** One hero for the distribution; `sol` is cut.

---

## The pattern behind every defect found so far

This is the most useful thing in this document, and this session was another
proof of it.

**Almost nothing has ever been wrong in a way that reading it would reveal.**
Nearly every defect has been a gap between what a file says and what a machine
does, obvious within seconds of watching:

| looked correct everywhere | what the machine did |
|---|---|
| `plymouth-set-default-theme` → nullLinux, 22 theme files on disk, `--check` passed | the initramfs it booted contained **zero** of them; the screen showed Fedora's default |
| `config/sway/idle.conf` carries `before-sleep '… null-lock'` | `swayidle` was never started, so **no installed machine had ever locked** |
| `bootloader --location=mbr` — valid kickstart, install completes | on EFI anaconda **stopped reading the file at that line**: no user, no root password |
| the app launcher drew, took a pick, and returned | it launched apps with the column's own config-home, racing the column's teardown, so **the app usually never appeared** |
| the live image was built, themed, and booted | Fedora's preset enabled sddm, which took the console ahead of the autologin, so the live medium **stopped at a login screen for a passwordless user** |
| the settings "People" row was written and drew a list | it only *listed* — there was **no way to add an account** from the desktop |
| `null-system --apply firewall` in the installer's `%post`, valid ruleset, `check-firewall` green | the chroot has no netlink, so `nft -c` failed; its error wording went unrecognised and a good ruleset was refused — **every ISO install shipped firewalld, not the nftables default-deny** |
| `null-system plymouth --apply` worked on nox; the theme is 22 files on disk | it read the theme from `system/plymouth-theme`, gitignored and present only on a build machine — so **no ISO install's initramfs ever carried the splash** |

The countermeasures are structural, not resolutions:

- `verify/in-guest.sh` runs the suite **inside a real nullLinux machine**.
- `verify/check-tests-stay-off-the-host.sh` refuses any check that modprobes,
  formats, useradds, pkills or systemctls without guarding or restoring.
- Checks read the **artefact** — the built ISO, the live initramfs, the installed
  disk, the boot menu on the medium — not the source that was supposed to produce
  it.
- Where a machine had to be watched, it was: the front end was driven and
  screenshotted, and the live image booted, before either was called done.

66 checks, up from 24 when the plan was written. Almost every one added since
exists because something it now catches had already shipped.

---

## Two ways to misread this system

- **A screenshot taken by the host is not what a person sees.** qemu's
  `screendump` misreads a framebuffer whose width is not 4-aligned: at 1366 it
  returns the desktop sheared, colour-separated and with rows dropped, which looks
  exactly like a broken renderer. `grim`, from inside the compositor, shows it
  perfect. When the two disagree, the compositor is right.

- **`@` is the top of the ramp**, and Terminus draws it as a box containing a
  box. At high load the CPU and CORES meters fill with it and it reads as a
  missing glyph. It is not: the on-screen glyph matches the atlas's U+0040 at
  128 of 128 pixels, checked in every strike.

- **One ordinary kernel**, so the rescue entry is the sole fallback (§9.6 assumes
  several). Recorded rather than worked around.
