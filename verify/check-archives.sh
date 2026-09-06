#!/usr/bin/env bash
# THE ARCHIVE FORMATS THIS SYSTEM OFFERS TO OPEN CAN BE OPENED.
#
# xarchiver is declared, is themed, appears in the file manager's context menu
# through thunar-archive-plugin, and is what bin/null-open hands an archive to.
# All of that was true while "Extract here" on a .tar.gz did nothing at all,
# because xarchiver is a FRONT END: its binary names `tar` 45 times and `zip`
# 40, and neither was installed. `unzip` had arrived through somebody else's
# dependency and `zip` had not, so the system could open a zip and not make one.
#
# NO EXISTING CHECK COULD SEE IT. check-declared-providers reads the first
# choice of each null-open role and the compositor's exec lines -- and xarchiver
# IS declared. What xarchiver *runs* is a second layer, invisible to a check
# that looks at what this system names.
#
# So this checks the FORMAT rather than the package: for each archive a person
# will actually meet, is there a declared program that can read it, and for the
# two anybody makes, one that can write it. A format with no tool is a menu
# entry that does nothing.
#
# It was found by asking a running guest what it had, which is why
# verify/in-guest.sh exists. Reading the package list cannot show an absence.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

[ -x bin/pkg ] || { note "bin/pkg is gone"; exit 1; }
DECLARED=$(./bin/pkg list-packages base 2>/dev/null | tr ' ' '\n' | sort -u)
CORE=$(./bin/pkg list-group core 2>/dev/null)
[ -n "$CORE" ] || note "(could not read @core; a tool from the base system may be reported)"

# THROUGH bin/pkg, never rpm or dnf (NULL.md 9.1).
provided() {  # <command> -> the package that gives it, or nothing
  local path; path=$(command -v "$1" 2>/dev/null) || return 1
  ./bin/pkg owner-name "$path" 2>/dev/null
}

is_declared() {  # <package>
  printf '%s\n' "$DECLARED" | grep -qix "$1" && return 0
  [ -n "$CORE" ] && printf '%s\n' "$CORE" | grep -qix "$1"
}

# format : the command that reads it : whether anybody makes one here
#
# Chosen by what a person meets, not by what a library supports. .tar.gz is
# every source release and every "extract here" on the internet; .zip is what
# arrives from anything that is not Linux; .tar.xz is Fedora's own packages and
# most kernel-adjacent downloads.
check_format() {  # <description> <reader command> <writes?>
  local what=$1 cmd=$2 writes=${3:-}
  local pkg
  if ! pkg=$(provided "$cmd") || [ -z "$pkg" ]; then
    # Not installed HERE. On a build host that is a finding about the list, not
    # about this machine, so say which it is.
    if printf '%s\n' "$DECLARED" | grep -qix "$cmd"; then
      note "($what: $cmd is declared but not installed on this machine)"
    else
      note "$what needs '$cmd', which is neither installed here nor declared"
      note "      xarchiver would show the archive and extract nothing"
      fail=1
    fi
    return
  fi
  case $pkg in *'not owned'*) note "($what: $cmd is not owned by any package here)"; return ;; esac
  if is_declared "$pkg"; then
    note "ok    $what: $cmd, from '$pkg'${writes:+  (and can create one)}"
  else
    note "$what relies on '$cmd' from '$pkg', which is neither declared nor in @core"
    note "      it is here only because something else brought it"
    fail=1
  fi
}

check_format ".tar, .tar.gz, .tar.xz"  tar   yes
check_format ".zip (reading)"          unzip
check_format ".zip (creating)"         zip   yes
check_format ".gz"                     gzip
check_format ".xz"                     xz
check_format ".bz2"                    bzip2

# AND THE FRONT END ITSELF, which is the thing the menu entry names.
check_format "the archive window"      xarchiver

# THE FRONT END REALLY DOES SHELL OUT, which is the whole reason the layer
# below it has to be declared. Read from the binary rather than asserted: if a
# future xarchiver linked libarchive instead, this check should stop insisting.
if command -v xarchiver >/dev/null 2>&1; then
  x=$(command -v xarchiver)
  n=$(python3 - "$x" <<'PY' 2>/dev/null
import re, sys
b = open(sys.argv[1], "rb").read()
print(len(re.findall(rb"tar\b", b)))
PY
)
  if [ "${n:-0}" -gt 5 ]; then
    note "ok    xarchiver names tar $n times, so tar is not optional for it"
  else
    note "(xarchiver names tar ${n:-?} times; it may no longer shell out)"
  fi
fi

# AND IT CAN ACTUALLY DO IT, where the tools are here. Behavioural, because
# every statement above is about names.
if command -v tar >/dev/null 2>&1; then
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
  mkdir -p "$t/src"; echo nullLinux > "$t/src/probe.txt"
  ( cd "$t" && tar -czf a.tar.gz src ) 2>/dev/null
  ( cd "$t" && mkdir -p out && tar -C out -xzf a.tar.gz ) 2>/dev/null
  [ "$(cat "$t/out/src/probe.txt" 2>/dev/null)" = nullLinux ] \
    && note "ok    a .tar.gz made here can be read back here" \
    || { note "making and reading a .tar.gz did not round-trip"; fail=1; }
fi

[ $fail = 0 ] && echo "PASS: every archive format this system offers has a tool that opens it"
exit $fail
