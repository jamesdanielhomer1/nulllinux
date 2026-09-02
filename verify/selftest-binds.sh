#!/usr/bin/env bash
# Prove the binding audit can FAIL (NULL.md §10.1 rule 3, §10.4).
#
# A check that has never failed is indistinguishable from one that cannot.
# Three planted faults, each of which the audit must catch, and a clean case it
# must pass -- otherwise the check proves nothing.

set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd); cd "$ROOT"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
CHK="python3 verify/check_binds.py"

fail=0
expect() {  # expect <want: pass|fail> <label> <file>
  local want=$1 label=$2 file=$3
  if $CHK "$file" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then
    printf '  %-46s %s (as required)\n' "$label" "$got"
  else
    printf '  %-46s %s -- EXPECTED %s\n' "$label" "$got" "$want"; fail=1
  fi
}

# 1. clean
cat > "$T/clean" <<'C'
set $mod Mod4
#: Terminal
bindsym $mod+Return exec foot
#: Close window
bindsym $mod+Shift+q kill
C
expect pass "clean config" "$T/clean"

# 2. the same chord twice
cat > "$T/dup" <<'C'
set $mod Mod4
#: Terminal
bindsym $mod+Return exec foot
#: Something else
bindsym $mod+Return exec other
C
expect fail "same chord bound twice" "$T/dup"

# 3. the same chord written with modifiers in a different order and case.
#    This is the one a naive string comparison misses.
cat > "$T/dup_order" <<'C'
set $mod Mod4
#: Move left
bindsym $mod+Shift+h move left
#: Something else
bindsym Shift+Mod4+H move right
C
expect fail "same chord, different modifier order/case" "$T/dup_order"

# 4. a binding with no description
cat > "$T/undesc" <<'C'
set $mod Mod4
#: Terminal
bindsym $mod+Return exec foot
bindsym $mod+d exec launcher
C
expect fail "binding without a description" "$T/undesc"

# 5. the same key in two different MODES is not a collision, and treating it as
#    one would make the check cry wolf until it was ignored.
cat > "$T/modes" <<'C'
set $mod Mod4
#: Resize
bindsym $mod+r mode "resize"
mode "resize" {
#: Grow
    bindsym $mod+r resize grow width 10px
}
C
expect pass "same key in two modes is not a collision" "$T/modes"

# 6. a binding hidden behind an include must still be audited
mkdir -p "$T/inc"
cat > "$T/inc/extra.conf" <<'C'
#: Hidden duplicate
bindsym $mod+Return exec sneaky
C
cat > "$T/included" <<C
set \$mod Mod4
#: Terminal
bindsym \$mod+Return exec foot
include $T/inc/*.conf
C
expect fail "duplicate hidden behind an include" "$T/included"

exit $fail
