# Reading source without reading its prose. Sourced, never executed.
#
# Checks in verify/ ask questions about the tree by grepping it, and this
# codebase explains itself at length: every file has a header saying what went
# wrong before, and those headers quote the very thing the check is looking for.
#
# Prose has fooled a check here SEVEN times, each one a different disguise:
#
#   setvtrgb named in a `say` line, read as the console palette being set
#   a banned token inside a comment
#   a check flagging its own explanation of the hazard it checks for
#   `systemctl enable firewalld.service` inside a grep PATTERN, read as an
#     invocation of systemctl
#   `modprobe` inside a note explaining why a modprobe must be tolerant
#
# Five separate files had grown their own stripper by then, each slightly
# different and each correct only about the case that had bitten it. This is
# the one, and it strips the three things that are text rather than code:
#
#   comments        -- whole-line and trailing
#   quoted strings  -- where a grep pattern and a message both live
#   here-documents  -- generated files, kickstart fragments, usage text
#
# It is deliberately crude: it is not a shell parser and does not try to be. It
# errs towards deleting too much, because a check that misses a real call is a
# bug to find, and a check that fires on a comment is a bug that teaches people
# to ignore the suite.

# null_code_only [file...]  -- or stdin. Prints what is left after the prose.
null_code_only() {
  sed -e 's/[[:space:]]*#.*$//' "$@" \
  | sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g' \
  | awk '
      # A heredoc body is data, whatever it contains. Track the delimiter and
      # drop everything up to it. Quoted and unquoted, <<- as well as <<.
      {
        if (indoc) { if ($0 ~ ("^[[:space:]]*" doc "[[:space:]]*$")) indoc = 0; next }
        line = $0
        if (match(line, /<<-?[[:space:]]*[A-Za-z_][A-Za-z0-9_]*/)) {
          d = substr(line, RSTART, RLENGTH)
          sub(/<<-?[[:space:]]*/, "", d)
          doc = d; indoc = 1
        }
        print line
      }'
}
