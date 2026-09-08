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

    # THE PALETTE, NOT fzf's SIXTEEN.
    #
    # This was --color=16, which hands the picker fzf's own scheme -- and the
    # picker IS every menu in this system. Fifteen surfaces generated from
    # assets/palette.json, and the one the hand is on took its colours from
    # somewhere else.
    #
    # Roles, spelled as config/sway/colours.conf spells them:
    #   neutral #ffefe6 text, background #05060a ground, line #232c40 rule,
    #   accent #b9ccff selection and marks, dim #ff7800 labels.
    #
    # The current line is accent-on-background, which is what
    # theme_selected_bg_color already does in GTK -- one selection idiom, not
    # two. A match on that line is UNDERLINED rather than recoloured: a mark,
    # not a second fill (§7.1).
    --color=fg:#ffefe6,bg:#05060a,hl:#b9ccff
    --color=fg+:#05060a,bg+:#b9ccff,hl+:#05060a:underline
    --color=prompt:#ff7800,header:#ff7800,info:#ff7800
    --color=pointer:#b9ccff,marker:#b9ccff
    --color=border:#232c40,gutter:#05060a,query:#ffefe6
  )
  # Inside the column the surface has already drawn a frame with the topic set
  # into its top rule, and the picker's own border would land one cell inside
  # it. Everywhere else there is no chrome, so it draws one.
  #
  # SHARP, NOT ROUNDED. Two reasons and either would do. The design system has
  # no rounded corners anywhere -- border-radius is 0 in gtk.css, corner_radius
  # 0 in dunst, rounded_corners False in btop. And a rounded border is drawn
  # with U+256D..U+2570, which the console font does not carry: the same reason
  # btop's config gives for its own setting.
  if [ -n "${NULL_COLUMN:-}" ]; then NULL_FZF+=(--border=none)
  else NULL_FZF+=(--border=sharp); fi
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

# A CONTROL FOR WRITING A LINE, where the picker is a control for choosing one.
# Same mark and rule as every control (§7.1): the prompt is the mark, and the
# single "row" is a rule to write on, laid UNDER the prompt (--layout=reverse
# puts the prompt on top). Filtering is DISABLED so the rule stays put beneath
# the words -- the affordance is the drawing, never a header saying "type":
# rows mean pick one, a rule means write one.
#
# A default arrives already IN the field (--query), where Enter keeps it and
# typing replaces it -- visible in the control instead of named in prose.
#
# The colour overrides keep the rule a rule: fzf styles its one row as the
# current row, and without them it would sit accent-filled under the prompt
# like a selection. Roles as null_fzf_flags spells them: line #232c40 on
# background #05060a.
null_ask() {  # <prompt> [default] -> the line written; empty if none
  fzf "${NULL_FZF[@]}" --disabled --print-query --layout=reverse \
      --prompt="$1 > " --query="${2:-}" --pointer=' ' \
      --color=fg:#232c40,fg+:#232c40,bg+:#05060a \
      <<<"$(printf '\u2500%.0s' $(seq 1 24))" | head -1
}

