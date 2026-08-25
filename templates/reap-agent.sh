#!/usr/bin/env bash
# Kill any Telegram server still holding this agent's state dir.
# Matching on the state dir, not on a process name: several agents run the same
# binary and killing by name would take the whole fleet down.
set -uo pipefail
name="${1:?usage: reap-agent.sh <name>}"
STATE="$HOME/.claude/channels/telegram-$name"
for pid in $(pgrep -f "server.ts" 2>/dev/null); do
  tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
    | grep -qx "TELEGRAM_STATE_DIR=$STATE" && kill "$pid" 2>/dev/null
done
exit 0
