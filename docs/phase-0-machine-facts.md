# Phase 0 — Machine facts

> Figures below are **as measured on the date given, against the inputs
> stated here**. They are a record of that run, not a claim about the
> system now. Current figures, with their inputs, live in
> [measurements.md](measurements.md) (§10.7).

Gate (NULL.md §11 Phase 0): *every item in §0.2 confirmed on the machine, in
writing, with the command that confirmed it; any deviation resolved or its
consequence recorded.*

Taken 2026-08-29 on the target machine.

## §0.2 — confirmed

| property | required | found | command |
|---|---|---|---|
| distribution | Fedora 44 | Fedora release 44 (Forty Four) | `cat /etc/fedora-release` |
| variant | classic rpm/dnf, **not** ostree | `rpm-ostree status` fails → classic | `rpm-ostree status` |
| package manager | dnf5 | dnf5 5.4.3.0 | `dnf --version` |
| init | systemd | systemd | `ps -p 1 -o comm=` |
| initramfs | dracut | /usr/bin/dracut | `command -v dracut` |
| bootloader | GRUB2 + BLS entries | 2 entries incl. `*-0-rescue.conf` | `ls /boot/loader/entries/` |
| CPU | i5-9300H, 4c/8t | i5-9300H @ 2.40GHz, 8 threads | `grep model\ name /proc/cpuinfo` |
| memory | — | 15 GiB | `free -h` |
| integrated GPU | UHD 630 | Intel UHD 630 (CFL GT2) | `lspci -nn` |
| discrete GPU | GTX 1660 Ti Mobile | NVIDIA TU116M GTX 1660 Ti Mobile | `lspci -nn` |
| panel | 1920x1080 | eDP-1 connected, 1920x1080 @ 59.977 Hz | `swaymsg -t get_outputs` |
| root filesystem | **unencrypted** | no `crypto_LUKS` present | `lsblk -o NAME,FSTYPE` |

## Additional facts established

| fact | value | consequence |
|---|---|---|
| root filesystem type | **btrfs**, subvol `root` (id 257), zstd, 467 GiB unallocated | snapshots are free → NULL.md §9.4 amended to require one before every root-owned change |
| SELinux | **Enforcing**, targeted policy | §9.2 applies in full; label restoration is mandatory, not optional |
| display scale | **1.0** | §2.1 satisfied with no change; no fractional-scaling machinery needed |
| session | Wayland, seat0, tty2, started by SDDM | — |
| compositor running | **Sway 1.11-3.fc44** | §8.1 settled on Sway (see deviation 1) |
| display manager | **SDDM, enabled** | §9.7 already largely satisfied — greeter is themeable and installed |
| console font path | `/usr/lib/kbd/consolefonts/` | **not** `/usr/share/kbd/consolefonts/`; strikes present: `ter-112n`, `ter-118n`, `ter-u12n`, `ter-u18n` |
| Terminus via fontconfig | resolves | `fc-match Terminus` → `ter-u12n.otb`; `Terminus:pixelsize=18` → `ter-u18n.otb` |
| fontconfig probe discriminates | yes | bogus family → `NotoSans[wght].ttf`, so a match is real (§10.1 rule 3) |
| bitmap rejection | **not active** | `70-no-bitmaps.conf` available but not linked |
| bitmap scaling | **active** | `10-scale-bitmap-fonts.conf` is linked — §9.3 hazard confirmed; mitigate by pinning every size to a real strike |
| Vulkan adapters | 3 | GPU0 Intel UHD 630 (Mesa); **GPU1 NVIDIA GTX 1660 Ti via NVK, DISCRETE**; GPU2 llvmpipe |

**§5.5's claim is confirmed on this machine:** the open-source NVIDIA driver
exposes the discrete GPU as a Vulkan compute device. Develop against GPU0,
bake on GPU1. No proprietary driver decision is required.

## Grid arithmetic at 1920x1080, scale 1.0

| strike | cell | grid | divides exactly |
|---|---|---|---|
| ter-u16n | 8 x 16 | 240 x 67 | no (1080 % 16 = 8) |
| **ter-u18n** | **10 x 18** | **192 x 60** | **yes** |
| ter-u20n | 10 x 20 | 192 x 54 | yes |
| ter-u22n | 11 x 22 | 174 x 49 | no |
| ter-u24n | 12 x 24 | 160 x 45 | yes |

Confirms §2.2's interface strike: **ter-u18n at 10x18, 192 x 60 cells.**
Bake strike `ter-112n` at 6x12 is present as a console PSF.

## Deviations

**1. Hyprland is not packaged for Fedora 44.** NULL.md §8.1 named it as the
default choice and that was wrong. Only supporting libraries
(`hyprutils`, `hyprcursor`, `hyprgraphics`, `hyprland-protocols`) are in the
repositories; the compositor is not. Taking it would mean a third-party
repository, which §9.1 forbids for a core component.
**Resolved:** §8.1 rewritten. Sway is the settled choice, verified against all
six requirements on this machine.

**2. Sway exposes loaded configuration text, not a parsed binding list.** The
duplicate-key audit cannot be a query.
**Resolved:** §8.1 and §10.4 rewritten. The audit parses what
`swaymsg -t get_config` returns — which is better than reading the file from
disk, because it reflects includes and reflects what the running compositor
actually has.

**3. Root filesystem is btrfs, not assumed.**
**Resolved:** treated as an advantage. §9.4 now requires a read-only snapshot
before every root-owned change, with the explicit note that this does not
replace the fallback boot entry — a snapshot is reachable only from a system
that boots, so it covers a bad configuration and not a bad initramfs.

**4. Hostname was `customer.lndngbr1.isp.starlink.com`, not `nox`.** The
machine profile selects by hostname (§0.2).
**Resolved.** The machine had no static hostname at all — only a transient one
assigned by DHCP — so setting a static hostname cleanly overrides it and
survives lease renewal. Now `nox`, static and transient, resolving locally
via `nss-myhostname` with no `/etc/hosts` entry required (an unresolvable
hostname causes sudo delays, so this was checked rather than assumed).

**5. `10-scale-bitmap-fonts.conf` is active.** Asking for a size with no strike
will silently return a scaled bitmap rather than failing.
**Consequence recorded:** every size must be pinned to a real strike and the
resulting cell metrics verified by measurement, per §9.3. The strikes required
(6x12 and 10x18) both exist, so nothing is blocked.

## Gate

**MET.** All five deviations resolved; four by amending the specification,
one by naming the machine.
