#!/usr/bin/env bash
# Stage 6 — start the agents, and check they actually came up.
. "$(dirname "$0")/lib.sh"
AGENTS="$(agent_names)"

started=""; skipped=""
step "starting"
for a in $AGENTS; do
  if [ ! -s "$HOME/.fleet/secrets/telegram-$a.env" ]; then
    skipped="$skipped $a"; warn "$a has no bot token — not starting it"; continue
  fi
  systemctl --user start "agent@$a.service" >/dev/null 2>&1
  started="$started $a"
done

# GIVE THEM A MOMENT, THEN CHECK THE THING ITSELF. `systemctl start` returning 0
# means the unit ran, not that an agent is alive: the unit is oneshot and exits
# immediately, so it reports success the instant tmux exists.
[ -n "$started" ] && sleep 5

step "did they actually come up?"
bad=""
for a in $started; do
  if tmux has-session -t "agent-$a" 2>/dev/null; then ok "$a is running"
  else warn "$a did NOT start"; bad="$bad $a"; fi
done

# A first-run prompt blocks startup with no messaging and no MCP server, while
# the unit still reports active. Worth naming, because the pane looks fine.
for a in $started; do
  pane=$(tmux capture-pane -t "agent-$a" -p 2>/dev/null | tail -25)
  case "$pane" in
    *"trust this folder"*|*"allow external imports"*)
      warn "$a is waiting on a first-run prompt — attach and answer it:  tmux attach -t agent-$a" ;;
  esac
done

say ""
[ -n "$skipped" ] && say "  Not started (no bot token):$skipped"
[ -n "$bad" ] && { say "  Failed to start:$bad"; say "  Look with: tmux attach -t agent-<name>"; }
[ -z "$bad" ] && [ -n "$started" ] && ok "fleet up:$started"
say ""
say "  Now run the acceptance checks:  tests/acceptance.sh"
exit 0
