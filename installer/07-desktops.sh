#!/usr/bin/env bash
# Stage 7 — browser desktops. Optional, and off unless asked for.
#
# WHY A DESKTOP AT ALL. Plenty of real work has no API: a vendor portal, a
# console three menus deep, a form with forty fields. Without a browser an agent
# hands that back to you with instructions. With one, it does the work and stops
# at the two things that are genuinely yours — payment and authentication.
#
# YOU CAN WATCH AND TAKE OVER. Each desktop serves a web view on localhost, so
# you can open it, take the mouse, sign in, and let the agent carry on.
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

WANT="$(conf_get DESKTOPS)"
if [ -z "$WANT" ]; then
  say "  No desktops requested. Add DESKTOPS=<name>[,<name>] to $FLEET_CONF and"
  say "  re-run with ./install.sh --resume if you want them."
  exit 0
fi
have docker || { warn "docker not installed — skipping desktops. Install docker, then ./install.sh --resume"; exit 0; }

IMAGE="lscr.io/linuxserver/webtop:ubuntu-xfce"
ROOT="$HOME/.fleet/desktops"; mkdir -p "$ROOT"
port=3010

step "desktops"
for d in $(printf '%s' "$WANT" | tr ',' ' '); do
  c="${d}-desktop"
  if docker inspect "$c" >/dev/null 2>&1; then ok "$d already exists"; port=$((port+1)); continue; fi
  mkdir -p "$ROOT/$d/config" "$ROOT/$d/shots"
  # seccomp=unconfined and apparmor=unconfined are REQUIRED, not paranoia:
  # the browser sandbox (bwrap) and PNG decoding both fail under the default
  # profiles and the container crash-loops with an error that points nowhere
  # near the real cause. shm-size matters for the same reason — a small /dev/shm
  # makes the browser die under load and look like a memory problem.
  #
  # Bound to 127.0.0.1 ON PURPOSE. This is a full desktop with your logged-in
  # sessions in it and NO authentication of its own. Do not publish the port;
  # reach it over a VPN or an authenticating proxy if you need it remotely.
  if docker run -d --name "$c" --restart unless-stopped --shm-size 1g \
       --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
       -p "127.0.0.1:${port}:3000" -v "$ROOT/$d/config:/config" \
       -e TITLE="${d} desktop" -e SELKIES_FRAMERATE=15 \
       -e PUID="$(id -u)" -e PGID="$(id -g)" -e TZ="$(conf_get TIMEZONE UTC)" \
       "$IMAGE" >/dev/null 2>&1; then
    ok "$d -> http://127.0.0.1:${port}  (open it in a browser to watch or take over)"
  else
    warn "$d failed to start — docker logs $c"
  fi
  port=$((port+1))
done

step "the driving tools"
install -m 750 "$HERE/templates/desktop.sh" "$HOME/.fleet/bin/desktop.sh"
ok "desktop.sh installed — read / find / click / type, with screenshots off by default"

# Enforced at the TOOL level, not just in desktop.sh: a script-level block only
# guards the polite path, and `xwd` walks straight past it.
install -m 750 "$HERE/templates/screenshot-guard.sh" "$HOME/.fleet/bin/screenshot-guard.sh"
python3 - "$HOME/.claude/settings.json" <<'PY' && ok "screenshot guard wired in" || warn "could not wire the screenshot guard"
import json, sys
p = sys.argv[1]
try: d = json.load(open(p))
except Exception: d = {}
cmd = "$HOME/.fleet/bin/screenshot-guard.sh"
pre = d.setdefault("hooks", {}).setdefault("PreToolUse", [])
for e in pre:
    if e.get("matcher") == "Bash":
        for h in e.get("hooks", []):
            if "screenshot-guard" in h.get("command", ""): sys.exit(0)
        e["hooks"].append({"type": "command", "command": cmd, "timeout": 10}); break
else:
    pre.append({"matcher": "Bash", "hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
json.dump(d, open(p, "w"), indent=2)
PY

# THE SKILL IS HOW AN AGENT LEARNS ANY OF THIS. Shipping the tools without it
# leaves every agent to rediscover the rules — and the first thing they
# rediscover is screenshotting a page in order to read it.
step "skill"
mkdir -p "$HOME/.claude/skills"
cp -r "$HERE/templates/skills/agent-desktops" "$HOME/.claude/skills/" 2>/dev/null \
  && ok "agent-desktops skill installed — every agent picks it up automatically" \
  || warn "could not install the skill"

step "verify"
for d in $(printf '%s' "$WANT" | tr ',' ' '); do
  check "$d container running" bash -c "docker inspect -f '{{.State.Running}}' '${d}-desktop' 2>/dev/null | grep -q true"
done
check "desktop.sh installed" test -x "$HOME/.fleet/bin/desktop.sh"
say ""
say "  A desktop takes a minute to come up. Then: ~/.fleet/bin/desktop.sh --help"
