#!/usr/bin/env bash
# THE INSTALLER IS THIS SYSTEM'S, AND EVERYTHING IT NEEDS IS ON THE MEDIUM.
#
# nullLinux shows its own installer. anaconda does the machinery -- partitioning,
# the package transaction, the bootloader, all places where a second
# implementation would trade a real risk for an aesthetic -- but a person never
# sees an anaconda screen. bin/null-installer draws the questions in this
# system's colours beside its hero, from anaconda's own %pre, which runs on a
# console before anything is written to disk.
#
# TWO THINGS HAVE ALREADY GONE WRONG HERE and both are the same shape:
#
#   the session entry was written, wired into null-install, and never put in
#     the package -- so a fresh install had Fedora's greeter session
#   the installer was staged, named by the kickstart, and not passed to
#     mkksiso -- so the medium referenced a path it did not carry
#
# A file that is referenced and absent fails at the worst possible moment: in
# front of somebody installing an operating system.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

I=bin/null-installer
[ -x "$I" ] || { note "$I is gone -- the ISO would show anaconda"; exit 1; }

# 1. IT MUST WRITE NOTHING WHEN DECLINED. This is the whole safety property:
#    the %include of a file that was never written is what stops anaconda.
out=$(mktemp -u)
printf '1\nh\nu\nU\np\np\n1\ngb\nno\n' | "./$I" --generate "$out" --dry-run >/dev/null 2>&1
rc=$?
if [ -e "$out" ]; then
  note "declining still wrote $out -- anaconda would proceed"; fail=1; rm -f "$out"
elif [ "$rc" -eq 0 ]; then
  note "declining exited 0 -- anaconda would not know to stop"; fail=1
else
  note "ok    declining writes no file and exits non-zero"
fi

# 2. AND IT MUST WRITE A USABLE ONE WHEN CONFIRMED.
# THE DISK THE INSTALLER ITSELF WOULD OFFER, not the first one lsblk names.
#
# A raw lsblk here picked /dev/sda while the installer's filtered list offered
# /dev/nvme0n1, so the confirmation never matched and this check reported the
# installer as broken. Same filter as bin/null-installer's disks(), which is
# the only thing that makes the confirmation meaningful.
disk=$(lsblk -dnpo NAME,SIZE,MODEL,TYPE 2>/dev/null \
       | awk '$NF=="disk" { $NF=""; sub(/[ \t]+$/,""); print }' \
       | grep -vE '^/dev/(zram|nbd|loop|ram|sr|fd)[0-9]' \
       | grep -vE ' 0B( |$)' | awk '{print $1; exit}')
if [ -n "$disk" ]; then
  out=$(mktemp)
  printf '1\ntesthost\ntester\nTest Person\npw\npw\nEurope/London\ngb\n\n%s\n' "$disk" \
    | "./$I" --generate "$out" --dry-run >/dev/null 2>&1
  # `lang` is here because the installer used not to ask: the kickstart said
  # en_GB.UTF-8 and everybody got it whatever they answered.
  for want in '^clearpart ' '^autopart ' '^bootloader ' '^user --name=tester' '^rootpw --lock' '^network .*--hostname=testhost' '^lang [a-z][a-z]_'; do
    grep -qE "$want" "$out" 2>/dev/null || { note "the fragment has no line matching $want"; fail=1; }
  done
  # ROOT IS LOCKED. An installer that sets a root password creates a credential
  # that exists only because installers have always asked for one.
  grep -qE '^rootpw --lock' "$out" 2>/dev/null \
    && note "ok    the fragment locks root and puts the user in wheel" \
    || { note "root is not locked in the generated fragment"; fail=1; }
  if command -v ksvalidator >/dev/null 2>&1; then
    # The fragment alone is not a whole kickstart; validate it inside one.
    whole=$(mktemp)
    { echo 'text'; cat "$out"; echo '%packages'; echo '@core'; echo '%end'; } > "$whole"
    ksvalidator "$whole" >/dev/null 2>&1 \
      && note "ok    the fragment is valid kickstart" \
      || { note "ksvalidator rejects what null-installer writes:"; ksvalidator "$whole" 2>&1 | sed 's/^/      /'; fail=1; }
    rm -f "$whole"
  fi
  rm -f "$out"

  # 2b. AND IT MUST NOT PRINT A WALL.
  #
  #     The first install this ISO ever ran reached the timezone question and
  #     printed all 598 of them, one per numbered line, onto a console with no
  #     scrollback -- taking the hero, every answer already given and the line
  #     promising nothing had been written yet off the screen with it.
  #
  #     Measured, not asserted about the source: run the thing and count what
  #     it put on the screen.
  out=$(mktemp); screen=$(mktemp)
  printf '1\ntesthost\ntester\nTest Person\npw\npw\nEurope/London\ngb\n\n%s\n' "$disk" \
    | "./$I" --generate "$out" --dry-run >"$screen" 2>&1
  lines=$(wc -l <"$screen")
  if [ "$lines" -gt 120 ]; then
    note "the installer printed $lines lines to ask nine questions -- a console has no scrollback"
    fail=1
  else
    note "ok    nine questions cost $lines lines, not a screenful per list"
  fi
  rm -f "$out" "$screen"
