# Goals

What has to be true before this is **nullLinux 1.0.0**, and what is scoped to
come after it. The specification is `NULL.md`; where each claim was proven is
[STATUS.md](STATUS.md). This file is the checklist, not the argument.

---

## What 1.0.0 means

> The ISO installs on real hardware, the result is usable for an ordinary day
> without ever dropping to a terminal to work around it, and every claim made
> about it has been watched, not merely read.

`NULL.md` §0.2 states the goal; this is the acceptance test for calling it done.

---

## 1.0.0 acceptance criteria

Met:

- [x] **One command takes stock Fedora to the desktop** — `bin/null-bootstrap` (VM).
- [x] **The installer ISO boots and installs**, BIOS and UEFI and UEFI+secure
      boot, both unattended and by answering ten questions (VM).
- [x] **Every answer takes** — hostname, user, timezone, keymap read back off the
      installed disk; declining writes nothing (VM).
- [x] **The installed disk boots alone to the desktop** — greeter, then bar,
      column, hero, audio (VM, and on metal by in-place conversion).
- [x] **The live ISO boots to the desktop** — autologin into the themed session,
      not a greeter it cannot pass (VM).
- [x] **A panel it has never seen derives its own grid** (VM at 1366×768).
- [x] **Both boot menus name the product, not Fedora's release** — entry 0, 5 s,
      "nullLinux 0.1.0" (measured on both artefacts).
- [x] **Every ordinary daily task works without a terminal** — launch/switch
      apps, files and network drives, clipboard, browser and mail, capture,
      accounts, language, default applications, brightness/power/radios, lock,
      idle, suspend.
- [x] **The boot splash is baked into the image** — the installer sets the
      nullLinux plymouth theme and rebuilds the initramfs to contain it, so the
      splash draws from the first boot of a fresh install (verified in a guest:
      23 theme files in the initramfs, default theme `nullLinux`), and it draws
      on metal. No manual apply step.
- [x] **The whole verify suite passes**, on the build host and inside an
      installed guest (`verify/in-guest.sh`) — including, now, that the firewall
      actually took and the splash is actually in the initramfs, two things that
      had silently not been true before (see STATUS.md).
- [x] **An off-machine copy exists** — the source is on GitHub, and the one
      artefact nox cannot re-bake, the raytraced HDR master, is a GitHub release
      asset with a restore proven from GitHub alone; `assets/prebuilt/`
      regenerates from it CPU-only. (`bin/null-backup` to removable media is an
      optional second copy, for when a drive is attached.)
- [x] **A code review passed** — this session was its own gate: real bugs found
      and fixed (the firewall never applied on an ISO install, the splash never
      baked into one, the lock), each with a new guard against regression; the
      non-bugs are on the roadmap below.
- [x] **The source is on a remote** — pushed to GitHub after every commit.
- [x] **The package and both ISOs build from a clean HEAD.**

Not yet met — the road to 1.0.0:

- [ ] **A clean install on real hardware.** nox runs nullLinux on metal today,
      but by *in-place conversion*, not by installing the ISO. A cold ISO install
      still has to prove: partitioning and the bootloader on real firmware; the
      cell grid derived from a real panel's EDID; and the subsystems a VM cannot
      exercise — wifi *association* (not merely the firmware being present),
      suspend/resume on real firmware, the dock, the trackpoint, and two
      batteries with one removable while the machine runs. The off-machine copy
      now exists (above), so nox can be wiped and restored — this needs a spare
      disk, or a willingness to wipe and restore nox itself.
- [ ] **Mail and office seen by eye.** Thunderbird and LibreOffice are installed
      and their pieces verified; the chrome and GTK theming can be shown in a
      guest but are finally judged on a screen.

When both boxes above are ticked, tag `0.1.0` → `1.0.0` (`null-brand` reads the
version from the spec/package; bump there) and cut the release ISOs.

---

## After 1.0.0

Scoped, so a later session can pick any one of these up cold. None is required
for 1.0.0; each is a deliberate addition, not a loose end.

1. **Hibernate.** Swap is zram today, so there is nowhere to write a hibernation
   image; if the batteries run flat while suspended, unsaved work is gone
   (`null-battery` says so, and UPower falls back to power-off). Adding it means
   an install-time option for a swap partition at least the size of RAM, and
   wiring UPower's HybridSleep. Scope: the installer question, the partitioning,
   the UPower policy, and a check that resume-from-disk works on metal.

2. **A flatpak remote, on request.** `flatpak` is installed; no remote is added,
   because §9.1 makes adding one a deliberate, recorded decision. Scope: a single
   menu action under `software` that adds Flathub and says what it did — never a
   default.

3. **Third-party application theming, as far as it goes.** A sandboxed flatpak
   does not see `/usr/share/themes`. Scope: document the ceiling honestly, and
   apply what the portal and per-app overrides *can* reach, without pretending to
   more.

4. **Broader hardware.** More than one panel and one laptop: desktops, external
   displays and a visual arrangement over `null-outputs`, HiDPI strikes, and a
   second and third machine profile derived from scratch to prove the derivation
   travels.

5. **Localisation.** `null-locale` sets the system language and offers the
   installed ones; post-1.0 is offering more `glibc-langpack`s cleanly and
   deciding whether the desktop's own English strings are ever translated.

6. **An update story that is nullLinux's own.** Today a running machine updates
   through dnf against Fedora plus the local package. Scope: how a released
   nullLinux learns about and moves to the next nullLinux version — a channel, a
   signature, and a `null-update` that knows about it.

7. **Secure Boot with our own keys.** The installer boots under secure boot
   through Fedora's shim. Scope: a MOK enrolment story so the product signs its
   own boot chain rather than riding Fedora's.

8. **A backup and restore a person would actually run.** `null-backup` is a
   correct CLI that has proven restore; post-1.0 is a friendlier flow, a schedule,
   and a restore path someone reaches for without reading the source.

---

## Smaller items, recorded from the 1.0.0 review

Not features -- cleanups and defence-in-depth the review surfaced. None blocks
1.0.0; each is a few lines when someone picks it up.

1. **Bump the lock client's shm pool.** `render/src/bin/lock.rs` sizes its
   `SlotPool` at 4 MB, just under one 1366x768 buffer, so it grows once on the
   first frame. Cosmetic; size it for the largest expected panel up front.
2. **Guard the derived installer kickstart against a shipped credential.** The
   shipped kickstart is derived from `nulllinux-install.ks` with `rootpw`,
   `user` and `sshpw` stripped, and `check-installer.sh` proves the interactive
   fragment locks root -- but nothing greps the derived artefact itself for a
   plaintext password. A check that reads the derived kickstart would match how
   the rest of the suite reads artefacts rather than source.
3. **Re-derive the fastfetch logo in the build.** `config/fastfetch/logo.txt` is
   committed and regenerated by hand with `bake/make_fastfetch_logo.py`; wiring
   that into `null-build` would keep it tracking the hero if it is ever re-baked.

---

## Deliberate non-goals

Not oversights — decisions, recorded so they are not reopened by accident.

- **Accessibility.** None, at James's direction (2026-09-07, `NULL.md` §0.6), and
  it cannot be bolted on: AT-SPI has no working path on a wlroots compositor, so
  it would mean changing compositor or shipping a control that does nothing.
  Revisit only if the compositor story itself changes.
- **A flatpak remote by default.** See post-1.0 item 2 — offered, never assumed.
- **Theming the interiors of third-party apps** beyond what the toolkit exposes.
- **Per-machine heroes.** One hero for the distribution; `sol` was cut (§0.1).
