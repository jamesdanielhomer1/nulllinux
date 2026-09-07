#!/usr/bin/env bash
# THE FILE THE SPEC HAS BEEN CLAIMING EXISTS.
#
# packaging/nulllinux.spec said, above its Requires block:
#
#     # Runtime. Kept in step with packages/fedora/base.list by
#     # verify/check-package-list.sh, so the two cannot drift.
#
# and there was no verify/check-package-list.sh. The two drifted -- `cava` was
# added to the list and not to the spec, so an ISO booted into a desktop whose
# spectrum said "cava did not start" -- and bin/null-package was then taught to
# REGENERATE the Requires block from the list, which is the better fix.
#
# The spec's comment was never corrected, so it went on naming a file that had
# never existed. This is that file, and it now checks the thing the comment
# always said was checked.
#
# WHY IT STILL MATTERS, given that null-package regenerates. A regenerated spec
# is only correct after somebody runs null-package. The spec in the tree is
# what a reader believes, what a distribution packager would build from, and
# what `rpmspec -q` reports -- and between an edit to base.list and the next
# package build it says something false. Seven firmware packages were in that
# state while this was written.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

LIST=packages/fedora/base.list
SPEC=packaging/nulllinux.spec
[ -r "$LIST" ] || { note "$LIST is gone"; exit 1; }
[ -r "$SPEC" ] || { note "$SPEC is gone"; exit 1; }

# THE LIST, READ EXACTLY AS bin/null-package READS IT.
#
# Two rules, and getting either wrong makes this check lie:
#
#   a line containing `build-only` is excluded -- rust, cargo, the -devel
#     headers and numpy build the tree and are not needed to run it
#   EVERY token before the `#` counts, not the first. One line is `grim slurp`,
#     and a reader that takes only the first word loses slurp. That exact bug
#     is already recorded in docs/STATUS.md as one of the four that stopped the
#     bootstrap working, and the first version of THIS file reproduced it --
#     reporting slurp as required-but-undeclared when the line declaring it was
#     right there.
want=$(python3 - "$LIST" <<'PY'
import sys
out = []
for ln in open(sys.argv[1]):
    if "build-only" in ln:
        continue
    out += ln.split("#")[0].split()
print("\n".join(sorted(set(out))))
PY
)
# THE SAME COLLATION ON BOTH SIDES, or comm refuses. python sorts by codepoint
# and `sort` sorts by the locale, and mixing them produced "file 1 is not in
# sorted order" and two completely wrong lists -- every package reported as
# both missing and extra.
want=$(printf '%s\n' "$want" | LC_ALL=C sort -u)
# The spec's runtime Requires. BuildRequires is a different question and is
# deliberately not compared: rust and cargo belong on a build host and nowhere
# near an installed machine.
have=$(grep -E '^Requires: +' "$SPEC" | sed -E 's/^Requires: +//' | awk '{print $1}' | LC_ALL=C sort -u)

missing=$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))
extra=$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))

if [ -n "$missing" ]; then
  note "declared in $LIST and NOT required by the package:"
  printf '%s\n' "$missing" | sed 's/^/      /'
  note "      an install would not get these. Run bin/null-package to regenerate."
  fail=1
fi
if [ -n "$extra" ]; then
  note "required by the package and NOT in $LIST:"
  printf '%s\n' "$extra" | sed 's/^/      /'
  note "      the list is meant to be the single statement of what this needs"
  fail=1
fi
[ $fail = 0 ] && note "ok    $(printf '%s\n' "$want" | grep -c .) packages, and the spec asks for exactly those"

# AND THE SPEC MAY NOT NAME A CHECK THAT DOES NOT EXIST. That is how this
# started: a comment describing a guarantee nothing provided.
while IFS= read -r ref; do
  [ -e "$ref" ] || { note "$SPEC names $ref, which does not exist"; fail=1; }
done < <(grep -oE 'verify/[a-z0-9-]+\.(sh|py)' "$SPEC" | sort -u)

# The regenerator has to keep working, too: it finds the Requires block by
# pattern, and a spec reformatted by hand could silently stop matching.
grep -q 'could not find the Requires block to regenerate' bin/null-package \
  || { note "bin/null-package no longer reports a failure to regenerate the Requires block"; fail=1; }

# AND WHAT SHIPS IS WHAT THE GENERATOR WOULD WRITE TODAY.
#
# assets/prebuilt/ is generated, not committed, and it is what the RPM carries.
# bake/make_boot_assets.py was changed to write `Font=Terminus 12` where it had
# written Cantarell; system/plymouth-theme picked that up and
# assets/prebuilt/boot/plymouth-theme -- the copy an installed machine actually
# boots -- did not, because nobody re-ran the generator. Every installed
# nullLinux declared a typeface this system does not ship, and
# verify/check-one-typeface.sh passed throughout, because it read config/ and
# system/ and never the artefact.
#
# REGENERATED AND COMPARED, not dated. The first version of this compared the
# generator's commit time against the output's mtime and reported two files
# stale whose contents were perfectly correct -- a regenerated file can easily
# be older than the commit that regenerated it. Asking what the generator would
# write today is the only question with a true answer.
#
# The TEXT outputs only. The images are a deterministic render whose
# reproducibility the bake already checks, and comparing them here would mean
# re-rendering 32 frames to answer a question about a config file.
if [ -d assets/prebuilt/boot ] && command -v python3 >/dev/null 2>&1; then
  gtmp=$(mktemp -d)
  if python3 bake/make_boot_assets.py --out "$gtmp" >/dev/null 2>&1; then
    drift=0
    for rel in plymouth-theme/nullLinux.plymouth sddm-theme/Main.qml; do
      [ -r "$gtmp/$rel" ] || continue
      for where in system assets/prebuilt/boot; do
        [ -r "$where/$rel" ] || continue
        if ! cmp -s "$gtmp/$rel" "$where/$rel"; then
          note "$where/$rel is not what bake/make_boot_assets.py writes now:"
          diff "$where/$rel" "$gtmp/$rel" 2>/dev/null | head -6 | sed 's/^/        /'
          drift=$((drift+1))
        fi
      done
    done
    if [ "$drift" -gt 0 ]; then
      note "      run bin/null-prebake -- an installed machine boots the stale copy"
      fail=1
    else
      note "ok    the shipped boot and greeter themes are what the generator writes"
    fi
  else
    note "(the boot asset generator would not run here; the shipped themes are not compared)"
  fi
  rm -rf "$gtmp"
fi

[ $fail = 0 ] && echo "PASS: the package asks for exactly what the list declares"
exit $fail
