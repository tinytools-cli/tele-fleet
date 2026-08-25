#!/usr/bin/env bash
# Start one agent: its own working directory, its own Telegram bot, its own
# state directory. Generic — every user-specific value comes from fleet.conf.
set -uo pipefail
name="${1:?usage: start-agent.sh <name>}"
case "$name" in *[!a-z0-9-]*|""|.|..) echo "bad agent name: $name" >&2; exit 2 ;; esac

FLEET_CONF="${FLEET_CONF:-$HOME/fleet.conf}"
DIR="$HOME/Projects/$name"
STATE="$HOME/.claude/channels/telegram-$name"
TOKEN="$HOME/.fleet/secrets/telegram-$name.env"
SESSION="agent-$name"

[ -d "$DIR" ]   || { echo "no agent directory: $DIR" >&2; exit 1; }
tmux has-session -t "$SESSION" 2>/dev/null && { echo "$SESSION already running"; exit 0; }

# THE SEPARATE STATE DIR IS THE WHOLE POINT. The Telegram plugin defaults to
# ONE shared directory, so two bots would share access.json, messages.db and —
# fatally — data/telegram.lock. One polls; the other looks healthy while
# silently dropping every inbound message.
mkdir -p "$STATE/data"; chmod 700 "$STATE"

# A reboot always leaves a lock behind, and a stale one makes the new server
# start in MCP-only mode: tools present, polling skipped, inbound dead. That
# failure reports as healthy everywhere else.
lock="$STATE/data/telegram.lock"
if [ -f "$lock" ]; then
  pid="$(tr -dc '0-9' < "$lock")"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then rm -f "$lock"; fi
fi

env_files=""
[ -r "$TOKEN" ] && env_files=". '$TOKEN' && "
tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  "cd '$DIR' && export TELEGRAM_STATE_DIR='$STATE' && export TIX_AGENT='$name' && \
   set -o allexport && ${env_files}set +o allexport && exec claude"
echo "started $SESSION (dir=$DIR)"
