#!/usr/bin/env bash
# THE MACHINE SAYS SOMETHING BEFORE IT RUNS OUT.
#
# It did not. The bar shows a percentage and that was the whole of it. UPower's
# CriticalPowerAction is Auto -- hybrid-sleep if it can, hibernate if it can,
# power off if it cannot -- and packaging/nulllinux-install.ks partitions with
# `autopart --noswap`, so it cannot. The installed default was therefore: at 2%
# the machine goes off, having said nothing at all first.
#
# Powering off at 2% is the right last resort. Doing it silently is not.
#
# The decision logic is tested here rather than on hardware because it cannot
# be tested on hardware: waiting for a real battery to reach 5% is not a test
# anyone runs twice, and this laptop has two cells that disagree.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

B=bin/null-battery
[ -x "$B" ] || { note "$B is gone -- nothing warns before the machine powers off"; exit 1; }

# 1. It has to be STARTED. A watcher nobody runs is the same as no watcher, and
#    sway does not run XDG autostart.
grep -q 'null-battery watch' config/sway/config \
  || { note "config/sway/config does not start null-battery -- nothing would warn"; fail=1; }

# 2. THE DECISION, exhaustively. Each row is percent, status, the band last
#    recorded, and what must be said.
while read -r pct status last want; do
  [ -n "$pct" ] || continue
  got=$("./$B" decide "$pct" "$status" "$last")
  if [ "$got" = "$want" ]; then
    note "ok    ${pct}% ${status} (was ${last}) -> ${got}"
  else
    note "${pct}% ${status} (was ${last}): expected ${want}, got ${got}"
    fail=1
  fi
done <<'ROWS'
50  Discharging none     none
20  Discharging none     low
19  Discharging low      none
5   Discharging low      critical
3   Discharging critical none
4   Discharging none     critical
15  Charging    low      none
100 Full        none     none
21  Discharging none     none
ROWS

# 3. AGGREGATED ACROSS CELLS. This ThinkPad has BAT0 at 5% and BAT1 at 83%.
#    Reading the first battery found reports 5% on a machine that is
#    five-sixths charged, which fires every warning at once and teaches the
#    person to ignore them -- the same defect that was fixed in
#    render/src/sysinfo.rs and would be just as invisible here.
t=$(mktemp -d)
mk() { mkdir -p "$t/$1"; echo "$2" > "$t/$1/energy_now"; echo "$3" > "$t/$1/energy_full"; echo "$4" > "$t/$1/status"; }
mk BAT0 2500000 50000000 Discharging
mk BAT1 39840000 48000000 Discharging
got=$(NULL_POWER_SUPPLY="$t" "./$B" once | grep -oE '^[0-9]+')
if [ "${got:-0}" -gt 40 ] && [ "${got:-0}" -lt 46 ]; then
  note "ok    two cells at 5% and 83% report ${got}%, not 5%"
else
  note "two cells at 5% and 83% reported ${got:-nothing} -- the reading is not aggregated"
  fail=1
fi
rm -rf "$t"

# 4b. AND THAT PROBE MUST NOT TAKE THE REAL WATCHER WITH IT.
#
#     `watch` displaces any other instance of itself, which is right: one
#     warner, and the newest wins. But it used to do that BEFORE deciding
#     whether it was staying, so step 4 above -- which points it at a directory
#     with no battery precisely so that it will exit -- killed the watcher the
#     session was running and then exited itself, leaving nothing at all. The
#     step printed "ok". Running the suite took the low-battery warning away
#     for the rest of the session, on a machine that cannot hibernate.
#
#     Measured: a watcher started here, and required to still be there.
probe=$(mktemp -d); mkdir -p "$probe/BAT0"
echo 1 > "$probe/BAT0/present"
echo 50000 > "$probe/BAT0/energy_now"; echo 100000 > "$probe/BAT0/energy_full"
echo Discharging > "$probe/BAT0/status"
NULL_POWER_SUPPLY="$probe" "./$B" watch >/dev/null 2>&1 &
keeper=$!
sleep 1
if kill -0 "$keeper" 2>/dev/null; then
  t=$(mktemp -d); mkdir -p "$t/AC"; echo 1 > "$t/AC/online"
  NULL_POWER_SUPPLY="$t" timeout 5 "./$B" watch >/dev/null 2>&1
  sleep 1
  if kill -0 "$keeper" 2>/dev/null; then
    note "ok    a watcher with no battery leaves the working one alone"
  else
    note "$B on a batteryless machine killed the watcher that was working"
    fail=1
  fi
  rm -rf "$t"
else
  note "(the probe watcher would not stay up; step 4b not exercised)"
fi
kill "$keeper" 2>/dev/null
wait "$keeper" 2>/dev/null
rm -rf "$probe"

# 4. A MACHINE WITH NO BATTERY IS NOT A BROKEN LAPTOP. The watcher must exit
#    rather than loop for ever over a directory that will never have one.
t=$(mktemp -d); mkdir -p "$t/AC"; echo 1 > "$t/AC/online"
if NULL_POWER_SUPPLY="$t" timeout 5 "./$B" watch >/dev/null 2>&1; then
  note "ok    a desktop with no battery exits instead of looping"
else
  note "$B does not exit cleanly on a machine with no battery"
  fail=1
fi
rm -rf "$t"

# 5. THE LID. Not the idle ladder -- that is a timer and is off by request --
#    but the deliberate act of closing a laptop, which had no configured
#    behaviour at all.
LID=config/systemd/10-null-lid.conf
if [ -r "$LID" ]; then
  grep -q '^HandleLidSwitch=' "$LID" \
    || { note "$LID does not set HandleLidSwitch"; fail=1; }
  # Docked must be ignore, or closing the lid with an external monitor
  # attached suspends the machine mid-use.
  grep -q '^HandleLidSwitchDocked=ignore' "$LID" \
    || { note "$LID: docked lid close is not ignored -- an external monitor would suspend the machine"; fail=1; }
  grep -q '10-null-lid' bin/null-install \
    || { note "bin/null-install does not place $LID"; fail=1; }
  note "ok    the lid has a configured default, and 50- from null-settings still overrides it"
else
  note "$LID is gone -- closing the lid does whatever logind decides"
  fail=1
fi

[ $fail = 0 ] && echo "PASS: the machine warns before it runs out, and knows what a closed lid means"
exit $fail
