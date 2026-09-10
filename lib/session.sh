# Identity shared by the shell components of one Wayland session.
# XDG_RUNTIME_DIR is per USER, so it cannot identify a compositor by itself.
null_session_file() {  # component suffix
  local hash
  hash=$(printf '%s\0' "$(id -u)" "${WAYLAND_DISPLAY:-wayland-0}" | sha256sum) || return
  printf '%s/%s-%s.%s\n' "${XDG_RUNTIME_DIR:-/tmp}" "$1" "${hash:0:16}" "$2"
}

null_same_session() {  # pid -- unreadable identity is never permission to kill
  local pid=$1 entry display=wayland-0 runtime=/tmp
  [[ $pid =~ ^[0-9]+$ ]] && [ -O "/proc/$pid" ] && [ -r "/proc/$pid/environ" ] || return 1
  while IFS= read -r -d '' entry; do
    case $entry in
      WAYLAND_DISPLAY=*) display=${entry#*=}; display=${display:-wayland-0} ;;
      XDG_RUNTIME_DIR=*) runtime=${entry#*=}; runtime=${runtime:-/tmp} ;;
    esac
  done < "/proc/$pid/environ" 2>/dev/null || return 1
  [ "$display" = "${WAYLAND_DISPLAY:-wayland-0}" ] && [ "$runtime" = "${XDG_RUNTIME_DIR:-/tmp}" ]
}
