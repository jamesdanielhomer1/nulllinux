# The marker is created by the media's root service, only on a live boot.
# Requiring both signals keeps live-only behavior out of ordinary installs.
null_is_live() {
  [ -f /run/nulllinux-live ] && grep -Eq '(^|[[:space:]])rd[.]live[.]image([[:space:]]|$)' /proc/cmdline
}
