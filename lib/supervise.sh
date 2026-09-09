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
  # Remove the pidfile only if it is still OURS -- a newer supervisor that just
  # displaced us already owns it and must not have it deleted from under it.
  [ "$(cat "${XDG_RUNTIME_DIR:-/tmp}/$TAG.pid" 2>/dev/null || true)" = "$$" ] \
    && rm -f "${XDG_RUNTIME_DIR:-/tmp}/$TAG.pid"
  exit 0
}

# How many consecutive times the compositor failed to answer. A surface
# supervisor has no reason to outlive its compositor, and this one did: when
# sway went away the event stream hit EOF and it dropped into the poll loop
# below, where it sat for ever asking a dead compositor what screens it had.
# One leaked process per session, invisible because it does nothing.
_gone=0

reconcile() {
  local seen=() name w h scale p found s out
  if ! out=$("$RENDER" outputs 2>/dev/null); then
    _gone=$((_gone + 1))
    # Three strikes, not one: a compositor restarting is not a compositor gone,
    # and reaping every surface over one dropped query would be worse.
    if [ "$_gone" -ge 3 ]; then
      echo "$TAG: no compositor answers -- stopping"
      _supervise_cleanup
    fi
    return 0
  fi
  _gone=0
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
  done <<<"$out"

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
  # ONE SUPERVISOR PER SESSION. exec_always re-runs the caller on EVERY
  # compositor reload, and killing the stray daemons (as the caller does) is not
  # enough: the PREVIOUS supervisor is still alive, so it reconciles and respawns
  # its surfaces, and each reload stacks another set -- the bar drawn four times
  # after four reloads. So a fresh copy displaces the previous supervisor by
  # pidfile (per $TAG); killing it fires the EXIT trap that takes its surfaces
  # down. The cmdline is checked too, since pids are recycled, and it is exactly
  # the displacement the column and dwindle supervisors already do.
  local pidfile="${XDG_RUNTIME_DIR:-/tmp}/$TAG.pid" old i
  if [ -r "$pidfile" ]; then
    old=$(cat "$pidfile" 2>/dev/null || true)
    if [ -n "${old:-}" ] && [ "$old" != "$$" ] && kill -0 "$old" 2>/dev/null \
       && tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null | grep -q "$TAG"; then
      kill "$old" 2>/dev/null || true
      for i in 1 2 3 4 5; do kill -0 "$old" 2>/dev/null || break; sleep 0.1; done
    fi
  fi
  echo $$ > "$pidfile"

  trap _supervise_cleanup EXIT INT TERM
  reconcile

  # WATCH FOR SCREENS COMING AND GOING.
  #
  # sway can say the instant it happens, and blocking on it costs nothing until
  # something changes. A compositor that cannot is polled instead, because
  # "works on any device" has to include the ones that are not sway.
  if command -v swaymsg >/dev/null 2>&1 && swaymsg -t get_version >/dev/null 2>&1; then
    # AN EVENT IS NOT THE ONLY REASON TO LOOK.
    #
    # This blocked on sway's output events alone, which is right for hotplug
    # and wrong for everything else: a renderer that DIED -- crashed, or killed
    # on purpose when its exact hero finished deriving -- produces no output
    # event, so nothing ever noticed and that screen stayed blank until a
    # monitor happened to be plugged in. The derivation landing was silent in
    # exactly this way.
    #
    # So: block on events, but wake every few seconds anyway and sweep. `read`
    # returns >128 on timeout and something else at EOF, which is how the loop
    # tells "nothing happened yet" from "sway has gone".
    exec {SUBFD}< <(swaymsg -t subscribe -m '["output"]' 2>/dev/null)
    while true; do
      if read -t 5 -r _ <&$SUBFD; then
        reconcile
      elif [ $? -gt 128 ]; then
        reconcile          # the periodic sweep; catches a child that died
      else
        break              # EOF: sway is gone, fall through to polling
      fi
    done
    exec {SUBFD}<&-
  fi

  # Reached when there is no sway, or when it went away. One Wayland round-trip
  # every few seconds; a new monitor does not need its wallpaper inside a second.
  while true; do
    sleep 5
    reconcile
  done
}
