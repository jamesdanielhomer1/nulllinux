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

`./verify/run.sh` — **51 checks**. It was 24 when this line was written; the
difference is one night's work, and most of the new ones exist because
something they now catch had already gone wrong once. Menu coverage derives its topics from the menu
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

§8.4's component list stands at **16 of 16**. This said 13 — absent: player,
calendar, clipboard — and all three have existed for some time:
`bin/null-player`, `bin/null-calendar`, `bin/null-clipboard`, each reachable as
a column topic. The line was stale, not the work.

## nullLinux installs itself

**2026-09-06.** The ISO shows this system's own installer, not anaconda's
screens. anaconda still does the machinery — partitioning, the package
transaction, the bootloader, every place where a second implementation would
trade a real risk for an aesthetic — but it is driven from a kickstart fragment
that `bin/null-installer` writes from answers a person gave on a console, in
this system's palette, beside its hero.

Driven end to end in a VM: nine questions, then 1042 packages and **6.03 GiB**
written. The disk boots on its own with no medium attached, reaches the greeter
showing the hostname that was typed into the installer, and logging in reaches
the full desktop.

Nothing is written until the last question, which asks for the disk's name in
full. Declining writes no file at all, and the kickstart's `%include` of that
missing file is what stops anaconda — the refusal is structural rather than a
branch that has to be remembered.

Three defects only a real run could show, each fixed:

- **A getty was stealing every keystroke.** The installer drew correctly on
  tty6 and could not be answered. `openvt` finds a genuinely free VT and is not
  in anaconda's runtime, so it is shipped on the medium — 24 KB, only libc.
- **The timezone question printed all 598 of them**, numbered, onto a console
  with no scrollback, taking the hero and every previous answer off the screen.
  Long lists are now narrowed by typing; nine questions cost 51 lines.
- **`openvt` returned 8 from a run that succeeded**, and `%pre` reported that as
  its own verdict. It now decides on whether the answers exist.

## The two open gates

**1. Reboot (Phase 10).** Nothing had ever been verified across a reboot;
everything was checked inside one long-lived session. **Being closed in the
guest, 2026-09-07:**

- the ISO **boots under UEFI**, and under UEFI with secure boot enrolled, which
  is how nox boots and which nothing here had ever tried
- a fresh install boots, derives its profile from a panel it has never seen
  (1366x768), and reaches the desktop
- the **rescue entry boots to a full running system** — `systemctl
  is-system-running` says `running`, its title is `nullLinux (0-rescue-…)`, and
  the console palette is on its command line too

**And the splash was applied and booted, which is how it was found to have
never worked.** Every previous install showed Fedora's default — a #2E3436
screen with three grey dots — because the initramfs contained zero nullLinux
theme files while its own `plymouthd.conf` said `Theme=nullLinux`. Two causes:
`plymouth-set-default-theme` writes the config and does not create the
`default.plymouth` symlink dracut resolves through, and `--check` built with
`PLYMOUTH_THEME_NAME=nullLinux` while `--apply` did not — so the check counted
22 theme files in an image nobody would ever boot. `--apply` now builds the way
the check builds and reads the live image back, restoring the previous theme
and refusing if the theme is not in it. **23 theme files in the live image, and
the hero draws.**

On metal all of this is still owed.

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

- ~~**The session runs as root.**~~ **RETIRED 2026-09-06.** This described the
  BUILD HOST, not the product. An installed machine creates `null` at uid 1000,
  and a real login through the greeter reaches a full session with sway,
  dwindle, column, bar and the wallpaper all running as that user — and with
  PipeWire answering on `/run/user/1000/pulse/native`. Audio works. See
  "Somebody logged in" below.
- **One ordinary kernel**, so the rescue entry is the sole fallback (§9.6
  assumes several). Recorded rather than worked around.
- ~~**Runtime CPU figures are absent.**~~ **MEASURED 2026-09-06.** Whole
  desktop idle across three outputs: **1% of one core** — sway 0.7%, and the
  column, bar, wallpaper and dwindle under 0.2% each. Taken in a headless sway
  session on the installed guest, which is what made it possible to measure at
  all without a session lock.

