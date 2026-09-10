# Terminal-adjacent chrome (NULL.md §7.6).
#
# The shell prompt, the pager and the diff viewer are looked at more than any
# window. They are CHROME: they belong in the palette and they are ASCII-only.
#
# These tools default to icon-font glyphs and powerline separators, which are
# pictograms from private-use codepoints that this font does not have and
# cannot have. Nothing here draws one, and the gate is that each was verified
# by RUNNING it and reading the codepoints -- never by reading its config.

# Derived from this file's own location, not a literal: the checkout moves
# when the session moves off root, and a baked-in path follows nothing.
[ -n "${NULL_ROOT:-}" ] || NULL_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../.." && pwd)
. "$NULL_ROOT/config/shell/colours.sh"

# --- the prompt --------------------------------------------------------
#
# name + value, no pictograms (§7.1). A separator drawn out of punctuation is
# a second icon set: it is no more legible than the first and considerably
# more obscure, so there isn't one. The host is dim because it is chrome; the
# path is the reading, so it takes ink.
#
# $? is shown ONLY when it is non-zero, and as a number rather than a coloured
# symbol -- a symbol that means "something failed" without saying what is a
# readout that has to be explained.
__null_branch() {
    local b
    b=$(git symbolic-ref --short HEAD 2>/dev/null) || return 0
    printf ' (%s)' "$b"
}
__null_prompt() {
    # $? MUST be captured on the very first line. Anything before it -- a
    # local, a test, a function call -- replaces it with its own status, and
    # the failure the prompt exists to report is silently lost. The first
    # version read it inside a helper and always reported success.
    local code=$?
    local st="" br
    [ "$code" -ne 0 ] && st=" $code"
    br=$(__null_branch)
    PS1="${NULL_DIM}\h${NULL_RESET} ${NULL_NEUTRAL}\w${NULL_RESET}"
    [ -n "$br" ] && PS1+="${NULL_LINE}${br}${NULL_RESET}"
    [ -n "$st" ] && PS1+="${NULL_ERROR}${st}${NULL_RESET}"
    PS1+=" ${NULL_ACCENT}\$${NULL_RESET} "
}
PROMPT_COMMAND=__null_prompt

# --- the pager ---------------------------------------------------------
#
# -R passes colour through; -F quits if it fits on one screen, so a short file
# does not become a mode you have to leave; -X keeps it on screen afterwards.
# No mouse, no icons, nothing to render but text.
export LESS='-R -F -X -i --use-color'
export PAGER=less

# less draws its own emphasis through termcap. Pointed at the palette so a
# manual page is in the same colours as everything else.
export LESS_TERMCAP_md=$'\e[38;2;185;204;255m'   # accent  -- headings
export LESS_TERMCAP_me=$'\e[0m'
export LESS_TERMCAP_us=$'\e[38;2;255;177;97m'    # warning -- underline
export LESS_TERMCAP_ue=$'\e[0m'
export LESS_TERMCAP_so=$'\e[38;2;5;6;10;48;2;185;204;255m'  # the status line
export LESS_TERMCAP_se=$'\e[0m'

# --- the editor --------------------------------------------------------
#
# Set everywhere, so the version-control system, the privileged-edit wrapper
# and anything reading the environment all agree (§8.8).
# nano FIRST, deliberately. James prefers it (§ the mail/office/editor choices),
# and it is the only one themed from the palette (config/nano/nanorc via
# bake/export_theme.py). The order used to be nvim, vim, nano -- which held only
# because @core's vim-minimal provides `vi`, not `vim`; the day anything pulled in
# vim-enhanced or a user added nvim, EDITOR flipped to an UNthemed editor against
# a stated preference. nano is a declared package, so this resolves to nano; the
# rest are a fallback for a machine that somehow has none.
if command -v nano >/dev/null 2>&1; then export EDITOR=nano
elif command -v vim >/dev/null 2>&1; then export EDITOR=vim
elif command -v nvim >/dev/null 2>&1; then export EDITOR=nvim
else export EDITOR=vi; fi
export VISUAL="$EDITOR"
export SUDO_EDITOR="$EDITOR"

# --- paths -------------------------------------------------------------
case ":$PATH:" in *":$NULL_ROOT/bin:"*) ;; *) PATH="$NULL_ROOT/bin:$PATH" ;; esac
export PATH

# --- the greeting ------------------------------------------------------
#
# fastfetch when a person opens a terminal: the hero and the machine's
# particulars, themed from the palette (config/fastfetch). ASCII-only, like the
# rest of this file. Guarded so it draws once for an interactive terminal and
# never in a script, a pipe, or a nested shell -- NULL_GREETED is exported, so
# child shells inherit "already shown" while a fresh terminal starts without it.
if [[ $- == *i* ]] && [ -t 1 ] && [ -z "${NULL_GREETED:-}" ] \
   && command -v fastfetch >/dev/null 2>&1; then
  export NULL_GREETED=1
  fastfetch
fi
