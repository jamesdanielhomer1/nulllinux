#!/usr/bin/env bash
# WHO IT WILL AND WILL NOT REMOVE.
#
# bin/null-users is the panel for accounts, and everything about it that matters
# is a refusal. The refusals are checked here; the account database is not
# touched, on any machine, ever -- every case below is either a name that does
# not exist or one this must decline before it acts.
#
# WHY THERE IS NO END-TO-END TEST HERE, unlike verify/check-drive.sh. A drive
# can be faked: scsi_debug makes a real removable disk out of memory and
# formatting it costs nothing. An account cannot be faked in the same way -- it
# is the machine's own /etc/passwd -- and the last attempt to test one on the
# development machine deleted a real person's account and home directory.
#
# So the account-creating path is exercised in the guest, by
# verify/vm-post-install.sh, on a machine whose whole purpose is being
# reinstalled. Here, only the refusals, which are the part that has to be right.
#
# THE VERB THAT CAUSED IT NO LONGER EXISTS. Each mutating verb used to split in
# two -- `remove` asked the questions, `remove-confirmed` did the deed under
# pkexec -- and the second was reachable from a command line, guarded by
#
#     [ "$(id -u)" = 0 ] || refuse
#
# which permits exactly the dangerous case and refuses only the harmless one.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
note() { printf '  %s\n' "$*"; }

U=bin/null-users
[ -x "$U" ] || { note "$U is gone -- accounts are useradd in a terminal again"; exit 1; }
[ -r lib/source.sh ] || { note "lib/source.sh is gone"; exit 1; }
. lib/source.sh

# 1. THERE IS NO PRE-CONFIRMED VERB. This is the whole shape of the defect: a
#    verb that does the deed, reachable without the questions.
code=$(null_code_only "$U")
if grep -qE '^\s*[a-z-]+-confirmed\)' <<<"$code"; then
  note "$U still has a pre-confirmed verb in its case statement:"
  grep -nE '^\s*[a-z-]+-confirmed\)' "$U" | sed 's/^/      /'
  note "      a verb that acts without asking is reachable from a command line"
  fail=1
else
  note "ok    no verb acts without asking"
fi

# And the guard that let it through must not come back: a test for root that
# PERMITS root is not a guard on something only root can do.
if grep -qE '\[ "\$\(id -u\)" = 0 \] \|\| \{ oops' "$U"; then
  note "$U guards a privileged action with [ id -u = 0 ] || refuse"
  note "      that permits exactly the case that can do damage"
  fail=1
fi

# 2. ROOT IS REACHED BY RE-RUNNING THE SAME VERB, so the questions are asked by
#    the process that acts.
grep -q 'need_root' "$U" \
  || { note "$U does not elevate at all, so its mutating verbs fail for an ordinary user"; fail=1; }
for verb in add passwd admin remove; do
  grep -qE "^cmd_$verb\(\) \{[[:space:]]*$" "$U" && grep -qE "need_root $verb" "$U" \
    || { note "cmd_$verb does not re-run itself as root with its own verb"; fail=1; }
done

# 3. THE REFUSALS. Every one of these names an account that either does not
#    exist or must be declined; none of them can change anything.
run() { "./$U" "$@" 2>&1; }

out=$(run remove nulllinux-no-such-person-xyz)
grep -q 'does not exist' <<<"$out" \
  && note "ok    removing somebody who is not there is refused by name" \
  || { note "removing an absent account did not say so: $out"; fail=1; }

# A system account, chosen from the machine rather than named. root is uid 0
# everywhere, and below UID_MIN by definition.
out=$(run remove root)
grep -qE 'system account' <<<"$out" \
  && note "ok    a system account is refused" \
  || { note "removing root was not refused as a system account: $out"; fail=1; }

# 4. THE LAST ADMINISTRATOR STAYS. Derived from the machine: if there is exactly
#    one member of wheel, withdrawing them must be refused. If there are none or
#    several, this cannot be exercised and says so.
admins=$(getent group wheel 2>/dev/null | awk -F: '{print $4}' | tr ',' '\n' | grep -c '^..*$')
if [ "${admins:-0}" = 1 ]; then
  only=$(getent group wheel | awk -F: '{print $4}' | cut -d, -f1)
  out=$(run admin "$only" no)
  grep -q 'only administrator' <<<"$out" \
    && note "ok    withdrawing the last administrator is refused" \
    || { note "withdrawing the only administrator ($only) was not refused: $out"; fail=1; }
else
  note "(this machine has $admins administrators; the last-admin refusal is not exercised)"
fi

# 5. UID_MIN IS READ, NOT ASSUMED. 1000 is a setting in /etc/login.defs, and a
#    machine that set it elsewhere would have this panel offering to delete its
#    daemons.
grep -q 'login.defs' "$U" \
  || { note "$U assumes where ordinary accounts start instead of reading UID_MIN"; fail=1; }

# 6. `list` AND `records` CHANGE NOTHING (§8.4), measured against the account
#    database itself rather than asserted.
before=$(getent passwd | cksum; getent group | cksum)
run list    >/dev/null 2>&1
run records >/dev/null 2>&1
run --help  >/dev/null 2>&1
after=$(getent passwd | cksum; getent group | cksum)
[ "$before" = "$after" ] \
  && note "ok    list, records and --help leave the account database untouched" \
  || { note "reading the accounts changed them"; fail=1; }

# 7. AND THE PANEL OFFERS IT.
grep -q 'null-users' bin/null-settings \
  || { note "bin/null-settings does not offer null-users"; fail=1; }

[ $fail = 0 ] && echo "PASS: accounts can be managed, and the dangerous verb cannot be reached"
exit $fail