## The goal, and where it stands

**One command takes a stock Fedora 44 to a working nullLinux desktop, proven in
a clean VM rather than on nox.**

| criterion | state |
|---|---|
| `null-bootstrap` exists, idempotent, report-first | **done** |
| a clean Fedora 44 reaches a built, installed desktop from the git tree alone | **done** |
| the hero bake run end-to-end and its cost measured | not started |
| the check suite passes inside the guest | **done** — 56 checks, `verify/in-guest.sh` |
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

## ~~The unattended install does not work yet~~ — SUPERSEDED

**It works, and has since 2026-09-03.** The section below is kept because the
diagnosis in it is still the record of how it was made to, but its title is
wrong and reading only the heading would mislead. See "The non-live installer
ISO installs" and everything after it.

## Where it used to stop

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
- **Audio was never broken** -- that claim, repeated here for weeks, was wrong.
  It had never worked in *testing* for two reasons, both of them the test's:
  the VM had no sound device at all (`/dev/snd` held only `seq` and `timer`),
  and every session it was tried in was `root` or `su`. Neither is a seat, and
  logind grants the device ACL to the user on the active seat -- so PipeWire
  started correctly and saw nothing, every time.

  Given a card and a session, the sink appears immediately. The card is tagged
  `uaccess`, so adding users to the `audio` group is unnecessary and wrong; the
  kickstart is right to leave it out. What was genuinely broken was the
  message: "cava exited -- is an audio daemon running?" for every cause, when
  the daemon was usually the one thing that was fine.

  The harness gives the guest a card now -- `hda-output`, because `hda-duplex`
  with a null audiodev hangs the guest at switch-root.

---

## The boot splash (2026-09-05) -- SOLVED, see the end of this section

`null-system plymouth --apply --fallback-verified` works, the machine boots
fine afterwards, and the risk the gate guards against did not materialise. The
fallback entry was verified the way §9.6 asks -- `grub2-reboot 1`, an actual
boot into the rescue entry, confirmed by `BOOT_IMAGE=...vmlinuz-0-rescue-...`
and a running system -- rather than asserted.

**One real defect found:** `plymouth-plugin-two-step` was not in `base.list`.
The theme names `ModuleName=two-step`, Fedora ships that module separately, and
a minimal install has `details`, `text` and `tribar` and not it. Without it
`plymouth-set-default-theme` refuses outright:

    REFUSING: plymouth module 'two-step' is not installed

Same shape as the missing display manager: a surface this project builds,
needing a package nothing asked for.

**And one that is not solved.** With the module installed the splash applies,
but plymouth draws its own grey background (`#2e3436`) and built-in three-dot
spinner instead of the theme. Everything that could be missing is present:

| | |
|---|---|
| theme installed | `/usr/share/plymouth/themes/nullLinux/nullLinux.plymouth` |
| in the initramfs | 34 files, including every frame |
| module in the initramfs | `two-step.so` |
| renderer in the initramfs | `drm.so`, `frame-buffer.so` |
| `plymouthd.conf` | `Theme=nullLinux`, on the system and inside the image |
| `default.plymouth` | symlinked to ours, and in the image |
| plymouth ran | 9 s, `plymouth-start.service` active |

**Diagnosed and fixed.** `plymouth.debug=file:/var/log/plymouth-debug.log` on
the kernel command line was the only thing that showed it:

    two-step/plugin.c:1862  show_splash_scree: loading lock image
    ply-boot-splash.c:553   can't show splash: No such file or directory
    main.c:505              Could not start default splash screen,
                            showing text splash screen

The two-step plugin loads the password-prompt furniture -- `lock.png`,
`box.png`, and the entry widget -- at `show_splash_screen`, BEFORE it reaches
the animation, and one missing file abandons the whole splash. It never names
the file. Fedora's themes get those images from packages a minimal install does
not pull in; the `spinner` theme on a fresh install ships `watermark.png` and
nothing else.

