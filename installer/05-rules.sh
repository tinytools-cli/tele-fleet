#!/usr/bin/env bash
# Stage 5 — the rules and the guard. The least obvious part to reinvent and
# the most valuable thing here.
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OPERATOR="$(conf_get OPERATOR Operator)"

step "shared rules"
if [ ! -f "$HOME/AGENTS.md" ]; then
  sed "s|{{OPERATOR}}|$OPERATOR|g" "$HERE/templates/AGENTS.md" > "$HOME/AGENTS.md"
  ok "~/AGENTS.md written"
else ok "~/AGENTS.md already exists — left alone"; fi

# STARTS EMPTY ON PURPOSE. This is where the fleet records what it learns about
# the person it works for. Shipping it pre-filled would mean shipping somebody
# else's personal information, which is the one thing this installer must never
# do. The main agent fills it in by ASKING.
if [ ! -f "$HOME/OPERATOR.md" ]; then
  cat > "$HOME/OPERATOR.md" <<EOF
# $OPERATOR

Everything the fleet learns about who it works for goes here — preferences, how
they like to be addressed, working style, context that is not in any repo.

It starts nearly empty on purpose. Your main agent will interview you and fill
it in. Add to it when you learn something durable; do not keep it in one agent's
memory, because the others will not have it.

## Basics
- Name: $OPERATOR
- Timezone: $(conf_get TIMEZONE UTC)
EOF
  ok "~/OPERATOR.md created (the main agent fills this in with you)"
fi

step "ticket guard"
mkdir -p "$HOME/.fleet/workguard"
install -m 750 "$HERE/templates/work-guard.sh" "$HOME/.fleet/bin/work-guard.sh"
SETTINGS="$HOME/.claude/settings.json"; mkdir -p "$HOME/.claude"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
# MERGE, never overwrite: a settings file may already carry the operator's own
# hooks and permissions, and replacing it would silently discard them.
python3 - "$SETTINGS" <<'PY' && ok "Stop hook wired into settings.json" || warn "could not wire the hook"
import json, sys, os
p = sys.argv[1]
try:
    d = json.load(open(p))
except Exception:
    d = {}
cmd = "$HOME/.fleet/bin/work-guard.sh"
hooks = d.setdefault("hooks", {})
stop = hooks.setdefault("Stop", [])
for entry in stop:
    for h in entry.get("hooks", []):
        if "work-guard" in h.get("command", ""):
            sys.exit(0)
stop.append({"hooks": [{"type": "command", "command": cmd, "timeout": 15}]})
json.dump(d, open(p, "w"), indent=2)
PY

# THE GUARD FOR THE FAILURE THAT LOOKS EXACTLY LIKE SUCCESS.
# An agent can compose a perfect answer, print it, and stop — and the person
# waiting receives silence while every process check stays green. It happened
# twice in one day on the machine this came from, to two different agents.
# Rules are advice; a Stop hook is enforcement, because the harness runs it
# rather than the model.
# Blocks at most ONCE per inbound message, so a genuine "no reply needed" costs
# one nudge and never loops. Fails open on any missing state.
step "reply guard"
install -m 750 "$HERE/templates/reply-guard.sh" "$HOME/.fleet/bin/reply-guard.sh"
python3 - "$SETTINGS" <<'PY' && ok "reply guard wired in" || warn "could not wire the reply guard"
import json, sys
p = sys.argv[1]
try: d = json.load(open(p))
except Exception: d = {}
cmd = "$HOME/.fleet/bin/reply-guard.sh"
stop = d.setdefault("hooks", {}).setdefault("Stop", [])
for e in stop:
    for h in e.get("hooks", []):
        if "reply-guard" in h.get("command", ""): sys.exit(0)
stop.append({"hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
json.dump(d, open(p, "w"), indent=2)
PY

# THE BOARD A HUMAN ACTUALLY LOOKS AT. tix's CLI is what agents use; this is how
# the operator sees what the whole fleet is doing without asking each of them,
# which is the entire reason for a shared tracker.
# THE QUESTION AN AGENT ASKS WHERE NOBODY CAN SEE IT.
# AskUserQuestion renders a menu in the agent's own terminal and blocks until
# someone presses a key THERE. If the operator is on a chat channel they will
# never see it, and the agent sits wedged MID-TURN — work in flight, every
# health check green — until a human happens to look.
#
# It cannot be caught afterwards: the reply guard is a Stop hook, and Stop hooks
# fire when a turn ENDS. This turn never ends. PreToolUse is the only place.
#
# Fires only when a chat channel is actually in play; a terminal session with a
# human at the keyboard should use the terminal tool, and still can.
step "question guard"
install -m 750 "$HERE/templates/askuser-guard.sh" "$HOME/.fleet/bin/askuser-guard.sh"
python3 - "$SETTINGS" <<'PY' && ok "question guard wired in" || warn "could not wire the question guard"
import json, sys
p = sys.argv[1]
try: d = json.load(open(p))
except Exception: d = {}
cmd = "$HOME/.fleet/bin/askuser-guard.sh"
pre = d.setdefault("hooks", {}).setdefault("PreToolUse", [])
for e in pre:
    if e.get("matcher") == "AskUserQuestion":
        sys.exit(0)
pre.append({"matcher": "AskUserQuestion", "hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
json.dump(d, open(p, "w"), indent=2)
PY

step "dashboard"
if [ -x "$HOME/.local/share/tix-venv/bin/tix-web" ]; then
  install -m 644 "$HERE/templates/tix-web.service" "$HOME/.config/systemd/user/tix-web.service"
  systemctl --user daemon-reload 2>/dev/null
  systemctl --user enable --now tix-web.service >/dev/null 2>&1 \
    && ok "dashboard on http://127.0.0.1:8791 (localhost only — it has no login)" \
    || warn "dashboard installed but would not start: systemctl --user status tix-web"
else
  warn "tix-web not found — skipping the dashboard (the CLI still works)"
fi

step "verify"
check "~/AGENTS.md present"   test -s "$HOME/AGENTS.md"
check "~/OPERATOR.md present" test -s "$HOME/OPERATOR.md"
check "guard installed"       test -x "$HOME/.fleet/bin/work-guard.sh"
check "settings.json is valid json" python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$SETTINGS"
