# Status — the plan, phases 0 to 12

Taken 2026-08-30. Figures and their inputs: [measurements.md](measurements.md).

**Every phase gate that can be met from inside a running session is met.** Two
remain, and neither is work — one needs a reboot, one needs a drive.

| phase | | gate |
|---|---|---|
| 0 Machine facts | **met** | profile derived, nothing stored that can be probed |
| 1 The two abstractions | **met** | one package component, one machine profile |
| 2 Font, ramp, palette | **met** | ramps monotonic per strike, font hash guarded |
| 3 The renderer | **met** | delta blits, shm cycling, one sleep |
| 4 Compositor and keys | **met** | no key bound twice; audit follows includes |
| 5 Bar, then column | **met** | 0.00% idle; zone tracks the animation |
| 6 Menus and components | **met** | every topic drawable from the atlas |
| 7 Terminal surfaces | **met** | every surface draws only glyphs the font has |
| 8 The real hero | **met** | 11 analytic checks at 0.000%; shader matches reference |
| 9 The bake | **all but backup** | bakes reproducible, all targets derived — **off-machine copy outstanding** |
| 10 Root-owned surfaces | **all but reboot** | console and greeter live and verified; splash built and verified — **needs real boots** |
| 11 Third-party | **met** | font probe discriminates, deslop default-deny, hero in empty states |
| 12 Maintenance | **met** | report-first structural, every claim states its inputs |

Phase 13 (`sol`) is **cut**: there is one hero, `null`, for the whole
distribution. Per-machine heroes made the system's identity depend on which
box it was installed on, and doubled everything that must be baked and shipped.

## Verification

`./verify/run.sh` — 24 checks, including six that had drifted out of the suite
and are now wired back in. Menu coverage derives its topics from the menu
itself: **28 topics, 27 drawing clean**, the 28th recorded with its reason.

## Since the plan: Omarchy alignment

Requested after Phase 12 and documented in
[omarchy-alignment.md](omarchy-alignment.md): Omarchy's bindings and menu tree,
only two layouts (dwindle and fullscreen), and the file manager in both halves.

That work found two silent defects worth naming here, because neither was
visible to any existing check:

- **The menu bindings had never worked.** The column hosted two topics and
  every other one hit a default arm that returned. The coverage verifier ran
  each topic in its own pty, so it proved they *draw* while saying nothing
  about whether anything could *reach* them.
- **The column's terminal printed part of every charset designation.**
  `ESC ( B` is three bytes and only the `(` was consumed, so hosted output came
  out sprayed with stray capital Bs.

§8.4's component list stands at **13 of 16**. Absent: player, calendar,
clipboard.

## The two open gates

**1. Reboot (Phase 10).** Nothing in this build has ever been verified across a
reboot; everything was checked inside one long-lived session.

```
  reboot into the rescue entry once, confirm it reaches a shell
  bin/null-system plymouth --apply --fallback-verified
  reboot normally: splash -> greeter -> login -> lock
```

The splash deliberately refuses to install until you confirm the first step,
because it is the only component that can leave the machine unbootable and this
machine has **one ordinary kernel**, so the rescue entry is the only fallback.

**2. Off-machine copy (Phase 9).** No removable drive is attached. The master
is manifested and the copy is one command, which verifies the destination
rather than trusting it:

```
  bin/null-backup                 # reports; copies nothing
  bin/null-backup /run/media/...  # copies, then checksums the COPY
```

It refuses a destination on this machine's own disk, because that does not
satisfy the gate.

## Known deviations

- **The session runs as root.** PipeWire will not connect, so audio readings are
  `--` and the audio component cannot be exercised. A user `james` (uid 1000)
  exists and is unused. Not a plan item — the spec says nothing about which
  account the desktop runs as — but it is the largest single gap between this
  and a daily driver, and the recommended next piece of work.
- **One ordinary kernel**, so the rescue entry is the sole fallback (§9.6
  assumes several). Recorded rather than worked around.
- **Runtime CPU figures are absent, not stale.** They cannot be taken under a
  session lock without being false zeros, and the harnesses now refuse instead
  of reporting them.

## The goal, and where it stands

**One command takes a stock Fedora 44 to a working nullLinux desktop, proven in
a clean VM rather than on nox.**

| criterion | state |
|---|---|
| `null-bootstrap` exists, idempotent, report-first | **done** |
| a clean Fedora 44 reaches a built, installed desktop from the git tree alone | **done** |
| the hero bake run end-to-end and its cost measured | not started |
| the 24-check suite passes inside the guest | not started |
| deviations written down rather than skipped | ongoing |

