#!/usr/bin/env bash
# PreToolUse hook: refuse the TERMINAL question tool when the human is on Telegram.
#
# WHY THIS EXISTS. An agent once asked the operator a question with
# AskUserQuestion. It renders a menu in the agent's tmux pane and blocks until
# someone presses a key THERE. the operator is on Telegram and could not see it, so
# An agent sat wedged for 15 minutes — mid-task, work in flight, every health check
# green — until the operator noticed and I pressed the key for him.
#
# The rule already existed in the shared instructions and the agent had read them.
# That is the point: a written rule is advice, and advice loses to a tool that
# is right there and looks correct. The reply-tool version of this failure got a
# hook two days ago; this one never did.
#
# IT CANNOT BE CAUGHT AFTER THE FACT. The reply guard is a Stop hook, and a Stop
# hook only fires when a turn ENDS. This wedge happens mid-turn — the turn never
# ends — so it has to be refused BEFORE the tool runs. PreToolUse is the only
# place it can be caught at all.
#
# ONLY WHEN TELEGRAM IS IN PLAY. A terminal session with a human at the keyboard
# should use AskUserQuestion; that is what it is for. The signal is
# TELEGRAM_STATE_DIR, which every Telegram-wired agent has and a plain terminal
# session does not.
#
# (recorded in the maintainer's tracker)
set -uo pipefail
payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0

# Not a Telegram-wired session? Then the terminal tool is the right one.
[ -n "${TELEGRAM_STATE_DIR:-}" ] || exit 0

tool="$(printf '%s' "$payload" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('tool_name',''))
except Exception: print('')" 2>/dev/null)"
[ "$tool" = "AskUserQuestion" ] || exit 0

python3 -c "
import json
print(json.dumps({'hookSpecificOutput':{'hookEventName':'PreToolUse','permissionDecision':'deny','permissionDecisionReason':'''AskUserQuestion renders a menu in YOUR TERMINAL. The person you are asking is on Telegram and will never see it — you will block mid-turn, waiting on a keypress that cannot arrive, and no health check will notice because nothing is broken.

That exact wedge cost an agent 15 minutes on once.

Use the Telegram one instead — it sends real tappable buttons and blocks until they tap:

    ask_user(chat_id, text, buttons: [\"1 Yes\", \"2 No\", \"3 Something else\"])

Number the buttons to match your numbered list, keep each label to a few words (there is a hard byte cap), and put the options at the END of your message.

If you genuinely need the terminal tool — you are debugging at the keyboard, not talking to them — say so and unset TELEGRAM_STATE_DIR for that call.'''}}))
"
exit 0
