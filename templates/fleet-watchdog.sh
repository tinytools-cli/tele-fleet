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
# TWO WEDGES THAT NEED OPPOSITE TREATMENT. Both leave an agent mute with every
# process check green — and restarting is right for one and destructive for the
# other, so they must never share a label.
#
# stuck()   a FIRST-RUN PROMPT. The agent never got going and has done no work.
#           Restart is the correct fix.
# waiting() the agent is WAITING ON A HUMAN — a question menu it rendered, or a
#           full-screen panel. It is MID-TASK with work in flight. Restarting
#           throws that work away AND loses the question. Report it; never
#           "repair" it.
#
# Learned by nearly doing the wrong thing: an earlier version of this file
# treated an open panel as "stuck", which would have restarted an agent that was
# simply waiting on an answer — every ten minutes, reporting success each time.
stuck() {
  tmux capture-pane -t "agent-$1" -p 2>/dev/null \
    | grep -qE "trust this folder|allow external imports|Enter to confirm"
}

waiting() {
  local pane; pane=$(tmux capture-pane -t "agent-$1" -p 2>/dev/null) || return 1
  printf '%s' "$pane" | tail -10 | grep -q "Enter to select" && return 0
  printf '%s' "$pane" | tail -8 | grep -q "Esc to cancel" \
    && ! printf '%s' "$pane" | tail -8 | grep -q "❯" && return 0
  return 1
}

bad=""; blocked=""
for a in $agents; do
  if waiting "$a"; then
    # NOT added to $bad on purpose — this one must not be restarted.
    echo "$a: WAITING ON A HUMAN — a question or panel is open. Answer it or press Esc."
    blocked="$blocked $a"
  elif stuck "$a"; then echo "$a: stuck on a first-run prompt"; bad="$bad $a"
  elif ! alive "$a"; then echo "$a: NOT running"; bad="$bad $a"; fi
done
[ -n "$blocked" ] && printf '{"ts":%s,"waiting_on_human":"%s"}\n' "$(date +%s)" "${blocked# }" >> "$LOG"

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
