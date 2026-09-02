#!/usr/bin/env bash
# Structural check: exactly one component may name a package manager.
#                   (NULL.md §9.1, §10.6)
#
# The abstraction is only real if it is checked. Without this, the second
# component to want a package is the one that types the package manager's name
# directly, and the distribution stops being a parameter -- silently, and in a
# way nobody notices until a second distribution is attempted.
#
# THIS FILE IS EXEMPT AND SO IS THE COMPONENT ITSELF. The exemption is narrow
# and listed explicitly below rather than being a broad pattern, because an
# exemption that grows is an abstraction that has already gone.

set -euo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd)
cd "$ROOT"

# The one component permitted to name a package manager, plus this checker.
EXEMPT_PATHS='^(bin/pkg|lib/pkg/|verify/check-package-abstraction\.sh|packages/)'

# Names to look for, as whole words.
MANAGERS='dnf|dnf5|yum|rpm|pacman|apt|apt-get|aptitude|zypper|emerge|xbps-install|apk|portage'

scan() {
  local target=${1:-.}
  git -C "$ROOT" ls-files -- "$target" 2>/dev/null \
    | grep -Ev "$EXEMPT_PATHS" \
    | while IFS= read -r f; do
        [ -f "$f" ] || continue
        case $f in *.md) continue ;; esac   # prose may discuss them
        grep -nEH "\\b($MANAGERS)\\b" -- "$f" || true
      done
}

violations=$(scan | grep -v '^$' || true)

if [ -n "$violations" ]; then
  printf 'FAIL: a package manager is named outside the package abstraction\n\n'
  printf '%s\n' "$violations" | sed 's/^/  /'
  printf '\nAdd a verb to bin/pkg instead. See NULL.md §9.1.\n'
  exit 1
fi

printf 'PASS: no package manager named outside bin/pkg and lib/pkg/\n'
