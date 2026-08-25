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

step "verify"
check "~/AGENTS.md present"   test -s "$HOME/AGENTS.md"
check "~/OPERATOR.md present" test -s "$HOME/OPERATOR.md"
check "guard installed"       test -x "$HOME/.fleet/bin/work-guard.sh"
check "settings.json is valid json" python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$SETTINGS"