The generator draws them now, in the palette, and
`verify/check-splash-complete.sh` asserts each one -- the failure is silent and
looks like a plain theme that loaded.

Measured through a boot, from the package, with the hand-copied experiment
deleted first:

    t+0    to t+10.2s   splash   hero on (5,6,10), no login box
    t+11   to t+14.4s   handover
    t+15.3s onward      greeter  hero and login box

The splash still stays STAGED rather than applied by `null-machine-sync`: it
rewrites the initramfs, and §9.6 wants the fallback entry confirmed by an
actual reboot first. That is a decision for whoever owns the machine, not for a
first-boot service. It is verified to render correctly when applied.

**A harness note worth keeping:** with `console=ttyS0` on the kernel command
line plymouth stays in text mode entirely and no splash of any kind appears.
The installed system inherits that from the installer's own boot arguments, so
the graphical path can only be tested after removing it -- `grubby
--remove-args`. A real machine booted from the ISO has no serial console and
does not have this.

---

## A boot hang I could not reproduce (2026-09-05)

One install from the ISO hung at `initrd-switch-root` -- no further console
output, no ssh, and **zero disk I/O** across twenty seconds of qemu
`query-blockstats`, which is how "hung" was told from "slow". Removing
`console=ttyS0,115200 console=tty0` from that disk's boot entry offline, and
changing nothing else, took it from hung to a login screen in 32 seconds.

A later identical install booted fine with those arguments still present.

So: a serial console makes some race reachable at switch-root, and it is not
deterministic. **No fix is claimed.** The installer's console arguments are now
removed from the installed system in `%post` -- with `grubby`, checked
afterwards -- because a machine inheriting the installer's serial console is
wrong on its own terms, not because it is known to fix this.

Worth knowing if it recurs: it appeared only after `plymouth-plugin-two-step`
was installed, which is the first time plymouth had a graphical plugin to load.

---

## Speed, measured (2026-09-06)

All numbers from the clean VM install unless marked, and all reproducible with
`systemd-analyze` and `render derive`'s own phase clock.

### Boot

| | |
|---|---|
| at the start of the session | 26.8s |
| after dropping our `systemd-udev-settle` dependency | 18.9s |
| now | **17.9s**, *and* with a generic initramfs |

The generic initramfs costs 0.66s on its own, so like-for-like the userspace
work below is worth more than the totals suggest.

    firewalld -> nftables with a static ruleset   userspace 10.2s -> 8.1s
    netfilter modules preloaded at sysinit        nftables.service 766ms -> 164ms
    machine-sync reads its profile once           718ms -> 252ms

What is left, and why it is left:

* `initrd-switch-root` 3.5s. Most of it is the kernel freeing a 219 MB
  initramfs and PID 1 re-execing; SELinux policy load inside that window
  measures ~90ms and is not the problem.
* `systemd-udev-trigger` 1.1s in the initrd. This is the price of a generic
  initramfs and is being paid deliberately.
* `firewalld` is gone from the boot path but still installed, so the revert is
  one `systemctl enable`.

### A hero derive

A monitor the machine has not seen before waits for this. On the 4-core guest:

| grid | before | after |
|---|---|---|
| 320x90 (1080p) | 24.3s | **6.9s** |
| 640x180 (4K) | 57.8s | **21.1s** |

Byte-identical output: at `--zstd-level 19` the new binary reproduces the old
one's files exactly under `cmp`. The order the costs were found in is worth
recording, because the first two guesses were both wrong:

1. split the frame resample across cores -- **2%**
2. hoist a per-cell `Vec` allocation -- 14%
3. `zstd` level 19 on a **local cache** file -- 12.5s of 19.6s
4. `tone_curve` recomputing two `ln()`s and calling `powf(1.0)` per cell
5. `Ramp::len()` walking the UTF-8 ramp string per cell

`render derive` now prints its own phase timings on every run, so the next
person does not have to guess twice.

### The running desktop

