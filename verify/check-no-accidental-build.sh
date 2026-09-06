#!/usr/bin/env bash
# A MISTYPED ARGUMENT MUST NOT DESTROY HOURS OF WORK.
#
# bin/null-installer-iso rebuilds Anaconda boot media: hours of build time and
# about a gigabyte of downloads, and it `rm -rf`s the previous media first. It
# used to look at $1 for --embed-only and ignore every other argument, so
# `null-installer-iso --help` deleted the media and started lorax. It is not a
# hypothetical: that is how one build's media was lost.
#
# The same shape applies to anything else here that is expensive and
# destructive, so this checks the class rather than the one script.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

for tool in bin/null-installer-iso; do
  [ -x "$tool" ] || { note "$tool: missing or not executable"; fail=1; continue; }

  # -h must print usage and do nothing. Timeout, because "does nothing" is the
  # property under test and a regression here would hang for hours.
  out=$(timeout 20 "./$tool" --help 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    note "$tool --help exited $rc (124 = it started working instead of printing help)"
    fail=1
  elif ! printf '%s' "$out" | grep -qi '^usage:'; then
    note "$tool --help printed no usage"
    fail=1
  else
    note "ok    $tool --help prints usage and exits"
  fi

  # An argument it does not understand must be refused, not ignored.
  out=$(timeout 20 "./$tool" --definitely-not-a-real-flag 2>&1); rc=$?
  if [ $rc -eq 0 ]; then
    note "$tool accepted an unknown argument -- a typo would start a rebuild"
    fail=1
  elif [ $rc -eq 124 ]; then
    note "$tool started working when given an unknown argument"
    fail=1
  else
    note "ok    $tool refuses an argument it does not understand"
  fi

  # The rm -rf has to be guarded by something. Grepping for the guard is weak,
  # but the alternative is running a build to find out.
  if ! grep -q 'ASSUME_YES' "$tool"; then
    note "$tool: the rebuild deletes existing media with no confirmation"
    fail=1
  else
    note "ok    $tool asks before deleting boot media"
  fi
done

[ $fail = 0 ] && echo "PASS: an expensive destructive build cannot start by accident"
exit $fail
