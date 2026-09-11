# Code review and release validation for 1.0

Review date: 11 September 2026. Baseline:
`1cbc7817b0d08d6d20414b7d266cfc41a803ed7e` (0.1.0).
Work branch: `codex/stabilize-1.0`.

## Release verdict

The baseline review found reproducible
faults in clean builds, package publication, account protection, lock scheduling,
surface resize, application launching and the numerical pipeline. The
stabilization changes address these faults and add independent regression
coverage. The distribution version is now 1.0.0, with RPM Release 1. The RPM and
release images must be built from this versioned source; the earlier 0.1.0-2
artifacts retain their original identity and evidence. Publication of the
Try / Install release is authorized, subject to the final artifact checks below.
Real-hardware coverage remains incomplete and must be stated in release notes.

This review covers the implementation, build scripts, packaging, installation,
desktop controls, generated assets, verification tools and release documentation.
It includes independent reviews of runtime, bake and installation subsystems.
Historical claims of successful VM installs were treated as historical evidence,
not proof that this changed revision has passed.

## Findings and changes

P1 means a release blocker; P2 means a significant correctness or reliability
defect. The table groups related defects by the behavior a user encounters.

| Priority | Reproduction and consequence | Change and regression coverage |
|---|---|---|
| P1 | `null-users admin USER off` bypassed the exact-`no` last-admin guard and removed the only wheel administrator. | Accept only `yes` or `no` before mutation; safe command doubles prove invalid states and sole-admin removal are refused. |
| P1 | Firewall replacement could disable the existing firewall before the replacement started, and failed startup could look successful. | Validate before transition, preserve/restore the previous protection on failure and propagate failure. Mocked service transitions exercise refusal and failed startup. |
| P1 | Lock drawing requested new frame callbacks both from its timer and from callbacks, accumulating independent callback chains. | One timer schedules drawing. Live Wayland checks count zero requested frame callbacks and check memory while displays are active and powered off. |
| P1 | The ISO test web server exposed its whole work directory, including the private guest SSH key, on all interfaces. | Serve only a temporary public staging tree containing the Kickstart, public key and package repository, bind localhost, reject staged symlinks and check startup. Fresh-work-directory and exposure regressions cover the harness. |
| P1 | A clean prebake wrote into a missing output directory, consumed an atlas before producing it, and lacked required renderer prerequisites. | Build prerequisites first, create output directories before consumers and test a clean filesystem. |
| P1 | `null-build --skip-hero` made a directory named `placeholder.cells` instead of a loadable cell file; boot assets ran before the renderer and icons went into the builder's home. | Quantize the placeholder into RCEL, fix stage ordering and pass the declared icon output path. Disposable driver fixtures reproduce each failure. |
| P1 | Incomplete/stale prebuilts could be accepted, and all historical RPMs from a persistent build directory were republished. A dirty working spec could describe archived HEAD from a different revision. | Validate the archived asset set, bind it to source provenance, build spec/Requires from the same revision, publish only the current build through a staging directory and preserve the prior repository if metadata generation fails. |
| P1 | The actual RPM preserved writable Windows prebake modes; machine-sync propagated writable shell colour/configuration assets and theme directories into system locations. | Normalize Source1, the staged package and copied destination directories. Reproduce with 0777/0666 fixtures and inspect the rebuilt RPM and installed system. |
| P1 | Binary dependencies and recolored Adwaita icons shipped without their complete upstream notices. | Preserve exact Adwaita notices and collect locked Cargo, embedded native/protocol and Fedora Rust toolchain notices offline; verify every collected file hash and record source-delivery gates separately. |
| P1 | A passwordless live session could enter the normal screen lock and have no usable password to unlock it. | Require a root-created marker and the exact live boot argument before disabling live-session lock/idle entry. Installed sessions retain normal authentication; marker-only and argument-only fixtures prove the boundary. |
| P1 | A shell wrapper around live `agetty` ran in the wrong SELinux domain. PAM accepted the live login, then SELinux denied the user shell, leaving a blank screen and a failed getty unit. | Invoke Fedora's labeled `agetty` directly, with a separate live-session condition. The actual guest starts Sway and the welcome with SELinux still enforcing. |
| P1 | SDDM's queued boot job stopped the live getty through its stock conflict, even though a live-only condition subsequently skipped the greeter. | Disable its boot alias in the composed live base; installed cleanup restores the greeter. A real systemctl fixture verifies the live base has no display-manager alias. |
| P1 | Polkit's installer guard could not inspect the root-created live marker with its default SELinux label. Install fell back to an unavailable authentication prompt and exited. | Label that runtime authorization marker with Fedora's existing Polkit runtime type. The original marker/kernel checks authorize Anaconda under enforcing SELinux without a new allow policy. |
| P1 | Branding the OS as nullLinux prevented Anaconda from detecting its Fedora profile. Guided installation inherited generic LVM defaults instead of the intended Btrfs layout and Fedora EFI directory. | Add a detected nullLinux profile inheriting Fedora, retain Firefox, and keep the account page visible. The real Anaconda configuration loader verifies Btrfs, zstd compression, EFI placement and account controls. |
| P2 | The read-only live base retained its composed machine ID and random seed. The running preview reused that machine ID. | Clear the base ID and remove its seed at the end of compose; remove copied seed state during target cleanup while preserving Anaconda's newly generated installed ID. Redirected filesystem tests cover both paths. |
| P2 | Closing the live welcome terminal sent SIGHUP to its installer child and ended installation. | Launch the installer through the compositor, outside the terminal's process group. A real Sway/foot recording process reproduces the failure before the change and survives after it. |
| P2 | A failed live compose deleted previous build results and could combine a newer recipe with an older package. | Give each compose its own directory, retain the last image on failure, validate concrete repository URLs, and require matching clean source/package provenance. |
| P2 | Publishing another RPM while an image composed could change its package or label the completed image with the next build's metadata. | Snapshot the local repository in each compose, validate its captured revision, and use that snapshot for both Anaconda and the published metadata. A concurrent-publication regression proves the package and sidecar stay paired. |
| P2 | The standalone installer displayed the stock console font/palette, and changing the palette alone left old background cells visible. | Stage the exact Terminus font and generated palette; apply them to the owned VT and repaint before prompting. Actual UEFI framebuffer comparison verifies exact glyphs and colours; final-confirmation cancellation leaves a blank virtual disk unallocated. |
| P2 | Failed surface installation could still write the machine-sync success stamp; upgrades did not invalidate it. | Stamp only after required operations succeed and invalidate copied-surface state on install/upgrade. |
| P2 | Correctly normalized RPM theme files were deduplicated as hardlinks, causing first-boot directory copies to fail with a same-file error. | Replace destination entries when refreshing GTK, SDDM and Plymouth trees. A hardlinked fixture fails before the change, then passes with independent destination inodes; the real guest setup also completes. |
| P2 | Plymouth could report a successful rebuild after dracut failed by inspecting an older image. Snapshot guidance suggested deleting the mounted root. | Build and inspect a candidate initramfs before replacing the active image; restore theme selection on failure. Recovery guidance now requires rescue media and explains separate `/boot` limitations. |
| P2 | Quotes and backslashes in installer answers changed Kickstart parsing; failed answer output could return success. | Encode answers as Kickstart arguments, propagate output failures and test round trips without running an installer against host storage. |
| P2 | A nonexistent backup destination bypassed the same-filesystem check. | Resolve/check its existing ancestor before creating it; mocked filesystem identities verify refusal. |
| P2 | Bar buffers retained the old dimensions/stride after configure events. The column did not resize its hosted PTY/VT. | Recreate surface buffers and propagate geometry. Real Sway resizing confirms surviving surfaces and changed terminal dimensions. |
| P2 | Column keyboard modifiers were discarded; closing/replacing a host could retain repeat or stale poll state. | Preserve modifiers, handle Alt/Shift-Tab, clear repeats and match polled descriptors to the host that was actually polled. |
| P2 | Raster bounds checked the total buffer length but let oversized rows spill into the next scanline. | Clip each scanline in both raster and text-grid drawing; pixel assertions exercise undersized surfaces. |
| P2 | Malformed assets could request unbounded decompression, zero geometry/timing, invalid palette indices or incompatible font bitmaps. | Validate sizes and indices before use, cap decompression, reject unsupported layouts and test corrupt inputs. |
| P2 | Hero caches survived changed masters/palettes; wallpaper startup killed unrelated `render` processes; a process merely named `lock` suppressed locking in another session. | Fingerprint all derivation inputs, rely on supervisor ownership and scope readiness to a successful handshake in the relevant Wayland session and process lifetime. |
| P2 | Supervisors, replacement scans and column IPC collided between two Wayland sessions belonging to one user. | Namespace state/control sockets by session and verify process ownership before replacement; independent two-session fixtures prove isolation. |
| P2 | Slow PAM authentication blocked the lock event loop, and removed outputs retained their lock surfaces. | Keep one authentication attempt on a worker and accept its result on the event thread; a lost worker rejects. Release removed surfaces. Unit tests cover delayed/lost authentication and a real compositor test exercises three monitor removal/re-enable cycles. |
| P2 | Wallpaper occlusion/power decisions combined every display, pausing a bare desktop because another monitor had a window. | Scope workspace and power queries to the surface's output. |
| P2 | Mixed charge/energy battery readings were added as though they shared units. | Normalize charge using voltage when possible and avoid claiming an unsupported combined energy reading. |
| P2 | Every nonzero binary16 subnormal decoded at half its correct value. | Fix the exponent and exhaustively compare half-float patterns. |
| P2 | Temperature was averaged with dark samples and by different weights in different render paths, cooling antialiased edges. | Use the composable luminance moment `sum(L*T)/sum(L)` consistently in CPU reference, shader and screen reductions, preserving RGB/light. Add physical and cross-implementation regressions and regenerate the master. |
| P2 | Default application resolution lost quoted arguments/field positions, ignored XDG precedence and could expose shell interpretation. | Share desktop-entry discovery/argument expansion, preserve NUL-separated argv for direct execution, shell-quote the compositor handoff and respect hidden entries and desktop visibility. Tests launch recording executables with spaces and metacharacters. |
| P2 | Invalid input values were persisted; keyboard authorization failures looked successful; settings discarded useful error output. | Validate before atomic replacement, use localed's authorized keyboard conversion and display failed mutations in the settings panel. |
| P2 | A failed system upgrade still ran orphan removal/cache cleanup and returned success; failed orphan queries reported zero. | Stop at the failing update channel, preserve its exit status and report an unknown count when the query fails. Five isolated command tests cover report-only behavior and upgrade, cleanup, firmware and query failures. |
| P2 | A successful first-run log produced two zeroes in its problem count and an integer-comparison error. The same pattern split the empty Bluetooth device count across lines. | Keep the single zero already emitted by `grep -c`; clean, duplicate-error and distinct-error log fixtures verify reporting. |