Whole desktop idle, three outputs, on the guest: **1% of one core**
(sway 0.7%, column, bar, wallpaper, dwindle under 0.2% each). The column's
event loop is a real `poll()` with no sleeps in it; the wallpaper suspends
when occluded. Nothing here needed changing.

### Many monitors, verified rather than assumed

Driven with headless sway on the guest: three outputs at two different
resolutions, each with its own bar and its own wallpaper; two outputs of the
same size share one derive through the flock; hot-unplug removes the surfaces
and re-plug brings them back on the new output name. A new output shows a
prebuilt rung immediately and swaps to its own exact grid when the derive
lands, so a freshly plugged screen is never blank.

---

## The install test now checks what it installed (2026-09-06)

`verify/vm-iso-install.sh` ended at "the install is unattended and reboots when
it finishes". What happened after that was inspected by hand, differently each
time — which is how an initramfs that could not boot on other hardware
survived every install test the project ever ran. Nobody asked it.

`verify/vm-post-install.sh`, reachable as `vm-iso-install.sh check`, asserts
over ssh what the ISO claims. It found a real failure on its first run.

### What it caught immediately

`%post` could not install the firewall:

    src/mnl.c:66: Unable to initialize Netlink socket: Protocol not supported
    REFUSING: nulllinux.nft does not parse
    WARNING -- nftables did not take; restoring firewalld

`nft -c` is not a syntax check. It opens a netlink socket to the kernel's
nf_tables and validates against it, and anaconda's `%post` chroot has none. A
good ruleset was refused. The fallback behaving correctly is the only reason
that install was *slow* — 26.6s, with the firewall this work replaced — rather
than unprotected.

A parse error still refuses. An environment that cannot answer says so and
continues, because the ruleset is checked for real at build time on a machine
that has a kernel. `check-firewall` drives `cmd_firewall` with a stub `nft`
that fails each way and asserts the two stay distinguishable.

### The run that passed

Fresh install from media, then a reboot for the steady-state number:

    Startup finished in 2.300s (kernel) + 7.152s (initrd) + 7.634s (userspace)
      = 17.087s

Every assertion green: nftables active with input *and* forward at policy drop
and all five policy-carrying rules present; firewalld not enabled; the
`hostonly=no` drop-in installed and the running initramfs carrying `sdhci_pci`,
`mmc_block`, `megaraid_sas`, `i915`, `amdgpu`, `nouveau`, `ast`; the package
byte-identical to `packaging/repo`; `/etc/os-release` a real file; no failed
units; machine-sync taking its fast path.

So the headline claim is now tested rather than argued: **a disk installed in
one machine carries the drivers to boot in another**, and it boots in 17s.

### Still true, and said plainly

A VM cannot test real firmware, secure boot, a discrete GPU, a wifi chipset,
suspend and resume, or a panel whose EDID is not qemu's. The post-install
check says so in its own header rather than implying otherwise.

### Owed

The lorax boot media was destroyed by `null-installer-iso --help`, which the
script ignored as an unknown argument and turned into a destructive rebuild.
The install tests above ran against the surviving ISO from the previous build,
which is valid — the harness boots that ISO's kernel directly and serves
today's kickstart and package over HTTP — but a full media rebuild, an
`--embed-only` pass, and a `NULL_TEST_EMBEDDED=1` run to prove the offline
path are all still owed.

---

## Somebody logged in (2026-09-06)

Until now nothing had ever logged in to an installed nullLinux. The greeter
rendered and that was as far as any test went — `last` showed only reboots and
`/home/null` held nothing but the skeleton files. "Reaches a themed greeter"
was the proven claim; "you can log in and use it" was not.

Driven through the real path, by typing at the greeter over the qemu monitor
rather than by configuring autologin: `null` / `nulltest`, Tab, Enter.

It works, and it brings three things with it that had never been observed:

    session 54  user null  seat0  tty2
    sway, dwindle, column, bar, render  — all running as null, not root
    pactl: Server String: /run/user/1000/pulse/native