Reached on the fourth attempt. The first three failed, and every reason was a
thing nox could never have revealed:

1. `pkg install-list fedora/base` -- the backend is prefixed by pkg, so the
   name was doubled. The message said so; the bootstrap discarded it.
2. `install` was not idempotent: dnf5 fails a transaction containing anything
   already installed, so no half-finished install could be resumed.
3. `read_list` returned whole lines, and one line is `grim slurp`, so those two
   have never been installable from the list at all.
4. `dnf install -- pkgs` is rejected by dnf5 5.4.1 and accepted by 5.4.3. The
   guest and this machine are a few weeks of updates apart.
5. Terminus ships PSF1 as well as PSF2 -- every 8-wide strike is PSF1 -- and
   `fontlib` read only PSF2. The guest's 1280x800 panel chose an 8x16 strike,
   so the atlas baker was handed a format it refused.
6. numpy, pillow and gobject were never in the package list, though the bake
   imports all three.

What worked first time, and had never been tried: the profile generator, on a
headless virtio display it has never seen, detecting `Virtual-1` at 1280x800
and choosing `ter-u16n` at 8x16 for 160 columns, exact. That was the blocker
that made "any Fedora machine" impossible.

The guest's interface atlas is 34,618 bytes; this machine's is 48,034. Different
strikes for different panels, from the same tree, with nothing configured by
hand. That is the parameterisation working rather than being asserted.

## The unattended install does not work yet, and here is exactly where it stops

The ISO boots. That is proved twice, with screenshots: it comes up in the
desktop, autologin, sway, the hero, the bar and the column, from the disc.

**Installing FROM it, unattended, does not.** Four attempts, and the failures
were three different things:

1. **My own live kickstart beat the installer.** `mkksiso` had put
   `inst.ks=hd:LABEL=...` on every boot entry and the kickstart was on the
   medium, and the autologin into sway ran first and won. Fixed: an unattended
   install now takes precedence over the desktop.

2. **`liveinst` was not in the image.** `anaconda` was; `anaconda-live`, which
   provides `/usr/bin/liveinst`, was not -- so both the unattended path and the
   desktop's own "Install nullLinux" entry pointed at a missing binary. Fixed.

3. **The harness tested a stale ISO, twice.** `find ... | head -1` returns
   directory order, and with two images present it kept choosing the older one.
   Two full install cycles measured a build from before the fixes. Fixed: newest
   by mtime.

4. **`mkksiso`'s output does not boot at all.** This is where it stands. The
   comparison is direct, same qemu invocation, same moment:

   | image | after ~2 minutes |
   |---|---|
   | `boot.iso` (as built) | 80,733 non-black pixels -- the full desktop |
   | `nulllinux-autoinstall.iso` (mkksiso) | **0** -- black screen, forever |

   The disk stays at 1 MB, the serial console is empty, and Enter at the
   supposed boot menu changes nothing. qemu is alive; the guest is not.

So the ISO is sound and the kickstart-embedding step breaks it.

**Passing `inst.ks` on the kernel command line instead gets much further.** The
ISO's own kernel and initrd are extracted and booted directly, with the image
attached unmodified and the kickstart served over HTTP from the host at
10.0.2.2 -- so the medium under test stays byte-identical to the one that would
go on a stick.

| | mkksiso ISO | kernel command line |
|---|---|---|
| guest boots | **no** -- 0 pixels, for ever | yes |
| kernel receives inst.ks | n/a | yes, confirmed in the boot log |
| the live hook fires | n/a | yes -- sway does NOT start |
| `liveinst` runs | n/a | yes |
| anaconda initialises storage | n/a | yes -- device-mapper, multipath, `No iBFT detected` |
| anything written to disk | no | **no** |

Two more of my own bugs were found and fixed on the way there. The hook parsed
`inst.ks` by splitting on the last colon, which is right for
`hd:LABEL=X:/path` and turns `http://10.0.2.2:8899/install.ks` into
`8899/install.ks` -- so it fell through to the desktop. And the one line
explaining that fall-through went to stderr on a tty sway then covered, which
is why it took two attempts to see.

**Where it stops now:** anaconda starts at about 75 seconds, probes storage,
and then does nothing. Disk stays at 1 MB, the screen is blank, the serial
console goes quiet. `inst.text inst.notmux` changes nothing.

**The logs were read, and the answer is complete.** A debugging ssh key --
gated on a kernel argument, so a shipped ISO carries none -- got a shell into
the live session. The chain, end to end:

