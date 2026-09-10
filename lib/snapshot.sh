# Snapshot / before changing it, and keep the pile bounded. Sourced, never run.
#
# bin/null-system and bin/null-install each carried a copy of the same dozen
# lines -- and neither copy ever pruned. Every --apply added a read-only
# snapshot of / to /.null-snapshots and nothing removed one, so an installed
# machine grew a snapshot per settings change for ever: thirteen on the build
# host after four days. A rollback point is worth keeping; a hundred of them is
# a full disk with no warning.
#
# The caller defines say(), $APPLY and $STAMP (both tools do) and calls
#
#     null_snapshot <label>
#
# KEEP is how many are kept, newest first, ACROSS every label: any one of them
# rolls the whole of / back, so the label is for the person reading the list,
# not for the policy. Newest is decided by the stamp in the NAME
# (YYYYMMDD-HHMMSS, which sorts as text), never by mtime.
#
# Report-first, like everything else here: with no --apply it says what it
# would snapshot and what it would prune, and touches nothing.
NULL_SNAPDIR=${NULL_SNAPDIR:-/.null-snapshots}
NULL_SNAP_KEEP=${NULL_SNAP_KEEP:-5}

# The snapshots older than the newest <n>, oldest first. Only entries that
# carry a stamp are considered, so a stray file in the directory is never
# handed to `btrfs subvolume delete`.
_null_snap_beyond() {  # <n>
  [ -d "$NULL_SNAPDIR" ] || return 0
  ls -1 "$NULL_SNAPDIR" 2>/dev/null \
    | grep -E -- '-[0-9]{8}-[0-9]{6}$' \
    | awk -F- '{ print $(NF-1) "-" $NF " " $0 }' | sort | cut -d' ' -f2- \
    | head -n -"$1"
}

null_snapshot_prune() {
  local old
  for old in $(_null_snap_beyond "$NULL_SNAP_KEEP"); do
    if btrfs subvolume delete "$NULL_SNAPDIR/$old" >/dev/null 2>&1; then
      say "pruned old snapshot: $old"
    else
      say "could not prune $old -- left in place"
    fi
  done
}

null_snapshot() {  # <label>
  local label=${1:?null_snapshot needs a label}
  if [ "$APPLY" -ne 1 ]; then
    # Once the new one exists, everything beyond the newest KEEP-1 of today's
    # set is what would go.
    local would; would=$(_null_snap_beyond $((NULL_SNAP_KEEP - 1)) | tr '\n' ' ')
    say "would snapshot / before changing anything, keep the newest $NULL_SNAP_KEEP, and prune: ${would:-nothing}"
    return 0
  fi
  command -v btrfs >/dev/null 2>&1 || { say "no btrfs tooling; skipping the snapshot"; return 0; }
  mkdir -p "$NULL_SNAPDIR"
  local snap="$NULL_SNAPDIR/$label-$STAMP"
  if btrfs subvolume snapshot -r / "$snap" >/dev/null 2>&1; then
    say "snapshot: $snap"
    say "  To recover, boot rescue media and mount the Btrfs top-level filesystem."
    say "  Locate this snapshot there and create a writable snapshot for recovery;"
    say "  update the root subvolume selection to match the installed boot layout."
    say "  Do not delete or replace the mounted root. Separate filesystems such as"
    say "  /boot and nested subvolumes are not restored by this root snapshot."
  else
    say "snapshot failed (not a btrfs subvolume?) -- continuing without one"
    return 0
  fi
  null_snapshot_prune
}
