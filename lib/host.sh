# Am I the product, or the machine that builds it? Sourced, never executed.
#
# nullLinux is developed on a machine that is NOT nullLinux. nox runs /opt/rice,
# the system this one replaces, and the tree at /opt/nulllinux is a checkout on
# it. Every tool here therefore runs in two places that look alike from inside a
# shell and are not alike at all: one is a scratch machine whose state nobody
# minds, and the other is somebody's desktop.
#
# WHY THIS FILE EXISTS. Twice in one evening a test run damaged the build host:
#
#   `pkill -x sway`, typed to clear up a headless instance started for a test,
#     matched the compositor the machine was actually running and ended the
#     session
#   `null-users remove-confirmed james delete`, typed expecting a refusal,
#     deleted a real account and its home directory
#
# Neither was the shipped code misbehaving. Both were a destructive test aimed
# at the development machine because nothing stopped it going there.
#
# So: anything in verify/ that changes state OUTSIDE this repository asks first
# whether it is on a machine whose state is expendable, and says what it skipped
# when it is not. verify/check-tests-stay-off-the-host.sh enforces that.
#
# WHAT COUNTS AS EXPENDABLE:
#
#   an installed nullLinux    -- ID or NAME in /etc/os-release. The product's
#                                own machines are where the product is tested.
#   NULL_TEST_MACHINE=1       -- a deliberate, explicit statement that this box
#                                is scratch. A VM guest, a spare laptop.
#
# Everything else -- a Fedora build host, somebody's desktop, an unknown box --
# is not, and a destructive check reports that it skipped rather than running.

# Is the machine we are ON an installed nullLinux?
null_is_nulllinux() {
  [ -r /etc/os-release ] || return 1
  grep -qiE '^(ID|NAME|ID_LIKE)=.*null' /etc/os-release
}

null_host_description() {
  ( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${NAME:-unknown}}" )
}

# May this run do something to the machine that outlives it?
null_machine_is_expendable() {
  # OPT-IN ONLY. This once also returned true for any nullLinux machine, on the
  # assumption that the only nullLinux around was the disposable VM guest. That
  # stopped being true the day the build host itself became nullLinux: a daily
  # driver must NOT be expendable, or `verify/run.sh` would kill its desktop.
  # The guest opts in explicitly (verify/in-guest.sh sets NULL_TEST_MACHINE=1).
  [ "${NULL_TEST_MACHINE:-0}" = 1 ]
}

# The one place that phrases the refusal, so it reads the same everywhere and
# is one string to search the output for.
#
#   null_only_on_a_test_machine "the end-to-end format" || skip_that_part
null_only_on_a_test_machine() {  # <what would have run>
  null_machine_is_expendable && return 0
  printf '  (%s not run: this is %s, not a nullLinux test machine)\n' \
    "$1" "$(null_host_description)"
  printf '  (set NULL_TEST_MACHINE=1 if this box is scratch, or run it in the guest:\n'
  printf '   verify/in-guest.sh)\n'
  return 1
}