1. `getty@tty1` **failed** with `start-limit-hit`. It had autologged in and
   exited six times in a row, so systemd gave up. The autologin override was
   fine; whatever it ran kept exiting.
2. What it ran was `liveinst`, and `liveinst` exits immediately, because
   **Fedora 44's Anaconda is a WEB UI**. It launches Firefox:

       No default browser set in anaconda.conf, using firefox
       webui-desktop: line 183: DISPLAY: unbound variable
       Gtk-WARNING: Failed to open display

   The hook runs it before sway, so there is no display, so it fails and exits
   cleanly -- six times, which is what killed the getty.
3. `liveinst --text` gets much further: the text installer starts and paints
   its summary hub. But it **stops at an interactive prompt**, with
   Installation Destination, Root password and User creation all marked
   incomplete -- all three of which the kickstart specifies.
4. The reason is in the log:

       anaconda called with cmdline = [..., '--kickstart=/tmp/inst.ks']
       Found a kickstart file: /usr/share/anaconda/interactive-defaults.ks
       Parsing kickstart: /usr/share/anaconda/interactive-defaults.ks

   The supplied kickstart is on the command line and anaconda parses the
   interactive defaults instead. `interactive-defaults.ks` says in its own
   first lines that it "is not loaded if a kickstart file is provided on the
   command line". It was loaded anyway.

**Conclusion: the live-image path is the wrong road for an unattended install
on Fedora 44.** `inst.ks` is designed for Anaconda BOOT MEDIA -- netinst and
DVD images -- where it is the documented, supported mechanism. A live image
installs by copying its own filesystem through a web UI meant for a person at
a keyboard.

The right fix is a second, non-live installer ISO built for that purpose, and
that is a lorax invocation rather than a kickstart workaround. The live ISO
stays what it is: a thing that boots and shows you the desktop.

**Nothing here says the installer is broken.** It says the installer has not
been reached. Those are different claims and only the second is supported.

---

## The non-live installer ISO installs (2026-09-03)

`bin/null-installer-iso` builds Anaconda boot media with lorax -- 1.2 GB --
and it does what the live path could not: an unattended install from a
kickstart passed as `inst.ks` on the kernel command line.

**It works.** 734 packages, 854.2 MiB downloaded, all installed and
configured, initramfs built, users created, powered off cleanly. The installed
disk boots, `nulllinux-0.1.0-1.fc44.x86_64` is present, the machine-sync service
is enabled and active, and it generated a machine profile, selected
`ter-u16n` for the interface and `ter-112n` for the bake, placed the prebuilt
hero and theme, and installed the desktop system-wide -- in about a second,
with no GPU and no compiler on the machine. `verify/vm-iso-install.sh` runs
the whole thing.

Two things had to be fixed to get there, and both are worth recording because
neither is documented anywhere obvious:

- **Anaconda does not expand `$releasever` in a kickstart `url` line.** The
  failure it reports is "Error setting up repositories", which names none of
  that. The kickstart now carries concrete URLs, verified with curl to return
  200 before the VM is started.
- **qemu ignores `-boot once=d` when `-kernel` is supplied.** The completed
  install rebooted straight back into the installer and wiped itself. The
  kickstart ends in `poweroff` rather than `reboot`.

### What the install then revealed

The installed system is where this project's assumptions about its own machine
keep dying, and this round killed four.

**It did not say its own name.** `PRETTY_NAME` read "Fedora Linux 44", because
branding lived in the live image's kickstart and the installer path never ran
it. Moving it into the package (`bin/null-brand`, called from `%post`) exposed
that the branding was itself wrong twice over: `/etc/os-release` is a symlink
into `/usr/lib/os-release`, so writing to it rewrote a file owned by
`fedora-release-identity-basic`; and `ID=nulllinux` made `bin/pkg` look for
`packages/nulllinux/` and find nothing, so installing our own branding
disabled our own package management. Both are checked now
(`verify/check-branding.sh`), and `rpm -V fedora-release-identity-basic`
verifies clean on the installed machine.

**Three tools had no caller.** `null-join` (found and fixed once before, by
moving the call into `null-firstrun` -- which then had no caller either), and
`null-toolkit`, which applies the settings keys §8.10 says outrank every
configuration file this system writes. The shell and git now install
system-wide, where no per-user action is needed at all;
`verify/check-callers.sh` requires every tool in `bin/` to be invoked or to
declare itself an operator entry point.

**lorax writes 88 MB of dependency-solver dumps into the working directory**,
and it was being run from the checkout, so they reached git -- the same
mistake as the baked assets and the RPM before them. The source tarball was
86 MB; it is 1.2 MB.

