#!/usr/bin/env bash
# Stop hook: refuse to end a turn that did REAL WORK without recording it in tix.
#
# ROUTING ONLY. The decision, the transcript parsing and the checkpointing all
# live in `tix guard check`, which is maintained with tix itself. This works out
# which agent is stopping, points TIX_GUARD_CONF at that agent's role-conf if it
# has one, and hands over to tix's own adapter.
#
# Do not reimplement the logic here. A local copy drifts from the upstream one
# and you inherit bugs that were already fixed.
#
# FAILS OPEN everywhere: no tix, no adapter, no agent — exit 0. A guard that can
# wedge a session is worse than the discipline problem it enforces.
set -uo pipefail

TIX_DIR="${TIX_DIR:-$HOME/.local/share/tix}"
ADAPTER="$TIX_DIR/adapters/claude-code-stop-hook.sh"
if [ ! -r "$ADAPTER" ]; then
  echo "work-guard: no adapter at $ADAPTER — ticket enforcement is OFF for this session" >&2
  exit 0
fi
if ! command -v tix >/dev/null 2>&1; then
  echo "work-guard: tix not on PATH — ticket enforcement is OFF for this session" >&2
  exit 0
fi

agent="${TIX_AGENT:-}"
if [ -z "$agent" ]; then
  case "$PWD" in
    "$HOME"/Projects/*) agent="$(basename "${PWD#"$HOME"/Projects/}" | cut -d/ -f1)" ;;
    *) agent="default" ;;
  esac
fi

CONF="$HOME/.fleet/workguard/${agent}.conf"
[ -f "$CONF" ] && export TIX_GUARD_CONF="$CONF"

# stdin (the hook payload) passes straight through untouched.
exec bash "$ADAPTER"
