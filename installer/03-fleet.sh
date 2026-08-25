#!/usr/bin/env bash
# Stage 3 — create the agents: directories, identities, units, sessions.
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

AGENTS="$(agent_names)"; MAIN="$(conf_get MAIN)"; OPERATOR="$(conf_get OPERATOR)"
[ -n "$AGENTS" ] || die "no agents in $FLEET_CONF — run ./install.sh --config"

step "fleet directories"
mkdir -p "$HOME/.fleet/bin" "$HOME/.fleet/secrets" "$HOME/Projects"
chmod 700 "$HOME/.fleet/secrets"
install -m 750 "$HERE/templates/start-agent.sh" "$HOME/.fleet/bin/start-agent.sh"
install -m 750 "$HERE/templates/reap-agent.sh"  "$HOME/.fleet/bin/reap-agent.sh"
ok "helpers in ~/.fleet/bin"

step "systemd unit"
mkdir -p "$HOME/.config/systemd/user"
install -m 644 "$HERE/templates/project-agent@.service" "$HOME/.config/systemd/user/agent@.service"
systemctl --user daemon-reload 2>/dev/null || warn "systemd --user unavailable (no session bus?)"
ok "agent@.service installed"

step "agents"
for a in $AGENTS; do
  dir="$HOME/Projects/$a"; mkdir -p "$dir"
  role="$(conf_get "ROLE_$a" "general purpose")"
  if [ "$a" = "$MAIN" ]; then tmpl="$HERE/templates/CLAUDE.main.md"; else tmpl="$HERE/templates/CLAUDE.agent.md"; fi
  if [ ! -f "$dir/CLAUDE.md" ] && [ -r "$tmpl" ]; then
    sed -e "s|{{AGENT}}|$a|g" -e "s|{{ROLE}}|$role|g" -e "s|{{OPERATOR}}|$OPERATOR|g" \
        -e "s|{{AGENTS}}|${AGENTS// /, }|g" "$tmpl" > "$dir/CLAUDE.md"
  fi
  [ -f "$dir/RUNLOG.md" ] || printf '# %s — runlog\n\nNewest entry at top.\n' "$a" > "$dir/RUNLOG.md"
  systemctl --user enable "agent@$a.service" >/dev/null 2>&1 || true
  ok "$a  ($role)"
done

step "verify"
for a in $AGENTS; do
  check "$a has a working directory" test -d "$HOME/Projects/$a"
  check "$a has an identity file"    test -s "$HOME/Projects/$a/CLAUDE.md"
done
say ""
say "  Agents are created but NOT started — they need their Telegram bot first."
say "  Stage 4 handles that."