## Performance work

The changes target unnecessary work with a visible correctness benefit: bound
lock scheduling, pause wallpaper only on its own covered/off display, invalidate
caches accurately, avoid parsing all desktop files to resolve one default, and
reuse target HDR geometry across font strikes. They preserve the existing visual
design and do not lower bake quality to improve a benchmark.

On this Fedora WSL test host, software Vulkan traced one production frame
(2560×720 rays, 4× supersampling, 3000 steps) in 8.56 seconds, 9.50 seconds wall
time. This is an environment measurement, not a hardware performance promise.
The live lock test's RSS was unchanged over the active-display and powered-off
observation windows. Longer device-specific power measurements remain necessary.

The live image now uses zstd SquashFS. On the same Fedora Firefox directory
with two compression workers, xz took 90.62 seconds and produced 132,653,056
bytes; zstd took 59.80 seconds and produced 139,128,832 bytes (4.9% larger).
Median extraction time for the identical `libxul.so` was 2.48 versus 0.83
seconds; all extracted SHA-256 hashes matched. These are sample measurements
under concurrent build load, not whole-image timing promises. The actual
Fedora 44 image kernel enables SquashFS zstd decompression.

## Numerical and runtime evidence

- Baseline Rust suite: 55 library tests and 8 renderer tests passed before fixes;
  the new reproductions exposed gaps in that coverage.
