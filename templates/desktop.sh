#!/usr/bin/env bash
# Drive the desktop container: look at the screen, then act on it.
#
#   desktop.sh shot                 capture the screen -> prints a PNG path to Read
#   desktop.sh click <x> <y>        move there and left-click
#   desktop.sh rclick <x> <y>       right-click
#   desktop.sh dblclick <x> <y>     double-click
#   desktop.sh move <x> <y>         move the pointer only
#   desktop.sh type "text"          type text at the focus
#   desktop.sh key <keyspec>        a key or chord, e.g. Return, ctrl+l, alt+Tab
#   desktop.sh scroll up|down [n]   wheel
#   desktop.sh url <address>        open an address in the running Chrome
#   desktop.sh where                pointer position
#
# Input goes through xdotool, so these are real X events. A website cannot tell
# them from a hand on a mouse — unlike CDP-synthesised clicks, which are the
# ones bot detection looks for. That is the point of doing it this way.
#
# ALWAYS `shot` before acting. Coordinates from a stale screenshot click the
# wrong thing, and you will not notice until something odd has already happened.
set -uo pipefail

# WHICH DESKTOP. There is more than one now (one agent's shared one, a second agent's own,
# added once). Select with DESKTOP=<name>, or DESKTOP_CONTAINER for a
# container whose name is not "<name>-desktop". Defaults to an agent so every
# existing caller and every doc keeps working unchanged.
# WHOSE DESKTOP BY DEFAULT — the operator's rule, once: "one agent's desktop for
# one agent's and another agent's for everyone else as primary."
#
# Routed here rather than left to eleven agents to remember. A default that is
# right only for one agent is a default that is wrong nine times, and the agent
# does not find out until it is typing into somebody else's browser session.
# TIX_AGENT is exported by every launcher (agent.sh, start-agent.sh,
# start-project-agent.sh), so it is a reliable signal.
#
# An explicit DESKTOP= always wins. Unset TIX_AGENT falls back to an agent, which
# keeps her unattended watchers (outlook-watch, whatsapp-watch) unchanged.
# FAIL CLOSED WHEN WE DO NOT KNOW WHO IS ASKING.
#
# This used to default to an agent when TIX_AGENT was unset, "so her unattended
# watchers keep working". On once that default drove ME onto HER desktop:
# an interactive Bash tool session does not inherit TIX_AGENT either, so the
# fallback meant to protect two watchers silently handed someone else's browser
# -- signed into his work Outlook and WhatsApp -- to any caller who forgot to
# say which desktop they meant. I navigated a tab on her screen before noticing.
#
# A default that is right for two callers and dangerous for everyone else is
# not a default, it is a trap. Unknown identity now REFUSES and says what to
# pass. The watchers were changed to pass DESKTOP= explicitly, which is where
# that decision belonged in the first place.
# SELF-HEAL A COLLAPSED VIEWPORT INSTEAD OF JUST COMPLAINING ABOUT IT.
#
# The window collapses whenever a VIEWER disconnects from the desktop -- the X
# display follows the viewing browser, and a window sized for something larger
# is left stranded. That is routine, not exceptional, so it WILL recur.
#
# On once it dropped one agent’s desktop's browser to 43 pixels tall. Every
# coordinate computed from it pointed at other windows; two agents spent an
# evening on it. The first fix only DETECTED the state and told the agent to
# run `fit` -- better than silence, but it still leaves a trap that fires on
# every disconnect and costs a round trip each time.
#
# `fit` is idempotent and sizes windows to the display's ACTUAL geometry, so
# running it when nothing is wrong changes nothing. That makes healing strictly
# safer than refusing. Refusal is kept only for the case where healing FAILED.
_heal_viewport() {
  local w h dw dh
  read -r dw dh < <(X "xdotool getdisplaygeometry")
  [ -n "${dw:-}" ] || return 0
  # If the DISPLAY itself is tiny there is nothing to heal -- that is a real
  # small screen, and resizing windows to match is already correct.
  [ "$dh" -lt 200 ] && return 0
  for wid in $(X "xdotool search --class chromium" 2>/dev/null); do
    local g ww hh
    g=$(X "xdotool getwindowgeometry $wid" | awk "/Geometry/ {print \$2}")
    ww=${g%%x*}; hh=${g##*x}
    [ -z "$ww" ] && continue
    [ "$ww" -lt 400 ] && continue          # decoration/shadow frames, not real windows
    if [ "${hh:-0}" -lt 200 ]; then
      echo "note: a browser window was ${ww}x${hh} — collapsed. Refitting to ${dw}x${dh}." >&2
      X "xdotool windowmove $wid 0 0; xdotool windowsize $wid $dw $dh"
      sleep 1
    fi
  done
}

_default_desk() {
  # ROUTING IS BY CONVENTION, NOT A HARDCODED LIST.
  #
  # An agent gets ITS OWN desktop if one exists -- $DESKTOP_ROOT/<agent> --
  # and otherwise falls back to the shared one. Nothing here names a
  # particular agent, so adding or removing agents needs no edit to this file.
  #
  # Lowercased before matching. Exact matching means Alice and alice route to
  # different desktops, and one capital letter between an agent and a
  # colleague's signed-in browser is not a difference anyone reliably respects.
  #
  # An explicit DESKTOP= always wins. An UNSET agent name REFUSES rather than
  # guessing -- guessing once put an agent on somebody else's logged-in
  # browser, so the fallback here is failure, not a default.
  local a
  a=$(printf '%s' "${TIX_AGENT:-}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
  [ -n "$a" ] || { echo ""; return; }
  if [ -d "${DESKTOP_ROOT:-$HOME/agent-desktops}/$a" ]; then
    echo "$a"
  else
    echo "${DEFAULT_DESKTOP:-main}"
  fi
}
DESK="${DESKTOP:-$(_default_desk)}"
if [ -z "$DESK" ]; then
  echo "WHICH DESKTOP? I cannot tell who is asking (TIX_AGENT is not set)." >&2
  echo "  Refusing rather than guessing -- guessing once put an agent on somebody" >&2
  echo "  else's signed-in browser." >&2
  echo "" >&2
  echo "  Say it explicitly:   DESKTOP=another agent $0 $*" >&2
  echo "  Available:           $(ls -d ${DESKTOP_ROOT:-$HOME/agent-desktops}/*/ 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')" >&2
  exit 2
fi
C="${DESKTOP_CONTAINER:-${DESK}-desktop}"
SHOT_DIR="${DESKTOP_ROOT:-$HOME/agent-desktops}/${DESK}/shots"
X() { docker exec -u abc "$C" bash -c "DISPLAY=:1 $*" 2>/dev/null; }

docker ps --format '{{.Names}}' | grep -qx "$C" || { echo "desktop container '$C' is not running" >&2; exit 1; }
mkdir -p "$SHOT_DIR"

# ── one agent on the desktop at a time ──────────────────────────────────────
# There is ONE X session and several agents that can drive it: interactive
# sessions, and fresh agents woken by the trigger dispatcher, which run with no
# knowledge of each other. On once two one agent sessions drove this browser
# concurrently — a click meant for a dialog landed on the WhatsApp tab because
# the other one moved focus mid-action. She spotted it and backed off.
#
# It is not only input: `shot` writes a SHARED /config/.shot.xwd and a SHARED
# screen.png, so two captures at once corrupt each other's image — and the
# caller cannot tell, which is the dangerous part.
#
# So every command takes an exclusive lock for its (short) duration. Failing
# loudly when the desktop is busy beats interleaving two agents' actions.
# One lock PER DESKTOP: two agents on the same screen must serialise, but a second agent
# working on his own screen must not be blocked by one agent working on hers.
LOCK="${DESKTOP_ROOT:-$HOME/agent-desktops}/${DESK}/.desktop.lock"
mkdir -p "$(dirname "$LOCK")" 2>/dev/null || true
# NOT `exec 9>"$LOCK" 2>/dev/null` — `exec` with no command applies its
# redirections to the WHOLE SHELL, so that 2>/dev/null permanently silenced
# every error this script would ever print. The "desktop busy" message was
# invisible from the moment the lock was added; agents just got exit 75 with
# nothing explaining it. Redirect only what needs redirecting.
if ! exec 9>"$LOCK"; then
  echo "cannot open the desktop lock at $LOCK" >&2
  exit 1
fi
# A CLAIM held ACROSS COMMANDS, which the flock below cannot provide.
#
# the operator, once: "seems multiple agents are using workstations, I
# thought you set something up so that doesn't happen". He is right and the
# lock was not enough. flock is held for ONE desktop.sh invocation and released
# when the process exits, so it serialises individual COMMANDS and not a
# SESSION of work. Agent A can `find`, release, agent B can `click`, release,
# and A then clicks coordinates measured against a page B has already navigated
# away from. Every call is individually correct; the sequence is nonsense.
#
# `claim` writes a holder + expiry; other agents are refused for its duration.
# It EXPIRES ON A TIMER rather than needing release, because an agent that dies
# mid-task must not wedge a desktop until a human notices -- the failure this
# fleet keeps having is silent state nobody is watching.
CLAIM="${DESKTOP_ROOT:-$HOME/agent-desktops}/${DESK}/.claim"
WAITLIST="${DESKTOP_ROOT:-$HOME/agent-desktops}/${DESK}/.waitlist"

# TELL THE NEXT WAITER, ONCE, WITH A FIXED SENTENCE.
#
# hq deliberately refuses to type arbitrary strings into an agent's REPL --
# "an open string would be an injection channel into every agent here" -- and
# that refusal is right. So this does NOT pass through any caller-supplied
# text. The message is a constant; the only variable is a desktop name matched
# against ^[a-z][a-z0-9-]*$ and confirmed to be a real directory. Nothing an
# agent controls reaches the keystrokes.
#
# One notification, to ONE waiter, who is removed from the queue as it is sent.
# No broadcast, no repeat: eleven agents told "a desktop is free" is chatter,
# and chatter between agents is the failure mode that scales fastest here.
_notify_next_waiter() {
  [ -s "$WAITLIST" ] || return 0
  local next rest sess
  next=$(head -n1 "$WAITLIST")
  rest=$(tail -n +2 "$WAITLIST")
  printf '%s' "$rest" > "$WAITLIST"
  [ -s "$WAITLIST" ] || rm -f "$WAITLIST"
  case "$next" in ''|*[!a-zA-Z0-9_-]*) return 0 ;; esac
  case "$DESK" in ''|*[!a-z0-9-]*) return 0 ;; esac
  sess="agent-$(printf '%s' "$next" | tr '[:upper:]' '[:lower:]')"
  # has-session, never display-message: tmux resolves loosely and send-keys
  # against a bogus target is how you type into the wrong pane.
  tmux has-session -t "$sess" 2>/dev/null || { echo "  (next waiter '$next' has no session; skipped)"; return 0; }
  tmux send-keys -t "${sess}:0.0" \
    "The ${DESK} desktop you were waiting for is now free. Claim it before use: desktop.sh claim 15" 2>/dev/null \
    && sleep 1 && tmux send-keys -t "${sess}:0.0" Enter 2>/dev/null \
    && echo "  told $next that $DESK is free" \
    || echo "  (could not notify $next)"
}
_claim_holder() {
  [ -f "$CLAIM" ] || return 1
  local who until now
  who=$(sed -n 1p "$CLAIM" 2>/dev/null); until=$(sed -n 2p "$CLAIM" 2>/dev/null)
  now=$(date +%s)
  case "$until" in ''|*[!0-9]*) return 1 ;; esac
  # A LAPSED CLAIM MUST NOTIFY TOO. Release is the tidy path; expiry is the
  # common one, because an agent that finishes and moves on rarely remembers to
  # release. Without this the queue only ever drained on the well-behaved path
  # and a waiter could sit forever behind a holder who simply walked away.
  if [ "$now" -ge "$until" ]; then
    rm -f "$CLAIM" 2>/dev/null
    _notify_next_waiter 2>/dev/null || true
    return 1
  fi
  echo "$who $(( (until - now + 59) / 60 ))"
  return 0
}
case "${1:-}" in
  claim)
    mins="${2:-15}"
    if h=$(_claim_holder); then
      # read, NOT `set --`: set REPLACES the positional parameters and destroyed
      # the subcommand the caller typed, so a claim holder could not use their
      # OWN desktop (fell through to usage, exit 2). Caught only by testing the
      # ALLOWED case; testing just the blocked case would have shipped it.
      read -r _who _mins <<<"$h"
      if [ "$_who" != "${TIX_AGENT:-?}" ]; then
        echo "'$DESK' is claimed by $_who for another $_mins min — do not drive it." >&2
        exit 75
      fi
    fi
    printf '%s\n%s\n' "${TIX_AGENT:-unknown}" "$(( $(date +%s) + mins * 60 ))" > "$CLAIM"
    echo "claimed $DESK for $mins min (expires on its own; release early with: desktop.sh release)"
    exit 0 ;;
  release)
    if h=$(_claim_holder); then
      # read, NOT `set --`: set REPLACES the positional parameters and destroyed
      # the subcommand the caller typed, so a claim holder could not use their
      # OWN desktop (fell through to usage, exit 2). Caught only by testing the
      # ALLOWED case; testing just the blocked case would have shipped it.
      read -r _who _mins <<<"$h"
      [ "$_who" = "${TIX_AGENT:-?}" ] || { echo "'$DESK' is claimed by $_who, not you — not releasing." >&2; exit 75; }
    fi
    rm -f "$CLAIM"; echo "released $DESK"
    _notify_next_waiter
    exit 0 ;;
  waiting)
    for d in ${DESKTOP_ROOT:-$HOME/agent-desktops}/*/; do
      o=$(basename "$d"); w="$d/.waitlist"
      if [ -s "$w" ]; then printf '  %-14s queue: %s\n' "$o" "$(tr '\n' ' ' < "$w")"
      else printf '  %-14s no one waiting\n' "$o"; fi
    done
    exit 0 ;;
  claims)
    for d in ${DESKTOP_ROOT:-$HOME/agent-desktops}/*/; do
      o=$(basename "$d"); c="$d/.claim"
      if [ -f "$c" ]; then
        u=$(sed -n 2p "$c" 2>/dev/null); n=$(date +%s)
        if [ -n "$u" ] && [ "$u" -gt "$n" ] 2>/dev/null; then
          printf '  %-14s claimed by %-10s %d min left\n' "$o" "$(sed -n 1p "$c")" "$(( (u-n+59)/60 ))"
        else printf '  %-14s free (stale claim)\n' "$o"; fi
      else printf '  %-14s free\n' "$o"; fi
    done
    exit 0 ;;
