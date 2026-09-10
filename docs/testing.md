# Testing and building

Use Fedora 44 x86_64 for this build. `.gitattributes` keeps shell sources at LF
on Windows checkouts; execute them in Linux. Cargo lockfiles are build inputs.
The build machine needs Rust/Cargo, a C compiler, Wayland/xkbcommon/PAM headers,
Python 3.14 with NumPy and Pillow, Terminus console fonts, Adwaita icons, and
Vulkan for raytracing. Python 3.14 supplies the `compression.zstd` module.
Software Vulkan works; it is substantially slower than a discrete GPU.

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
replace a cold installation from the final ISO. BIOS/UEFI boot, final image
contents, graphical login and PAM unlock require their own integration checks.
Real firmware, GPU/EDID, Wi-Fi, suspend, docking and battery behavior need the
hardware acceptance tests in `goals.md`.
