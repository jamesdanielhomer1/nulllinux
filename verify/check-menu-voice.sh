#!/usr/bin/env bash
# TWO WORDING RULES THE MENUS KEEP DRIFTING PAST, made structural.
#
# The design language (docs/design-language.md) is prose, and prose does not
# fail a build. These two rules are the mechanically checkable core of it, and
# each was found violated in practice before this check existed:
#
#   1. A SPEC SECTION IS NEVER CITED ON A MENU. §-marks belong in code comments
#      and in report output (null-system, run.sh label their sections with
#      them); a picker header saying "(§8.5)" is chrome citing its own
#      documentation at somebody who asked for a timeout. Found live in two
#      null-settings headers.
#
#   2. NO BRACKET PLURALS in anything a person is shown. "3 thing(s)" is
#      neither word; the code picks one ("problem"/"problems") or rephrases.
#      Found live in null-firstrun ("thing(s)") and null-player ("player(s)").
#
# Scope: the picker surfaces (--header=, choose/say/pick_value/null_pick
# arguments) and notification bodies (notify-send) in bin/. Report tools keep
# their citations -- the grep looks only at surface-string lines.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

# Lines that put a string on a menu or a notification. Comments are stripped
# so a rule's own documentation cannot trip it.
#
# `say` is scoped to the two menu programs, where it draws a picker note. The
# CLI report tools (null-system, null-install, null-backup...) each define a
# say of their own that prints to a terminal -- that is report output, where a
# spec section is the house style (run.sh labels its own sections with them).
surface_lines() {  # <file...>
  # The two menu programs are scanned WHOLE: every non-comment line in them
  # builds or dispatches a surface, and a header string continued across lines
  # would slip a line-based grep aimed at the call site.
  { grep -nHE -- "--header=|notify-send|(^|[^a-z_])(pick_value|null_pick)[ )]" "$@" 2>/dev/null
    grep -nH '.' bin/null-menu bin/null-settings 2>/dev/null; } \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | sort -u
}

FILES=$(ls bin/null-* bin/machine bin/pkg 2>/dev/null)

# 1. spec citations on a surface
cites=$(surface_lines $FILES | grep -E '§[0-9]' || true)
if [ -n "$cites" ]; then
  note "a menu surface cites the specification at the person using it:"
  printf '%s\n' "$cites" | sed 's/^/    /'
  fail=1
else
  note "ok    no menu surface cites a spec section"
fi

# 2. bracket plurals
plurals=$(surface_lines $FILES | grep -E '[a-z]\(s\)' || true)
if [ -n "$plurals" ]; then
  note "a surface shows a bracket plural -- pick the word:"
  printf '%s\n' "$plurals" | sed 's/^/    /'
  fail=1
else
  note "ok    no surface hedges its plurals"
fi

# AND THE SCANNER STILL SEES A VIOLATION (§10.1: a check that cannot fail is
# not a check). A probe file carrying both faults must be flagged twice.
probe=$(mktemp --suffix=.sh)
cat > "$probe" <<'PROBE'
#!/usr/bin/env bash
x=$(pick_value stage "later stages are dragged with it (§8.5)")
notify-send "Setup" "$n thing(s) to look at"
PROBE
p_cites=$(surface_lines "$probe" | grep -cE '§[0-9]' || true)
p_plur=$(surface_lines "$probe" | grep -cE '[a-z]\(s\)' || true)
rm -f "$probe"
if [ "${p_cites:-0}" -ge 1 ] && [ "${p_plur:-0}" -ge 1 ]; then
  note "ok    the scanner flags a planted citation and a planted plural"
else
  note "the scanner MISSED a planted violation (cites=$p_cites plurals=$p_plur) -- it proves nothing"
  fail=1
fi

[ "$fail" = 0 ] && echo "PASS: the menus state facts, in words, without citing the spec"
exit $fail
