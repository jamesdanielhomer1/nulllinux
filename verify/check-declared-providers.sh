#!/usr/bin/env bash
# WHAT IS THIS RESTING ON THAT NOBODY DECLARED?
#
# Six things were found by hand in one evening, each present only because
# something else dragged it in, and each with a silent failure:
#
#   nftables      the firewall's own binary, arriving through four levels of
#                 Requires from the firewalld this system stopped using
#   polkit        with no agent, every privileged action fails with no prompt
#   pipewire      no sound server
#   wireplumber   pipewire runs and routes nothing, which reads as broken audio
#   nano          the editor role landed on it by luck
#   udisks2/gvfs/thunar-volman
#                 a USB stick might mount, or might do nothing
#
# A package that is not declared is a package a dependency change nobody made
# deliberately can remove.
#
# WHAT THIS DOES NOT DO, and why. verify/check-commands.py's header records an
# earlier attempt to scan the shell components for command names: 175 false
# positives out of 258 -- case labels, prose in generated files, Python inside
# heredocs. A checker at that ratio teaches people to ignore it.
#
# So this reads only sources where the intent is UNAMBIGUOUS:
#
#   * the first entry of each `first "a" "b" "c"` list in bin/null-open -- the
#     tool this system intends, the rest being fallbacks it tolerates
#   * absolute program paths the compositor execs unconditionally
#
# Everything guarded by `command -v` is deliberately excluded: a guard is a
# statement that the program is optional.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

command -v rpm >/dev/null 2>&1 || { note "(no rpm here; skipped)"; exit 0; }

DECLARED=$(./bin/pkg list-packages base 2>/dev/null | tr ' ' '\n' | sort -u)

# @core is the base every Fedora has. A command from it is not an undeclared
# dependency, it is the operating system. Fetched once; if the metadata is not
# reachable the check says so rather than inventing a verdict.
CORE=$(dnf -q group info core 2>/dev/null | sed -n 's/^ *: *//p' | tr -d ' ' | sort -u)
[ -n "$CORE" ] || note "(could not read @core; a command from the base system may be reported)"

# --- the intended tool for each role bin/null-open offers -------------------
wanted=$(grep -oE 'cmd=\$\(first "[^"]+"' bin/null-open | sed 's/.*first "//; s/".*//' | awk '{print $1}')

# --- what the session starts unconditionally --------------------------------
wanted="$wanted
$(grep -oE '^exec(_always)? [^#]*' config/sway/config | grep -oE '/usr/(bin|libexec)/[A-Za-z0-9_.-]+' | xargs -r -n1 basename)"

checked=0 unresolved=0 missing=""
for c in $(printf '%s\n' $wanted | sort -u); do
  [ -n "$c" ] || continue
  path=$(command -v "$c" 2>/dev/null) || { unresolved=$((unresolved+1)); missing="$missing $c"; continue; }
  pkg=$(rpm -qf --qf '%{NAME}\n' "$path" 2>/dev/null | head -1)
  case $pkg in ''|*'not owned'*) unresolved=$((unresolved+1)); continue ;; esac
  checked=$((checked+1))
  # CASE-INSENSITIVELY, and only here. dnf resolves package names without
  # regard to case -- base.list says `thunar` and the rpm is named `Thunar`,
  # and `dnf install thunar` installs it. That is the OPPOSITE of the rule for
  # theme directory names, where case is the name and getting it wrong falls
  # back to the light palette in silence (§8.10). Two different questions that
  # look alike; verify/check-theme-names.sh is the one that must stay strict.
  if printf '%s\n' "$DECLARED" | grep -qix "$pkg"; then
    continue
  elif [ -n "$CORE" ] && printf '%s\n' "$CORE" | grep -qix "$pkg"; then
    continue
  else
    note "$c comes from '$pkg', which is neither declared nor part of @core"
    note "    It is present here only because something else brought it."
    fail=1
  fi
done

note "$checked command(s) resolved to a package; $unresolved not installed here:$missing"
[ "$unresolved" -gt 0 ] && note "(a program this system ships but this build host does not install cannot be checked here;"
[ "$unresolved" -gt 0 ] && note " verify/vm-post-install.sh asserts the important ones on the installed guest instead)"

[ $fail = 0 ] && echo "PASS: every program this system relies on comes from a declared package"
exit $fail
