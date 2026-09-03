# One surface per screen, kept in step with the hardware (NULL.md §6.3).
#
# Sourced by bin/null-wallpaper and bin/null-bar, which differ only in what
# they start. Everything else -- reconciling against the live output list,
# reaping a screen that was unplugged, restarting one whose renderer died,
# and doing it again when the monitors change -- is the same problem twice, so
# it is written once.
#
# The caller defines:
#     start_one <output-name> <width> <height>
# and sets $RENDER (used to ask the compositor what screens exist) and $TAG
# (what to call itself in messages). Then calls `supervise`.

declare -A CHILD=()
declare -A GEOM=()       # output name -> WxH it was started for

# CHILDREN DIE WITH THE SUPERVISOR. Without this a compositor reload leaves the
# previous run's surfaces mapped, and the new ones stack on top of them --
# which is how a "restart" ends up drawing the same screen twice.
_supervise_cleanup() {
  local p
  for p in "${CHILD[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  exit 0
}

reconcile() {
  local seen=() name w h scale p found s
  while IFS=$'\t' read -r name w h scale; do
    [ -n "$name" ] || continue
    seen+=("$name")
    p=${CHILD[$name]:-}
    # A MODE CHANGE IS NOT A NEW SCREEN. Change a monitor's resolution and the
    # name stays the same, so nothing here would notice -- and the surface would
    # keep the hero grid and the strike chosen for the size it used to be. The
    # geometry it was started for is remembered, and a change restarts it.
    if [ -n "$p" ] && [ "${GEOM[$name]:-}" != "${w}x${h}" ]; then
      echo "$TAG: $name is now ${w}x${h}, was ${GEOM[$name]:-unknown} -- restarting"
      kill "$p" 2>/dev/null || true
      unset "CHILD[$name]"; p=
    fi
    # A surface whose renderer DIED must be noticed here. Otherwise that screen
    # stays blank until the next hotplug event, which may never come.
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then continue; fi
    [ -n "$p" ] && unset "CHILD[$name]"
    if start_one "$name" "$w" "$h"; then GEOM["$name"]="${w}x${h}"; fi
  done < <("$RENDER" outputs 2>/dev/null)

  for name in "${!CHILD[@]}"; do
    found=0
    for s in "${seen[@]:-}"; do [ "$s" = "$name" ] && { found=1; break; }; done
    if [ "$found" -eq 0 ]; then
      echo "$TAG: $name unplugged, stopping its surface"
      kill "${CHILD[$name]}" 2>/dev/null || true
      unset "CHILD[$name]"; unset "GEOM[$name]"
    fi
  done
}

supervise() {
  trap _supervise_cleanup EXIT INT TERM
  reconcile

  # WATCH FOR SCREENS COMING AND GOING.
  #
  # sway can say the instant it happens, and blocking on it costs nothing until
  # something changes. A compositor that cannot is polled instead, because
  # "works on any device" has to include the ones that are not sway.
  if command -v swaymsg >/dev/null 2>&1 && swaymsg -t get_version >/dev/null 2>&1; then
    while IFS= read -r _; do
      reconcile
    done < <(swaymsg -t subscribe -m '["output"]' 2>/dev/null)
  fi

  # Reached when there is no sway, or when it went away. One Wayland round-trip
  # every few seconds; a new monitor does not need its wallpaper inside a second.
  while true; do
    sleep 5
    reconcile
  done
}
