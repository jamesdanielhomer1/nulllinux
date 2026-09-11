# Testing and building

Use Fedora 44 x86_64 for this build. `.gitattributes` keeps shell sources at LF
on Windows checkouts; execute them in Linux. Cargo lockfiles are build inputs.
The build machine needs Rust/Cargo and `rust-std-static`, a C compiler,
pkg-config, Wayland/xkbcommon/PAM headers,
Python 3.14 with NumPy and Pillow, Terminus console fonts, Adwaita icons, and
Vulkan for raytracing. Python 3.14 supplies the `compression.zstd` module.
Software Vulkan works; it is substantially slower than a discrete GPU.

Live-media composition additionally needs `lorax` (`livemedia-creator` and
`mkksiso`), `pykickstart` (`ksvalidator`), `createrepo_c`, and the Fedora
`anaconda-core`, `anaconda-tui` and `anaconda-install-env-deps` build environment.
Installing the Python Kickstart parser alone does not necessarily provide the
`ksvalidator` command. Use an isolated Fedora build host: the current compose
uses Anaconda's `--no-virt` chroot path and needs root, mounts and loop devices.
The recipe allocates a 12 GiB root image; the builder requires at least 20 GiB
free and retains intermediate images, so allow additional space for repeated
composes, package caches and evidence.

## Source checks

```sh
bash verify/source.sh
```

This checks shell/Python syntax, structural checks and their negative fixtures,
the isolated Python regression suites, CPU physics, Rust tests, Clippy
correctness diagnostics and the production renderer build. Fixtures use temporary
directories and mocked system commands. It does not install the desktop, change
accounts or reconfigure the current session. `NULL_TEST_MACHINE` is unset by
the runner. Missing dependencies are failures, not a source-suite pass.

The GitHub workflow runs this command in Fedora 44. Its dependency installer,
`packages/fedora/ci-dependencies.sh`, belongs in a disposable build environment.
The GPU cross-validation and full prebake are additional artifact checks;
passing source CI alone does not certify an image.

## Assets and packages

```sh
bin/null-build
bin/null-prebake
bin/null-package
```

The master bake writes a completion manifest only after every HDR frame is
complete. It records the numerical model, scene, source/renderer hashes and frame
hashes. The corrected model uses luminance-weighted temperature reduction.
The original `v0.1.0` master predates this model: verify its published checksum
for historical comparisons, but do not relabel it as a corrected bake. The
explicit legacy option is for recovery/comparison and is recorded in provenance.

Package from a clean committed revision. `--allow-dirty` deliberately packages
HEAD, not pending edits. The RPM build records its source and asset provenance;
check the resulting package and repository before building an ISO. Do not reuse
an earlier RPM merely because its filename looks right.

The RPM build collects notices from locked, offline Cargo metadata, including
embedded native zstd and Wayland protocol material. It also verifies the pinned
Rust standard-library vendor notice bundle against the Fedora build toolchain.
When dependencies or the toolchain change, review their licenses and refresh
the notice inventory as needed. Inspect the built RPM's license files and
manifest, not only its `License` field. This package places license material in
`/opt/share/licenses/nulllinux/`. Prebuilt directories must be `0755`, prebuilt
data files `0644`, and system configuration must not be writable by ordinary
users. See [the licensing inventory](LICENSING.md).

## Primary Try / Install live image

The live builder uses zstd SquashFS compression, supported by Fedora 44's
kernel. It favors faster decompression when trying the desktop from USB;
the secondary Anaconda installer image retains Lorax's own format.

From the same clean committed revision used to build the repository:

```sh
sudo bin/null-iso
```

The builder checks package/source identity, validates the composed Kickstart,
and uses a fresh compose directory. A failed compose keeps the previously
published ISO. The default output is
`/var/lib/nulllinux-iso/nulllinux-0.1.0.iso`, with `.sha256` and
`.build-info.json` sidecars. `NULL_ISO_WORK` selects another build/output
directory. Keep the compose logs and identify the exact image checksum in
test results.

The image includes `anaconda-live` for `/usr/bin/liveinst`, `anaconda-webui`,
Firefox and polkit. These are live-image requirements in
`packaging/nulllinux-live.ks`; installing only an Anaconda backend is insufficient
for the graphical Install action. The running live session invokes `liveinst`
as its user, allowing Fedora's wrapper to preserve the Wayland connection and
perform its own privilege handoff. Live installs are interactive: do not use
`inst.ks` or `liveinst --kickstart` to test this path.

The intended flow is a welcome offering Try and Install after machine setup has
completed. Try closes the welcome without launching an installer or formatting
disks. Install opens Anaconda's target-selection and confirmation flow; the same
entry appears in the application launcher. The live account is temporary and
passwordless, so locking and automatic idle/suspend are unavailable there.
Choosing Try does not prevent deliberate writes to storage through other apps.

A root service creates the live account and `/run/nulllinux-live` only for a
boot carrying `rd.live.image`. The live user receives authorization for the
specific installer action rather than passwordless sudo. Getty waits for live
setup and machine reconciliation before starting the session. Anaconda's
internal installed-target post-script removes live autologin, installer
authorization/launcher and optional debug access, clears the machine-sync stamp,
and enables the installed login path. It removes the blank temporary live account
while retaining a same-named account given a password by the installer.

Validate the final image in a disposable VM with BIOS and UEFI boot, initially
without an installation disk to exercise Try. Then attach a disposable disk and
check that Install reaches the supported graphical installer, performs the
chosen installation, and boots the target after the live medium is removed.
Check account preservation, absence of live/debug privileges, ordinary login,
password unlock, image/package provenance and installed file permissions. The
mocked cleanup tests establish intended behavior; they do not establish that
Anaconda ran the hook on a real installation. Record that evidence separately.

## Secondary standalone installer

`bin/null-installer-iso` retains the separate Anaconda `boot.iso` workflow with
the project's console prompts and generated Kickstart. It is useful for testing
that installer path, but does not replace validation of the primary live
Try / Install medium. Keep its BIOS/UEFI, disk-confirmation and installed-system
results separate; never feed the unattended test template to a physical machine.

## Running desktop and installed-system checks

The headless harness exercises real Wayland surfaces with isolated sockets,
fixture assets and only the processes it starts:

```sh
NULL_RUN_HEADLESS=1 python3 verify/headless-runtime.py
```

See [the harness documentation](../verify/README-headless-runtime.md) for
dependencies and evidence paths. It is separate from installed-system checks.

`verify/run.sh` includes checks of installed state and some destructive guest
fixtures. Run it through `verify/in-guest.sh` in a newly created disposable VM.
Never set `NULL_TEST_MACHINE=1` on a workstation to make skipped tests disappear.
Retain guest logs and inspect skips and diagnostics as well as exit status.
The VM harness's forwarded SSH listener is bound to `127.0.0.1`.

Package installation into a Fedora cloud VM is useful evidence, but does not
replace a cold installation from the final live ISO. BIOS/UEFI boot, final image
contents, graphical login and PAM unlock require their own integration checks.
Real firmware, GPU/EDID, Wi-Fi, suspend, docking and battery behavior need the
hardware acceptance tests in `goals.md`.