**Audio works.** The largest recorded deviation — "the session runs as root,
PipeWire will not connect, audio readings are `--`" — was a property of the
build host, not of the product. An ordinary user on an installed machine gets
a working PipeWire.

**The per-user hero cache was already right.** `null-hero` falls back from
`/var/cache/nulllinux/hero` to `~/.cache/nulllinux/hero` when it cannot write
the system one, so the wallpaper derived its own 213x66 grid into
`/home/null/.cache/` with no privilege at all. Worth naming because it is the
kind of thing that is usually wrong and is only ever discovered here.

One inefficiency, not a defect: machine-sync takes its fast path at boot and
never populates the system cache, so the first login pays for its own derive
(about 7s, in the background, behind a prebuilt rung). Nothing is blank while
it happens.

### What this closes

Phase 10's reboot gate and the audio deviation. What remains genuinely
untested is real hardware: firmware, secure boot, a discrete GPU, a wifi
chipset, suspend and resume, and a panel whose EDID is not qemu's.

---

## The ISO installs with no repository of ours reachable (2026-09-06)

`NULL_TEST_EMBEDDED=1` points the kickstart at `file:///run/install/repo/nulllinux`
— the copy of the package on the medium — instead of the harness's HTTP server.
That is the path a stranger's machine takes, and the one that cannot be tested
by accident, because everything works on a build host either way.

It passes. Every assertion green, including the ones that matter for a disk
that will be moved: nftables active with input and forward at policy drop, the
generic initramfs carrying `sdhci_pci`, `mmc_block`, `megaraid_sas`, `i915`,
`amdgpu`, `nouveau`, `ast`, the greeter up, no failed units, machine-sync
`loaded success`.

Boot on this install: 25.1s first boot (machine-sync placing 11 files), 17.1s
steady state.

The media itself was rebuilt from scratch after `null-installer-iso --help`
destroyed the previous copy — the script ignored the argument and turned it
into a destructive rebuild. Two lorax runs then died forty minutes in on a
single package that every mirror has, because `download.fedoraproject.org` is a
redirector and hands each of nine hundred requests to a different mirror. The
builder now resolves **one** mirror from the metalink and proves it answers for
both metadata and a real package before downloading anything.

---

## What a person can actually do with it (2026-09-06)

The question "is this fully featured as an operating system" turned out to have
a short and unflattering answer: `bin/null-open` knew three roles — `dir`,
`reveal`, `editor`. `grim` is installed and bound to Print, so **this system
could take a screenshot it had no way to show you**. Nor open a PDF, a video,
or a zip.

It now dispatches on MIME type read from the bytes — a text file called
`notes.pdf` opens in the editor, which is what it is — with roles for image,
PDF, video, audio and archive, each degrading through what is installed. An
unrecognised type opens its folder rather than erroring.

The tools were chosen for the design system as much as for the capability:

| role | tool | why that one |
|---|---|---|
| image | `imv` | Wayland-native, background and text are settings |
| PDF | `zathura` | every colour it draws is a `zathurarc` line |
| video, audio | `mpv` | one player for one verb; its rounded translucent OSC is off |
| archive | `xarchiver` | GTK3, so it inherits the theme rather than being themed |
| editor | `nano` | terminal-first, so it inherits foot's palette |

A GTK4/libadwaita viewer would do neither, which is why none is listed first.

Also added, each because its absence was silent: **printing** (GTK's print
dialog talks to CUPS; with no CUPS it offered nothing at all), the **portal
backends** (a file chooser that never appears), `gvfs-mtp` (a phone over USB),
and a **polkit agent** — without which every privileged action failed with no
prompt and no message.

### Declared rather than inherited

Four things this system depends on were present only because something else
dragged them in, and each failure would have been silent:

    nftables      the firewall's own binary, arriving via the firewalld we
                  stopped using — four hops of Requires
    polkit        nothing would put the password prompt on screen
    pipewire      no sound server
    wireplumber   pipewire runs and routes nothing, which reads as missing
                  hardware — this is why "audio has never worked" sat in these
                  notes for weeks
    nano          the editor role landed on it by luck