- Exhaustive half-float comparison: 2,046 finite mismatches before the fix,
  exactly the positive/negative nonzero subnormals.
- CPU/GPU check at 80×24: hit geometry matched; median/p95 luminance error
  1.30%/1.71%, temperature error 0.000054%/0.000809%. Quantized glyph agreement
  was 99.7396%; every differing glyph was one adjacent ramp level.
- At full 2560×720 resolution on the same llvmpipe adapter, the baseline and
  corrected shaders produced bit-identical RGB for frame 0. The temperature
  correction changed 68,966 temperature samples. The unprovenanced historical
  release master differs in RGB; it is not used to claim byte-identical output.
- Legacy master inspection: 322,804 lit cells in 240 frames had temperatures
  below the palette's physical lower bound. This information cannot be recovered
  by relabeling the old master; a new bake is required.
- Python/Rust derivation of the explicitly labeled legacy 240-frame master to
  80×24 produced identical glyph and colour planes after the numerical fixes.
  Measured time including reads was 4.67 seconds in Rust and 8.76 in Python;
  this comparison checks implementation parity, not the legacy master's quality.
- Live headless Sway: two isolated outputs; resize 640×480 to 480×360 kept
  wallpaper/bar/column alive and changed the hosted PTY from 63×44 to 63×32.
- Native locker emitted `LOCKED`, requested zero frame callbacks, and retained
  constant RSS during four-second active and four-second powered-off windows.
  Terminating only that locker left a solid compositor lock frame.
