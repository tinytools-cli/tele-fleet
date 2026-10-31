#!/usr/bin/env bash
# Stop hook: refuse to end a turn that answered into the terminal.
#
# THE PROBLEM THIS SOLVES DETERMINISTICALLY. Rules and nudges are advice; an
# agent can compose a perfect answer, print it, and stop. It happened to two
# different agents, and in both cases everything measurable was green.
# A Stop hook is enforcement: the harness runs it, not the model, and it can
# refuse to let the turn end.
#
# HOW IT DECIDES: the plugin records every message with an is_outgoing flag.
# If the newest inbound is newer than the newest outbound, this turn received
# something and said nothing back.
#
# ⚠️ IT BLOCKS AT MOST ONCE PER INBOUND MESSAGE. A Stop hook that blocks
# unconditionally is an infinite loop -- the agent would never be allowed to
# finish. The message id is recorded, so a genuine "no reply needed" case
# (a "thanks", a "disregard") costs exactly one extra nudge, ever.
#
# ⚠️ FAILS OPEN. No database, no TELEGRAM_STATE_DIR, unreadable state -- the
# turn is allowed to end. A guard that can wedge a session on its own bug is
# worse than the bug it guards against.
set -uo pipefail
cat >/dev/null 2>&1 || true          # drain hook stdin; we do not need it

allow() { exit 0; }

dir="${TELEGRAM_STATE_DIR:-$HOME/.claude/channels/telegram}"
db="$dir/data/messages.db"
[ -r "$db" ] || allow
command -v sqlite3 >/dev/null 2>&1 || allow

read -r lin lout <<<"$(sqlite3 "$db" \
  "select coalesce((select max(date) from messages where is_outgoing=0),0),
          coalesce((select max(date) from messages where is_outgoing=1),0);" 2>/dev/null | tr '|' ' ')"
case "${lin:-}${lout:-}" in ''|*[!0-9]*) allow ;; esac
[ "$lin" = 0 ] && allow
[ "$lin" -le "$lout" ] && allow        # already answered since the last message

# Identify the specific message so we block for it only once.
mid=$(sqlite3 "$db" "select message_id from messages where is_outgoing=0 order by date desc limit 1;" 2>/dev/null)
case "${mid:-}" in ''|*[!0-9]*) allow ;; esac
seen="$dir/data/.reply-guard-seen"
touch "$seen" 2>/dev/null || allow
grep -qxF "$mid" "$seen" 2>/dev/null && allow
echo "$mid" >> "$seen"
tail -n 100 "$seen" > "$seen.tmp" 2>/dev/null && mv "$seen.tmp" "$seen"

chat=$(sqlite3 "$db" "select chat_id from messages where message_id=$mid limit 1;" 2>/dev/null)

cat <<JSON
{"decision":"block","reason":"You received a Telegram message and are ending this turn without having sent anything back. Text you printed is NOT visible to the operator -- it reached your terminal only.\n\nIf you meant to answer, send it now:\n    reply({ chat_id: \"${chat:-<their chat id>}\", text: \"...\" })\n\nIf this message genuinely needs no reply (a 'thanks', a 'disregard', an acknowledgement), just say so and stop -- this check will not ask again about this message."}
JSON