## Every key window is this system's (2026-09-06)

| surface | was | now |
|---|---|---|
| lock screen | stock swaylock: a full-screen **white** field with a rounded ring | palette, Terminus, indicator as a rule, greeter's own frame behind it |
| every menu | fzf's own 16 colours, `--border=rounded` | palette roles, `--border=sharp` |
| the greeter's session | Fedora's "Sway", running bare `sway` | `nullLinux`, running `bin/null-session` |
| Qt windows | stock Fusion **light** | `QT_QPA_PLATFORMTHEME=gtk3` → the nullLinux GTK theme |
| virtual console | the kernel's 1992 primaries | the same sixteen the terminal uses |
| sway's error bar | a saturated red slab with a filled button | text on the ground, severity as a rule |
| boot splash | `Font=Cantarell` | Terminus |
| GTK, on the next bake | `gtk-theme-name=Default` | the generator writes `nullLinux` |

Two of those were wrong **in the generator**, not just the output —
`bake/export_theme.py` and `bake/make_boot_assets.py` would have undone the fix
on the next bake. Checks now cover generators as well as their products.

Two config files were read by **nothing**: `config/fzf/flags` (deleted;
`lib/menu.sh` is what the pickers use) and `config/btop` (installed to
`/etc/xdg/btop`, where btop has no system path at all). Every destination now
comes from that program's own manual page, and
`verify/check-config-reaches-apps.sh` makes an orphan impossible.

---

## Tests run on nullLinux, not on the machine that builds it (2026-09-06)

nox runs the system this one replaces, and the tree is a checkout on it — so
every check ran, by default, against somebody's desktop. Two things were broken
on the build host in one evening by tests aimed at it, and neither was the
shipped code misbehaving:

- `pkill -x sway`, to clear up a headless instance started for a test, matched
  the compositor nox was running and ended the session.
- `null-users remove-confirmed james delete`, run expecting a refusal, deleted
  a real account and `/home/james`. `/home` is its own btrfs subvolume and none
  of the snapshots cover it, so the files are gone; the account was
  reconstructible from the journal (uid 1000, `wheel`, `rice`).

`lib/host.sh` answers one question — is this machine's state expendable? True
on an installed nullLinux, or with `NULL_TEST_MACHINE=1`. False here.

`verify/check-tests-stay-off-the-host.sh` enforces it: a check that modprobes,
formats, useradds, pkills or systemctls must guard with
`null_only_on_a_test_machine` or restore with an `EXIT` trap.

`verify/in-guest.sh` is where they go instead — it copies the **working tree**,
not the installed package, into the ISO-installed guest and runs the suite
there.

## The suite passes on nullLinux, not just about it (2026-09-07)

`verify/in-guest.sh` — **ALL CHECKS PASS**, 56 of them, inside the
ISO-installed guest. This gate had read "not started" since the plan was
written.

The first run turned six red, and **not one was a defect in nullLinux**. All
six were checks that had only ever run on the machine they were written on: a
machine profile derived for the wrong host, two bake checks reporting a missing
numpy as a verdict, `sway --validate` asking for a GPU the guest has no render
node for, and the file-manager check reading root's own empty xfconf channel
over ssh and calling it the desktop.

It also answered a question the build host structurally cannot: nullLinux
shipped no `tar`. See "Every key window is this system's".

## What this is honestly not, yet (2026-09-06)

Written down rather than left to be discovered.

**Accessibility.** There is none. No screen reader, no magnifier, no sticky
keys. This is not an oversight that a package would fix: AT-SPI, which every
Linux screen reader is built on, has no working path on a wlroots compositor —
Orca cannot read a sway session the way it reads GNOME. A desktop that cannot
be used without sight is not a general-purpose operating system, and saying so
plainly is better than shipping a checkbox that does nothing.