**§9.1 had quietly broken** while the ISO tooling was written: six components
named `rpm` or `dnf` directly. The backend grew the verbs they needed rather
than the checker growing exemptions.

### Still open

- `/etc/os-release` is branded, but the boot splash, GRUB and the installer's
  own UI still show Fedora's.
- Metal only: real firmware and secure boot, a discrete GPU driver, a wifi
  chipset, suspend and resume, a monitor whose EDID is not qemu's.
- Audio has never been exercised anywhere -- root cannot run PipeWire and the
  VM has no sound device -- so the mixer and the equaliser are unverified
  against real audio.

---

## The ISO carries the bake, and each screen derives its own (2026-09-04)

The package shipped forty-five quantised grids -- nine strikes by five rungs --
and a screen was given whichever came closest. That is exact on 1920x1080 and
2560x1440 and on nothing else. The laptop this now runs on is 1366x768, and
1366 = 2 x 683 with 683 prime, so no rung divides it: the wallpaper drew a
1920x1080 surface and the black hole fell off the edge of the screen.

**The master ships instead.** `bake/pack_master.py` packs the bake into 9.1 MB
-- smaller than the forty-five grids it replaces -- and any grid is derived
from it exactly. The quantiser only ever read two things from an HDR frame:

    L = arr[..., :3] @ LUMA     luminance
    T = arr[..., 3]             observed temperature

Colour is a function of one variable (§4.5), so RGB exists only to be collapsed
into L. Two channels at float16 is lossless for everything downstream: 423 MB
becomes 9.1 MB, 46x. float16 was checked rather than assumed -- it loses no lit
cell and moves the P30 black point by four parts in a million.

`quantise.py` grew `quantise_frame_lt` and `quantise_sequence` so the bake and a
screen run the SAME exposure, hysteresis and loop closure; the refactor was
proved by quantising the whole master before and after and comparing bytes.

**The tone curve travels inside the master.** It is swept by `bake/tune.py` and
is a property of the emission model, not of any grid -- a machine deriving its
own cannot re-run a sweep. Leaving it out did not look like an error: the
defaults blank 34% of the subject and drop ink from 15.4% to 10.2%, which reads
as a dimmer picture. Found by deriving a grid that MATCHES a prebuilt rung and
comparing: with the curve carried, ink is 16.21% against 16.22%, glyphs
identical in 98.3% of cells and within one ramp step in 100.0%.

Nothing waits for it. The wallpaper starts on the nearest rung and derives
behind it; `bin/null-hero` caches per (grid, ramp), flock-guarded, system-wide.
Measured: up instantly, exact about two minutes later, and a warm start goes
straight to exact.

### The ISO now contains the package

lorax builds boot media with no payload, so every package came over the
network -- the raytraced hero travelled separately from the thing that installs
it. A comment claimed `-i nulllinux` put it on the image; there was no such
flag. `mkksiso` embeds the repo and the kickstart now, and the build refuses to
ship a kickstart with a placeholder left in it.

**Verified on a machine installed from that ISO**, with no source tree and no
repository of ours reachable: it installed from `file:///run/install/repo/
nulllinux`, then derived 213x60 from the shipped master and swapped onto it.

### What this cost, and what it taught

Five things failed on the way, and only one was the product:

| what failed | why |
|---|---|
| `bake/` absent from the RPM | excluded deliberately when nothing derived; the deriver IS `bake/`. Every test passed because they ran from a source tree on the build host. |
| lorax died at 12:37, no trace | the machine was shut down under it |
| "Failed to download packages" | a single `baseurl` is a single mirror: one interrupted transfer, and *"No more mirrors to try"* for a file answering 200 seconds later. Metalinks now. |
| "Failed to download metadata" | `&` in a sed replacement means *the whole match*, so `repo=fedora-44&arch=x86_64` became `repo=fedora-44NULLLINUX_BASEURLarch=x86_64` |
| numpy would not import | qemu's default CPU is below x86-64-v2, the baseline Fedora builds numpy for |

Only the first was a defect in nulllinux, and it was found by asking what the
RPM contains rather than what works on this machine -- which is a different
question, because this machine predates nulllinux and runs the tree it grew
out of.

### Still open

- Deriving is ~2 minutes of numpy per grid. `python3-numpy` is a runtime
  dependency now, about 30 MB. The honest end state is a Rust deriver and no
  numpy at all.
- A grid whose ratio differs from the master's 640:180 is letterboxed, because
  a different framing needs its own camera (§5.3) and there is no GPU on an
  installed machine. On 16:9 at any strike this is within one cell.
- Audio has never worked in any environment tested.
