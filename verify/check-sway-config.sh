#!/usr/bin/env bash
# The compositor's own validator.
#
# It reports errors on stdout while STILL EXITING 0, so the output is the
# evidence and the status is not (§10.1 rule 1). This wrapper exists so that
# distinction is made once, here, rather than forgotten at each call site.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd); cd "$ROOT"
# A CONFIG IS VALIDATED WITHOUT A SESSION.
#
# `sway --validate` still creates a backend, and the backend it picks by
# default is the Wayland one when WAYLAND_DISPLAY is set. Point that at a
# display which is not there -- a session that ended, a headless build, a
# guest, CI -- and the validator dies on "Could not connect to remote display"
# and the check reports that the compositor REJECTED the configuration. It did
# not; it never read it.
#
# Observed the hard way: a session on this build host ended mid-run and this
# check turned red while nothing about the configuration had changed.
#
# Forced to the headless backend, which needs no display, no seat and no
# hardware, so this asks the same question on every machine.
out=$(env -u WAYLAND_DISPLAY -u DISPLAY -u SWAYSOCK \
      WLR_BACKENDS=headless \
      sway --validate --config "$ROOT/config/sway/config" 2>&1)
# AND A VALIDATOR THAT COULD NOT START IS NOT A VERDICT. "Unable to create
# backend" says nothing about the configuration, and reporting it as a
# rejection is the same error as reading a crash as a test failure.
if grep -q 'Unable to create backend' <<<"$out"; then
  echo "SKIP: sway could not start any backend here, so the config was never read"
  grep ERROR <<<"$out" | head -4
  exit 0
fi
if grep -q ERROR <<<"$out"; then
  echo "FAIL: the compositor rejects this configuration"
  grep ERROR <<<"$out" | head -8
  exit 1
fi
echo "PASS: the compositor accepts this configuration"
