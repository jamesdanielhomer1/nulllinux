#!/usr/bin/env bash
# Audit the bindings of the configuration that is actually installed.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." && pwd); cd "$ROOT"
CONF=${NULL_SWAY_CONFIG:-$HOME/.config/sway/config}
[ -r "$CONF" ] || CONF="$ROOT/config/sway/config"
exec python3 verify/check_binds.py "$CONF"
