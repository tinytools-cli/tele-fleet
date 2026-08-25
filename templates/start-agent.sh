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

# TWO FIRST-RUN PROMPTS BLOCK STARTUP COMPLETELY, and they do it invisibly:
# Claude sits waiting, no messaging server starts, no polling happens — while
# the service manager reports the unit active. On the machine this came from,
# four agents sat like that and were only found because a human noticed.
#
# Auto-answered because neither is a real security decision HERE: the folder is
# one this installer just created, and the "external import" is the operating
# rules file it just wrote. Matching is on the EXACT prompt text — never a
# blanket "press 1 at anything", which is how an agent ends up agreeing to
# something nobody read. Anything else is left alone and reported.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 2
  pane="$(tmux capture-pane -t "$SESSION" -p 2>/dev/null)" || break
  case "$pane" in
    *"Yes, I trust this folder"*)
      tmux send-keys -t "$SESSION" 1 Enter 2>/dev/null
      echo "  answered the trust-this-folder prompt (we created this directory)" ;;
    *"Yes, allow external imports"*)
      tmux send-keys -t "$SESSION" 1 Enter 2>/dev/null
      echo "  answered the external-imports prompt (the import is your own rules file)" ;;
    *) : ;;
  esac
done
