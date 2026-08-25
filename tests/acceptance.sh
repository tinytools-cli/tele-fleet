#!/usr/bin/env bash
# Does this install actually WORK — not "did the installer finish".
#
# Every check here asks whether the thing DOES ITS JOB, because on the machine
# this came from, each of these looked healthy while being broken:
#   a service manager reporting a dead agent "active"
#   an agent process running with its message polling silently dead
#   a saved bot token that Telegram had never accepted
#   a guard that accepted reading the board as evidence of writing to it
#
# Run it as often as you like; it changes nothing.
#   tests/acceptance.sh            all checks
#   tests/acceptance.sh --quiet    only failures (for a fix-and-retry loop)
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/installer/lib.sh"

QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1
PASS=0; FAIL=0; FAILED=""

t() {  # t "<what it proves>" <command...>
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS+1)); [ "$QUIET" = 1 ] || ok "$what"
  else
    FAIL=$((FAIL+1)); FAILED="$FAILED\n    - $what"; warn "FAIL: $what"
  fi
}

AGENTS="$(agent_names)"; MAIN="$(conf_get MAIN)"

step "foundations"
t "tmux is installed"                     have tmux
t "claude is on PATH"                     have claude
t "tix is on PATH"                        have tix
t "agents survive logout (linger on)"     bash -c 'loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q "Linger=yes"'

step "identity and rules"
t "shared operating rules exist"          test -s "$HOME/AGENTS.md"
t "operator profile exists"               test -s "$HOME/OPERATOR.md"
t "the ticket guard is installed"         test -x "$HOME/.fleet/bin/work-guard.sh"
t "the reply guard is installed"          test -x "$HOME/.fleet/bin/reply-guard.sh"
t "settings.json is valid json"           python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$HOME/.claude/settings.json"

step "per agent"
for a in $AGENTS; do
  t "$a has a working directory"          test -d "$HOME/Projects/$a"
  t "$a has an identity file"             test -s "$HOME/Projects/$a/CLAUDE.md"
  t "$a service is enabled"               systemctl --user is-enabled "agent@$a.service"
  # RUNNING, not "the unit says active" -- the unit is oneshot+RemainAfterExit
  # and reports active forever once tmux has ever existed.
  t "$a has a live tmux session"          tmux has-session -t "agent-$a"
  # A token that was merely SAVED is the classic silent failure: the agent
  # starts, looks healthy, and never receives anything. Ask Telegram.
  if [ -s "$HOME/.fleet/secrets/telegram-$a.env" ]; then
    tok=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$HOME/.fleet/secrets/telegram-$a.env" | head -1)
    t "$a bot token is accepted by Telegram" \
      bash -c "curl -s -m 15 'https://api.telegram.org/bot${tok}/getMe' | grep -q '\"ok\":true'"
  fi
done

step "credentials that survive a reboot"
# An interactive login works and a systemd-started agent fails — the worst
# possible split, because it only shows up after a restart nobody is watching.
t "long-lived Claude token stored"        test -s "$HOME/.fleet/secrets/claude-token.env"

step "state backup"
t "state backup installed"                test -x "$HOME/.fleet/bin/state-backup.sh"
t "state backup timer active"             systemctl --user is-active state-backup.timer

step "the watchdog"
# The one thing standing between a dead agent and nobody noticing.
t "watchdog is installed"                 test -x "$HOME/.fleet/bin/fleet-watchdog.sh"
t "watchdog timer is active"              systemctl --user is-active fleet-watchdog.timer

step "the tracker actually round-trips"
t "tix can list projects"                 tix projects

echo
if [ "$FAIL" = 0 ]; then
  ok "all $PASS checks green"
  exit 0
fi
warn "$FAIL of $((PASS+FAIL)) checks FAILED:"
printf '%b\n' "$FAILED" >&2
cat >&2 <<'EOS'

  Fix what you can, then run this again. Three rules if you are an agent
  working through this list:
    * stop after 3 full passes and report what is still red
    * the same error twice is a question for your operator, not a third retry
    * you may fix configuration; you may NOT redesign. Uninstalling something
      to make a check pass is not a fix.
EOS
exit 1
