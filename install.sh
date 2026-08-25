#!/usr/bin/env bash
# Agent Fleet Installer — bare VPS to a running fleet of Claude Code agents.
#
#   ./install.sh              interview, then install
#   ./install.sh --config     interview only, write fleet.conf and stop
#   ./install.sh --resume     skip the interview, use the existing fleet.conf
#
# WHAT YOU DO vs WHAT THIS DOES. You authenticate: your Claude login, and one
# Telegram bot per agent from BotFather. Everything else is this script's job.
# That split is deliberate -- agents should not be asking a human to click
# through settings screens, and a human should not be asked for a credential
# a script could have avoided needing.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/installer/lib.sh"

MODE="${1:-}"

banner() {
cat <<'B'

  Agent Fleet Installer
  ---------------------
  Sets up Claude Code agents on this machine: each one its own working
  directory, its own Telegram bot, its own identity, supervised so they
  come back after a reboot. Shared ticket tracking via tix.

B
}

# ── the interview ───────────────────────────────────────────────────────────
# A prompted setup rather than a config file you have to author blind. Every
# question has a default you can press Enter through: a first run that demands
# ten decisions from someone who has not used this before gets abandoned.
ask() {
  local prompt="$1" def="${2:-}" ans
  if [ -n "$def" ]; then printf '  %s [%s]: ' "$prompt" "$def" >&2
  else printf '  %s: ' "$prompt" >&2; fi
  IFS= read -r ans || true
  printf '%s' "${ans:-$def}"
}

interview() {
  step "Who are you?"
  say "  The main agent is the ENGINEERING agent for this server. It will"
  say "  introduce itself when you first talk to it and ask the rest."
  say ""
  local op tz n names role
  op=$(ask "Your name (how the agents should address you)" "$(id -un)")
  tz=$(ask "Your timezone" "$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)")
  conf_set OPERATOR "$op"; conf_set TIMEZONE "$tz"

  step "How many agents?"
  say "  Each agent is a separate Claude Code session with its own Telegram bot."
  say "  ${C_WARN}Cost note:${C_OFF} ten agents on a single Claude plan hit the usage"
  say "  limit on the machine this came from. Start smaller if you are unsure."
  while :; do
    n=$(ask "Number of agents" "3")
    case "$n" in ''|*[!0-9]*) warn "a number, please"; continue ;; esac
    [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le 20 ] && break
    warn "pick between 1 and 20"
  done

  step "What are they called?"
  say "  Lowercase letters, digits and hyphens. The name IS the identity: it"
  say "  becomes the folder, the tmux session, the service and the ticket"
  say "  assignee. Renaming later is not supported -- delete and recreate."
  names=""
  local i=1
  while [ "$i" -le "$n" ]; do
    local nm; nm=$(ask "  agent $i name" "agent$i")
    if ! valid_name "$nm"; then warn "invalid: lowercase/digits/hyphen, max 24, no leading or trailing hyphen"; continue; fi
    case ",$names," in *",$nm,"*) warn "already used"; continue ;; esac
    role=$(ask "  agent $i one-line role" "general purpose")
    names="${names:+$names,}$nm"
    conf_set "ROLE_$nm" "$role"
    i=$((i+1))
  done
  conf_set AGENTS "$names"
  conf_set MAIN "${names%%,*}"

  step "Browser desktops?"
  say "  A desktop is a real Linux desktop with a browser, running in a container."
  say "  It lets an agent do work that has no API — a vendor portal, a console, a"
  say "  form with forty fields — instead of handing it back to you. You can open"
  say "  it in a browser, watch, and take over to sign in or pay."
  say ""
  say "  ${C_WARN}Cost:${C_OFF} each one is a container with its own browser — roughly a GB of"
  say "  RAM when busy. Start with one shared desktop unless you know you need more."
  say ""
  say "    1  one shared desktop  (recommended)"
  say "    2  one per agent"
  say "    3  none"
  local pick desks=""
  while :; do
    pick=$(ask "Which" "1")
    case "$pick" in
      1) desks="shared"; break ;;
      2) desks="${names}"; break ;;
      3) desks=""; break ;;
      *) warn "1, 2 or 3" ;;
    esac
  done
  [ -n "$desks" ] && conf_set DESKTOPS "$desks"

  step "Written to $FLEET_CONF"
  say "  operator : $op ($tz)"
  say "  agents   : ${names//,/, }"
  say "  main     : ${names%%,*}   (your engineering agent)"
  local dl; dl="$(conf_get DESKTOPS)"
  say "  desktops : ${dl:-none}"
  say ""
  say "  No tokens are stored yet. Telegram comes later and asks per agent."
}

banner
case "$MODE" in
  --resume) [ -r "$FLEET_CONF" ] || die "no $FLEET_CONF — run without --resume first" ;;
  --config) interview; exit 0 ;;
  ""|--install) [ -r "$FLEET_CONF" ] && say "  Using existing $FLEET_CONF (delete it to start over)" || interview ;;
  -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  *) die "unknown option: $MODE" ;;
esac

for stage in "$HERE"/installer/[0-9][0-9]-*.sh; do
  [ -r "$stage" ] || continue
  step "$(basename "$stage" .sh)"
  # shellcheck disable=SC1090
  FLEET_CONF="$FLEET_CONF" bash "$stage" || die "stage failed: $(basename "$stage")"
done

step "Done"
say "  Next: talk to your main agent on Telegram. It knows what is still"
say "  pending and will finish setting itself up with you."
