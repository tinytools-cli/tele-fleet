#!/usr/bin/env bash
# Shared helpers. Sourced by every stage.
#
# TWO RULES THIS FILE EXISTS TO ENFORCE, both learned the hard way on the
# machine this was extracted from:
#
# 1. NEVER REPORT SUCCESS YOU HAVE NOT CHECKED. Every failure worth a day of
#    debugging there looked like success first: systemd reporting a dead agent
#    "active", an API returning ok on a call it rejected, a screenshot that was
#    silently half-size, a session name that resolved to nothing with exit 0.
#    So stages verify their own work and say plainly when they cannot.
# 2. NOTHING PERSONAL, EVER. No names, tokens, chat ids or paths from the
#    machine this came from. Everything user-specific is a config value.
set -uo pipefail

: "${FLEET_ROOT:=$HOME}"
: "${FLEET_CONF:=$FLEET_ROOT/fleet.conf}"

C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
[ -t 1 ] || { C_OK=; C_BAD=; C_WARN=; C_DIM=; C_OFF=; }

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s\n' "$C_DIM" "$C_OFF" "$*"; }
ok()   { printf '  %s+%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '  %sx%s %s\n' "$C_BAD" "$C_OFF" "$*" >&2; exit 1; }

# Verify, do not assume. Usage: check "<what it proves>" <command...>
check() {
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$what"; return 0; fi
  warn "FAILED: $what"; return 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# Config access. Values are written by the interview; nothing is hardcoded.
conf_get() {
  local key="$1" def="${2:-}"
  [ -r "$FLEET_CONF" ] || { printf '%s' "$def"; return; }
  local v; v=$(sed -n "s/^${key}=//p" "$FLEET_CONF" | head -1 | sed 's/^"//;s/"$//')
  printf '%s' "${v:-$def}"
}
conf_set() {
  local key="$1" val="$2"
  touch "$FLEET_CONF"; chmod 600 "$FLEET_CONF"
  if grep -q "^${key}=" "$FLEET_CONF" 2>/dev/null; then
    local tmp; tmp=$(mktemp); grep -v "^${key}=" "$FLEET_CONF" > "$tmp"; mv "$tmp" "$FLEET_CONF"; chmod 600 "$FLEET_CONF"
  fi
  printf '%s=%s\n' "$key" "$val" >> "$FLEET_CONF"
}
agent_names() { conf_get AGENTS | tr ',' ' '; }

# A name becomes a directory, a tmux session, a systemd instance and a state
# dir. Reject anything that cannot safely be all four -- much better than
# discovering it when systemd refuses the unit halfway through an install.
valid_name() {
  case "$1" in
    ""|.|..)                 return 1 ;;
    *[!a-z0-9-]*)            return 1 ;;   # lowercase, digits, hyphen only
    -*|*-)                   return 1 ;;
    *)                       [ ${#1} -le 24 ] ;;
  esac
}
