# Isolated runtime checks

`test_runtime_wrappers.py` runs ordinary fixture tests for cache invalidation,
wallpaper process ownership, lock readiness, and supervisor/once replacement
scoped to a Wayland session:

```sh
python3 verify/test_runtime_wrappers.py -v
python3 verify/test_battery.py -v
```

`headless-runtime.py` requires explicit opt-in. It creates tiny assets, a private
runtime directory, and a minimal two-output Sway compositor without desktop
startup commands. When invoked as root it runs the compositor and clients as
`nobody`. It never connects to the caller's compositor. Cleanup signals only
process groups started by the harness.

Requirements: Linux, Sway with the headless/pixman backend, `swaymsg`, `grim`,
Python 3 with Pillow, libzstd, and `runuser` when invoked as root. Build all four
surface binaries first. Missing prerequisites or absent opt-in return status 77.

```sh
cargo build --locked --manifest-path render/Cargo.toml --bins
NULL_RUN_HEADLESS=1 \
NULL_HEADLESS_BIN_DIR="$PWD/render/target/debug" \
python3 verify/headless-runtime.py
```

Set `NULL_HEADLESS_BIN_DIR` to an external Cargo target directory when using
`CARGO_TARGET_DIR`. Set `NULL_HEADLESS_EVIDENCE` to a dedicated evidence directory;
the default is `/var/tmp/null-headless-evidence-<pid>`. As root, this directory is
made writable by `nobody`, so use a directory intended only for this test.

The harness checks actual Wayland surface survival across a 640×480 to 480×360
resize, the bar's right-edge pixel, PTY `SIGWINCH`/dimensions, literal punctuation
through Sway's `exec` handoff, the native session-lock handshake, callback count,
RSS stability while outputs are active and powered off, the compositor's solid
locked frame after the locker dies, three output removal/re-enable cycles with
lock-surface destruction, and exit after compositor disconnect.
It saves screenshots, client protocol logs, and `results.json`.

It uses a synthetic font/hero and does not test production visual fidelity,
hardware scaling/rotation, keyboard devices, or PAM password acceptance. The
locker is never authenticated; the test ends by terminating its own compositor.

The lock's unit tests exercise delayed authentication, rejection of overlapping
attempts, and worker failure without invoking PAM. Production PAM acceptance and
refusal require a disposable guest with its normal keyboard device and test
account: build the ordinary lock binary, lock the guest, enter a wrong password
through the guest keyboard, assert the lock remains, then enter the correct
password and assert the desktop returns. Resize or hotplug an output while an
authentication attempt is pending to check protocol responsiveness. Do not use
`lock-test-hook` in a production package or describe a skipped PAM test as passed.
