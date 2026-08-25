#!/usr/bin/env bash
# PreToolUse hook: screenshots of the agent desktops are off, whatever path is used.
#
# WHY A HOOK AND NOT JUST THE SCRIPT. `desktop.sh shot` already refuses, and that
# was the whole enforcement until the operator asked "could the message be given at
# the CLI level itself?" -- which prompted the obvious test I had not run:
#
#     docker exec -u abc agent-desktop bash -c 'DISPLAY=:1 xwd -root > /tmp/x.xwd'
#     -rw-r--r-- 1 abc abc 13786219 ... /tmp/x.xwd
#
# 13 MB, no desktop.sh involved. The block covered the POLITE path only. Not
# malice -- an agent that does not know desktop.sh exists, or improvises when a
# command refuses, gets there in one step. A control that only holds when you
# use the front door is a convention, not a control.
#
# So the rule lives where every command passes: the Bash tool.
#
# TEACHES RATHER THAN JUST REFUSING ("that way we don't
# have to proactively inform"). The denial names the alternative, says who set
# the rule, and points at the skill.
#
# Tracked in an internal ticket.
set -uo pipefail
payload="$(cat 2>/dev/null || true)"
cmd="$(printf '%s' "$payload" | python3 -c "
import json,sys
try: print((json.load(sys.stdin).get('tool_input') or {}).get('command',''))
except Exception: print('')" 2>/dev/null)"
[ -n "$cmd" ] || exit 0

# The deliberate escape hatch. One variable, so it stays a decision.
case "$cmd" in *SHOT_OK=1*) exit 0 ;; esac

# ONLY AT A COMMAND POSITION — never merely mentioned.
#
# The first version grepped for the verb ANYWHERE in the command, and within
# the hour it blocked a `tix note add` whose TEXT described this very bug,
# because the word "xwd" appeared inside the note. Writing about a tool is not
# using it. That is the cry-wolf failure I had explicitly warned about for
# `import` and then shipped anyway in the same file.
#
# So a match now requires the verb to sit where a COMMAND goes: at the start,
# or after a separator (; && || | ( { newline), or inside a `-c '...'` payload,
# optionally preceded by VAR=value assignments. A verb inside prose, a heredoc
# or a quoted document no longer matches.
#
# Erring toward under-blocking is deliberate. A missed screenshot costs tokens;
# a guard that blocks legitimate work gets disabled, and then it protects
# nothing at all.
VERBS='xwd|scrot|maim|spectacle|gnome-screenshot|import[[:space:]]+-(window|root)'
POS='(^|[;&|({]|&&|\|\||-c[[:space:]]+["'"'"'])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
if printf '%s' "$cmd" | grep -qE "${POS}(${VERBS})\b" \
   || printf '%s' "$cmd" | grep -qE 'x11grab|desktop\.sh[[:space:]]+shot([[:space:]]|$)'; then
  case "$cmd" in *screenshot-guard*) exit 0 ;; esac
  python3 -c "
import json
print(json.dumps({'hookSpecificOutput':{'hookEventName':'PreToolUse','permissionDecision':'deny','permissionDecisionReason':'''SCREENSHOTS OF THE AGENT DESKTOPS ARE OFF — a deliberate rule, not a fault.

Agents read, control and execute through the CLI:

    ~/.fleet/bin/desktop.sh read                    what the page SAYS
    ~/.fleet/bin/desktop.sh find \"<css selector>\"    WHERE to click -> screen x,y
    ~/.fleet/bin/desktop.sh find --text \"Send\"       same, by visible text
    ~/.fleet/bin/desktop.sh pagetitle               did anything change

find reads coordinates from the page itself, so they cannot drift from what is
rendered. A half-scale screenshot mis-aimed every click on every desktop for
hours on 2026-08-25 and opened reply drafts on real customer mail (an internal ticket).

Genuinely need to SEE it — a native dialog, a window that will not paint, a
rendering fault with no text behind it? Then say so on purpose:

    SHOT_OK=1 ~/.fleet/bin/desktop.sh shot

Full rules: the \\'agent-desktops\\' skill, which loads in every session.'''}}))
"
  exit 0
fi
exit 0