else
  note "(no disk visible here; the confirmed path is not exercised)"
fi

# 3. THE ISO BUILDER MUST SHIP WHAT THE KICKSTART NAMES.
B=bin/null-installer-iso
grep -q 'stage/nulllinux-installer' "$B" \
  || { note "$B does not stage the installer"; fail=1; }
grep -q -- '-a "$stage/nulllinux-installer"' "$B" \
  || { note "$B stages the installer but never passes it to mkksiso -- the medium would reference a path it does not carry"; fail=1; }
grep -q 'nulllinux-answers.ks' "$B" \
  || { note "$B does not make the kickstart interactive"; fail=1; }
grep -q "the interactive kickstart has no %include" "$B" \
  || { note "$B does not verify the kickstart it generated"; fail=1; }

# 4. IT RUNS IN BOTH LAYOUTS. In the checkout it sits beside lib/; on the ISO
#    it is three files in one directory. Looking only in lib/ meant the medium
#    silently lost the picker styling.
grep -q 'menu.sh"; do' "$I" \
  || { note "$I looks for menu.sh in only one place -- on the ISO there is no lib/"; fail=1; }

# 5b. A CONSOLE NOBODY ELSE IS ON.
#
#     The installer drew perfectly on /dev/tty6 and then could not be answered:
#     anaconda runs a getty there, and a getty wins every keystroke. openvt
#     finds the first FREE virtual terminal -- but the runtime does not have
#     it, even though it has chvt, because lorax prunes what it installs. So it
#     is SHIPPED: 24 KB, needs only libc, same Fedora release.
grep -q 'install -m 0755 /usr/bin/openvt' "$B" \
  || { note "$B does not ship openvt -- the installer would land on a VT with a getty on it and be unanswerable"; fail=1; }
grep -q 'OPENVT=$INST/openvt' "$B" \
  || { note "$B does not prefer the shipped openvt"; fail=1; }
grep -q 'ps -o pid= -t tty6' "$B" \
  || { note "$B's fallback does not clear tty6 first, so a getty would eat the answers"; fail=1; }

# 5c. %pre DECIDES ON THE ANSWERS, NOT ON THE WRAPPER.
#
#     openvt returned 8 from a run that installed correctly. The installer has
#     no exit path that returns 8, so that status belonged to the wrapper --
#     and %pre was passing it on as its own.
grep -q 'if \[ -s /tmp/nulllinux-answers.ks \]' "$B" \
  || { note "$B's %pre reports the wrapper's exit status rather than whether the answers exist"; fail=1; }

# 5. THE HERO TRAVELS AS WHAT IT WILL BE SHOWN AS. The installer environment
#    has no renderer, no atlas and no cells file.
grep -q 'hero.ansi' "$I" \
  || { note "$I cannot use a shipped still, so the ISO installer would show only its name"; fail=1; }
grep -q 'still --frame 0 --out "$stage/nulllinux-installer/hero.ansi"' "$B" \
  || { note "$B does not render the installer's hero at build time"; fail=1; }

[ $fail = 0 ] && echo "PASS: the installer is ours, refuses safely, and travels complete"
exit $fail
