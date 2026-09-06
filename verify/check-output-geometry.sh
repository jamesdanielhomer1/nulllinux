#!/usr/bin/env bash
# THE TWO WAYS OF ASKING HOW BIG THE SCREEN IS MUST GIVE THE SAME ANSWER.
#
# bin/machine's detect_output has two branches. With a compositor running it
# asks over Wayland; without one -- which is the case at boot, before the
# display manager, where nulllinux-machine-sync runs -- it reads
# /sys/class/drm.
#
# The profile is written by one branch and checked by the other. If they
# disagree, `machine check-profile` reports MISMATCH on hardware that has not
# changed, and every boot re-derives every surface.
#
# They did disagree. `render outputs` was written to prefer xdg_output's
# LOGICAL size, which is the mode divided by the scale factor: on a HiDPI
# screen at scale 2, 1920x1080 where DRM says 3840x2160. Half. On exactly the
# machines "works on any hardware" is about.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

RENDER=render/target/release/render

# 1. Static: the Rust side must prefer the current mode. This is the check that
#    works on a build host with no compositor and no DRM, which is most of them.
if grep -q 'i.modes.iter().find(|m| m.current)' render/src/outputs.rs \
   && grep -A2 'let (w, h) = i.modes' render/src/outputs.rs | grep -q 'or(i.logical_size)'; then
  note "ok    render/src/outputs.rs reports the current mode, with logical size only as a fallback"
else
  note "render/src/outputs.rs no longer prefers the current mode -- it will disagree with the DRM branch on any scaled screen"
  fail=1
fi

# 2. bin/machine must still have both branches, and the DRM one must still be
#    reachable. A detect_output that only asks the compositor cannot run at
#    boot at all.
grep -q 'render/target/release/render" outputs\|rbin" outputs' bin/machine \
  || { note "bin/machine: the compositor branch of detect_output is gone"; fail=1; }
grep -q '/sys/class/drm' bin/machine \
  || { note "bin/machine: the DRM branch of detect_output is gone -- nothing can detect an output at boot"; fail=1; }

# 3. Dynamic, when this machine can answer: run both branches for real and
#    require the same geometry. Skipped rather than faked when it cannot.
drm_geometry() {
  local d name mode
  for d in /sys/class/drm/card*-*/; do
    [ -r "$d/status" ] || continue
    [ "$(cat "$d/status" 2>/dev/null)" = connected ] || continue
    mode=$(head -1 "$d/modes" 2>/dev/null)
    [ -n "$mode" ] || continue
    name=$(basename "$d"); name=${name#card*-}
    printf '%s %s %s\n' "$name" "${mode%x*}" "${mode#*x}"
    return 0
  done
  return 1
}

if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -x "$RENDER" ] && drm=$(drm_geometry); then
  if way=$("$RENDER" outputs 2>/dev/null | head -1); then
    wname=$(printf '%s' "$way" | cut -f1)
    wgeom="$(printf '%s' "$way" | cut -f2)x$(printf '%s' "$way" | cut -f3)"
    dname=$(printf '%s' "$drm" | cut -d' ' -f1)
    dgeom="$(printf '%s' "$drm" | cut -d' ' -f2)x$(printf '%s' "$drm" | cut -d' ' -f3)"
    note "compositor: $wname $wgeom"
    note "DRM:        $dname $dgeom"
    # The names can legitimately differ in form; the geometry cannot.
    if [ "$wgeom" = "$dgeom" ]; then
      note "ok    both branches report the same geometry"
    else
      note "the two branches disagree: $wgeom vs $dgeom -- check-profile will report a false MISMATCH every boot"
      fail=1
    fi
  else
    note "(the compositor did not answer; dynamic comparison skipped)"
  fi
else
  note "(no compositor or no DRM here; dynamic comparison skipped, static checks stand)"
fi

[ $fail = 0 ] && echo "PASS: both ways of measuring the screen agree"
exit $fail
