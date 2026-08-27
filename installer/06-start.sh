#!/usr/bin/env bash
# Stage 6 — start the agents, and check they actually came up.
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS="$(agent_names)"

# THE WATCHDOG IS NOT OPTIONAL, and shipping the fleet without it was an
# oversight caught by the operator asking whether everything had made it in. The
# unit file itself says "a dead agent reports active forever — the honest check
# is the watchdog", and then the watchdog was not installed. Documentation
# pointing at a thing that does not exist is worse than no documentation.
# VERSION THE STATE, hourly. Rules, identities, ticket database — all text or
# small SQLite, so git gives a restore point AND the history of who changed
# what. Allowlist rather than ignore-list, so a new file is excluded by default
# and the failure mode is "missing" rather than "leaked". Secrets deliberately
# excluded: tokens are re-issuable, and copying them creates a second place to
# leak from.
step "state backup"
install -m 750 "$HERE/templates/state-backup.sh" "$HOME/.fleet/bin/state-backup.sh"
install -m 644 "$HERE/templates/state-backup.service" "$HOME/.config/systemd/user/state-backup.service"
install -m 644 "$HERE/templates/state-backup.timer"   "$HOME/.config/systemd/user/state-backup.timer"
systemctl --user daemon-reload 2>/dev/null
systemctl --user enable --now state-backup.timer >/dev/null 2>&1 \
  && ok "state versioned hourly into ~/.fleet/state (restore is verified on every run)" \
  || warn "state backup installed but the timer would not start — run ~/.fleet/bin/state-backup.sh by hand"

step "acceptance suite"
# CLAUDE.main.md tells the main agent to run ~/.fleet/tests/acceptance.sh and
# loop until green. Nothing ever put it there — the suite only ever existed at
# a path relative to this repo checkout, so on a real install the thing the
# install is meant to be validated against was simply absent. Installed here,
# not vendored elsewhere, because it needs installer/lib.sh's helpers
# alongside it at the same relative layout acceptance.sh already expects.
mkdir -p "$HOME/.fleet/tests" "$HOME/.fleet/installer"
install -m 750 "$HERE/tests/acceptance.sh" "$HOME/.fleet/tests/acceptance.sh"
install -m 640 "$HERE/installer/lib.sh"    "$HOME/.fleet/installer/lib.sh"
check "acceptance suite installed" test -x "$HOME/.fleet/tests/acceptance.sh"

step "watchdog"
install -m 750 "$HERE/templates/fleet-watchdog.sh" "$HOME/.fleet/bin/fleet-watchdog.sh"
mkdir -p "$HOME/.config/systemd/user"
install -m 644 "$HERE/templates/fleet-watchdog.service" "$HOME/.config/systemd/user/fleet-watchdog.service"
install -m 644 "$HERE/templates/fleet-watchdog.timer"   "$HOME/.config/systemd/user/fleet-watchdog.timer"
systemctl --user daemon-reload 2>/dev/null
if systemctl --user enable --now fleet-watchdog.timer >/dev/null 2>&1; then
  ok "watchdog running every 10 minutes — it repairs dead agents and reports what it cannot fix"
else
  warn "watchdog installed but the timer would not start — run it by hand: ~/.fleet/bin/fleet-watchdog.sh"
fi


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
say "  Now run the acceptance checks:  ~/.fleet/tests/acceptance.sh"
exit 0
