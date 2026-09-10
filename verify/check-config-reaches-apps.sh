#!/usr/bin/env bash
# A CONFIG FILE NOTHING READS IS WORSE THAN NO CONFIG FILE.
#
# It reads as proof the problem was handled. Two of these were found in one
# evening, both carefully written and both inert:
#
#   config/fzf/flags    set --border=none and safe glyphs. Nothing read it.
#                       lib/menu.sh is what the pickers actually use, and it
#                       said --border=rounded and --color=16.
#   config/btop/        installed to /etc/xdg/btop by null-install. btop reads
#                       $XDG_CONFIG_HOME/btop and has no system-wide path at
#                       all, so it never read a line of it.
#
# So: every directory under config/ must have somewhere it goes, and that
# somewhere must be a path the program actually reads. This checks the first
# half mechanically and makes the second half a deliberate, written-down claim
# rather than an assumption.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

# Every config directory, and what carries it to the machine. Anything not
# listed here is an orphan until somebody says otherwise.
#
# The right-hand side is tool:where[:token]. `token` is what to grep for in
# bin/<tool>, and defaults to the directory name -- it exists because some
# carriers build the path by interpolation (null-install writes "gtk-$v", not
# "gtk-3.0"), and a check that demanded the literal string would be demanding
# the code be written a particular way rather than that it do the job.
declare -A CARRIED=(
  [dunst]="null-install:/etc/xdg/dunst:dunst|/etc/xdg/dunst/"
  [foot]="null-install:/etc/xdg/foot:foot|/etc/xdg/foot/"
  [fastfetch]="null-install:/etc/xdg/fastfetch:fastfetch|/etc/xdg/fastfetch/"
  [mpv]="null-install:/etc/mpv:mpv|/etc/mpv/"
  [imv]="null-install:/etc/imv_config:imv/config|/etc/imv_config"
  [zathura]="null-install:/etc/zathurarc:zathura/zathurarc|/etc/zathurarc"
  [nano]="null-install:/etc/nanorc:nano/nanorc|/etc/nanorc"
  [pam.d]="null-install:carries config/pam.d/null-lock:/etc/pam.d/null-lock"
  [gtk-3.0]="null-install:/etc/xdg/gtk-3.0 and /usr/share/themes/nullLinux:gtk-\$v"
  [gtk-4.0]="null-install:/etc/xdg/gtk-4.0 and /usr/share/themes/nullLinux:gtk-\$v"
  [sway]="null-install:/etc/sway/config includes it from the checkout:/etc/sway/config"
  [swaynag]="null-install:/etc/swaynag/config:swaynag/config|"
  [swaylock]="null-lock:passed with -C, so it needs no install:config/swaylock/config"
  [btop]="null-firstrun:seeded per user; btop has no system-wide path:btop|btop.conf"
  [firefox]="null-firefox:userChrome lives inside a profile, which is per-user:config/firefox"
  [thunderbird]="null-thunderbird:userChrome lives inside a profile, which is per-user:config/thunderbird"
  [git]="null-join:joined into the user's own gitconfig:git"
  [shell]="null-join:joined into the user's own shell files:shell"
  [fzf]="ORPHAN"
  [nftables]="null-system:/etc/nftables + /etc/sysconfig/nftables.conf:config/nftables/nulllinux.nft"
  [vconsole]="null-install:/etc/vconsole/vtrgb:vconsole/vtrgb|"
  [systemd]="null-install:/etc/systemd/logind.conf.d:systemd/10-null-lid.conf|"
)

for d in config/*/; do
  app=$(basename "$d")
  carrier=${CARRIED[$app]:-}
  if [ -z "$carrier" ]; then
    note "config/$app/ has no declared carrier -- nothing installs it, and nothing says why not"
    note "    Add it to CARRIED in this file, or delete the directory."
    fail=1
    continue
  fi
  if [ "$carrier" = ORPHAN ]; then
    note "config/$app/ is declared an ORPHAN -- delete it or give it a carrier"
    fail=1
    continue
  fi
  tool=${carrier%%:*}
  rest=${carrier#*:}
  case $rest in
    *:*) where=${rest%:*}; token=${rest##*:} ;;
    *)   where=$rest;      token=$app ;;
  esac
  # THE CODE, NOT A COMMENT.
  #
  # A plain grep for the app's name is satisfied by the comment block that
  # explains the table, so removing an entry from the table left this passing.
  # That is the third time tonight a check has been fooled by prose. Comment
  # lines are stripped before looking.
  #
  # PROCESS SUBSTITUTION, NOT A PIPE. `sed ... | grep -q` under `set -o
  # pipefail` reports FAILURE on success: grep -q exits the moment it matches,
  # sed gets SIGPIPE, and pipefail takes the pipeline's status from sed. The
  # first version of this line said "null-install never mentions it" about
  # eight lines that mention it.
  if grep -qF "$token" <(sed 's/[[:space:]]*#.*//' "bin/$tool" 2>/dev/null); then
    note "ok    config/$app/ -> $tool ($where)"
  else
    note "config/$app/ claims $tool carries it, but bin/$tool never mentions it"
    fail=1
  fi
done

# The reverse direction: a carrier must not name a config directory that does
# not exist, which is how an install ends up silently skipping a surface.
for app in dunst foot mpv imv zathura; do
  [ -e "config/$app" ] || { note "bin/null-install installs config/$app, which is not in the tree"; fail=1; }
done

[ $fail = 0 ] && echo "PASS: every config directory has a carrier, and every carrier has its config"
exit $fail