esac
# Someone else's live claim blocks every other command too, not just `claim`.
if h=$(_claim_holder); then
  # read, NOT `set --`: set REPLACES the positional parameters and destroyed
  # the subcommand the caller typed, so a claim holder could not use their
  # OWN desktop (fell through to usage, exit 2). Caught only by testing the
  # ALLOWED case; testing just the blocked case would have shipped it.
  read -r _who _mins <<<"$h"
  if [ "$_who" != "${TIX_AGENT:-?}" ]; then
    echo "desktop '$DESK' is CLAIMED by $_who for another $_mins min." >&2
    echo "  They are mid-task. Interleaving with them is how coordinates end up" >&2
    echo "  measured against a page that has already changed." >&2
    # QUEUE INSTEAD OF SPIN. the operator's suggestion, once: tell the
    # blocked agent WHO has it and get word back when they finish, rather than
    # leaving them to guess or -- worse -- invent a workaround, which is how two
    # agents ended up on one screen originally.
    if [ -n "${TIX_AGENT:-}" ]; then
      wl="${DESKTOP_ROOT:-$HOME/agent-desktops}/${DESK}/.waitlist"
      grep -qxF "$TIX_AGENT" "$wl" 2>/dev/null || echo "$TIX_AGENT" >> "$wl"
      echo "  You are QUEUED. You will be told when '$DESK' frees up — do not spin." >&2
      echo "  Queue: $(tr '\n' ' ' < "$wl" 2>/dev/null)" >&2
    fi
    echo "  Another screen may be free:  desktop.sh claims" >&2
    exit 75
  fi
fi

# IMPLICIT CLAIM. THE WHOLE POINT: the explicit `claim` command shipped at
# 15:48 and by 16:05 two agents were interleaving on another agent’s desktop again --
# another agent mid-task, another agent stepping in. The usage log shows ZERO claim commands
# ever run. Both agents were using the CLI correctly; neither claimed, because
# nothing made them.
#
# That was my design error, and the same one twice: I built a mechanism, told
# the operator it was handled, and left it depending on eleven agents remembering
# a step. Opt-in safety is not safety. So touching a desktop now CLAIMS it,
# automatically, and a second agent is refused without anyone having to
# remember anything.
#
# The auto-claim is SHORT (3 min) and EXTENDED BY USE, so an agent that takes
# one look does not hold a screen it has finished with, while an agent working
# steadily keeps it for as long as they keep working. An explicit
# `desktop.sh claim 15` is still there for a long task with pauses in it --
# filling a slow form, waiting on a page -- where 3 minutes of silence would
# otherwise hand the screen away mid-job.
if [ -n "${TIX_AGENT:-}" ]; then
  case "${1:-}" in
    claims|waiting|fit) : ;;   # read-only/inspection: never claim
    *)
      _auto=$(( $(date +%s) + ${DESKTOP_AUTOCLAIM_SECS:-180} ))
      if [ -f "$CLAIM" ]; then
        # Ours (the block above already refused anyone else) -- extend it, but
        # never SHORTEN an explicit longer claim.
        _cur=$(sed -n 2p "$CLAIM" 2>/dev/null)
        case "$_cur" in ''|*[!0-9]*) _cur=0 ;; esac
        [ "$_auto" -gt "$_cur" ] && printf '%s\n%s\n' "$TIX_AGENT" "$_auto" > "$CLAIM"
      else
        printf '%s\n%s\n' "$TIX_AGENT" "$_auto" > "$CLAIM"
      fi ;;
  esac
fi

# APPEND-ONLY USAGE LOG. There was none, so when the operator asked whether two
# agents were sharing a screen NOBODY COULD ANSWER -- not him, not me. A rule
# with no record is a rule you cannot check.
printf '%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "${TIX_AGENT:-unknown}" "$DESK" "${1:-?}" \
  >> "${DESKTOP_ROOT:-$HOME/agent-desktops}/usage.log" 2>/dev/null || true

