#!/usr/bin/env bash
# The splash theme must carry every image two-step loads (NULL.md §9.6).
#
# THE FAILURE THIS CATCHES IS SILENT AND EXPENSIVE.
#
# plymouth's two-step plugin loads the password-prompt furniture -- lock.png,
# box.png, and the entry widget -- at show_splash_screen, BEFORE it reaches the
# animation. One missing file and the whole splash is abandoned:
#
#     two-step/plugin.c:1862  show_splash_scree: loading lock image
#     ply-boot-splash.c:553   can't show splash: No such file or directory
#     main.c:505              Could not start default splash screen,
#                             showing text splash screen
#
# What you SEE is plymouth's own grey with its built-in three-dot spinner,
# which reads as "a plain theme loaded", not "the theme was thrown away".
# Every other signal said it had worked: the theme was installed, every frame
# and the module were in the initramfs, plymouthd.conf named it, and
# plymouth-set-default-theme reported success. Only
# plymouth.debug=file:... on the kernel command line showed the truth.
#
# Fedora's own themes get these images from packages a minimal install does not
# pull in -- the spinner theme on a fresh install ships watermark.png and
# nothing else -- so this project draws its own, and this checks they are there.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
cd "$ROOT"

THEME=assets/prebuilt/boot/plymouth-theme
[ -d "$THEME" ] || { echo "SKIPPED: no $THEME -- run bin/null-prebake"; exit 0; }

fail=0

# Loaded unconditionally: any one of them missing aborts the splash.
echo "== the images two-step loads before it draws anything"
for f in lock.png box.png entry.png bullet.png; do
  if [ -s "$THEME/$f" ]; then
    printf '  ok        %-14s %s bytes\n' "$f" "$(stat -c %s "$THEME/$f")"
  else
    printf '  FAIL      %-14s MISSING -- the splash will silently become stock\n' "$f"
    fail=1
  fi
done

# Asked for by name, logged as a failure, but survivable.
echo
echo "== asked for, and survivable if absent"
if [ -s "$THEME/keyboard.png" ]; then
  printf '  ok        %-14s present\n' keyboard.png
else
  printf '  note      %-14s absent; plymouth logs a failure and carries on\n' keyboard.png
fi

echo
echo "== the animation itself"
n=$(ls "$THEME"/throbber-*.png 2>/dev/null | wc -l)
[ "$n" -gt 0 ] && printf '  ok        %s throbber frame(s)\n' "$n" \
               || { printf '  FAIL      no throbber frames -- nothing would animate\n'; fail=1; }

# The name plymouth resolves: themes/<name>/<name>.plymouth
echo
echo "== the theme file is named after its directory"
want=$(basename "$(grep -oE '/usr/share/plymouth/themes/[A-Za-z0-9._-]+' bin/null-system \
       | grep -v nulllinux | sort -u | head -1)")
if [ -s "$THEME/$want.plymouth" ]; then
  printf '  ok        %s.plymouth\n' "$want"
else
  printf '  FAIL      expected %s.plymouth, found: %s\n' "$want" \
         "$(ls "$THEME"/*.plymouth 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
  fail=1
fi

echo
[ $fail = 0 ] && echo "PASS: the splash carries everything two-step loads" \
              || echo "FAIL: the splash would be abandoned for a missing image"
exit $fail
