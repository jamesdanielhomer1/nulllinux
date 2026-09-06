#!/usr/bin/env bash
# Run every verifier. Phases add to this; nothing is ever removed from it.
#
# A verifier that is written and then not wired in here is a verifier that
# stops being run the week after it was written.

set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
cd "$ROOT"

fail=0
run() {
  local label=$1; shift
  printf '\n== %s\n' "$label"
  if ! "$@"; then fail=1; printf '   ^^ FAILED\n'; fi
}

run "package abstraction (§9.1)"      ./verify/check-package-abstraction.sh
run "branding is safe"               ./verify/check-branding.sh
run "no silent takeover"              ./verify/check-no-takeover.sh
run "no accidental rebuild"          ./verify/check-no-accidental-build.sh
run "screen measured one way"        ./verify/check-output-geometry.sh
run "initramfs boots elsewhere"      ./verify/check-portable-initramfs.sh
run "firewall is default-deny"       ./verify/check-firewall.sh
run "the lock screen is ours"        ./verify/check-lock-screen.sh
run "every tool has a caller (§10.1)"     ./verify/check-callers.sh
run "themes have one name (§8.10)"       ./verify/check-theme-names.sh
run "the splash is complete (§9.6)"      ./verify/check-splash-complete.sh
run "the desktop offers what it installs"  ./verify/check-menu-programs.sh
run "the two derivers agree (§5.3)"      ./verify/check-derive-parity.sh
run "no hard-coded screen size (§0.2)"    ./verify/check-no-hardcoded-geometry.sh
run "one surface per screen (§6.3)"      ./verify/check-per-output.sh
run "... and that can fail (§10.1)"       ./verify/selftest-callers.sh
run "... and it can fail (§10.1)"     ./verify/selftest-package-abstraction.sh
run "machine profile grid (§2.1)"     ./bin/machine check-grid
run "machine profile is readable"     ./bin/machine get hero
run "ramps: monotonic + font hash (§2.4)"  ./verify/check-ramps.sh
run "a ramp belongs to one strike (§2.3)"  ./verify/check-cross-strike-ramp.sh
run "mode ladder within Nyquist (§3.4)"    python3 bake/ladder.py
run "Kerr physics + shader (§10.2)"        ./verify/check-kerr.sh
run "compositor accepts the config (§8.2)" ./verify/check-sway-config.sh
run "no key bound twice (§8.3, §10.4)"     ./verify/check-binds.sh
run "... and that audit can fail (§10.1)"  ./verify/selftest-binds.sh
run "idle ladder is in order (§8.5)"       ./bin/null-idle check
run "every menu topic is drawable (§10.5)" ./verify/check-menu-coverage.sh
run "terminal-adjacent surfaces (§7.6)"   ./verify/check-terminal-surfaces.sh
run "file manager behaviour (§8.7)"       ./bin/null-filemanager check
run "joins into foreign files (§9.8)"     ./bin/null-join check

# Added after the phases that wrote them. Six verifiers had already drifted out
# of this file by Phase 12 -- exactly what the note at the top warns about --
# so they are listed here whether or not they are convenient to run.
run "column zone tracks the animation (§7.3)" ./verify/check-column-zone.sh
run "dwindle splits the longer axis (§8.2)"   ./verify/check-dwindle.sh
run "keyboard agrees on all 3 surfaces (§9.5)" ./verify/check-keyboard.sh
run "the intended font renders (§8.10)"       python3 verify/check-font-substitution.py "Terminus (TTF)"
run "report-first is structural (§8.4)"       python3 verify/check-report-first.py
run "every command invoked exists (§10.1)"    python3 verify/check-commands.py /etc/sway/config
run "... and that check can fail (§10.1)"     ./verify/selftest-report-first.sh

# THE MENU COVERAGE CHECK NOW DOMINATES THIS SUITE'S RUNTIME. It went from 7
# topics at a 2 s window to 28 at 6 s, so it alone takes about five minutes and
# the whole suite about twelve. Both changes were correct -- the topic list is
# derived rather than hand-kept, and a window shorter than the thing being
# measured measures nothing -- but the cost is real and is recorded here rather
# than discovered by someone waiting.
#
# If it becomes a reason not to run the suite, the fix is to probe the topics
# concurrently (they are independent processes), NOT to shorten the window back
# to a length that reports a slow topic as broken.

# verify/measure-*.sh are deliberately NOT here. They produce NUMBERS, not
# verdicts, and a number has no pass/fail without a threshold this system has
# not agreed. They belong to the standing measurement discipline (§10.7) and
# are run when a claim is being made or refreshed -- see docs/measurements.md,
# which records what each figure was taken against and when.

printf '\n'
if [ $fail -eq 0 ]; then echo "ALL CHECKS PASS"; exit 0; else echo "CHECKS FAILED"; exit 1; fi
