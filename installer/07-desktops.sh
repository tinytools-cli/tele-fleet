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
#
# ONE PER AGENT, OR ONE SHARED -- ROUTED BY NAME, NOT BY A LIST. desktop.sh picks
# the desktop from the caller's TIX_AGENT: if ~/.fleet/desktops/<agent>/ exists,
# that agent drives <agent>-desktop and nobody else's. Anyone without their own
# falls back to the name in ~/.fleet/desktops/.default, and if there is none the
# tool REFUSES rather than guessing -- a guess puts an agent on somebody else's
# signed-in browser. Adding an agent's desktop later is just DESKTOPS=...,<name>
# and a re-run; no script names anyone.
#
# CHEAP WHEN IDLE. A stopped desktop is started by the first command that needs
# it (wake on use), so you can stop idle ones to give memory back and nothing
# breaks. Each runs under a memory cap (DESKTOP_MEM, default 3g) so one runaway
# browser cannot take the machine down with it.
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# SKILLS. Every skill under templates/skills/ is installed here. Most are not about
# desktops at all (continuous-work, autonomous-ticket-loop), so they install even
# when no desktop is requested; agent-desktops itself only installs when there is
# a desktop for it to describe -- a skill for a tool that is not there misleads.
#
# SUBSTITUTED, NOT COPIED VERBATIM. A plain `cp -r` ships any `{{...}}`
# placeholder in a skill file through as literal text — which is exactly how
# an earlier version of this skill leaked its own author's agent name into
# every install. Every skill goes through the same placeholder pass as
# CLAUDE.md, so a new skill gets substitution for free.
install_skills() {   # $1 = all | nodesk
  mkdir -p "$HOME/.claude/skills"
  local MAIN OPERATOR skill_ok=1 skill_src name dest f rel done_list=""
  MAIN="$(conf_get MAIN)"; OPERATOR="$(conf_get OPERATOR)"
  for skill_src in "$HERE"/templates/skills/*/; do
    name="$(basename "$skill_src")"
    [ "$1" = nodesk ] && [ "$name" = agent-desktops ] && continue
    dest="$HOME/.claude/skills/$name"
    while IFS= read -r -d '' f; do
      rel="${f#"$skill_src"}"
      mkdir -p "$dest/$(dirname "$rel")" || { skill_ok=0; continue; }
      sed -e "s|{{MAIN}}|$MAIN|g" -e "s|{{OPERATOR}}|$OPERATOR|g" "$f" > "$dest/$rel" 2>/dev/null \
        || { skill_ok=0; continue; }
      chmod --reference="$f" "$dest/$rel" 2>/dev/null || true
    done < <(find "$skill_src" -type f -print0)
    done_list="$done_list $name"
  done
  [ "$skill_ok" = 1 ] && ok "skills installed:$done_list — every agent picks them up automatically" \
    || warn "could not install every skill"
}

WANT="$(conf_get DESKTOPS)"
if [ -z "$WANT" ]; then
  install_skills nodesk
  say "  No desktops requested. Add DESKTOPS=<name>[,<name>] to $FLEET_CONF (an agent's"
  say "  name gives that agent its own; 'shared' gives everyone one) and"
  say "  re-run with ./install.sh --resume if you want them."
  exit 0
fi
have docker || { install_skills nodesk; warn "docker not installed — skipping desktops. Install docker, then ./install.sh --resume"; exit 0; }

IMAGE="lscr.io/linuxserver/webtop:ubuntu-xfce"
ROOT="$HOME/.fleet/desktops"; mkdir -p "$ROOT"
MEM="$(conf_get DESKTOP_MEM 3g)"

# FIND A FREE PORT rather than assuming one. Starting at a fixed number failed
# the first time it met a machine that already had something on it — docker
# reports "Bind for 127.0.0.1:3010 failed: port is already allocated", which is
# a clear message attached to a failure the installer should simply not have.
free_port() {
  local p="${1:-3010}"
  while [ "$p" -lt 3100 ]; do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then printf '%s' "$p"; return 0; fi
    exec 3>&- 2>/dev/null || true
    p=$((p+1))
  done
  return 1
}
port=3010

step "desktops"
for d in $(printf '%s' "$WANT" | tr ',' ' '); do
  c="${d}-desktop"
  # "It exists" is not "it works". A container that failed to start is still
  # inspectable, so the first version of this reported a broken desktop as
  # already-present and moved on — the exact silent success this whole project
  # keeps tripping over. Check whether it is RUNNING, and clear away a corpse.
  if docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -q true; then
    ok "$d already running"; continue
  fi
  if docker inspect "$c" >/dev/null 2>&1; then
    warn "$d exists but is not running — removing and recreating it"
    docker rm -f "$c" >/dev/null 2>&1
  fi
  port="$(free_port "$port")" || { warn "no free port between 3010 and 3100 — skipping $d"; continue; }
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
  #
  # --memory caps the container, not the browser: the browser cannot see the cap
  # and will not trim itself, which is what desktop-mem-watch.sh is for.
  if docker run -d --name "$c" --restart unless-stopped --shm-size 1g --memory "$MEM" \
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

# THE FALLBACK for agents without a desktop of their own. Written only when it is
# unambiguous: DESKTOP_DEFAULT if you set one, else a desktop literally named
# "shared", else the only desktop there is. With several per-agent desktops and
# no explicit default, NONE is written on purpose -- silently handing every other
# agent the first agent's signed-in browser is the exact mistake routing exists
# to prevent.
DEF="$(conf_get DESKTOP_DEFAULT)"
set -- $(printf '%s' "$WANT" | tr ',' ' ')
if [ -z "$DEF" ]; then
  for d in "$@"; do [ "$d" = shared ] && DEF=shared; done
  [ -z "$DEF" ] && [ "$#" -eq 1 ] && DEF="$1"
fi
if [ -n "$DEF" ]; then
  printf '%s\n' "$DEF" > "$ROOT/.default"
  ok "default desktop for agents without their own: $DEF"
else
  say "  no shared default -- agents without their own desktop will be refused (set DESKTOP_DEFAULT to change)"
fi

step "the driving tools"
install -m 750 "$HERE/templates/desktop.sh" "$HOME/.fleet/bin/desktop.sh"
# lib/ holds the page-side helpers desktop.sh pipes into the container (element
# resolution, verification, fill, choose). desktop.sh finds them next to itself.
mkdir -p "$HOME/.fleet/bin/lib"
install -m 640 "$HERE"/templates/lib/*.py "$HOME/.fleet/bin/lib/"
install -m 750 "$HERE/templates/desktop-dropdown.sh" "$HOME/.fleet/bin/desktop-dropdown.sh"
install -m 750 "$HERE/templates/desktop-report.py" "$HOME/.fleet/bin/desktop-report.py"
install -m 750 "$HERE/templates/desktop-mem-watch.sh" "$HOME/.fleet/bin/desktop-mem-watch.sh"
ok "desktop.sh installed — read / find / activate / fill / choose, with screenshots off by default"
say "  what the desktops did:   ~/.fleet/bin/desktop-report.py"
say "  memory warnings:         run ~/.fleet/bin/desktop-mem-watch.sh every minute from cron"

# TAB HOUSEKEEPING. Browser tabs accumulate because nothing ever closes them:
# an agent opens one for a lookup and moves on. Left alone a desktop reaches
# twenty-odd tabs -- including several copies of the same page -- and the
# containers become the largest memory consumer on the box. That is not
# theoretical: it contributed to an out-of-memory event that killed a running
# agent.
#
# The sweeper closes an unprotected tab nothing has touched for a while, and
# caps how many unprotected tabs a desktop may hold. It will NEVER close
# anything listed in desktop-protected.conf, because those hold LOGIN
# SESSIONS: closing an idle-looking mail tab once cost a human a full
# multi-factor re-authentication. Edit that file freely -- a wrong protect
# costs a little memory, a wrong close costs somebody their afternoon.
install -m 750 "$HERE/templates/desktop-tabsweep.py" "$HOME/.fleet/bin/desktop-tabsweep.py"
install -m 640 "$HERE/templates/desktop-protected.conf" "$HOME/.fleet/desktop-protected.conf"
ok "tab sweeper installed — run it from cron/systemd hourly, or by hand"
say "  protected tabs: \$HOME/.fleet/desktop-protected.conf (edit before relying on it)"

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

step "skill"
install_skills all

step "verify"
for d in $(printf '%s' "$WANT" | tr ',' ' '); do
  check "$d container running" bash -c "docker inspect -f '{{.State.Running}}' '${d}-desktop' 2>/dev/null | grep -q true"
done
check "desktop.sh installed" test -x "$HOME/.fleet/bin/desktop.sh"
check "desktop helpers installed" test -s "$HOME/.fleet/bin/lib/resolve-elements.py"
check "dropdown tool installed" test -x "$HOME/.fleet/bin/desktop-dropdown.sh"
check "tab sweeper installed" test -x "$HOME/.fleet/bin/desktop-tabsweep.py"
check "protected-tab list present" test -s "$HOME/.fleet/desktop-protected.conf"
say ""
say "  A desktop takes a minute to come up. Then: ~/.fleet/bin/desktop.sh --help"