- Real `swaymsg exec` preserved a literal argument containing `$()`, semicolons,
  double quotes and a single quote without expanding or splitting it.

The combined `verify/source.sh` run at
`d262d5fe7bdf077b79b2792434449c95a7ed739a` passed: syntax for 139 shell and 52
Python sources; structural checks and their negative fixtures; 112 isolated system/UI
tests; 26 bake/build tests; 11 physics checks; 94 Rust tests; the Clippy
correctness gate; and compilation of all five production binaries. Existing
style and dead-code warnings are not promoted to correctness failures.

The corrected 240-frame master completed at production quality: 640×180 cells,
24 fps, 4× supersampling and 3000 integration steps. All 27,648,000 cells are
finite; all 4,256,400 lit cells have nonzero temperatures within the expected
physical range. Python and Rust derive identical glyph and colour planes for
all frames at both 80×24 and 227×64. The complete prebake contains 891 validated
files, nine atlases and 45 RCEL animations. The master archive SHA-256 is
`6e1a3eb1dc7aa542ab48174de2cab2e8f8b448324f9c7b19c89fb6c6aaaaac20`.

The first actual RPM was installed in a disposable Fedora 44 guest. Its
production PAM locker rejected a wrong password, remained responsive during
PAM's delay, then unlocked with the correct password. Real configured sessions
also exercised layout, column reservation, resized wallpaper, GTK/WebKit font
selection and launcher quoting. Those tests established runtime behavior but
also exposed the package-permission defect above; that intermediate RPM is
not a release artifact. Ten failures from running source-oriented legacy
verifiers inside the RPM were classified separately: seven expected omitted
source/build files, two caller checks expected omitted Rust source, and one
nano pattern was too restrictive and has been fixed.

The primary image now provides a live desktop with Try and Install choices.
Installation uses Fedora's supported interactive liveinst/WebUI. Temporary
autologin, the blank live account and the narrowly scoped installer authorization
are removed from the installed target. Boot and installation of the final live
image remain integration gates until results below explicitly record them.

The corrected RPM from `9ae6cfbe0cb940db487fb999bba7f54ddf951fd3` has SHA-256
`23398d475e0fc8fbee43eebbfc0cf190925d95c0f7bc81ae625d6d7e0495c5a5`.
All five production binaries match the earlier tested RPM byte for byte. The
changes in this rebuild correct packaged first-boot file handling.

That exact RPM was also installed from the standalone installer image onto a
fresh virtual disk. The unchanged installed-system verifier passed 53 checks,
with zero failures, against a frozen copy of the ISO's package. Ordinary disk
boots reached the graphical target in 28.662 and 37.364 seconds with no failed
units. Greeter login, a wrong-password rejection, correct-password unlock and
a further ordinary reboot passed using the actual keyboard and production
locker. This harness boots the installer kernel/initrd directly, so it does
not substitute for firmware-menu or guided live-install acceptance.

The subsequent `d262d5fe7bdf077b79b2792434449c95a7ed739a` RPM has SHA-256
`cebb15c1bcf3881ad3ba1bdfa298039bb824165582aa9e1f544be4679e5849c7`.
Its runtime binaries, other 59 commands, 12 libraries, PAM files, configuration,
895 asset entries and 311 license files match the accepted package in bytes,
modes and ownership. Only the live builder, its regression, provenance and
documentation changed. All 303 collected notice hashes were verified.

Lorax built fresh Fedora 44 installer boot media successfully. Its El Torito
catalog contains BIOS and UEFI entries. This is boot-media construction evidence;
embedding and installing the final package are separate acceptance steps.

## Repository maintenance

Added source CI and a documented separation between source, artifact and guest
checks; enforced Linux line endings across platforms; removed duplicate ignore
rules; corrected stale spin/build/status descriptions; retained the original
license bytes. All code work is isolated from the user's `master` checkout.

## Final release checks and follow-up coverage

1. Verify the final corrected master, prebuilts, package and release ISOs from
   the revision being released, including a cold install from the final ISO.
2. Prove graphical login and successful PAM unlock in the installed system;
   a lock handshake/fail-closed test alone does not prove password acceptance.
3. Retain the released source, corrected master, artifacts and checksums with
   the release evidence. Record the publication result when the release exists.

Real-hardware cold installation, firmware, EDID/GPU, Wi-Fi association,
suspend/resume, docking, trackpoint and battery tests remain follow-up work.
Thunderbird/LibreOffice and the regenerated hero/boot surfaces also need wider
on-screen acceptance against the project's visual rules. These limitations
must accompany the release; the version bump does not close them.