**Installing software that is not in Fedora.** `flatpak` is declared, because
it is in Fedora's own repositories. **No remote is added.** NULL.md §9.1 —
"third-party repositories are a deliberate, recorded decision each time" — and
Flathub is that decision, one command away when somebody wants it:

    flatpak remote-add --if-not-exists flathub \
      https://dl.flathub.org/repo/flathub.flatpakrepo

A flatpak is sandboxed and does not see `/usr/share/themes`, so it arrives in
its own colours. That is third-party application *interiors*, which §8.10
treats as its own tier — not a system window, and not claimed as styled.

~~**Formatting a drive** has no window.~~ **RETIRED 2026-09-06.**
`bin/null-drive` lists removable media, mounts, unmounts, ejects and formats
it, in this system's palette. Formatting names the device, its size, its model
and what is on it, and requires the device's own name typed in full — the same
confirmation the installer asks for, for the same reason. It refuses any disk
that is not removable, and refuses the one the system booted from.

~~**Adding or removing a user** is `useradd` in a terminal.~~ **RETIRED
2026-09-06.** `bin/null-users` lists who can log in and who can administer,
adds an account with a password, sets a password, grants or withdraws
administrator, and removes an account — asking separately about their files,
defaulting to keeping them. It refuses to remove a system account, the account
you are logged in as, and the last member of `wheel`: the installer locks root,
so `wheel` is the only way to `sudo` and `sudo` is the only way up.

It has one code path per verb. The first version split each in two — `remove`
asked, `remove-confirmed` acted under `pkexec` — and the second half was
reachable from a command line, guarded only by `[ "$(id -u)" = 0 ] || refuse`,
which permits exactly the dangerous case. It deleted a real account and its
home directory on the build host during a test of its refusals.

~~**The installer is Fedora's.**~~ **RETIRED 2026-09-06.** The questions are
this system's, asked on a console in its own palette beside its hero, and
nothing is written until the last one. Anaconda's progress display still shows
during the package transaction — a thousand lines of `Installing foo.x86_64
(412/1042)` — and that is left alone deliberately: it is the honest report of
a long operation, and replacing it would mean reimplementing progress
reporting for a transaction this project does not own. See "nullLinux installs
itself".

**A VM is not metal.** nox is the machine nullLinux is going onto once it is
finished — a ThinkPad T480, 1366x768, Intel graphics, two batteries — so "any
hardware" has one specific piece of hardware to be right about first. What is
now known about it, and what is not:

| | state |
|---|---|
| 1366x768, a width that is not 4-aligned | **verified in a VM** — profile derives, grid fits with 6 px unreached, desktop draws clean |
| Intel wifi (`wlp3s0`, `iwlwifi`) | firmware **now declared**; it was absent and would have left the card dead |
| UEFI boot | nox boots UEFI **with secure boot enrolled**; the ISO had only ever been booted under SeaBIOS. Being tested against OVMF |
| suspend and resume | untested. `before-sleep` locks, which is the part that can be got wrong silently |
| a panel whose EDID is not qemu's | untested |
| the trackpoint, the dock, the fingerprint reader | untested |

**Two ways to misread a screenshot of this system**, both of which cost an
hour tonight.

`@` IS THE TOP OF THE RAMP, AND TERMINUS DRAWS IT AS A BOX CONTAINING A BOX.
At high load the CPU meter and the CORES bars fill with `@`, and at 8x16 that
glyph is

    .#####..
    #.....#.
    #..####.
    #.#...#.
    #.#...#.
    #.#..##.
    #..##.#.
    #.......
    .######.

which reads as a missing-glyph box at a glance. It is not: the glyph on screen
matches the atlas's U+0040 at **128 of 128 pixels**. Every ramp glyph is
present in every strike's atlas — checked, for all three, rather than assumed.

**A screenshot taken by the host is not what a person sees.** qemu's
`screendump` misreads a framebuffer whose width is not 4-aligned: at 1366 it
returns the desktop sheared, colour-separated and with rows dropped, which
looks exactly like a broken renderer. `grim`, from inside the compositor,
showed the same desktop perfect. When the two disagree, the compositor is
right.
