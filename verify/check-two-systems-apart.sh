#!/usr/bin/env bash
# THE RICE AND THE DISTRIBUTION ARE TWO SYSTEMS.
#
# `nox` was a machine that ran `/opt/rice`, a Fedora rice, and it was where
# nullLinux was developed. On 2026-09-08 nullLinux was installed onto that
# machine in place, erasing the other one; it is hostnamed `null` now. The rice
# is gone, and this check is what keeps it gone: nothing of it, and nothing of
# the build host's own identity, may ride along in the shipped tree.
#
# They shared a person, a palette's ancestry and a hostname, and nothing else.
# Every way they have leaked into each other so far has been silent:
#
#   machines/nox.conf shipped inside the package. `bin/machine` selects a
#     profile BY HOSTNAME, so any installed machine called `nox` -- which is
#     precisely the machine this is going onto -- would have found a profile
#     matching itself and used geometry measured on the build host's panel
#     instead of deriving its own.
#
# PROSE IS NOT A LEAK. The comments in this tree explain at length that nox runs
# rice and why that matters -- lib/host.sh exists for it, and
# config/sway/config records which machine an instruction was about. That
# context is the reason the separation holds. So this reads code, with
# lib/source.sh, and leaves the explanations alone.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }
[ -r lib/source.sh ] || { note "lib/source.sh is gone"; exit 1; }
. lib/source.sh

# 1. NOTHING IN THE DISTRIBUTION READS OR WRITES THE RICE.
hits=0
for f in bin/* lib/*.sh lib/pkg/* verify/*.sh bake/*.py config/sway/config packaging/*.spec packaging/*.ks; do
  [ -f "$f" ] || continue
  case $f in verify/check-two-systems-apart.sh) continue ;; esac
  if null_code_only "$f" 2>/dev/null | grep -q '/opt/rice'; then
    note "$f names /opt/rice in code, not in a comment"
    hits=$((hits+1)); fail=1
  fi
done
[ "$hits" = 0 ] && note "ok    no code in the distribution touches the rice"

# 2. NO MACHINE PROFILE IS COMMITTED.
#
#    A profile is generated from the hardware. Committing one puts a measurement
#    of a particular panel into the history of a distribution meant for any
#    panel -- and §5.7 forbids committing derived files anyway.
tracked=$(git ls-files 'machines/*.conf' 2>/dev/null)
if [ -n "$tracked" ]; then
  note "a machine profile is committed:"; printf '%s\n' "$tracked" | sed 's/^/      /'
  fail=1
else
  note "ok    no machine profile is committed"
fi

# 3. AND NONE IS PACKAGED.
if [ -r packaging/nulllinux.spec ]; then
  grep -q 'rm -f %{buildroot}%{_prefix}/%{name}/machines/\*\.conf' packaging/nulllinux.spec \
    && note "ok    the package ships the machines directory and no profile in it" \
    || { note "packaging/nulllinux.spec does not strip machines/*.conf"
         note "      an installed machine sharing the build host's name would inherit its panel"
         fail=1; }
fi

# 4. NOTHING A PERSON SEES NAMES THE DEVELOPMENT MACHINE.
#
#    Named surfaces rather than a blanket grep, because the word appears
#    legitimately all over the comments. These are the strings that reach a
#    screen.
seen=0
check_visible() {  # <file> <what it is> <extractor...>
  local f=$1 what=$2; shift 2
  [ -r "$f" ] || return 0
  local v; v=$("$@" "$f" 2>/dev/null)
  [ -n "$v" ] || return 0
  seen=$((seen+1))
  case $v in
    *nox*|*rice*)
      note "$what says '$v' -- that is the development machine, not this system"
      fail=1 ;;
    *) note "ok    $what: $v" ;;
  esac
}
title_of() { sed -n 's/.*<title>\(.*\)<\/title>.*/\1/p' "$1" | head -1; }
name_of()  { sed -n 's/^Name=//p' "$1" | head -1; }

check_visible system/plymouth-theme/nullLinux.plymouth "the boot splash's name" name_of
[ "$seen" = 0 ] && note "(no shipped surface was readable here to check its name)"

# 5. AND THE HERO IS THE DISTRIBUTION'S, NOT A MACHINE'S.
#
#    The plan once had a hero per machine -- `nox` here, `sol` elsewhere. That
#    makes the identity of the system depend on which box it was installed on.
#    §0.1 cut it; this is the part that would bring it back.
if null_code_only bin/machine 2>/dev/null | grep -qE 'hero\s*=\s*(nox|sol)\b'; then
  note "bin/machine names a per-machine hero; §0.1 cut those"
  fail=1
else
  note "ok    one hero for the distribution, not one per machine"
fi

# 6. AND A TOOL THAT WRITES INTO A PERSON'S HOME REFUSES TO DO IT ON THE
#    OTHER SYSTEM.
#
#    Run on the development machine, `null-firefox --apply` found
#    /root/.mozilla/firefox/rice -- the browser profile of the system nullLinux
#    replaces -- and would have written this distribution's chrome into it. The
#    tool is not wrong to act on the machine it runs on. It is wrong to do that
#    to a machine that is a different system.
if [ -r lib/gecko.sh ]; then
  grep -q 'null_is_nulllinux' lib/gecko.sh \
    && note "ok    the profile appliers refuse a machine that is not this system" \
    || { note "lib/gecko.sh writes into a Gecko profile without asking whose machine it is"
         fail=1; }
fi

[ $fail = 0 ] && echo "PASS: the rice and the distribution stay separate"
exit $fail
