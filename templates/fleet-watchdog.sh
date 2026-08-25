#!/usr/bin/env bash
# Notice when an agent has quietly died, and bring it back.
#
# THE MOST DANGEROUS FAILURE IN THIS SETUP, because everything looks green.
# agent@<name>.service is Type=oneshot + RemainAfterExit with no Restart=, so
# once tmux has ever existed the unit reports "active" FOREVER. If the agent
# inside dies, systemd keeps saying it is fine. On the machine this came from,
# four agents sat dead-and-green and were only found because a human noticed
# something felt off.
#
# So this checks the things that are actually true: a live tmux session, and a
# claude process inside it. It repairs only what is genuinely broken — a restart
# costs an agent its place in whatever it was doing, so healthy ones are left
# alone.
#
# Wire it up:  systemctl --user enable --now fleet-watchdog.timer
set -uo pipefail
FLEET_CONF="${FLEET_CONF:-$HOME/fleet.conf}"
LOG="$HOME/.fleet/watchdog.jsonl"; mkdir -p "$(dirname "$LOG")"

agents=$(sed -n 's/^AGENTS=//p' "$FLEET_CONF" 2>/dev/null | tr ',' ' ')
[ -n "$agents" ] || exit 0

alive() {  # a claude process anywhere in this pane's tree, not just in front
  local s="agent-$1" pid kids c
  tmux has-session -t "$s" 2>/dev/null || return 1
  pid=$(tmux display-message -p -t "$s:0.0" '#{pane_pid}' 2>/dev/null) || return 1
  [ -n "$pid" ] || return 1
  kids=$(pgrep -P "$pid" 2>/dev/null)
  for c in $pid $kids $(for x in $kids; do pgrep -P "$x" 2>/dev/null; done); do
    [ "$(ps -o comm= -p "$c" 2>/dev/null)" = claude ] && return 0
  done
  return 1
}

# A first-run prompt blocks startup entirely while the unit still says active.
stuck() {
  local pane; pane=$(tmux capture-pane -t "agent-$1" -p 2>/dev/null) || return 1
  printf '%s' "$pane" | grep -qE "trust this folder|allow external imports|Enter to confirm" && return 0
  # AN OPEN PANEL IS JUST AS FATAL AND LESS OBVIOUS. /status, /context and /cost
  # open a full-screen view that sits until somebody presses Escape, and the
  # agent processes nothing while it is up — unit active, session alive, simply
  # mute. Three agents sat like that for hours on the machine this came from.
  printf '%s' "$pane" | tail -8 | grep -q "Esc to cancel" \
    && ! printf '%s' "$pane" | tail -8 | grep -q "❯" && return 0
  return 1
}

bad=""
for a in $agents; do
  if stuck "$a"; then echo "$a: waiting on a prompt"; bad="$bad $a"
  elif ! alive "$a"; then echo "$a: NOT running"; bad="$bad $a"; fi
done

[ -z "$bad" ] && exit 0
printf '{"ts":%s,"unhealthy":"%s"}\n' "$(date +%s)" "${bad# }" >> "$LOG"

for a in $bad; do
  echo "  restarting $a"
  systemctl --user restart "agent@$a.service" >/dev/null 2>&1
done
sleep 8

# REPORT WHAT IS STILL WRONG AFTER TRYING. A watchdog that silently fails to fix
# things is worse than none, because it reads as coverage.
still=""
for a in $bad; do alive "$a" || still="$still $a"; done
if [ -n "$still" ]; then
  echo "STILL DOWN:$still — look with: tmux attach -t agent-<name>"
  printf '{"ts":%s,"still_down":"%s"}\n' "$(date +%s)" "${still# }" >> "$LOG"
  exit 1
fi
echo "recovered:$bad"
