# Installing nullLinux on nox

nox is the machine this is for. It currently runs `/opt/rice`, the system
nullLinux replaces, and it holds the only copy of this project. Installing
nullLinux on it is the finish line and an irreversible act, so the order below
matters more than the steps do.

Written before the install rather than after it, because a runbook written
afterwards is a description of what happened to work.

## What nox is

| | |
|---|---|
| model | ThinkPad T480 |
| panel | 1366x768 — a width that is not a multiple of four |
| firmware | UEFI, **with secure boot enrolled** (`/sys/firmware/efi` and a `SecureBoot` variable are both present) |
| disk | `/dev/nvme0n1`, 476.9 GB |
| wifi | `wlp3s0`, `iwlwifi` — needs `iwlwifi-mvm-firmware`, which `linux-firmware` does **not** pull in |
| wired | `enp0s31f6`, `e1000e` |
| graphics | Intel, no discrete GPU |
| batteries | two — an internal and a hot-swappable one. `bin/null-battery` aggregates across cells |

Every one of those except the batteries has been exercised in a VM. None of it
has been exercised on the metal.

## Before anything is erased

**1. The project already exists off this machine — confirm it.** The source is
on GitHub (`github.com/jamesdanielhomer1/nulllinux`, pushed after every commit),
and the one artefact a T480 cannot regenerate — the 423 MB HDR raytraced master
— is a release asset there (`null-master-0.1.0.tar.gz`), with a restore proven
from GitHub alone: clone, `gh release download`, `sha256sum -c`, then
`bin/null-prebake` regenerates `assets/prebuilt/` CPU-only. So a wipe is
recoverable. Confirm HEAD is pushed and the release carries the current master
before erasing anything.

An **optional** second copy, onto one removable drive, for offline safety:

      bin/null-backup                      # reports; copies nothing
      bin/null-backup /run/media/<drive>   # the master AND a git bundle of the repo

`null-backup` refuses a destination on this machine's own disk, and verifies
what it writes (`sha256sum -c` against the manifest, `git bundle verify`). Commit
first — a bundle carries only committed history. Restoring is `git clone
<drive>/nulllinux-<hash>.bundle nulllinux`.

**2. Write the medium, and check it against what built it.**

    bin/null-installer-iso            # hours, and deletes the previous media
    bin/null-drive list               # find the stick
    bin/null-drive format /dev/sdX    # optional; the ISO is written raw below

The ISO is written with `dd`, not by the file manager: it is a hybrid image and
copying it as a file produces a stick that boots nothing.

**3. Know how to get back.** There is no undo. `/opt/rice` and everything in
`/home` go. If anything on nox is wanted afterwards, it has to leave first.

## The install

Boot the stick. On a T480 that is F12 at the ThinkPad logo, then the USB entry
under UEFI — not the legacy one; the medium boots both ways and only the UEFI
path has been tested against secure boot.

The menu waits five seconds and defaults to **Install nullLinux**. The other
entry verifies the medium first, which reads 1.2 GB before starting.

Then ten answers, on a console, in this system's colours:

    disk        the list excludes the stick you booted from, anything 0B, and
                anything not a disk. On nox it should show one 476.9G NVMe.
    hostname
    username    lowercase; it goes in `wheel`, and root is LOCKED
    full name
    password    twice
    timezone    598 of them: type part of a name, or enter for the default
    keyboard    gb
    locale      defaulted from the keyboard answer — gb gives en_GB.UTF-8
    confirm     type the disk's name in full

Nothing is written until that last answer. Anything other than the disk's exact
name stops the install without touching it.

anaconda then does the machinery — partitioning, the package transaction, the
bootloader — and shows its own progress while it does. That is deliberate: it
is an honest report of a long operation this project does not own.

## Afterwards

The first boot derives the machine profile from the hardware and re-selects
every prebuilt surface for it. On a 1366x768 panel expect:

    interface  ter-u16n  8x16 px  ->  170 x 48 cells, 6 px unreached
    bake       ter-112n  6x12 px

Then check the things that have been wrong before:

    verify/check-firmware.sh      wireless bound, and nothing asked for
                                  firmware it did not get
    machine check-grid            the grid fits the real panel
    machine check-profile         the recorded profile still matches
    systemctl --failed            empty
    null-outputs list             one screen, and no arrangement needed yet

The boot splash is **baked into the install** — the installer sets the nullLinux
plymouth theme and rebuilds the initramfs to contain it, so it draws from the
first boot (verified in a guest: 23 theme files in the initramfs, default theme
`nullLinux`). Nothing to apply by hand. Confirm it drew; and because rewriting an
initramfs is the one step that can leave a machine unbootable, and this system
has one ordinary kernel, confirm the rescue entry still boots as a standing
safety:

    grub2-reboot 1 && systemctl reboot     # boot the rescue entry once
    # confirm it reaches a running system, then reboot normally

`null-system plymouth --apply --fallback-verified` remains for RE-applying the
splash (say, after a theme change): it reads the rebuilt image back and restores
the previous theme if the new one is not in it.

## And afterwards it is portable

The disk this produces is meant to boot in a different machine, which is not an
incidental property — it is how nox came to be a T480 in the first place.

| | |
|---|---|
| initramfs | **generic**, not host-only. Fedora's `01-dist.conf` sets `hostonly="yes"`; `dracut-config-generic` is declared to undo it, and `verify/check-portable-initramfs.sh` asserts the drivers a different machine would need are in the image |
| `/etc/fstab` | every entry is a UUID. Nothing names a device node |
| secure boot | `/boot/efi/EFI/BOOT/BOOTX64.EFI` is shim, so a new board finds it with no NVRAM entry and secure boot can stay on |
| the profile | derived on the first boot that has a display, so a new panel is picked up rather than inherited. `nulllinux-machine-sync` reports `MISMATCH` and re-selects every surface |

## What a VM could not tell us

Real firmware and a real secure boot chain. A panel whose EDID is not qemu's.
Suspend and resume on hardware — tested against qemu's S3, which is real
suspend on virtual hardware and not the same as a T480's. Wifi association,
as opposed to firmware being present. The dock, the trackpoint, the fingerprint
reader. Battery behaviour with two cells, one of which can be removed while
the machine is running.