# A PICKER FOR A LIST OF THINGS. fzf when there is a terminal for it, numbers
# when there is not, and a typed filter when the list is longer than the
# screen.
#
# It began in bin/null-installer, where every one of the comments below was
# written after watching it fail: on an anaconda console with no fzf, on a
# console with no scrollback and 598 timezones, and on a pipe with no tty at
# all. bin/null-drive then needed exactly the same control to choose a drive to
# erase, and a second copy would have started the same education again.
null_pick() {  # <prompt> <context> <default> <option>...  -- options as ARGUMENTS
  # A TERMINAL, OR THE NUMBERED FALLBACK.
  #
  # fzf needs a tty and fails with "inappropriate ioctl for device" when it does
  # not have one -- and it fails to STDERR while returning nothing, so the
  # caller sees an empty answer and reports "no disk chosen". The installer
  # would look like it had rejected a perfectly good disk. Tested for, rather
  # than assumed, because the %pre console has a tty and a test harness does
  # not.
  local prompt=$1 header=$2 def=$3; shift 3
  local -a opts=("$@")
  [ "${#opts[@]}" -gt 0 ] || return 1

  # HOW MUCH SCREEN THERE IS. A virtual console has no scrollback, so anything
  # printed past the last row is gone rather than scrolled.
  local rows
  rows=$(stty size 2>/dev/null | awk '{print $1}')
  case $rows in ''|*[!0-9]*) rows=${LINES:-24} ;; esac

  if [ -t 0 ] && [ -t 2 ] && command -v fzf >/dev/null 2>&1 && [ "$(type -t null_fzf_flags)" = function ]; then
    null_fzf_flags
    printf '%s\n' "${opts[@]}" | fzf "${NULL_FZF[@]}" --prompt="$prompt > " --header="$header" --height=14 --reverse
  else
    # OPTIONS AS ARGUMENTS, NOT ON STDIN.
    #
    # The first version read the option list from stdin with mapfile, which
    # consumed the whole pipe -- so the `read` for the answer got EOF, returned
    # nothing, and the installer reported "no disk chosen" about a disk it had
    # just listed. On a machine with fzf the bug is invisible, because fzf
    # takes the list on stdin and the answer from the terminal itself.
    # A LIST TOO LONG TO PRINT IS NOT A LIST, IT IS A WALL.
    #
    # timedatectl knows 598 timezones. Numbered one per line that is 598 lines
    # onto a console with no scrollback: the hero, every question already
    # answered, and the line promising that nothing has been written yet all
    # leave the screen, and what remains is a wall of place names ending in a
    # prompt reading [1-598]. Observed, on the first install this ISO ever ran.
    #
    # So a long list is narrowed by typing, and the numbered picker comes back
    # the moment what is left fits. Same control -- a prompt and a rule -- and
    # the answer is still chosen from the list rather than spelled out, so a
    # typo cannot become a timezone.
    local room=$((rows - 10)); [ "$room" -lt 6 ] && room=6
    if [ "${#opts[@]}" -gt "$room" ]; then
      local q; local -a hit
      hint "$header" >&2
      while :; do
        if [ -n "$def" ]; then
          printf '  %s%s%s -- %d to choose from; type part of a name [%s]: ' \
            "$C_TEXT" "$prompt" "$C_RESET" "${#opts[@]}" "$def" >&2
        else
          printf '  %s%s%s -- %d to choose from; type part of a name: ' \
            "$C_TEXT" "$prompt" "$C_RESET" "${#opts[@]}" >&2
        fi
        read -r q || return 1
        if [ -z "$q" ]; then
          [ -n "$def" ] && { printf '%s\n' "$def"; return 0; }
          continue
        fi
        # FIXED STRINGS, not a regex: somebody typing "GMT+0" or "(" should get
        # an answer, not an error about an unmatched parenthesis.
        mapfile -t hit < <(printf '%s\n' "${opts[@]}" | grep -iF -- "$q")
        if [ "${#hit[@]}" -eq 0 ]; then
          oops "nothing matches '$q'" >&2
        elif [ "${#hit[@]}" -eq 1 ]; then
          printf '%s\n' "${hit[0]}"; return 0
        elif [ "${#hit[@]}" -gt "$room" ]; then
          hint "${#hit[@]} match '$q' -- narrow it further" >&2
        else
          opts=("${hit[@]}"); break
        fi
      done
    fi

    local i=1 o
    for o in "${opts[@]}"; do printf '  %2d) %s\n' "$i" "$o" >&2; i=$((i+1)); done
    printf '  %s [1-%d] ' "$prompt" "${#opts[@]}" >&2
    local n; read -r n
    if [ -z "$n" ] && [ -n "$def" ]; then printf '%s\n' "$def"; return 0; fi
    case $n in ''|*[!0-9]*) return 1 ;; esac
    [ "$n" -ge 1 ] && [ "$n" -le "${#opts[@]}" ] || return 1
    printf '%s\n' "${opts[$((n-1))]}"
  fi
}