if ! flock -w "${DESKTOP_LOCK_WAIT:-20}" 9 2>/dev/null; then
  # Do not just say "busy" — say what to do instead. the operator, once:
  # an agent turned away should be told which desktop IS free, and only told to
  # wait when they all are. A bare refusal makes agents invent workarounds,
  # which is how two of them ended up driving one screen in the first place.
  # NAME WHO IS HOLDING IT, AND FOR HOW LONG.
  # "busy — another agent is driving it" cannot distinguish a colleague working
  # normally from a WEDGED PROCESS holding the lock forever. Twice on
  # once a stuck `read` held this flock (6 min, then 8 min) and every
  # blocked agent saw only "busy" — so nobody could tell it was a corpse, and
  # another agent filed it as a desktop outage when it was one dead process.
  # fuser answers it in one line; showing it turns a mystery into a report.
  holder=$(fuser "$LOCK" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | head -1)
  if [ -n "$holder" ]; then
    hage=$(ps -o etime= -p "$holder" 2>/dev/null | tr -d ' ')
    hcmd=$(ps -o args= -p "$holder" 2>/dev/null | cut -c1-60)
    echo "  held by pid $holder for ${hage:-?}  ($hcmd)" >&2
    # CONVERT etime TO SECONDS. My first cut pattern-matched on the STRING and
    # only fired for HH:MM:SS or days -- but the real incidents showed as
    # "06:12" and "08:24" (MM:SS), so the warning would have stayed silent for
    # exactly the cases that caused it. Threshold 120s: longer than any normal
    # command, shorter than either wedge.
    hsec=$(printf '%s' "${hage:-0}" | awk -F'[-:]' '{
      if (NF==4) print $1*86400+$2*3600+$3*60+$4;
      else if (NF==3) print $1*3600+$2*60+$3;
      else if (NF==2) print $1*60+$2; else print 0 }')
    case "1" in
      1) [ "${hsec:-0}" -gt 120 ] && { echo "  THAT IS A LONG TIME — it may be wedged, not working." >&2
                      echo "  Check: fuser -v $LOCK   and kill EVERY pid listed," >&2
             echo "  including the 'docker' one: killing the bash alone does NOT" >&2
             echo "  release the lock, its docker exec child keeps the fd." >&2; } ;;
    esac
  fi
  free=""
  for other in ${DESKTOP_ROOT:-$HOME/agent-desktops}/*/; do
    o=$(basename "$other")
    [ "$o" = "$DESK" ] && continue
    docker inspect "${o}-desktop" >/dev/null 2>&1 || continue
    docker inspect -f '{{.State.Running}}' "${o}-desktop" 2>/dev/null | grep -q true || continue
    # A lock nobody holds can be taken immediately; flock -n tells us without waiting.
    if ( exec 8>"$other/.desktop.lock"; flock -n 8 ) 2>/dev/null; then free="$o"; break; fi
  done
  if [ -n "$free" ]; then
    echo "desktop '$DESK' is busy — another agent is driving it." >&2
    # NB: do not reference $cmd here — the lock runs BEFORE arguments are
    # parsed, and under `set -u` an unbound variable aborts the script with no
    # visible error. Made that exact mistake twice in this file today.
    echo "USE THIS ONE INSTEAD:  DESKTOP=$free $0 <same command>" >&2
    echo "(only if the work suits it — do not put your accounts on someone else's desktop)" >&2
  else
    echo "every desktop is busy right now (waited ${DESKTOP_LOCK_WAIT:-20}s)." >&2
    echo "Do NOT work around this. Wait and retry — a few minutes is normal." >&2
    echo "If you must be reminded, schedule it rather than spinning:" >&2
    echo "  echo 'retry the desktop job' | at now + 10 minutes    # or a systemd timer" >&2
  fi
  exit 75
fi

# --- pick ONE real browser window, and prove we got it ------------------------
# WHY: `xdotool search --class chromium windowactivate` applies to EVERY match,
# and Chromium keeps invisible utility windows (10x10, 200x200) in that class.
# The last one activated wins, so focus lands on a phantom and the following
# ctrl+l plus typed text goes wherever focus actually is -- including the XFCE
# desktop, which on once popped the wallpaper dialog and, on the next
# attempt, silently did nothing while still printing "opened". A navigation that
# reports success without navigating is the worst possible failure mode: I only
# caught it by screenshotting and noticing the tab title had not changed.
# On one agent's desktop the same fault could type over his live Outlook session.
# So: choose one window deliberately, activate it, VERIFY focus landed there,
# and refuse to type if it did not. Ticket an earlier incident.
_pick_window() {
  local w
  for w in $(X "xdotool search --class chromium" 2>/dev/null | tr -d '\r'); do
    [ -n "$w" ] || continue
    local geo width height
    geo=$(X "xdotool getwindowgeometry --shell $w" 2>/dev/null | tr -d '\r')
    width=$(printf '%s\n' "$geo" | sed -n 's/^WIDTH=//p')
    height=$(printf '%s\n' "$geo" | sed -n 's/^HEIGHT=//p')
    # Real browser windows are big; the utility ones are tiny.
    if [ "${width:-0}" -ge 400 ] 2>/dev/null && [ "${height:-0}" -ge 300 ] 2>/dev/null; then
      printf '%s\n' "$w"; return 0
    fi
  done
  return 1
}

_focus_window() {
  local w="$1" active
  X "xdotool windowactivate --sync $w" >/dev/null 2>&1
  sleep 1
  active=$(X "xdotool getactivewindow" 2>/dev/null | tr -d '\r\n ')
  [ "$active" = "$w" ] && return 0
  # One retry: the WM can refuse the first activate on a freshly mapped window.
  X "xdotool windowactivate --sync $w" >/dev/null 2>&1
  sleep 1
  active=$(X "xdotool getactivewindow" 2>/dev/null | tr -d '\r\n ')
  [ "$active" = "$w" ]
}


# ── where are these keystrokes actually going to land? ──────────────────────
# THE INCIDENT THIS PREVENTS. one agent clicked Outlook's search
# bar, the click landed on the message LIST instead, and her typed query became
# Outlook single-key shortcuts -- "R" opened REPLY on real customer threads in
# the operator's work inbox. Two compose panes. Nothing sent, by luck.
#
# The root cause of the miss was mine (a half-scale screenshot) and is fixed.
# But the SECOND failure is still live and general: `type` fires blind and
# reports "typed 12 chars" whether the characters became text or commands.
#
# So ask the browser. CDP knows exactly what has keyboard focus:
# document.activeElement being an INPUT/TEXTAREA/contenteditable means the text
# becomes text; a DIV or BODY means it becomes shortcuts. Costs ~0.3s.
#
# WARNS, DOES NOT BLOCK. The probe cannot see native dialogs or non-Chrome
# windows, so a confident refusal would eventually be confidently wrong and
# would break legitimate typing. the operator's ask, once: "a short message
# ... so that it only shows up once in the interaction."
#
# ONCE, NOT EVERY TIME: the verdict is remembered per desktop and the warning
# prints only on the transition into a bad state. Repeating it on every
# keystroke is how a real warning becomes noise that gets tuned out.
_focus_verdict() {
  docker exec -i "$C" python3 - <<'PYFOCUS' 2>/dev/null || echo "UNKNOWN probe-failed"
import sys, json, urllib.request, asyncio
try:
    import websockets
except Exception:
    print("UNKNOWN no-websockets"); sys.exit(0)
try:
    targets = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=4))
except Exception:
    print("UNKNOWN no-cdp"); sys.exit(0)
pages = [t for t in targets if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
if not pages:
    print("UNKNOWN no-page"); sys.exit(0)
EXPR = ("JSON.stringify({f:document.hasFocus(),"
        "a:(document.activeElement&&document.activeElement.tagName)||'',"
        "e:!!(document.activeElement&&document.activeElement.isContentEditable),"
        "r:(document.activeElement&&document.activeElement.getAttribute&&document.activeElement.getAttribute('role'))||''})")
async def probe(t):
    try:
        async with websockets.connect(t["webSocketDebuggerUrl"], max_size=2_000_000, open_timeout=4) as ws:
            await ws.send(json.dumps({"id":1,"method":"Runtime.evaluate",
                                      "params":{"expression":EXPR,"returnByValue":True}}))
            for _ in range(40):
                m = json.loads(await asyncio.wait_for(ws.recv(), timeout=4))
                if m.get("id") == 1:
                    v = (((m.get("result") or {}).get("result") or {}).get("value")) or "{}"
                    return json.loads(v)
    except Exception:
        return None
async def main():
    for t in pages:
        d = await probe(t)
        if d and d.get("f"):
            tag = (d.get("a") or "").upper()
            editable = d.get("e") or tag in ("INPUT", "TEXTAREA") or d.get("r") == "textbox"
            print(("SAFE " if editable else "UNSAFE ") + (tag or "NONE"))
            return
    print("UNKNOWN no-focused-page")
asyncio.run(main())
PYFOCUS
}

_warn_focus_once() {
  [ "${TYPE_NOCHECK:-0}" = "1" ] && return 0
  local st="${DESKTOP_ROOT:-$HOME/agent-desktops}/${DESK}/.focus.state" v prev
  v=$(_focus_verdict | tail -1)
  prev=$(cat "$st" 2>/dev/null)
  printf '%s' "$v" > "$st" 2>/dev/null
  case "$v" in
    UNSAFE*)
      [ "${prev%% *}" = "UNSAFE" ] && return 0        # already said so; stay quiet
      echo "⚠ NOTHING TEXT-EDITABLE HAS FOCUS (${v#UNSAFE }) — these keystrokes will act as SHORTCUTS, not text." >&2
      echo "  This is how a typed search became 'R' = reply on real mail." >&2
      echo "  Click the field again and re-check, or DESKTOP=${DESK} $0 read to see where you are." >&2
      echo "  Deliberate? TYPE_NOCHECK=1 silences this. Shown once, not per keystroke." >&2
      ;;
  esac
  return 0
}

cmd="${1:-}"; shift || true
case "$cmd" in
  shot)
    # STEER TO THE CHEAP PATH. Screenshots were the largest single cost on the
    # plan. This does not forbid `shot` -- sometimes you genuinely need
    # to see layout or find click coordinates -- but it names the alternative
    # every time, because the default habit was "photograph it to check", and
    # that habit is what produced a 190 MB session that was half image data.
    # REFUSED BY DEFAULT. the operator, once: agents read, control and
    # execute through the CLI; screenshots are not the working method.
    #
    # This used to be a polite NOTE and it did not change behaviour -- agents
    # kept photographing pages to read them, which was the single largest line
    # on the plan (one session 190 MB, 48% image data, 666 shots) AND the source
    # of the worst bug of the day: coordinates measured off an image are a
    # guess, and a half-scale image aimed every click on every desktop at the
    # wrong place for hours, opening reply panes on real customer mail.
    #
    # A block is only fair now that there is a real alternative for every
    # ordinary case, which there is as of an earlier incident:
    #     read       what the page SAYS      (~1% of the cost of an image)
    #     find       WHERE an element is, in screen coordinates, from the DOM
    #     pagetitle  did anything change at all
    #
    # THE ESCAPE HATCH IS DELIBERATE AND NARROW. CDP can only see Chrome pages.
    # Native XFCE windows, file dialogs, a browser that will not paint, a
    # rendering fault you have to SEE -- those have no text interface, and
    # blocking them outright would leave the desktop undiagnosable. SHOT_OK=1
    # says "I know why I need the picture". It is one variable, so it stays a
    # decision rather than a habit.
    if [ "${SHOT_OK:-0}" != "1" ]; then
      # THE MESSAGE IS THE DOCUMENTATION. the operator, once: "shouldn't
      # that info come from a message when they try to access? that way we
      # don't have to proactively inform." Correct -- and my reflex had been to
      # go and brief the agents by hand, which does not scale and misses anyone
      # woken later. A tool that changes its rules must teach them at the point
      # of refusal: WHAT to do instead, WHO set the rule (so it is not mistaken
      # for a bug worth routing around), and WHERE the full story is.
      echo "SCREENSHOTS ARE OFF — this is a rule from the operator, not a fault." >&2
      echo "Agents read, control and execute through the CLI. Use instead:" >&2
      echo "" >&2
      echo "    $0 read                        what the page SAYS" >&2
      echo "    $0 find \"<css selector>\"       WHERE to click -> screen x,y" >&2
      echo "    $0 find --text \"Send\"          same, by visible text" >&2
      echo "    $0 pagetitle                   did anything change" >&2
      echo "" >&2
      echo "  find reads coordinates from the page itself, so they cannot drift" >&2
      echo "  from what is rendered — a half-scale screenshot mis-aimed every" >&2
      echo "  click on every desktop for hours on once." >&2
      echo "" >&2
      echo "  Genuinely need to SEE it — a native dialog, a window that will not" >&2
      echo "  paint, a rendering fault with no text behind it? Say so on purpose:" >&2
      echo "      SHOT_OK=1 $0 shot" >&2
      echo "" >&2
      echo "  Full rules: the 'agent-desktops' skill (it loads in every session)." >&2
      exit 1
    fi
    out="$SHOT_DIR/screen.png"
    X "xwd -root -silent > /config/.shot.xwd" || { echo "capture failed" >&2; exit 1; }
    ffmpeg -y -loglevel error -i "${DESKTOP_ROOT:-$HOME/agent-desktops}/${DESK}/config/.shot.xwd" "$out" 2>/dev/null \
      || { echo "convert failed" >&2; exit 1; }
    rm -f "${DESKTOP_ROOT:-$HOME/agent-desktops}/${DESK}/config/.shot.xwd"
    # DO NOT DOWNSCALE. This block used to halve the image to save tokens
    # (2x smaller = ~4x cheaper to read) and it CAUSED A REAL INCIDENT on
    # once: the screen is 2048x2532, the saved PNG was 1024x1266, and
    # nothing said so. `click` takes ABSOLUTE screen coordinates, so every
    # coordinate an agent measured off a screenshot landed at HALF position --
    # up and to the left of the target, every single time.
    #
    # What that looked like in practice: one agent clicked Outlook's search bar and
    # landed on the message LIST. Focus went to the list, so her typed query
    # became Outlook keyboard shortcuts, and "R" opened REPLY on real customer
    # threads in the operator's work inbox. Two compose panes opened. Nothing was
    # sent, but only by luck.
    #
    # The optimisation broke the one thing a screenshot is FOR. Telling agents
    # to "remember to double the coordinates" is not a fix -- it is the same
    # foot-gun with a warning label. The cost problem is already solved properly
    # by steering to `read` above, which is ~1% of the cost, not 25%.
    #
    # If you are about to re-add this: don't. See an earlier incident.

    # PROVE THE IMAGE MATCHES THE SCREEN before handing it over. Tonight's
    # incident ran for hours because a screenshot silently disagreed
    # with reality and every consumer trusted it. The check that would have
    # caught it at the first capture costs one xdotool call, so do it every
    # time rather than relying on anyone remembering this happened.
    #
    # ONE-LINE python on purpose: the first version of this check used an
    # indented multi-line heredoc, and any reindentation broke it into an
    # IndentationError -> empty output -> check skipped. It sailed past a
    # deliberately half-scale test image while printing nothing. A guard that
    # quietly turns itself off is the exact failure it was written to prevent.
    geo=$(X "xdotool getdisplaygeometry" 2>/dev/null | tr -d '\r')
    sw=${geo%% *}; sh=${geo##* }
    dims=$(python3 -c 'import sys;from PIL import Image;im=Image.open(sys.argv[1]);print(im.size[0],im.size[1])' "$out" 2>/dev/null)
    iw=${dims%% *}; ih=${dims##* }
    if [ -z "$dims" ] || [ -z "$geo" ]; then
      # Say so rather than passing silently. Unverified is not the same as fine.
      echo "WARNING: could not verify this screenshot against the screen" >&2
      echo "  (image dims: ${dims:-unreadable}, screen: ${geo:-unreadable})." >&2
      echo "  Before clicking from it, check the size matches: xdotool getdisplaygeometry" >&2
    else
      # TOLERANCE, because the original check demanded EXACT equality and that
      # was wrong. What this guard exists to catch is a SCALED capture — a
      # half-size image (960 vs 1920) makes every click land at half position,
      # which opened reply panes on real customer mail. That is a ~50%
      # error. A window manager reporting 1918 where the image is 1920 is a
      # 2px border artefact and cannot misplace a click by anything that
      # matters — but the strict check refused it identically, and on
      # once that blocked another agent from an expense report the operator needed
      # THAT DAY, on an app whose content is inside an iframe so `read` could
      # not see it and `shot` was the only route.
      #
      # A guard that blocks correct work is not being safe, it is being
      # useless in a way that costs someone their afternoon. 8px is far below
      # anything that mis-targets a click and far above any plausible border.
      dw=$(( iw > sw ? iw - sw : sw - iw ))
      dh=$(( ih > sh ? ih - sh : sh - ih ))
      if [ "$dw" -gt 8 ] || [ "$dh" -gt 8 ]; then
        echo "REFUSING THIS SCREENSHOT: it is ${iw}x${ih} but the screen is ${sw}x${sh}." >&2
        echo "  Off by ${dw}x${dh}px - too much. Coordinates read off it will NOT match" >&2
        echo "  what 'click' does; click takes ABSOLUTE screen coordinates. This exact" >&2
        echo "  mismatch opened reply panes on real mail on once." >&2
        echo "  Fix the capture; do not scale by hand." >&2
        exit 1
      elif [ "$dw" -ne 0 ] || [ "$dh" -ne 0 ]; then
        echo "note: image ${iw}x${ih} vs screen ${sw}x${sh} (off by ${dw}x${dh}px)." >&2
        echo "  Within tolerance - clicks will land correctly. Proceeding." >&2
      fi
    fi
    echo "$out"
    ;;
  click)     X "xdotool mousemove ${1:?x} ${2:?y} click 1"; echo "clicked $1,$2" ;;
  rclick)    X "xdotool mousemove ${1:?x} ${2:?y} click 3"; echo "right-clicked $1,$2" ;;
  dblclick)  X "xdotool mousemove ${1:?x} ${2:?y} click --repeat 2 1"; echo "double-clicked $1,$2" ;;
  move)      X "xdotool mousemove ${1:?x} ${2:?y}"; echo "moved to $1,$2" ;;
  type)      t="${1:?text}"; _warn_focus_once
             X "xdotool type --delay 40 -- $(printf '%q' "$t")"; echo "typed ${#t} chars" ;;
  key)       X "xdotool key ${1:?key}"; echo "pressed $1" ;;
  scroll)
    dir="${1:-down}"; n="${2:-3}"; btn=5; [ "$dir" = up ] && btn=4
    X "xdotool click --repeat $n $btn"; echo "scrolled $dir x$n" ;;
    url)
      # If NOTHING is running, start the browser rather than typing into thin
      # air. This used to drive ctrl+l at a desktop with no browser on it, fail
      # every xdotool call silently, and still print "opened" — a second agent lost time
      # to exactly that on a fresh desktop (once) with the operator waiting.
      #
      # Detect by CLASS, not by window NAME: a browser showing
      # "X - The Everything App" contains no "chrom" in its title, so a
      # name-based check reports "no browser" while one is plainly on screen.
      # The original code had this flaw too and would silently type into
      # nothing whenever the page title lacked the word chrome.
      #
      # ALWAYS via /usr/local/bin/chrome, never the raw binary: the wrapper is
      # where --proxy-pac-url lives, and launching around it silently sends
      # traffic out from the datacenter instead of his home connection.
      if ! X "xdotool search --class chromium" | grep -q .; then
        echo "no browser on the ${DESK} desktop — starting one"
        docker exec -u abc -d "$C" bash -c \
          "DISPLAY=:1 nohup /usr/local/bin/chrome --new-window $(printf '%q' "${1:?url}") >/dev/null 2>&1 &" 2>/dev/null
        for _ in $(seq 1 20); do
          sleep 2
          X "xdotool search --class chromium" | grep -q . && break
        done
        if X "xdotool search --class chromium" | grep -q .; then
          echo "opened ${1} in a new browser"
        else
          echo "FAILED to start a browser on ${DESK} — check: hq desktop check ${DESK}" >&2
          exit 1
        fi
      else
        w=$(_pick_window) || {
          echo "no usable browser window on ${DESK} (only phantom/utility windows)" >&2; exit 1; }
        _focus_window "$w" || {
          echo "REFUSING to type: could not focus browser window $w on ${DESK}." >&2
          echo "Something else holds focus; typing now would land in the wrong window." >&2
          exit 1; }
        X "xdotool key ctrl+l"; sleep 1
        X "xdotool type --delay 30 -- $(printf '%q' "${1:?url}")"; sleep 1
        X "xdotool key Return"
        echo "opened ${1}"
      fi ;;
    tab)
      # Open a url in a NEW TAB, leaving what is already on screen alone.
      #
      # WHY THIS EXISTS. `url` drives ctrl+l, which navigates the CURRENT tab
      # and silently destroys whatever was there. That is fine on your own
      # desktop and hostile on a shared one: on once another agent's published
      # mockup was sitting on a second agent's desktop waiting for the operator to sign in
      # when I needed Cloudflare on the same screen. `url` would have thrown
      # his page away with no warning and no way to tell it had happened.
      #
      # Deliberately does NOT start a browser. The obvious implementation --
      # re-exec ourselves as `url` -- deadlocks: this process already holds the
      # desktop lock on fd 9, and the re-exec'd copy blocks forever trying to
      # take the same lock through a new descriptor. Say so and stop instead.
      if ! X "xdotool search --class chromium" | grep -q .; then
        echo "no browser on the ${DESK} desktop — start one first:" >&2
        echo "  DESKTOP=${DESK} $0 url ${1:?url}" >&2
        exit 1
      fi
      w=$(_pick_window) || {
        echo "no usable browser window on ${DESK}" >&2; exit 1; }
      _focus_window "$w" || {
        echo "REFUSING to type: could not focus browser window on ${DESK}." >&2; exit 1; }
      # CHECK THE ARGUMENT BEFORE OPENING A TAB, not in the middle of typing.
      # ${1:?url} fires under `set -u` AFTER ctrl+t has already run, so
      # `desktop.sh tab` with no argument left an empty tab open and died with
      # "line 690: 1: unbound variable" — a shell diagnostic, not an
      # explanation.
      [ -n "${1:-}" ] || {
        echo "desktop.sh tab needs a URL:  desktop.sh tab https://example.com" >&2
        echo "  (to switch between existing tabs use:  desktop.sh tabs / focus <n>)" >&2
        exit 2; }
      X "xdotool key ctrl+t"; sleep 2
      X "xdotool type --delay 30 -- $(printf '%q' "$1")"; sleep 1
      X "xdotool key Return"
      echo "opened ${1} in a new tab" ;;
  read)
    # Ask the page what it SAYS instead of photographing it.
    #
    # WHY THIS EXISTS. Screenshots were the single largest cost on the whole
    # plan: one session was 190 MB, 48% base64 image data, 666 shots.
    # An image never leaves the conversation -- it is re-sent on EVERY turn
    # after it -- so screenshotting to check "did that work?" compounds into
    # the dominant bill. A text answer does not. This returns the page's title,
    # URL and visible text for a rounding error of the cost.
    #
    # Requires --remote-debugging-port in /usr/local/bin/chrome (see the wrapper).
    # The port is bound inside the container only: no docker port mapping, not
    # on the tailnet, reachable solely via docker exec.
    #
    # USE THIS FIRST. Reach for `shot` only when you genuinely need to SEE
    # layout or click coordinates.
    # NO 2>/dev/null. It was there to hide websockets' noise and instead threw
    # away every diagnostic this block writes -- including "no FOCUSED page"
    # and the new busy-page message -- leaving a bare exit code and nothing to
    # act on. That is why one agent saw `read` fail with no explanation on
    # once and fell back to screenshots: the tool knew what was wrong and
    # discarded it on the way out. A silent failure is worse than a noisy one.
    _ft=$(cat "${DESKTOP_ROOT:-$HOME/agent-desktops}/${DESK}/.focustab" 2>/dev/null || true)
    docker exec -i -e FOCUS_TAB="$_ft" "$C" python3 - "${1:-4000}" <<'PYCDP'
import sys, json, asyncio, urllib.request
try:
    import websockets
except Exception:
    print("websockets missing in container", file=sys.stderr); sys.exit(1)
limit = int(sys.argv[1])
try:
    targets = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=5))
except Exception as e:
    print("no CDP on 9222 (%s). Is chrome running with --remote-debugging-port?" % e, file=sys.stderr)
    sys.exit(1)
pages = [t for t in targets if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
if not pages:
    print("no page target", file=sys.stderr); sys.exit(1)
# THE FOCUSED PAGE, not simply the first one CDP lists. Found by one agent in live
# testing on once: `read` returned a stray "Bad Gateway" tab's content
# while `find` and `pagetitle` both correctly reported Outlook as focused at the
# same instant. pages[0] is whatever order the debugger happens to return, so
# `read` was confidently describing a DIFFERENT WINDOW than the one being driven
# -- the worst shape of wrong, because the output looks perfectly valid.
#
# `find` got this right from the start and `read` did not, purely because read
# was written first and I never came back to it. Same selection logic now.
# TIMEOUT IS NOT THE SAME ANSWER AS "NOT FOCUSED", and conflating them is the
# bug one agent hit on once: `read` and `find` failed repeatedly on
# one agent’s desktop while `pagetitle` succeeded on the same window. Measured at the
# time, three of eight page targets -- including the Outlook page that WAS the
# active X window -- did not answer a Runtime.evaluate within the 4s budget.
# The old handler returned False for a TimeoutError, so a busy page looked
# exactly like an unfocused one, and the tool reported "no focused page" about
# a page that was focused and merely slow. She fell back to screenshots, which
# are the expensive path this whole read/find route exists to avoid.
#
# Two changes: probe every page CONCURRENTLY (so a generous timeout costs
# wall-clock once, not once per page), and REPORT timeouts separately so the
# next person is told "busy, retry" instead of a wrong diagnosis.
def _focused(pages):
    # HONOUR AN EXPLICIT `focus` CHOICE FIRST.
    # With more than one browser WINDOW open, several pages can each report
    # document.hasFocus() == true -- one per window -- and this used to return
    # whichever the debugger happened to list first. So `desktop.sh focus 1`
    # would correctly switch to the vendor app, confirm focus, and `read` would still
    # hand back a Microsoft page. The tool was not wrong about focus; "the
    # focused page" was simply ambiguous and it picked blind. Same family as
    # the pages[0] bug this function was written to fix.
    try:
        # PASSED IN AS AN ENV VAR, not read from a file. The first version
        # opened ${DESKTOP_ROOT:-$HOME/agent-desktops}/<desk>/.focustab -- a HOST path,
        # while this python runs INSIDE the container, where it does not exist.
        # The read silently failed, the preference was never applied, and
        # `focus` kept reporting success while read returned another window's
        # page. Three fixes chased the wrong layer before this one.
        import os as _os
        _want = _os.environ.get("FOCUS_TAB", "").strip()
        if _want:
            for _p in pages:
                if _p.get("id") == _want:
                    # RETURN IT OUTRIGHT, do not merely reorder. An explicit
                    # `desktop.sh focus <n>` is the agent stating which page it
                    # means; deferring to hasFocus() after that just reinstates
                    # the ambiguity focus exists to resolve. Reordering was not
                    # enough -- the chosen page can report hasFocus() false
                    # while another window's page reports true, so the probe
                    # skipped straight past it and read the wrong page anyway.
                    return _p, 0
    except Exception:
        pass
    import asyncio as _a, json as _j, websockets as _w
    async def probe(t):
        try:
            async with _w.connect(t["webSocketDebuggerUrl"], max_size=1_000_000, open_timeout=10) as ws:
                await ws.send(_j.dumps({"id":99,"method":"Runtime.evaluate",
                                        "params":{"expression":"document.hasFocus()","returnByValue":True}}))
                for _ in range(20):
                    m = _j.loads(await _a.wait_for(ws.recv(), timeout=10))
                    if m.get("id") == 99:
                        return bool((((m.get("result") or {}).get("result") or {}).get("value")))
        except (_a.TimeoutError, TimeoutError):
            return "timeout"
        except Exception:
            return False
        return False
    async def pick():
        res = await _a.gather(*(probe(t) for t in pages))
        slow = sum(1 for r in res if r == "timeout")
        for t, r in zip(pages, res):
            if r is True:
                return t, slow
        return None, slow
    return _a.run(pick())

t, slow = _focused(pages)
if t is None:
    # Say so rather than silently reading an arbitrary tab. A wrong answer that
    # looks right is worse than no answer -- that is the whole lesson of an earlier incident.
    if slow:
        # MEASURED, not guessed (once, one agent’s desktop): healthy targets
        # answer a trivial `1+1` in 0.0s; the failing ones time out at 30s on
        # that same expression. So this is a DEAD RENDERER, not a slow one, and
        # "wait and retry" is wrong advice -- waiting never helps. The tab has
        # to be reloaded to respawn its renderer. Two of the three hung targets
        # were abandoned shopping tabs; one was the Outlook window actually in
        # use, which is why `pagetitle` (X11, never touches the renderer)
        # succeeded on the very window `read` could not see.
        print("%d of %d page target(s) are UNRESPONSIVE — hung renderer, not busy." % (slow, len(pages)), file=sys.stderr)
        print("  Verified by measurement: a healthy tab answers in ~0.0s; these do not", file=sys.stderr)
        print("  answer at all. Waiting will NOT help.", file=sys.stderr)
        print("  Fix:  desktop.sh revive   (closes the wedged target via the browser", file=sys.stderr)
        print("  process and reopens its URL; ctrl+F5 does NOT work - a keystroke goes to", file=sys.stderr)
        print("  the very window that stopped responding. Discards unsaved drafts.)", file=sys.stderr)
        sys.exit(5)
    print("no FOCUSED page — click the window you mean, then read again.", file=sys.stderr)
    print("  (%d page target(s) open; refusing to guess which one you meant)" % len(pages), file=sys.stderr)
    sys.exit(4)
async def go():
    # HARD DEADLINE. This loop was `while True: await ws.recv()` with NO
    # timeout anywhere -- if the page never returned a reply with id 1, read
    # waited forever. It held the SHARED desktop flock while doing so, so one
    # slow page blocked every agent on that desktop. Seen twice on once:
    # six minutes, then eight.
    # Latent for a long time; the heavier iframe-walking expression made it
    # surface. A recv with no deadline is not a read, it is a hostage.
    async with websockets.connect(t["webSocketDebuggerUrl"], max_size=20_000_000,
                                  open_timeout=10) as ws:
        await ws.send(json.dumps({"id":1,"method":"Runtime.evaluate","params":{
            # SAME-ORIGIN IFRAME CONTENT, folded into the page text.
            # Without it, read returns a page's OUTER SHELL ONLY and does not
            # say it is hiding the application. Measured once: 40.3 MB of
            # one agent's 42.8 MB context was 308 SCREENSHOTS, taken because
            # the vendor expense app lives in an iframe and read showed her a
            # nav bar. Verified on a controlled page served over http:
            # before, read returned "Outer shell nav only"; now it returns the
            # form inside. Note file:// iframes are cross-origin to a file://
            # parent, so a file:// test page proves nothing -- that cost me a
            # false negative.
            "expression":"JSON.stringify({t:document.title,u:location.href,x:(function(){var o=document.body?document.body.innerText:'';try{document.querySelectorAll('iframe').forEach(function(f){try{var d=f.contentDocument;if(d&&d.body){var it=d.body.innerText;if(it&&it.trim().length>20){o+='\\n\\n[iframe '+(f.getAttribute('src')||'inline')+']\\n'+it;}}}catch(e){}});}catch(e){}return o;})()})",
            "returnByValue":True}}))
        _dl = asyncio.get_event_loop().time() + 25
        while True:
            _left = _dl - asyncio.get_event_loop().time()
            if _left <= 0:
                print("read timed out after 25s — the page never replied.", file=sys.stderr)
                print("  It may be wedged: desktop.sh tabs   (! marks unresponsive)", file=sys.stderr)
                sys.exit(7)
            m = json.loads(await asyncio.wait_for(ws.recv(), timeout=_left))
            if m.get("id") == 1:
                v = (((m.get("result") or {}).get("result") or {}).get("value")) or "{}"
                d = json.loads(v)
                print("TITLE: %s" % d.get("t",""))
                print("URL:   %s" % d.get("u",""))
                txt = " ".join((d.get("x") or "").split())
                print("TEXT:  %s" % txt[:limit])
                if len(txt) > limit:
                    print("... [%d more chars; pass a larger limit]" % (len(txt)-limit))
                return
asyncio.run(go())

# CROSS-ORIGIN FRAME READING WAS REMOVED HERE, once -- it HUNG.
# The mechanism worked and was proved against the live vendor app, but the
# implementation blocked forever: Page.enable streams events continuously, and
# a receive loop that only times out PER MESSAGE never reaches an overall
# deadline. One `desktop.sh read` held the shared desktop flock for SIX MINUTES
# and blocked every other agent. Adding an overall deadline and dropping
# Page.enable did NOT fix it, so it comes out rather than stay in while a
# shared tool is debugged in production.
# Evidence and the working prototype are on an earlier incident.
# Also learned: killing desktop.sh does NOT release the lock -- its `docker
# exec` child survives and keeps the file descriptor. Kill the docker pid too.
PYCDP
    ;;
  find)
    # WHERE IS IT ON SCREEN -- without a screenshot.
    #
    # the operator, via one agent, once: is there something that gives click
    # coordinates without a full screenshot each time? Yes. The page already
    # knows exactly where its elements are; getBoundingClientRect gives CSS
    # coordinates and the window's own geometry converts them to screen ones:
    #
    #   screen_x = window.screenX + css_x * devicePixelRatio
    #   screen_y = window.screenY + (outerHeight - innerHeight) + css_y * dpr
    #
    # VERIFIED END TO END before shipping, not derived on paper: predicted the
    # centre of two elements, moved the REAL pointer there with xdotool, and
    # asked the page what it saw. It reported clientX/clientY landing dead on
    # both targets. (`:hover` does NOT track in this X session -- that was my
    # first verifier and it returned NONE for everything, which looked like a
    # broken mapping and was a broken test.)
    #
    # WHY IT MATTERS BEYOND COST. Screenshots were the largest single line on
    # the plan, but the sharper problem is that coordinates read off an image
    # are a GUESS, and on once a half-scale image aimed every click on
    # every desktop at the wrong place for hours. These coordinates come
    # from the page itself, so they cannot drift from what is actually rendered.
    # The screen also RESIZES with the viewer's client -- one agent's went 2048x2532
    # to 1920x1080 during one session -- so any saved image is stale by nature.
    #
    #   desktop.sh find "input[type=search]"      CSS selector
    #   desktop.sh find --text "Send"             visible text, exact or substring
    #
    # Prints: TAG#id  x,y  (w x h)  "label" -- x,y is the CENTRE, ready for click.
    mode="sel"; [ "${1:-}" = "--text" ] && { mode="text"; shift; }
    q="${1:?usage: desktop.sh find \"<css selector>\" | --text \"<visible text>\"}"
    # NO `2>/dev/null` HERE. The first version had it and swallowed this
    # command's OWN error messages: a selector that matched nothing printed
    # absolutely nothing and exited 0, which reads as "found it, no output".
    # That is the same silent-success trap this file already documents for the
    # lock (`exec 9>"$LOCK" 2>/dev/null` hid every error the script could
    # print), and I reintroduced it three sections further down the same file.
    _heal_viewport
    MODE="$mode" Q="$q" docker exec -i -e MODE -e Q "$C" python3 - <<'PYFIND'
import os, sys, json, urllib.request, asyncio
try:
    import websockets
except Exception:
    print("websockets missing in container", file=sys.stderr); sys.exit(1)
try:
    targets = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=5))
except Exception as e:
    print("no CDP on 9222 (%s)" % e, file=sys.stderr); sys.exit(1)
pages = [t for t in targets if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
if not pages:
    print("no page target", file=sys.stderr); sys.exit(1)
mode, q = os.environ.get("MODE", "sel"), os.environ.get("Q", "")
qj = json.dumps(q)
# Only the FOCUSED page is trustworthy: a background window reports stale and
# sometimes contradictory geometry (one here had outerWidth < innerWidth).
EXPR = """(() => {
  if (!document.hasFocus()) return JSON.stringify({skip:1});
  // A COLLAPSED VIEWPORT MAKES EVERY COORDINATE BELOW A LIE, and silently.
  // once: one agent’s desktop's browser window was 43 PIXELS TALL. Elements were
  // scrolled far outside it, so getBoundingClientRect returned positions that
  // mapped to other windows entirely -- two agents spent an evening clicking
  // things that were not there, each assuming a stacking or scroll bug. The
  // numbers looked perfectly plausible the whole time. `desktop.sh fit` fixes
  // it in one command; the point is to be TOLD rather than to debug it twice.
  if (window.innerHeight < 200 || window.innerWidth < 400) {
    return JSON.stringify({tiny: [window.innerWidth, window.innerHeight]});
  }
  const dpr = window.devicePixelRatio || 1;
  // THE ORIGIN IS IN CSS PIXELS AND MUST BE SCALED BY dpr, SAME AS THE RECT.
  // The old form added screenX/screenY and the chrome height UNSCALED, then
  // scaled only the element rect. Identical when dpr == 1, wrong by the whole
  // origin when it is not -- and the original verification was done on a
  // dpr == 1 desktop, so it never showed.
  //
  // another agent hit it: find reported a tile at y=164, the real position was
  // ~301, and her clicks opened the address-bar padlock instead. X looked fine
  // ONLY because screenX happens to be 0 there -- 0 + l*dpr == (0 + l)*dpr --
  // which is why this read as a Y-specific bug for a year.
  //
  // Measured on both desktops, which disagree and both fit (screenY + chrome):
  //   one agent’s desktop : dpr 1, screenY 27,  chrome 91 -> viewport top 118 css
  //   another agent’s desktop: dpr 2, screenY 134, chrome 0  -> viewport top 134 css
  // chrome is clamped at >= 0 because one real tab reported -971.
  const oxc = window.screenX;
  const oyc = window.screenY + Math.max(0, window.outerHeight - window.innerHeight);
  let els;
  if (%s === "text") {
    const needle = %s.toLowerCase();
    els = [...document.querySelectorAll('a,button,input,textarea,select,[role],label,span,div,li,td')]
      .filter(e => { const t = (e.innerText || e.value || e.getAttribute('aria-label') || '').trim().toLowerCase();
                     return t && t.includes(needle) && e.children.length < 3; });
  } else { els = [...document.querySelectorAll(%s)]; }
  // SMALLEST FIRST. --text matching hits an element AND every ancestor that
  // contains it, so the unsorted list led with a full-width container rather
  // than the row you meant. The tightest box around the text is the thing a
  // human would click.
  els.sort((a, b) => {
    const ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect();
    return (ra.width * ra.height) - (rb.width * rb.height);
  });
  const out = [];
  for (const e of els) {
    const r = e.getBoundingClientRect();
    // 8px, not 1px. A 1px threshold let through a 1912x1 wrapper as the match
    // for a login account row on once -- clicking its centre lands on
    // whatever sits above or below the hairline, never the row. Nothing under
    // ~8px tall is a real click target, and a degenerate rect is a WRAPPER,
    // which is the wrong element even when the click happens to land.
    if (r.width < 8 || r.height < 8) continue;
    if (r.bottom < 0 || r.right < 0 || r.top > window.innerHeight || r.left > window.innerWidth) continue;
    const st = getComputedStyle(e);
    if (st.visibility === 'hidden' || st.display === 'none' || +st.opacity === 0) continue;
    out.push({
      tag: e.tagName.toLowerCase(), id: e.id || '',
      label: ((e.getAttribute('aria-label') || e.placeholder || e.innerText || e.value || '').trim()).slice(0, 48),
      x: Math.round((oxc + r.left + r.width / 2) * dpr),
      y: Math.round((oyc + r.top + r.height / 2) * dpr),
      w: Math.round(r.width * dpr), h: Math.round(r.height * dpr)});
    if (out.length >= 20) break;
  }
  return JSON.stringify({url: location.href, n: out.length, els: out});
})()""" % (json.dumps(mode), qj, qj)
async def go():
    for t in pages:
        try:
            async with websockets.connect(t["webSocketDebuggerUrl"], max_size=8_000_000, open_timeout=5) as ws:
                await ws.send(json.dumps({"id":1,"method":"Runtime.evaluate",
                                          "params":{"expression":EXPR,"returnByValue":True}}))
                while True:
                    m = json.loads(await asyncio.wait_for(ws.recv(), timeout=6))
                    if m.get("id") == 1:
                        v = (((m.get("result") or {}).get("result") or {}).get("value")) or "{}"
                        d = json.loads(v)
                        if d.get("tiny"):
                            w, h = d["tiny"]
                            print("REFUSING: the browser viewport is %dx%d." % (w, h), file=sys.stderr)
                            print("  Every coordinate from a window that size is wrong -- elements sit", file=sys.stderr)
                            print("  outside it and map onto other windows. Fix it first:", file=sys.stderr)
                            print("      desktop.sh fit", file=sys.stderr)
                            print("  then run find again.", file=sys.stderr)
                            sys.exit(6)
                        if d.get("skip"): break
                        if not d.get("els"):
                            print("no visible match for: %s" % q, file=sys.stderr)
                            print("  the page IS reachable -- try a looser selector, or --text", file=sys.stderr)
                            sys.exit(2)
                        print("page: %s" % (d.get("url") or "")[:90])
                        for e in d["els"]:
                            name = (e["tag"] + ("#" + e["id"] if e["id"] else ""))
                            print("  %-22s %5d,%-5d  (%dx%d)  %s" % (name, e["x"], e["y"], e["w"], e["h"], e["label"]))
                        print("  -> click with: desktop.sh click <x> <y>")
                        return
        except Exception:
            continue
    print("no focused page could be read", file=sys.stderr)
    sys.exit(3)
asyncio.run(go())
PYFIND
    ;;
  revive)
    # THE REMEDY FOR A WEDGED RENDERER, and the second attempt at it.
    #
    # The first version sent ctrl+F5 with xdotool and DID NOT WORK -- one agent ran
    # it twice on a focused, hung Outlook tab with no effect (once). A
    # keystroke is delivered to the window, and the window is exactly the thing
    # that has stopped processing. Verified the active window really was the
    # hung tab at the time, so this was not a targeting mistake; the approach
    # was simply wrong.
    #
    # What DOES work is the DevTools HTTP endpoint, because it is served by the
    # BROWSER process rather than the page's renderer: /json/close/<id> closed a
    # hung Home Depot tab first try ("Target is closing", 8 targets -> 7) after
    # clicking its X in the tab overlay had done nothing at all.
    #
    # Closes every unresponsive target and reopens its URL, so a hung app comes
    # back rather than merely going away. --close-only skips the reopen, for
    # abandoned junk you do not want back.
    #
    # DESTRUCTIVE IN ONE NARROW WAY: an unsaved draft in a hung tab is gone.
    # It was already unreachable -- that is what "hung" means -- but say so.
    # DRY RUN BY DEFAULT. Added immediately after I got this wrong myself
    # (once): I ran revive on one agent's desktop against a hung tab that was
    # her LIVE Outlook session, having told her minutes earlier that I would
    # not touch her screen precisely because it might hold a draft. Closing it
    # dropped her Microsoft session and left her at an account picker she now
    # has to click through.
    #
    # The tool was not wrong; running it unprompted on someone else's desktop
    # was. So it now SHOWS what it would close and stops. --yes performs it.
    # A destructive default on a shared machine is a trap that will catch the
    # next person exactly as it caught me.
    only_close=""; go=""
    for a in "$@"; do
      [ "$a" = "--close-only" ] && only_close=1
      [ "$a" = "--yes" ] && go=1
    done
    ONLY="$only_close" GO="$go" docker exec -i "$C" python3 - <<'PYREVIVE'
import json,urllib.request,urllib.parse,asyncio,os,sys
try:
    import websockets
except Exception:
    print("websockets missing in container", file=sys.stderr); sys.exit(1)
B="http://127.0.0.1:9222"
try:
    targets=json.load(urllib.request.urlopen(B+"/json",timeout=5))
except Exception as e:
    print("no CDP on 9222 (%s)"%e, file=sys.stderr); sys.exit(1)
pages=[t for t in targets if t.get("type")=="page" and t.get("webSocketDebuggerUrl")]
async def alive(t):
    try:
        async with websockets.connect(t["webSocketDebuggerUrl"],open_timeout=8) as ws:
            await ws.send(json.dumps({"id":1,"method":"Runtime.evaluate",
                                      "params":{"expression":"1","returnByValue":True}}))
            for _ in range(30):
                m=json.loads(await asyncio.wait_for(ws.recv(),timeout=8))
                if m.get("id")==1: return True
    except Exception:
        return False
    return False
async def _probe_all():
    return await asyncio.gather(*(alive(t) for t in pages))
res=asyncio.run(_probe_all())
hung=[t for t,ok in zip(pages,res) if not ok]
if not hung:
    print("all %d page target(s) responsive - nothing to revive"%len(pages)); sys.exit(0)
print("%d unresponsive target(s):"%len(hung))
if not os.environ.get("GO"):
    for t in hung:
        print("  would close: %s"%((t.get("url") or "")[:80]))
    print("")
    print("DRY RUN - nothing touched. Re-run with --yes to actually do it.")
    print("WARNING: closing a tab drops anything unsaved in it, and for an app")
    print("like Outlook it can drop the signed-in session too - the tab may come")
    print("back at an account picker that a HUMAN has to click. Check whose")
    print("desktop this is before you run it.")
    sys.exit(0)
for t in hung:
    url=t.get("url") or ""
    print("  closing: %s"%url[:80])
    try:
        urllib.request.urlopen(B+"/json/close/"+t["id"],timeout=8).read()
    except Exception as e:
        print("    close FAILED: %s"%e); continue
    if os.environ.get("ONLY"): continue
    if not url or url.startswith(("chrome://","about:")):
        print("    (blank/internal - not reopening)"); continue
    try:
        # PUT, not GET. Chromium 111+ rejects GET on /json/new with 405 Method
        # Not Allowed -- found the hard way: the close half worked and every
        # reopen failed, which would have left tabs shut and nothing restored.
        req=urllib.request.Request(B+"/json/new?"+urllib.parse.quote(url,safe=":/?&=%"),method="PUT")
        urllib.request.urlopen(req,timeout=10).read()
        print("    reopened")
    except Exception as e:
        print("    reopen failed (%s) - open it yourself: desktop.sh url '%s'"%(e,url))
print("done - give heavy apps a few seconds, then read again")
PYREVIVE
    ;;
  tabs)
    # LIST THE TABS, NUMBERED, SAYING WHICH ONE HAS FOCUS.
    # read/find deliberately refuse when no page is focused ("refusing to guess
    # which one you meant") -- correct, because reading the wrong tab is worse
    # than reading none. But with ~10 targets open there was NO WAY to see what
    # was there or to choose one, so the refusal became a dead end. another agent hit
    # exactly this trying to verify the iframe fix on a vendor app (once).
    docker exec -i "$C" python3 - <<'PYTABS'
import json, urllib.request, asyncio, sys
try:
    import websockets
except Exception:
    websockets = None
B = "http://127.0.0.1:9222"
try:
    t = json.load(urllib.request.urlopen(B + "/json", timeout=5))
except Exception as e:
    print("no CDP on 9222 (%s)" % e, file=sys.stderr); sys.exit(1)
pages = [x for x in t if x.get("type") == "page" and x.get("webSocketDebuggerUrl")]
if not pages:
    print("no page targets"); sys.exit(0)

async def focused(p):
    if not websockets: return None
    try:
        async with websockets.connect(p["webSocketDebuggerUrl"], open_timeout=5) as ws:
            await ws.send(json.dumps({"id":1,"method":"Runtime.evaluate",
                "params":{"expression":"document.hasFocus()","returnByValue":True}}))
            for _ in range(20):
                m = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
                if m.get("id") == 1:
                    return bool(m["result"]["result"]["value"])
    except Exception:
        return "?"
    return "?"

async def go():
    res = await asyncio.gather(*(focused(p) for p in pages))
    for i, (p, f) in enumerate(zip(pages, res), 1):
        mark = "*" if f is True else ("!" if f == "?" else " ")
        print("  %s%2d  %-38s %s" % (mark, i, (p.get("title") or "")[:38], (p.get("url") or "")[:60]))
    print("")
    print("  * = has focus (read/find will use it)   ! = unresponsive, try: desktop.sh revive")
    print("  switch with: desktop.sh focus <number>")
asyncio.run(go())
PYTABS
    ;;
  focus)
    # NAMED `focus`, NOT `tab` -- `tab <url>` already exists and opens a URL in
    # a new tab. My first cut called this `tab <n>` and was silently
    # unreachable: the earlier case matched first, so `tab 2` cheerfully
    # reported "opened 2 in a new tab". A colliding subcommand does not error,
    # it just does something else.
    n="${1:?usage: desktop.sh focus <number from 'desktop.sh tabs'>}"
    # ACTIVATE IS NOT ENOUGH. /json/activate raises the tab, but a page raised
    # PROGRAMMATICALLY can still report document.hasFocus() === false -- found
    # once when an activated window was active at the X level and its page
    # still had no DOM focus, which is what read/find actually test. So: raise
    # the tab via CDP, then focus the Chromium window with xdotool, then VERIFY
    # rather than assume.
    tid=$(docker exec -i "$C" python3 -c "
import json,urllib.request,sys
t=json.load(urllib.request.urlopen('http://127.0.0.1:9222/json',timeout=5))
p=[x for x in t if x.get('type')=='page' and x.get('webSocketDebuggerUrl')]
i=int('$n')
print(p[i-1]['id'] if 1<=i<=len(p) else '')" 2>/dev/null)
    [ -n "$tid" ] || { echo "no tab $n — run: desktop.sh tabs" >&2; exit 2; }
    docker exec -i "$C" bash -lc "curl -s -m 8 http://127.0.0.1:9222/json/activate/$tid" >/dev/null 2>&1
    sleep 1
    # ACTIVATE THE WINDOW THAT ACTUALLY HOLDS THIS TAB.
    # First version took `xdotool search --class chromium | tail -1` -- an
    # ARBITRARY window. With two browser windows open it raised the wrong one,
    # so X focus stayed elsewhere, the target page reported hasFocus() false,
    # and read kept returning the other window's page while `focus` cheerfully
    # said it had switched. Match on the tab's title instead, which is what
    # Chromium puts in the window name.
    ttl=$(docker exec -i "$C" python3 -c "
import json,urllib.request
t=json.load(urllib.request.urlopen('http://127.0.0.1:9222/json',timeout=5))
print(next((x.get('title','') for x in t if x.get('id')=='$tid'),''))" 2>/dev/null)
    w=""
    if [ -n "$ttl" ]; then
      w=$(X "xdotool search --name $(printf '%q' "$ttl")" | tail -1)
    fi
    [ -n "$w" ] || w=$(X "xdotool search --class chromium" | tail -1)
    [ -n "$w" ] && X "xdotool windowactivate $w" >/dev/null 2>&1
    sleep 2
    ok=$(docker exec -i "$C" python3 -c "
import json,urllib.request,asyncio,sys
try: import websockets
except Exception: print('?'); sys.exit()
t=json.load(urllib.request.urlopen('http://127.0.0.1:9222/json',timeout=5))
tg=[x for x in t if x.get('id')=='$tid']
if not tg: print('gone'); sys.exit()
async def go():
    try:
        async with websockets.connect(tg[0]['webSocketDebuggerUrl'],open_timeout=6) as ws:
            await ws.send(json.dumps({'id':1,'method':'Runtime.evaluate','params':{'expression':'document.hasFocus()','returnByValue':True}}))
            for _ in range(20):
                m=json.loads(await asyncio.wait_for(ws.recv(),timeout=6))
                if m.get('id')==1: print('yes' if m['result']['result']['value'] else 'no'); return
    except Exception: print('?')
asyncio.run(go())" 2>/dev/null)
    case "$ok" in
      yes) printf '%s' "$tid" > "${DESKTOP_ROOT:-$HOME/agent-desktops}/${DESK}/.focustab"
           echo "switched to tab $n — it has focus, read/find will use it" ;;
      no)  echo "raised tab $n but it does NOT have DOM focus." >&2
           echo "  read/find will still refuse. Click into the page body once:" >&2
           echo "    desktop.sh find --text <something on that page>   then click it" >&2
           exit 1 ;;
      *)   echo "raised tab $n but could not confirm focus (page may be unresponsive)." >&2
           echo "  try: desktop.sh revive" >&2; exit 1 ;;
    esac ;;
  pagetitle) # cheapest possible probe: did the page change at all?
    X "xdotool getactivewindow getwindowname" ;;
  where)     X "xdotool getmouselocation" ;;
  # The X display is resized by whoever is VIEWING it (selkies follows the
  # browser). Disconnect and it can shrink under a Chromium window that was
  # sized for a bigger screen -- the window then extends past the right edge,
  # and anything out there is invisible to `shot` and unclickable. The symptom
  # is a window wider than `xdotool getdisplaygeometry`. This refits it.
  fit)
    X 'read w h < <(xdotool getdisplaygeometry); \
       for win in $(xdotool search --class chromium 2>/dev/null); do \
         g=$(xdotool getwindowgeometry $win | awk "/Geometry/ {print \$2}"); \
         ww=${g%%x*}; [ -z "$ww" ] && continue; [ "$ww" -lt 400 ] && continue; \
         xdotool windowmove $win 0 0; xdotool windowsize $win $w $h; \
       done; echo "fitted to ${w}x${h}"' ;;
  *) sed -n '3,20p' "$0" | sed 's/^# \?//'; exit 2 ;;
esac
