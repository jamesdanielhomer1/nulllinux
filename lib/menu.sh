# Shared menu chrome (NULL.md §7.4). Sourced, never executed.
#
# Every menu is one filter-picker: name + dot leaders + value, with a dim
# context line under the prompt saying the one thing that topic can say for
# itself.
#
# The flags below each replace a DEFAULT that is a banned glyph (I1), and every
# one was found by RUNNING the picker and reading the codepoints -- never by
# reading its configuration. The gutter is the one that hides longest: it is
# the empty column beside every line that is not current, so it draws on every
# visible row at once, and a comment naming the pointer, marker and scrollbar
# is precisely the comment that omits it.

# Populates the NULL_FZF array. An ARRAY, not a string: a space-valued flag
# such as --gutter=' ' cannot survive word-splitting, and the quotes pass
# through literally -- fzf then rejects it with "gutter display width should
# be 1", which reads as fzf being fussy rather than as the quoting being wrong.
null_fzf_flags() {
  NULL_FZF=(
    --pointer='>'
    --marker='*'
    --gutter=' '
    # The spinner lives on the info line, and it is braille. §7.4 says the
    # fix for it is upstream -- and in this version it is: --info=hidden
    # removes the line the spinner draws on. The cost is the match count,
    # which is a fair trade for never drawing a banned glyph (I1).
    --info=hidden
    --no-scrollbar
    --no-mouse
    --color=16
  )
  # Inside the column the surface has already drawn a frame with the topic set
  # into its top rule, and the picker's own border would land one cell inside
  # it. Everywhere else there is no chrome, so it draws one.
  if [ -n "${NULL_COLUMN:-}" ]; then NULL_FZF+=(--border=none)
  else NULL_FZF+=(--border=rounded); fi
}

# A row: name, dot leaders, value -- so it reads as ONE thing rather than two
# columns floating apart (§7.1).
null_row() {
  local name=$1 value=$2 width=${3:-56}
  local n=${#name} v=${#value}
  local dots=$(( width - n - v - 2 ))
  [ "$dots" -lt 1 ] && dots=1
  printf '%s %s %s\n' "$name" "$(printf '.%.0s' $(seq "$dots"))" "$value"
}

# The one renderer of "no reading" (§7.1). A missing value printed four
# different ways is four different things to search for.
NULL_UNMEASURED="--"
