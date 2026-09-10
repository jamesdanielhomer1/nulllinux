#!/usr/bin/env bash
# The console and the session must use the same keyboard layout (§9.5).
#
# These are configured in two unrelated places -- /etc/vconsole.conf for the
# console, the compositor's input block for the session -- and a compositor
# with no input block does not warn, it just runs the xkb default. Both are
# read from the RUNNING system here, not from any file this repository owns,
# because the failure being checked for is precisely that a file says one
# thing and the machine does another.
set -uo pipefail
fail=0

# THREE surfaces, three unrelated sources:
#
#   console  /etc/vconsole.conf KEYMAP
#   greeter  localectl's X11 layout -- the greeter compositor execs
#            locale1-xkb-config, so it follows the system setting, not ours
#   session  our compositor's input block; with none, sway runs the xkb
#            default, because we deliberately do not include the
#            distribution's config.d files
#
# They are set in different places by different tools and nothing makes them
# agree. This asserts that they do.
console=$(sed -n 's/^KEYMAP="\?\([^"]*\)"\?/\1/p' /etc/vconsole.conf | head -1)
printf 'console keymap   : %s\n' "${console:-<unset>}"
[ -n "$console" ] || { echo "  FAIL: no KEYMAP in /etc/vconsole.conf"; fail=1; }

greeter=$(localectl status 2>/dev/null | sed -n 's/.*X11 Layout: *//p' | head -1)
printf 'greeter layout   : %s\n' "${greeter:-<unset>}"
if [ "$greeter" != "$console" ] && ! awk -v vc="$console" -v xkb="$greeter" \
    '$1 == vc && $2 == xkb {found=1} END {exit !found}' /usr/share/systemd/kbd-model-map 2>/dev/null; then
  echo "  FAIL: the greeter follows localectl, which says '${greeter:-<unset>}'," \
       "not '$console'. Fix with: localectl set-x11-keymap $console"
  fail=1
fi

if ! command -v swaymsg >/dev/null || ! swaymsg -t get_version >/dev/null 2>&1; then
  echo "session layout   : (no compositor; cannot check)"
  exit "$fail"
fi

# Report EVERY keyboard, not just the first: sway applies input rules per
# device, and a rule scoped to one identifier leaves the others on the default.
XKB_LST=/usr/share/X11/xkb/rules/evdev.lst
expected=$(awk -v want="$greeter" '/^! layout/{f=1;next} /^!/{f=0}
                                   f && $1==want {$1=""; sub(/^ +/,""); print; exit}' \
           "$XKB_LST" 2>/dev/null)
if [ -z "$expected" ]; then
  echo "  FAIL: '$greeter' is not a layout xkb knows ($XKB_LST)"
  fail=1
  expected="<unknown>"
fi
printf 'expected name    : %s\n' "$expected"

mapfile -t layouts < <(swaymsg -t get_inputs | python3 -c '
import json, sys
for d in json.load(sys.stdin):
    if d.get("type") == "keyboard":
        names = d.get("xkb_layout_names") or ["<none>"]
        print(d["identifier"], "|", ",".join(names))')

printf 'session keyboards: %d\n' "${#layouts[@]}"
for l in "${layouts[@]}"; do
  id=${l%% |*}; name=${l#*| }
  # AGREEMENT, not a particular layout.
  #
  # This asserted "English (UK)" by name, which made the machine's own choice
  # into the rule: changing the layout from the settings panel would have
  # failed the suite for doing exactly what it was asked. The invariant is that
  # the three places agree, and the console's KEYMAP is the one to agree with,
  # because it is the one set first and the one a rescue shell uses.
  #
  # The expected description is looked up in xkb's own table rather than
  # written here, so ninety-nine layouts are not ninety-nine chances to be
  # wrong.
  case "$name" in
    *"$expected"*) printf '  ok   %-34s %s\n' "$id" "$name" ;;
    *) printf '  FAIL %-34s %s (expected %s, for keymap %s)\n' \
              "$id" "$name" "$expected" "$console"; fail=1 ;;
  esac
done

if [ "$fail" -ne 0 ]; then
  echo
  echo "The console and the session disagree, or a device kept the xkb default."
  echo "Console keymap is '$console'."
fi
exit "$fail"
