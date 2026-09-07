#!/usr/bin/env bash
# Prove the structural check can FAIL.
#
# NULL.md §10.1 rule 3: a measurement where every candidate returns the same
# answer usually means the measurement is broken. A structural check that has
# never failed is indistinguishable from one that cannot fail, and the second
# kind is worse than none -- it reports success for ever.
#
# This plants a real violation, confirms the check catches it, removes it, and
# confirms the check passes again.

set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
cd "$ROOT"

PLANT=bin/__selftest_violation

# THE FIXTURE IS TRACKED IN AN ISOLATED INDEX, NEVER THE REAL ONE.
# The check reads `git ls-files`, so the planted violation must be tracked for
# it to be seen -- but doing that in the repo's real index means a concurrent
# `git add -A` (a commit running while the suite does) captures the fixture. It
# did once. So this points GIT_INDEX_FILE at a throwaway copy of the real index:
# the check (a child) inherits it and sees the fixture, while the real index --
# the one any other git command uses -- is never touched. Combined with the
# .gitignore entry, no stray add can reach it.
# THIS NEEDS A GIT CHECKOUT, and says so rather than dying.
#
# It plants a file and asks git to forget it, so on a deployed tree -- which is
# an unpacked tarball, not a repository -- git exits 128 and `set -e` takes the
# script down before it prints anything at all. A check that fails silently on
# a whole class of machine is worse than one that says it cannot run here.
if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "SKIPPED: not a git checkout, and this self-test plants and un-plants a"
  echo "         tracked file. Run it on the build host, where the repository is."
  exit 0
fi
# Resolve the REAL index path BEFORE GIT_INDEX_FILE is set -- rev-parse honours
# GIT_INDEX_FILE, so setting it first makes it resolve to itself and the copy
# becomes an empty self-copy (that bug cost a 128 and this comment).
_real_index=$(git -C "$ROOT" rev-parse --git-path index)
GIT_INDEX_FILE=$(mktemp "${TMPDIR:-/tmp}/null-selftest-index.XXXXXX")
cp "$_real_index" "$GIT_INDEX_FILE" 2>/dev/null || true
export GIT_INDEX_FILE
cleanup() { rm -f "$PLANT" "$GIT_INDEX_FILE"; }
trap cleanup EXIT

# 1. clean state must pass
if ! ./verify/check-package-abstraction.sh >/dev/null 2>&1; then
  echo "SELFTEST FAIL: check does not pass on a clean tree"; exit 1
fi

# 2. plant violations, one shape at a time, and require each to be caught.
#
# The checker deliberately IGNORES comments and the .rpm file extension, so
# that image builders can say `find -name '*.rpm'` and explain themselves. Each
# loosening is a hole unless something proves it did not swallow the real case,
# so both the must-catch and the must-not-catch shapes are listed here.
plant() { printf '%s\n' "$1" > "$PLANT"; chmod +x "$PLANT"; git -C "$ROOT" add -Nf "$PLANT" >/dev/null 2>&1; }
fails=0
must_catch() {
  plant "$2"
  if ./verify/check-package-abstraction.sh >/dev/null 2>&1; then
    echo "  MISS  $1"; fails=1
  else
    echo "  ok    catches: $1"
  fi
}
must_pass() {
  plant "$2"
  if ./verify/check-package-abstraction.sh >/dev/null 2>&1; then
    echo "  ok    ignores: $1"
  else
    echo "  FALSE POSITIVE  $1"; fails=1
  fi
}

# THE NAMES ARE SPLIT ON PURPOSE. This file's whole job is to contain package
# manager invocations, so written plainly it fails the very check it is testing
# -- and the fix must not be "exempt this file", because then a real violation
# could hide in it and because the checker's own header says an exemption that
# grows is an abstraction that has already gone. Adjacent quoted strings
# concatenate at parse time, so $DNF is exactly "dnf" at run time while the
# three letters never appear in a row on disk.
DNF="dn""f"; RPM="rp""m"; APT="apt-g""et"

must_catch "a bare invocation"                 "#!/bin/sh
$DNF install -y something"
must_catch "hidden behind a trailing comment"  "#!/bin/sh
$DNF install -y something   # install the thing"
must_catch "indented, inside a function"       "#!/bin/sh
f() {
    $RPM -qa | wc -l
}"
must_catch "a second manager entirely"         "#!/bin/sh
$APT install -y something"
must_pass  "a comment that merely mentions it" "#!/bin/sh
# $RPM hardlinks identical files, so this costs nothing
true"
must_pass  "the .$RPM file extension"          '#!/bin/sh
find /tmp -name "*.rpm" -o -name "*.src.rpm"'
must_pass  "no manager named at all"           '#!/bin/sh
echo hello'

[ $fails = 0 ] || { echo "SELFTEST FAIL: the checker does not discriminate"; exit 1; }

# 3. remove it and confirm the check recovers
cleanup
trap - EXIT
if ! ./verify/check-package-abstraction.sh >/dev/null 2>&1; then
  echo "SELFTEST FAIL: check still fails after the violation was removed"; exit 1
fi

echo "PASS: the structural check catches a planted violation and clears when it is removed"
