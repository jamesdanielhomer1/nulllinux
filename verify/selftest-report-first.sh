#!/usr/bin/env bash
# Does the report-first checker actually catch anything? (§10.3, §11 Phase 12)
#
# No package manager is named in this file: violations are planted through the
# abstraction (§9.1), which is the only way a component could mutate installed
# state in the first place.
#
# A verifier that has never been observed to fail is not evidence. It is a
# green tick of unknown provenance, and this project has already been bitten
# once by exactly that -- a greeter that "passed" for two rounds because a
# broken theme exits 0 and logs nothing.
#
# So violations are planted, one at a time, and the checker must reject each.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd); cd "$ROOT"
CHECK="python3 verify/check-report-first.py"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SRC=bin/null-update
fail=0

expect() {  # <expectation: pass|fail> <label> <file>
  local want=$1 label=$2 f=$3
  if $CHECK "$f" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then
    printf '  ok    %-46s (%s)\n' "$label" "$got"
  else
    printf '  FAIL  %-46s wanted %s, got %s\n' "$label" "$want" "$got"; fail=1
  fi
}

# The unmodified component must pass, or every result below is meaningless.
cp "$SRC" "$TMP/clean"; expect pass "unmodified component" "$TMP/clean"

# Each assignment on its own line. In `local a=$1 b=$a` bash expands the whole
# command line BEFORE any assignment takes effect, so $a is empty -- which made
# every planted file land on $TMP itself, awk fail, and the checker "fail" on a
# missing file rather than on the violation. Eleven tests passed having tested
# nothing, which is the exact failure this checker's docstring warns about.
plant() {  # <label> <line to inject into report_fonts>
  local label=$1
  local line=$2
  local f
  f="$TMP/plant_$(echo "$label" | tr -c 'A-Za-z0-9' '_')"
  awk -v ins="  $line" '
    /^report_fonts\(\) \{$/ {print; print ins; next} {print}' "$SRC" > "$f"
  # The planted line must actually be there, or the test is vacuous again.
  grep -qF "$line" "$f" || { printf '  FAIL  %-46s planting failed\n' "$label"; fail=1; return; }
  expect fail "$label" "$f"
}

plant "pkg upgrade"          '"$PKG" upgrade'
plant "pkg remove-orphans"   '"$PKG" remove-orphans'
plant "pkg clean-cache"      '"$PKG" clean-cache'
plant "fc-cache (no dry run)" 'fc-cache -f'
plant "rm"                   'rm -f /tmp/whatever'
plant "redirect to a file"   'echo hi > /tmp/whatever'
plant "sed -i"               'sed -i s/a/b/ /tmp/whatever'
plant "systemctl restart"    'systemctl restart sddm'
plant "gsettings set"        'gsettings set org.gnome.desktop.interface gtk-theme X'
plant "fwupdmgr update"      'fwupdmgr update'
plant "pkg install"          '"$PKG" install cowsay'
plant "btrfs subvolume delete" 'btrfs subvolume delete /snap'

# Read-only forms must NOT be flagged, or the checker becomes noise people mute.
keep() {  # <label> <line>
  local label=$1
  local line=$2
  local f
  f="$TMP/keep_$(echo "$label" | tr -c 'A-Za-z0-9' '_')"
  awk -v ins="  $line" '
    /^report_fonts\(\) \{$/ {print; print ins; next} {print}' "$SRC" > "$f"
  grep -qF "$line" "$f" || { printf '  FAIL  %-46s planting failed\n' "$label"; fail=1; return; }
  expect pass "not flagged: $label" "$f"
}
keep "pkg upgrade-available"       '"$PKG" upgrade-available >/dev/null 2>&1'
keep "pkg upgrade-count"           '"$PKG" upgrade-count >/dev/null'
keep "pkg cache-size"              '"$PKG" cache-size >/dev/null'
keep "2>/dev/null redirect"        'true 2>/dev/null'
keep "the word rm inside a string" 'echo "this mentions rm and install"'
keep "a comment mentioning rm"     '# rm -rf / would be bad'

# A file the checker cannot read must FAIL, not pass -- and must be
# distinguishable from a clean pass, which is what went wrong above.
expect fail "a file that does not exist" "$TMP/no-such-file"

# A function whose end cannot be found must be refused rather than skipped.
sed 's/^}$/  }/' "$SRC" > "$TMP/badbrace"
expect fail "unfindable function end" "$TMP/badbrace"

[ "$fail" -eq 0 ] && echo "the checker discriminates" || echo "THE CHECKER DOES NOT DISCRIMINATE"
exit "$fail"
