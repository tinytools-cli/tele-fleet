#!/usr/bin/env bash
# Stage 4 — give each agent its own Telegram bot, with the operator walked
# through it rather than sent away to work it out.
#
# WHY ONE BOT PER AGENT. They are separate identities with separate
# conversations. Sharing one bot means one inbox for ten agents and no way to
# tell who you are talking to.
#
# WHY THIS ASKS YOU TO DO IT. Creating a bot is authentication — it is yours,
# tied to your Telegram account, and no script should hold your credentials to
# make it. Everything AROUND that is this script's job: the steps, the
# validation, the storage, and finding your chat id so you never have to.
. "$(dirname "$0")/lib.sh"

AGENTS="$(agent_names)"; MAIN="$(conf_get MAIN)"
[ -n "$AGENTS" ] || die "no agents configured"
SECRETS="$HOME/.fleet/secrets"; mkdir -p "$SECRETS"; chmod 700 "$SECRETS"

have curl || { warn "curl missing — cannot verify tokens; skipping Telegram setup"; exit 0; }

count=$(printf '%s\n' $AGENTS | wc -l)
cat <<EOS

  Each of your $count agent(s) needs its own Telegram bot. You create them;
  this walks you through it and checks each one works.

  ONCE, in Telegram:
    1. search for  @BotFather  and open the chat
    2. send  /newbot
    3. give it a display name  (e.g. "Nova")  -- this is what you will see
    4. give it a username ending in 'bot'  (e.g. nova_yourname_bot)
    5. BotFather replies with a token like  8123456789:AAH...  -- copy it

  Repeat for each agent. Paste each token below. Nothing is stored until it
  has been checked against Telegram, and tokens are written 0600 to
  $SECRETS

EOS

# Ask Telegram, do not trust the paste. A typo'd token that is merely SAVED
# produces an agent that starts, looks healthy, and never receives a message --
# the exact silent failure this whole setup is built to avoid.
verify_token() {
  local tok="$1" out
  out=$(curl -s -m 15 "https://api.telegram.org/bot${tok}/getMe" 2>/dev/null) || return 1
  printf '%s' "$out" | grep -q '"ok":true' || return 1
  printf '%s' "$out" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p' | head -1
}

for a in $AGENTS; do
  f="$SECRETS/telegram-$a.env"
  if [ -s "$f" ]; then ok "$a already has a token (delete $f to redo)"; continue; fi
  while :; do
    printf '  token for %s (blank to skip this agent): ' "$a" >&2
    IFS= read -r tok || true
    [ -z "$tok" ] && { warn "$a skipped — it will start but cannot be reached on Telegram"; break; }
    case "$tok" in
      *[0-9]:*) ;;
      *) warn "that does not look like a bot token (expected digits, a colon, then letters)"; continue ;;
    esac
    if uname=$(verify_token "$tok"); then
      printf 'TELEGRAM_BOT_TOKEN=%s\n' "$tok" > "$f"; chmod 600 "$f"
      ok "$a -> @$uname  (verified with Telegram)"
      break
    fi
    warn "Telegram rejected that token. Check you copied all of it, then try again."
  done
done

# THE CHAT ID, WITHOUT MAKING ANYONE HUNT FOR IT. Every guide says "find your
# numeric chat id", which sends people to third-party bots to get a number they
# do not understand. The bot already learns it the moment you message it, so
# just ask them to say hello and read it back.
if [ -z "$(conf_get OWNER_CHAT_ID)" ]; then
  main_tok="$SECRETS/telegram-$MAIN.env"
  if [ -s "$main_tok" ]; then
    tok=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$main_tok" | head -1)
    say ""
    say "  Last step: open the chat with your MAIN agent's bot and send it anything"
    say "  (\"hello\" is fine), so it learns where to reach you."
    printf '  Press Enter once you have sent it: ' >&2; IFS= read -r _ || true
    upd=$(curl -s -m 15 "https://api.telegram.org/bot${tok}/getUpdates" 2>/dev/null)
    cid=$(printf '%s' "$upd" | sed -n 's/.*"chat":{"id":\(-\?[0-9]*\).*/\1/p' | head -1)
    if [ -n "$cid" ]; then conf_set OWNER_CHAT_ID "$cid"; ok "found you: chat id $cid"
    else warn "no message seen yet — you can set OWNER_CHAT_ID in $FLEET_CONF later, or re-run this stage"; fi
  fi
fi

step "verify"
for a in $AGENTS; do
  if [ -s "$SECRETS/telegram-$a.env" ]; then ok "$a has a verified bot token"
  else warn "$a has NO token — reachable only from the terminal"; fi
done
