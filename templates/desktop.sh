#!/usr/bin/env bash
# Drive the desktop container: look at the screen, then act on it.
#
#   desktop.sh shot                 capture the screen -> prints a PNG path to Read
#   desktop.sh goal "<task>"        say what you are doing -- RUN THIS FIRST, once per task
#   desktop.sh activate --text "Go"  click an element BY NAME and verify -- prefer to click
#   desktop.sh activate "#submit"    same, by css selector
#   desktop.sh click <x> <y>        move there and left-click
#   desktop.sh rclick <x> <y>       right-click
#   desktop.sh dblclick <x> <y>     double-click
#   desktop.sh move <x> <y>         move the pointer only
#   desktop.sh fill --label "Website" "text"  focus a field BY NAME, type, verify -- prefer to click+type
#   desktop.sh fill "input#email" "text"      same, by css selector
#   desktop.sh choose "<combobox>" "<option>"  pick an option by text from a custom listbox (scrolls it)
#   desktop.sh type "text"          type text at the focus
#   desktop.sh key <keyspec>        a key or chord, e.g. Return, ctrl+l, alt+Tab
#   desktop.sh scroll up|down [n]   wheel
#   desktop.sh url <address>        open an address in the running Chrome
#   desktop.sh read | find | tabs | focus <n> | close-tab <n>   read the page over CDP, no image
#
# Input goes through xdotool, so these are real X events. A website cannot tell
# them from a hand on a mouse — unlike CDP-synthesised clicks, which are the
# ones bot detection looks for. That is the point of doing it this way.
#
# LOOK BEFORE ACTING, with `read` and `find` -- not `shot`, which is off by default.
# Coordinates from a stale screenshot click the wrong thing, and you will not
# notice until something odd has already happened.
set -uo pipefail

# Where this script lives, so it can find lib/. Resolved via BASH_SOURCE rather than $0 so it
# still works when invoked through a symlink or from any cwd -- agents call it by absolute path,
# by relative path, and from inside other scripts.
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# WHERE DESKTOP STATE LIVES. One folder per desktop under DESKTOP_ROOT: its shots, its lock,
# its claim, its goal. The installer creates them; this script only reads the layout.
DROOT="${DESKTOP_ROOT:-$HOME/.fleet/desktops}"

# WHICH DESKTOP. Select with DESKTOP=<name>, or DESKTOP_CONTAINER for a container whose name
# is not "<name>-desktop". Without either, the desktop is routed from the caller's identity
# (TIX_AGENT) -- see _default_desk below.
#
# FAIL CLOSED WHEN WE DO NOT KNOW WHO IS ASKING. A fallback to "some" desktop when the identity
# is unset is a trap: an interactive shell does not inherit TIX_AGENT, so the fallback hands
# a colleague's signed-in browser (mail, chat, consoles) to anyone who forgot to say which
# desktop they meant. Unknown identity REFUSES and says what to pass. Unattended jobs that need
# a desktop pass DESKTOP= explicitly, which is where that decision belongs.
# SELF-HEAL A COLLAPSED VIEWPORT INSTEAD OF JUST COMPLAINING ABOUT IT.
#
# The window collapses whenever a VIEWER disconnects from the desktop -- the X
# display follows the viewing browser, and a window sized for something larger
# is left stranded. That is routine, not exceptional, so it WILL recur.
#
# It has dropped a browser to 43 pixels tall. Every coordinate computed from it
# pointed at other windows. The first fix only DETECTED the state and told the agent to
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

# What the caller of `fit` actually wants to know: is the page USABLE now.
# Window geometry and CSS viewport are different numbers and can disagree by a
# factor of three; reporting only the one we changed is how a true message
# ("fitted to 1280x720") talked an agent out of the real cause for an hour.
_report_css_viewport() {
  docker exec -i "$C" python3 - <<'PYVP' 2>/dev/null || true
import json, urllib.request, asyncio, sys
try:
    import websockets
except Exception:
    sys.exit(0)
try:
    targets = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=4))
except Exception:
    sys.exit(0)
E = ("JSON.stringify({f:document.hasFocus(),w:innerWidth,h:innerHeight,"
     "d:devicePixelRatio})")
async def go():
    best = None
    for t in [x for x in targets if x.get("type") == "page" and x.get("webSocketDebuggerUrl")]:
        try:
            async with websockets.connect(t["webSocketDebuggerUrl"], max_size=1_000_000, open_timeout=4) as ws:
                await ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate",
                                          "params": {"expression": E, "returnByValue": True}}))
                while True:
                    m = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
                    if m.get("id") == 1:
                        v = json.loads(m["result"]["result"]["value"])
                        if v.get("f"):
                            best = v
                        elif best is None:
                            best = v
                        break
        except Exception:
            continue
        if best and best.get("f"):
            break
    if not best:
        return
    w, h, d = best["w"], best["h"], best["d"]
    print("  css viewport now %dx%d @%gx" % (w, h, d))
    if d > 1.5 and (w < 400 or h < 200):
        print("  ^ STILL UNUSABLE, and fit cannot fix it: the DISPLAY is scaled", file=sys.stderr)
        print("    %gx, so the window is right and the viewport is not." % d, file=sys.stderr)
        print("    Re-running fit will not change this; change the viewer's scaling.", file=sys.stderr)
asyncio.run(go())
PYVP
}

_default_desk() {
  # ROUTING IS BY CONVENTION, NOT A HARDCODED LIST -- nothing here names an agent, so adding or
  # removing one needs no edit to this file.
  #
  #   1. $DROOT/<agent> exists        -> that agent's OWN desktop (<agent>-desktop)
  #   2. a shared default is set      -> DEFAULT_DESKTOP, else the name in $DROOT/.default
  #   3. otherwise                    -> refuse (empty), listing what exists
  #
  # Lowercased before matching: with an exact match "Alice" and "alice" route differently, and
  # one capital letter between an agent and a colleague's signed-in browser is not a difference
  # anyone reliably respects.
  local a d
  a=$(printf '%s' "${TIX_AGENT:-}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
  [ -n "$a" ] || { echo ""; return; }
  if [ -d "$DROOT/$a" ]; then echo "$a"; return; fi
  d="${DEFAULT_DESKTOP:-}"
  [ -n "$d" ] || d=$(head -n1 "$DROOT/.default" 2>/dev/null | tr -cd 'a-z0-9_-')
  echo "$d"
}
DESK="${DESKTOP:-$(_default_desk)}"
if [ -z "$DESK" ]; then
  if [ -z "${TIX_AGENT:-}" ]; then
    echo "WHICH DESKTOP? I cannot tell who is asking (TIX_AGENT is not set)." >&2
  else
    echo "WHICH DESKTOP? '${TIX_AGENT}' has no desktop of its own and no shared default is set." >&2
  fi
  echo "  Refusing rather than guessing -- guessing puts an agent on somebody" >&2
  echo "  else's signed-in browser." >&2
  echo "" >&2
  echo "  Say it explicitly:   DESKTOP=<name> $0 $*" >&2
  echo "  Available:           $(ls -d "$DROOT"/*/ 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')" >&2
  exit 2
fi
C="${DESKTOP_CONTAINER:-${DESK}-desktop}"
# MEMORY WARNING (desktop-mem-watch.sh writes this): delivered here because it is free and shows up
# exactly when the agent is using the browser.
if [ -s "$DROOT/${DESK}/.mem-warn" ]; then
  cat "$DROOT/${DESK}/.mem-warn" >&2
  echo "  list tabs: DESKTOP=${DESK} $0 tabs    close one: DESKTOP=${DESK} $0 close-tab <number|url-substring>" >&2
fi
# WAKE ON USE. A desktop that was stopped to save memory is started by the first command that
# needs it. Bookkeeping commands (claims/release/waiting) must not start a browser just to report
# on it. Set DESKTOP_WAKE=0 to turn this off.
if [ "${DESKTOP_WAKE:-1}" != 0 ] && docker inspect "$C" >/dev/null 2>&1 \
   && [ "$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)" != true ]; then
  case "${1:-}" in claims|waiting|release|"") ;; *)
    echo "starting $C (it was stopped) ..." >&2
    docker start "$C" >/dev/null && sleep "${DESKTOP_WAKE_WAIT:-20}" || { echo "could not start $C" >&2; exit 75; } ;;
  esac
fi
SHOT_DIR="$DROOT/${DESK}/shots"
X() { docker exec -u abc "$C" bash -c "DISPLAY=:1 $*" 2>/dev/null; }

# LOGGING IS INSTALLED HERE, ABOVE EVERYTHING THAT CAN REFUSE. Below the claim check, the two
# most interesting events on a shared desktop would both be invisible: a command refused because
# another agent holds the screen, and a command that could not run because the container is down.

# APPEND-ONLY USAGE LOG. Without it, "were two agents sharing a screen?" has no answer. A rule
# with no record is a rule you cannot check.
printf '%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "${TIX_AGENT:-unknown}" "$DESK" "${1:-?}" \
  >> "$DROOT/usage.log" 2>/dev/null || true

# ── STRUCTURED EXECUTION RECORD ─────────────────────────────────────────────
# The TSV line above is written BEFORE the command runs, so it can only ever record that
# something was ATTEMPTED. That leaves these unanswerable:
#     Did that click work?            Where does desktop time actually go?
#     What actually fails, and where?  How repetitive is the work?
# A record of attempts without outcomes reads exactly like a record of a rule being ignored
# (every refused `shot` looks like a screenshot taken).
#
# So this one is written AFTERWARDS, with what happened. Deliberately small: one JSON object per
# action, no metrics platform, no daemon, no schema registry. It exists to answer four questions
# with evidence and then justify -- or kill -- everything downstream of it.
EXEC_LOG="$DROOT/exec.jsonl"
_T0=$(date +%s%3N 2>/dev/null || echo 0)
_EXEC_WRITTEN=0
_CMD_NAME="${1:-?}"
_CMD_ARG="${2:-}"

# THE GOAL IS THE FIELD THAT MAKES SUBTASKS VISIBLE, and it is the one thing here that cannot be
# inferred afterwards. `find -> click -> read` is the shape of EVERY task on this box; it tells
# you nothing. `find -> click -> read` under goal "open a customer record", seen 37 times, is a
# candidate for a deterministic sequence. Without the goal the n-gram is just the house style.
_goal_now() {
  local f="$DROOT/${DESK}/.goal" who until txt
  [ -r "$f" ] || { printf '%s' "${DESKTOP_GOAL:-}"; return; }
  { read -r who; read -r until; IFS= read -r txt; } < "$f" 2>/dev/null
  case "$until" in ''|*[!0-9]*) until=0 ;; esac
  # Another agent's goal is not yours, and a lapsed goal is nobody's.
  if [ "$who" = "${TIX_AGENT:-unknown}" ] && [ "$(date +%s)" -lt "$until" ]; then
    printf '%s' "$txt"
  else
    printf '%s' "${DESKTOP_GOAL:-}"
  fi
}

# outcome is REQUIRED and is never inferred from "the command did not crash".
_exec_log() {
  local cmd="$1" arg="${2:-}" role="${3:-}" name="${4:-}" outcome="${5:-}" cands="${6:-}" rc="${7:-}"
  # SETTLE TIME IS NOT WORK. activate waits for the page to respond before it verifies; counting
  # that wait as tool latency would answer "where does desktop time go" with our own sleep.
  local settle="${_SETTLE_MS:-0}"
  local t1 dur; t1=$(date +%s%3N 2>/dev/null || echo 0); dur=$((t1 - _T0))
  [ "$_T0" = 0 ] && dur=-1
  CMD="$cmd" ARG="$arg" ROLE="$role" NAME="$name" OUTCOME="$outcome" CANDS="$cands" \
  RC="$rc" DUR="$dur" SETTLE="$settle" AGENT="${TIX_AGENT:-unknown}" DESKN="$DESK" GOAL="$(_goal_now)" \
  python3 -c '
import os, json, time, sys
def n(v):
    try: return int(v)
    except Exception: return None
r = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
     "agent": os.environ["AGENT"], "desktop": os.environ["DESKN"],
     "goal": os.environ["GOAL"] or None,
     "cmd": os.environ["CMD"], "arg": (os.environ["ARG"] or None),
     "target_role": os.environ["ROLE"] or None,
     "target_name": os.environ["NAME"] or None,
     "candidates": n(os.environ["CANDS"]),
     "outcome": os.environ["OUTCOME"] or None,
     "rc": n(os.environ["RC"]),
     "duration_ms": n(os.environ["DUR"]),
     "settle_ms": n(os.environ["SETTLE"]) or None,
     "work_ms": (n(os.environ["DUR"]) or 0) - (n(os.environ["SETTLE"]) or 0),
     "decision_source": os.environ.get("DECISION_SOURCE") or "deterministic"}
sys.stdout.write(json.dumps(r) + "\n")' >> "$EXEC_LOG" 2>/dev/null || true
  _EXEC_WRITTEN=1
}

# Every command gets a row, not just the rich ones -- otherwise "where does the time go" is
# answerable only for the instrumented commands, which is the same blind spot again.
_exec_trap() {
  local rc=$?
  [ "$_EXEC_WRITTEN" = 1 ] && return
  _exec_log "$_CMD_NAME" "$_CMD_ARG" "" "" "$([ "$rc" = 0 ] && echo ok || echo failed)" "" "$rc"
}
trap _exec_trap EXIT

docker ps --format '{{.Names}}' | grep -qx "$C" || { echo "desktop container '$C' is not running" >&2; exit 1; }
mkdir -p "$SHOT_DIR"

# ── one agent on the desktop at a time ──────────────────────────────────────
# There is ONE X session and several agents that can drive it: interactive
# sessions, and fresh agents woken by the trigger dispatcher, which run with no
# knowledge of each other. Two sessions driving one browser concurrently is
# how a click meant for a dialog lands on a chat tab, because the other one
# moved focus mid-action.
#
# It is not only input: `shot` writes a SHARED /config/.shot.xwd and a SHARED
# screen.png, so two captures at once corrupt each other's image — and the
# caller cannot tell, which is the dangerous part.
#
# So every command takes an exclusive lock for its (short) duration. Failing
# loudly when the desktop is busy beats interleaving two agents' actions.
# One lock PER DESKTOP: two agents on the same screen must serialise, but one
# agent working on its own screen must not be blocked by another on theirs.
LOCK="$DROOT/${DESK}/.desktop.lock"
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
# The flock alone is not enough. flock is held for ONE desktop.sh invocation and released
# when the process exits, so it serialises individual COMMANDS and not a
# SESSION of work. Agent A can `find`, release, agent B can `click`, release,
# and A then clicks coordinates measured against a page B has already navigated
# away from. Every call is individually correct; the sequence is nonsense.
#
# `claim` writes a holder + expiry; other agents are refused for its duration.
# It EXPIRES ON A TIMER rather than needing release, because an agent that dies
# mid-task must not wedge a desktop until a human notices -- the failure this
# fleet must avoid is silent state nobody is watching.
CLAIM="$DROOT/${DESK}/.claim"
WAITLIST="$DROOT/${DESK}/.waitlist"

# TELL THE NEXT WAITER, ONCE, WITH A FIXED SENTENCE.
#
# Typing an arbitrary string into another agent's session would be an
# injection channel into every agent on the box. So this does NOT pass through
# any caller-supplied text. The message is a constant; the only variable is a desktop name matched
# against ^[a-z][a-z0-9-]*$ and confirmed to be a real directory. Nothing an
# agent controls reaches the keystrokes.
#
# One notification, to ONE waiter, who is removed from the queue as it is sent.
# No broadcast, no repeat: every agent told "a desktop is free" is chatter,
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
    for d in $DROOT/*/; do
      o=$(basename "$d"); w="$d/.waitlist"
      if [ -s "$w" ]; then printf '  %-14s queue: %s\n' "$o" "$(tr '\n' ' ' < "$w")"
      else printf '  %-14s no one waiting\n' "$o"; fi
    done
    exit 0 ;;
  claims)
    for d in $DROOT/*/; do
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
    # QUEUE INSTEAD OF SPIN: tell the blocked agent WHO has it and get word back when they finish, rather than
    # leaving them to guess or -- worse -- invent a workaround, which is how two
    # agents ended up on one screen originally.
    if [ -n "${TIX_AGENT:-}" ]; then
      wl="$DROOT/${DESK}/.waitlist"
      grep -qxF "$TIX_AGENT" "$wl" 2>/dev/null || echo "$TIX_AGENT" >> "$wl"
      echo "  You are QUEUED. You will be told when '$DESK' frees up — do not spin." >&2
      echo "  Queue: $(tr '\n' ' ' < "$wl" 2>/dev/null)" >&2
    fi
    echo "  Another screen may be free:  desktop.sh claims" >&2
    exit 75
  fi
fi

# IMPLICIT CLAIM. An explicit `claim` command on its own does not work: agents
# using the CLI correctly simply never run it, because nothing makes them, and
# two of them end up interleaving on one screen again within minutes.
#
# A mechanism that depends on every agent remembering a step is opt-in safety,
# and opt-in safety is not safety. So touching a desktop now CLAIMS it,
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


if ! flock -w "${DESKTOP_LOCK_WAIT:-20}" 9 2>/dev/null; then
  # Do not just say "busy" — say what to do instead. An agent turned away should be told which desktop IS free, and only told to
  # wait when they all are. A bare refusal makes agents invent workarounds,
  # which is how two of them ended up driving one screen in the first place.
  # NAME WHO IS HOLDING IT, AND FOR HOW LONG.
  # "busy — another agent is driving it" cannot distinguish a colleague working
  # normally from a WEDGED PROCESS holding the lock forever. A stuck `read` has
  # held this flock for minutes while every blocked agent saw only "busy" — so
  # it got reported as a desktop outage when it was one dead process.
  # fuser answers it in one line; showing it turns a mystery into a report.
  holder=$(fuser "$LOCK" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | head -1)
  if [ -n "$holder" ]; then
    hage=$(ps -o etime= -p "$holder" 2>/dev/null | tr -d ' ')
    hcmd=$(ps -o args= -p "$holder" 2>/dev/null | cut -c1-60)
    echo "  held by pid $holder for ${hage:-?}  ($hcmd)" >&2
    # CONVERT etime TO SECONDS. Pattern-matching the STRING only fires for
    # HH:MM:SS or days -- but real wedges show as "06:12" (MM:SS), so the warning would have stayed silent for
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
  for other in $DROOT/*/; do
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
    # visible error.
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
# desktop, where it pops the wallpaper dialog or silently does nothing while
# still printing "opened". A navigation that reports success without navigating
# is the worst possible failure mode; on a desktop with a live mail session the
# same fault types over it. So: choose one window deliberately, activate it,
# VERIFY focus landed there, and refuse to type if it did not.
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
# THE INCIDENT THIS PREVENTS. A click meant for a webmail search bar landed on
# the message LIST instead, and the typed query became single-key shortcuts --
# "R" opened REPLY on real customer threads. Nothing sent, by luck.
#
# The cause of the miss (a half-scale screenshot) is fixed. But the SECOND
# failure is general: `type` fires blind and
# reports "typed 12 chars" whether the characters became text or commands.
#
# So ask the browser. CDP knows exactly what has keyboard focus:
# document.activeElement being an INPUT/TEXTAREA/contenteditable means the text
# becomes text; a DIV or BODY means it becomes shortcuts. Costs ~0.3s.
#
# WARNS, DOES NOT BLOCK. The probe cannot see native dialogs or non-Chrome
# windows, so a confident refusal would eventually be confidently wrong and
# would break legitimate typing. A short message, shown once per interaction.
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
  local st="$DROOT/${DESK}/.focus.state" v prev
  v=$(_focus_verdict | tail -1)
  prev=$(cat "$st" 2>/dev/null)
  printf '%s' "$v" > "$st" 2>/dev/null
  case "$v" in
    UNSAFE*)
      [ "${prev%% *}" = "UNSAFE" ] && return 0        # already said so; stay quiet
      echo "⚠ NOTHING TEXT-EDITABLE HAS FOCUS (${v#UNSAFE }) — these keystrokes will act as SHORTCUTS, not text." >&2
      echo "  This is how a typed search becomes 'R' = reply on real mail." >&2
      echo "  Filling a form field? Use: $0 fill --label \"<field>\" \"<text>\" -- it focuses via the DOM." >&2
      echo "  Click the field again and re-check, or DESKTOP=${DESK} $0 read to see where you are." >&2
      echo "  Deliberate? TYPE_NOCHECK=1 silences this. Shown once, not per keystroke." >&2
      ;;
  esac
  return 0
}

cmd="${1:-}"; shift || true
case "$cmd" in
  shot)
    # STEER TO THE CHEAP PATH. Screenshots are the largest single cost on the
    # plan. This does not forbid `shot` -- sometimes you genuinely need
    # to see layout or find click coordinates -- but it names the alternative
    # every time, because the default habit was "photograph it to check", and
    # that habit is what produced a 190 MB session that was half image data.
    # REFUSED BY DEFAULT, on the operator's rule: agents read, control and
    # execute through the CLI; screenshots are not the working method.
    #
    # This used to be a polite NOTE and it did not change behaviour -- agents
    # kept photographing pages to read them, which was the single largest line
    # on the plan (one session 190 MB, 48% image data, 666 shots) AND the source
    # of the worst bug of the day: coordinates measured off an image are a
    # guess, and a half-scale image aimed every click on every desktop at the
    # wrong place for hours, opening reply panes on real customer mail.
    #
    # A block is only fair because there is a real alternative for every
    # ordinary case:
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
      # THE MESSAGE IS THE DOCUMENTATION. Briefing agents by hand does not scale
      # and misses anyone woken later. A tool that changes its rules must teach them at the point
      # of refusal: WHAT to do instead, WHO set the rule (so it is not mistaken
      # for a bug worth routing around), and WHERE the full story is.
      echo "SCREENSHOTS ARE OFF — this is a rule from your operator, not a fault." >&2
      echo "Agents read, control and execute through the CLI. Use instead:" >&2
      echo "" >&2
      echo "    $0 read                        what the page SAYS" >&2
      echo "    $0 find \"<css selector>\"       WHERE to click -> screen x,y" >&2
      echo "    $0 find --text \"Send\"          same, by visible text" >&2
      echo "    $0 pagetitle                   did anything change" >&2
      echo "" >&2
      echo "  find reads coordinates from the page itself, so they cannot drift" >&2
      echo "  from what is rendered — a half-scale screenshot mis-aimed every" >&2
      echo "  click on every desktop for hours once." >&2
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
    ffmpeg -y -loglevel error -i "$DROOT/${DESK}/config/.shot.xwd" "$out" 2>/dev/null \
      || { echo "convert failed" >&2; exit 1; }
    rm -f "$DROOT/${DESK}/config/.shot.xwd"
    # DO NOT DOWNSCALE. This block used to halve the image to save tokens
    # (2x smaller = ~4x cheaper to read) and it CAUSED A REAL INCIDENT: the
    # screen was 2048x2532, the saved PNG 1024x1266, and nothing said so.
    # `click` takes ABSOLUTE screen coordinates, so every coordinate an agent
    # measured off a screenshot landed at HALF position -- which is how a
    # typed search became reply shortcuts on real customer mail.
    #
    # The optimisation broke the one thing a screenshot is FOR. Telling agents
    # to "remember to double the coordinates" is not a fix -- it is the same
    # foot-gun with a warning label. The cost problem is already solved properly
    # by steering to `read` above, which is ~1% of the cost, not 25%.
    #
    # If you are about to re-add this: don't.

    # PROVE THE IMAGE MATCHES THE SCREEN before handing it over. That
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
      # matters — but the strict check refused it identically, and blocked
      # urgent work on an app whose content `read` could not see, where
      # `shot` was the only route.
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
        echo "  mismatch once opened reply panes on real mail." >&2
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
      # LONG-ADDRESS GUARD: the address is TYPED by xdotool at 30 ms/char. A 48 KB data: URL takes
      # ~24 min, holds the desktop lock, spills keystrokes into other tabs and can wedge Chromium.
      # Refuse anything over 2000 chars and point at the file:// route.
      if [ "${#1}" -gt 2000 ]; then
        echo "REFUSING: address is ${#1} chars; desktop.sh types it at 30 ms/char (~$(( ${#1} * 30 / 60000 )) min) and long ones wedge the browser." >&2
        echo "Write the content to a file, then: docker cp <file> ${C}:/config/page.html && desktop.sh tab file:///config/page.html" >&2
        exit 2
      fi
      # If NOTHING is running, start the browser rather than typing into thin
      # air. This used to drive ctrl+l at a desktop with no browser on it, fail
      # every xdotool call silently, and still print "opened" on a fresh desktop.
      #
      # Detect by CLASS, not by window NAME: a browser showing
      # "X - The Everything App" contains no "chrom" in its title, so a
      # name-based check reports "no browser" while one is plainly on screen.
      # The original code had this flaw too and would silently type into
      # nothing whenever the page title lacked the word chrome.
      #
      # PREFER a /usr/local/bin/chrome wrapper if the desktop has one: that is
      # where per-desktop flags (proxy, profile) live, and launching around it
      # silently drops them. Without one, launch the stock browser with the
      # local debug port that read/find/tabs depend on.
      if ! X "xdotool search --class chromium" | grep -q .; then
        echo "no browser on the ${DESK} desktop — starting one"
        docker exec -u abc -d "$C" bash -c \
          "B=/usr/local/bin/chrome; [ -x \$B ] || B=\$(command -v chromium || command -v chromium-browser || command -v google-chrome); DISPLAY=:1 nohup \$B --remote-debugging-port=9222 --remote-debugging-address=127.0.0.1 --new-window $(printf '%q' "${1:?url}") >/dev/null 2>&1 &" 2>/dev/null
        for _ in $(seq 1 20); do
          sleep 2
          X "xdotool search --class chromium" | grep -q . && break
        done
        if X "xdotool search --class chromium" | grep -q .; then
          echo "opened ${1} in a new browser"
        else
          echo "FAILED to start a browser on ${DESK} — check: docker logs ${C}" >&2
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
      # LONG-ADDRESS GUARD: the address is TYPED by xdotool at 30 ms/char. A 48 KB data: URL takes
      # ~24 min, holds the desktop lock, spills keystrokes into other tabs and can wedge Chromium.
      # Refuse anything over 2000 chars and point at the file:// route.
      if [ "${#1}" -gt 2000 ]; then
        echo "REFUSING: address is ${#1} chars; desktop.sh types it at 30 ms/char (~$(( ${#1} * 30 / 60000 )) min) and long ones wedge the browser." >&2
        echo "Write the content to a file, then: docker cp <file> ${C}:/config/page.html && desktop.sh tab file:///config/page.html" >&2
        exit 2
      fi
      # Open a url in a NEW TAB, leaving what is already on screen alone.
      #
      # WHY THIS EXISTS. `url` drives ctrl+l, which navigates the CURRENT tab
      # and silently destroys whatever was there. That is fine on your own
      # desktop and hostile on a shared one: a page left waiting for the
      # operator to sign in is thrown away by the next agent's `url` with no
      # warning and no way to tell it had happened.
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
      # "1: unbound variable" — a shell diagnostic, not an explanation.
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
    # WHY THIS EXISTS. Screenshots are the single largest cost on the whole
    # plan: one session was 190 MB, 48% base64 image data, 666 shots.
    # An image never leaves the conversation -- it is re-sent on EVERY turn
    # after it -- so screenshotting to check "did that work?" compounds into
    # the dominant bill. A text answer does not. This returns the page's title,
    # URL and visible text for a rounding error of the cost.
    #
    # Requires the browser to listen on --remote-debugging-port=9222 (`url`
    # starts it that way when it has to start one).
    # The port is bound inside the container only: no docker port mapping, not
    # on the tailnet, reachable solely via docker exec.
    #
    # USE THIS FIRST. Reach for `shot` only when you genuinely need to SEE
    # layout or click coordinates.
    # NO 2>/dev/null. It was there to hide websockets' noise and instead threw
    # away every diagnostic this block writes -- including "no FOCUSED page"
    # and the new busy-page message -- leaving a bare exit code and nothing to
    # act on. An agent saw `read` fail with no explanation and fell back to
    # screenshots: the tool knew what was wrong and discarded it on the way out. A silent failure is worse than a noisy one.
    _ft=$(cat "$DROOT/${DESK}/.focustab" 2>/dev/null || true)
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
# THE FOCUSED PAGE, not simply the first one CDP lists. Found in live testing:
# `read` returned a stray "Bad Gateway" tab's content while `find` and
# `pagetitle` both correctly reported the mail app as focused at the same
# instant. pages[0] is whatever order the debugger happens to return, so
# `read` was confidently describing a DIFFERENT WINDOW than the one being driven
# -- the worst shape of wrong, because the output looks perfectly valid.
#
# `find` got this right from the start and `read` did not, purely because read
# was written first and nobody came back to it. Same selection logic now.
# TIMEOUT IS NOT THE SAME ANSWER AS "NOT FOCUSED", and conflating them was a
# real bug: `read` and `find` failed repeatedly on a desktop while `pagetitle`
# succeeded on the same window. Measured at the time, three of eight page
# targets -- including the page that WAS the active X window -- did not answer a Runtime.evaluate within the 4s budget.
# The old handler returned False for a TimeoutError, so a busy page looked
# exactly like an unfocused one, and the tool reported "no focused page" about
# a page that was focused and merely slow. The agent fell back to screenshots, which
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
    # would correctly switch to tab 1, confirm focus, and `read` would still
    # hand back a page from another window. The tool was not wrong about focus; "the
    # focused page" was simply ambiguous and it picked blind. Same family as
    # the pages[0] bug this function was written to fix.
    try:
        # PASSED IN AS AN ENV VAR, not read from a file. The first version
        # opened $DROOT/<desk>/.focustab -- a HOST path,
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
        # DEGRADE, DO NOT FAIL, WHEN A WEDGED TAB HOLDS THE FOCUS.
        # A hung tab keeps X focus, so every HEALTHY page truthfully reports
        # hasFocus() == false and this returned None -- meaning ONE dead tab
        # blocked reading every live one on that desktop. An agent hit exactly
        # that: the mail page was fine and unreadable because a wedged chat tab
        # held the focus.
        # If precisely ONE page is responsive, there is no ambiguity about
        # which page was meant, so use it and SAY SO. The refusal exists to
        # stop us guessing between candidates; with a single candidate there is
        # nothing to guess. Two or more still refuse -- picking one of those
        # would be the silent-wrong-answer this guard was built to prevent.
        alive = [t for t, r in zip(pages, res) if r is not True and r != "timeout"]
        responsive = [t for t, r in zip(pages, res) if r != "timeout"]
        if len(responsive) == 1:
            print("note: nothing holds focus (a wedged tab has it), but only one page "
                  "is responsive — reading that one.", file=sys.stderr)
            return responsive[0], slow
        return None, slow
    return _a.run(pick())

t, slow = _focused(pages)
if t is None:
    # Say so rather than silently reading an arbitrary tab. A wrong answer that
    # looks right is worse than no answer.
    if slow:
        # MEASURED, not guessed: healthy targets
        # answer a trivial `1+1` in 0.0s; the failing ones time out at 30s on
        # that same expression. So this is a DEAD RENDERER, not a slow one, and
        # "wait and retry" is wrong advice -- waiting never helps. The tab has
        # to be reloaded to respawn its renderer. Two of the three hung targets
        # were abandoned shopping tabs; one was the mail window actually in
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
async def _xframes(ws, have):
    seq = [1000]
    async def call(method, params):
        seq[0] += 1; i = seq[0]
        await ws.send(json.dumps({"id": i, "method": method, "params": params}))
        while True:
            m = json.loads(await asyncio.wait_for(ws.recv(), timeout=4))
            if m.get("id") == i:
                return m
    ft = ((await call("Page.getFrameTree", {})).get("result") or {}).get("frameTree") or {}
    stack, out, n = list(ft.get("childFrames") or []), "", 0
    while stack and n < 15:
        node = stack.pop(0); n += 1
        stack.extend(node.get("childFrames") or [])
        w = (await call("Page.createIsolatedWorld", {"frameId": node["frame"]["id"], "worldName": "desktop-read"})).get("result") or {}
        if not w.get("executionContextId"):
            continue
        r = await call("Runtime.evaluate", {"expression": "document.body ? document.body.innerText : ''",
                                            "contextId": w["executionContextId"], "returnByValue": True})
        it = (((r.get("result") or {}).get("result") or {}).get("value")) or ""
        # >20 chars, same threshold as the same-origin fold; and skip text the
        # same-origin fold already included so a frame is never printed twice.
        if len(it.strip()) > 20 and it.strip()[:200] not in have:
            out += "\n\n[iframe %s]\n%s" % (node["frame"].get("url", "")[:80], it)
    return out
async def _oopif_text():
    # Cross-SITE iframes are separate CDP targets (type "iframe", parentId = this page).
    out = ""
    try:
        for ft in json.load(urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=4)):
            if ft.get("type") != "iframe" or ft.get("parentId") != t.get("id") or not ft.get("webSocketDebuggerUrl"):
                continue
            async with websockets.connect(ft["webSocketDebuggerUrl"], max_size=8_000_000, open_timeout=4) as fw:
                await fw.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {
                    "expression": "document.body ? document.body.innerText : ''", "returnByValue": True}}))
                while True:
                    m = json.loads(await asyncio.wait_for(fw.recv(), timeout=4))
                    if m.get("id") == 1:
                        it = (((m.get("result") or {}).get("result") or {}).get("value")) or ""
                        if len(it.strip()) > 20:
                            out += "\n\n[iframe %s]\n%s" % (ft.get("url", "")[:80], it)
                        break
    except Exception:
        pass
    return out
async def go():
    # HARD DEADLINE. This loop was `while True: await ws.recv()` with NO
    # timeout anywhere -- if the page never returned a reply with id 1, read
    # waited forever. It held the SHARED desktop flock while doing so, so one
    # slow page blocked every agent on that desktop. Seen twice in one day:
    # six minutes, then eight.
    # Latent for a long time; the heavier iframe-walking expression made it
    # surface. A recv with no deadline is not a read, it is a hostage.
    async with websockets.connect(t["webSocketDebuggerUrl"], max_size=20_000_000,
                                  open_timeout=10) as ws:
        await ws.send(json.dumps({"id":1,"method":"Runtime.evaluate","params":{
            # SAME-ORIGIN IFRAME CONTENT, folded into the page text.
            # Without it, read returns a page's OUTER SHELL ONLY and does not
            # say it is hiding the application. Measured once: 40.3 MB of one
            # agent's 42.8 MB context was 308 SCREENSHOTS, taken because an
            # expense app lives in an iframe and read showed only a nav bar.
            # Verified on a controlled page served over http:
            # before, read returned "Outer shell nav only"; now it returns the
            # form inside. Note file:// iframes are cross-origin to a file://
            # parent, so a file:// test page proves nothing -- that cost a
            # false negative.
            "expression":"JSON.stringify({t:document.title,u:location.href,dlg:(function(){var o=[],seen=[];try{document.querySelectorAll('[role=dialog],[aria-modal=true],[role=alertdialog],[role=alert]').forEach(function(e){var r=e.getBoundingClientRect(),cs=getComputedStyle(e);if(r.width<2||r.height<2||cs.visibility==='hidden'||cs.display==='none')return;for(var i=0;i<seen.length;i++){if(seen[i].contains(e))return;}var tx=(e.innerText||'').replace(/\\s+/g,' ').trim();if(!tx)return;seen.push(e);var k=(e.getAttribute('role')==='alert')?'ALERT':'DIALOG';o.push(k+': '+tx);});}catch(e){}return o;})(),x:(function(){var o=document.body?document.body.innerText:'';try{document.querySelectorAll('iframe').forEach(function(f){try{var d=f.contentDocument;if(d&&d.body){var it=d.body.innerText;if(it&&it.trim().length>20){o+='\\n\\n[iframe '+(f.getAttribute('src')||'inline')+']\\n'+it;}}}catch(e){}});}catch(e){}return o;})()})",
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
                # CROSS-ORIGIN FRAMES -- the expression
                # above can only reach same-origin iframes. Same bounded,
                # event-free mechanism as lib/resolve-elements.py: frame tree,
                # an isolated world per frame, one evaluate each. No
                # Page.enable (that stream is what once hung the lock).
                try:
                    extra = await asyncio.wait_for(_xframes(ws, d.get("x") or ""), timeout=8)
                except Exception as ex:
                    extra = ""
                    print("note: cross-origin frames NOT read (%s)" % (ex or "8s budget"), file=sys.stderr)
                d["x"] = (d.get("x") or "") + extra + await _oopif_text()
                # OPEN MODALS / ALERTS FIRST. A modal is what the user is looking at, but body.innerText
                # lists the page behind it first and the limit cuts the dialog off -- Meta Business Suite's red
                # "You can't complete the setup process" banner was never seen. Labelled, before everything.
                for _b in (d.get("dlg") or []):
                    print(_b[:limit if limit < 2000 else 2000])
                if d.get("dlg"): print("---")
                print("TITLE: %s" % d.get("t",""))
                print("URL:   %s" % d.get("u",""))
                txt = " ".join((d.get("x") or "").split())
                print("TEXT:  %s" % txt[:limit])
                if len(txt) > limit:
                    print("... [%d more chars; pass a larger limit]" % (len(txt)-limit))
                return
asyncio.run(go())

# CROSS-ORIGIN FRAMES are read by _xframes above: isolated worlds, no Page.enable,
# per-recv timeouts plus an 8s budget. The history below is why it is shaped that way.
# A FIRST VERSION OF CROSS-ORIGIN FRAME READING HUNG.
# The mechanism worked and was proved against a live app, but the
# implementation blocked forever: Page.enable streams events continuously, and
# a receive loop that only times out PER MESSAGE never reaches an overall
# deadline. One `desktop.sh read` held the shared desktop flock for SIX MINUTES
# and blocked every other agent. Adding an overall deadline and dropping
# Page.enable did NOT fix it, so it comes out rather than stay in while a
# shared tool is debugged in production.
# Also learned: killing desktop.sh does NOT release the lock -- its `docker
# exec` child survives and keeps the file descriptor. Kill the docker pid too.
PYCDP
    ;;
  find)
    # WHERE IS IT ON SCREEN -- without a screenshot.
    #
    # The question that produced this: is there something that gives click
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
    # both targets. (`:hover` does NOT track in this X session -- that was the
    # first verifier and it returned NONE for everything, which looked like a
    # broken mapping and was a broken test.)
    #
    # WHY IT MATTERS BEYOND COST. Screenshots were the largest single line on
    # the plan, but the sharper problem is that coordinates read off an image
    # are a GUESS, and once a half-scale image aimed every click on every
    # desktop at the wrong place for hours. These coordinates come
    # from the page itself, so they cannot drift from what is actually rendered.
    # The screen also RESIZES with the viewer's client -- one went 2048x2532
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
    # print), and it was reintroduced three sections further down the same file.
    _heal_viewport
    # THE RESOLVER LIVES IN lib/resolve-elements.py.
    # `find` and `activate` MUST agree on where an element is -- if they drift,
    # activate clicks somewhere find never reported and the failure looks like a
    # site bug. One file, both callers.
    MODE="$mode" Q="$q" docker exec -i -e MODE -e Q ${RESOLVE_JSON:+-e RESOLVE_JSON} "$C" \
      python3 - < "$SCRIPTDIR/lib/resolve-elements.py"
    ;;
  goal)
    # SAY WHAT YOU ARE TRYING TO DO, ONCE, AND EVERY ROW AFTER IT CARRIES IT.
    #
    #   desktop.sh goal "open a customer record"     set it (default 60 min)
    #   desktop.sh goal --clear                      done
    #   desktop.sh goal                              what is it now
    #
    # This is the whole instrumentation ask, and it is one line of an agent's work. You cannot decide
    # whether to build a deterministic-sequence library until you know whether the same SUBTASK
    # recurs, and no amount of reprocessing thousands of rows of `click`/`find`/`read` will tell you.
    # The goal has to be recorded at the time, by whoever knew it.
    #
    # Scoped per agent and expiring like a claim, for the same reason a claim expires: an agent
    # that dies mid-task must not label somebody else's later work with its stale goal.
    GOALF="$DROOT/${DESK}/.goal"
    case "${1:-}" in
      "")
        if [ -r "$GOALF" ]; then
          { read -r _w; read -r _u; IFS= read -r _t; } < "$GOALF"
          _left=$(( _u - $(date +%s) ))
          if [ "$_left" -gt 0 ]; then
            echo "  goal ($_w, ${_left}s left): $_t"
          else
            echo "  no goal set (last one lapsed)"
          fi
        else
          echo "  no goal set — set one with: desktop.sh goal \"<what you are doing>\""
        fi ;;
      --clear)
        rm -f "$GOALF"; echo "  goal cleared" ;;
      *)
        _mins="${2:-60}"
        printf '%s\n%s\n%s\n' "${TIX_AGENT:-unknown}" "$(( $(date +%s) + _mins * 60 ))" "$1" > "$GOALF"
        echo "  goal set for ${_mins}m: $1" ;;
    esac
    _exec_log "goal" "${1:-}" "" "" "ok" ""
    ;;
  activate)
    # CLICK A THING BY WHAT IT IS, NOT WHERE IT IS.
    #
    #   desktop.sh activate "#submit"            css selector
    #   desktop.sh activate --text "Continue"    visible label
    #
    # WHY THIS EXISTS. Every click used to be `click <x> <y>`, and the agent
    # carried those numbers across turns. Three consequences, all of them paid for already:
    #   - STALENESS. Coordinates measured before a scroll, a resize or a re-render point at
    #     whatever moved into that spot. Once a half-scale screenshot aimed every click
    #     on every desktop at the wrong place for hours and opened reply drafts on real customer
    #     mail. `find` fixed the SOURCE of the numbers; it did not stop them going stale in the
    #     gap between measuring and clicking.
    #   - UNVERIFIABILITY. "Did the click work?" had no cheap answer, so agents screenshotted,
    #     which is the habit the screenshot ban exists to break.
    #   - UNMEASURABILITY. `click` in the usage log says nothing. Thousands of rows could not answer
    #     "how repetitive is our work", because a coordinate is not comparable to anything.
    #
    # This resolves, chooses, clicks and verifies inside ONE invocation, so the coordinates
    # never leave the process and cannot go stale -- measured microseconds before the click.
    #
    # IT STILL CLICKS WITH xdotool, deliberately. Real X events are indistinguishable from a
    # hand on a mouse; CDP-synthesised clicks get flagged by sites that care. Element-native
    # TARGETING and synthetic CLICKING are separable, and we only want the first.
    mode="sel"; [ "${1:-}" = "--text" ] && { mode="text"; shift; }
    q="${1:?usage: desktop.sh activate \"<css selector>\" | --text \"<visible label>\"}"
    # The EXIT trap logs the raw $2, which after the --text shift is the flag, not the query.
    # Every refusal row would have said arg="--text" -- useless for the one thing this log is
    # for. Point the trap at what was actually asked for.
    _CMD_ARG="$q"
    _heal_viewport

    before=$(docker exec -i "$C" python3 - < "$SCRIPTDIR/lib/page-state.py" 2>/dev/null)
    b_url=$(printf '%s' "$before" | python3 -c 'import sys,json;print((json.load(sys.stdin) or {}).get("url",""))' 2>/dev/null)
    b_title=$(printf '%s' "$before" | python3 -c 'import sys,json;print((json.load(sys.stdin) or {}).get("title",""))' 2>/dev/null)

    # RESOLVE. Exit codes are passed straight through -- 2 nothing matched, 3 could not see the
    # page, 6 viewport unusable. A caller must be able to tell those apart without reading prose.
    found=$(MODE="$mode" Q="$q" RESOLVE_JSON=1 docker exec -i -e MODE -e Q -e RESOLVE_JSON "$C" \
            python3 - < "$SCRIPTDIR/lib/resolve-elements.py")
    rc=$?
    [ "$rc" -ne 0 ] && exit "$rc"

    target=$(printf '%s' "$found" | python3 "$SCRIPTDIR/lib/choose-target.py")
    rc=$?
    [ "$rc" -ne 0 ] && exit "$rc"

    eval "$(printf '%s' "$target" | python3 -c '
import sys, json, shlex
e = json.load(sys.stdin)
for k in ("x", "y", "w", "h", "role", "name", "tag", "candidates", "frame"):
    print("T_%s=%s" % (k, shlex.quote(str(e.get(k, "")))))')"

    echo "  target : <$T_tag> role=$T_role  \"$T_name\"   ($T_w x $T_h at $T_x,$T_y)${T_frame:+  [in iframe $T_frame]}"
    X "xdotool mousemove $T_x $T_y click 1"

    # LOCAL VERIFICATION -- ask the browser, never a model. Settle first: a click that starts a
    # navigation has not finished one yet, and reading too early reports "nothing changed" for
    # an action that worked perfectly.
    sleep 1.2
    _SETTLE_MS=1200

    # DID THE THING I CLICKED GO AWAY? -- the second local check, and the one that rescues most
    # in-page actions from a useless verdict. url/title alone cannot see a dialog dismissed, a
    # banner closed, a row expanded: all of those report "nothing changed" while having worked
    # perfectly. Re-resolving the SAME query answers it exactly, for one more ~150ms round trip
    # and no model. Exit 2 from the resolver means it read the page and found nothing -- that is
    # the target being gone, which is why the 2-vs-3 exit code split had to exist first.
    _act_recheck() {
      after=$(docker exec -i "$C" python3 - < "$SCRIPTDIR/lib/page-state.py" 2>/dev/null)
      a_rc=$?
      gone=unchecked
      if [ "$a_rc" = 0 ]; then
        refound=$(MODE="$mode" Q="$q" RESOLVE_JSON=1 docker exec -i -e MODE -e Q -e RESOLVE_JSON "$C" \
                  python3 - < "$SCRIPTDIR/lib/resolve-elements.py" 2>/dev/null)
        case $? in
          0) gone=$(T_ROLE="$T_role" T_NAME="$T_name" R="$refound" python3 -c '
import os, json
d = json.loads(os.environ["R"] or "{}")
role, name = os.environ["T_ROLE"], os.environ["T_NAME"]
still = any(e.get("role") == role and (e.get("name") or "") == name for e in d.get("els") or [])
print("present" if still else "gone")' 2>/dev/null || echo unchecked) ;;
          2) gone=gone ;;
          *) gone=unchecked ;;
        esac
      fi
  
      VERIFY=$(B="$before" B_URL="$b_url" B_TITLE="$b_title" A="$after" A_RC="$a_rc" GONE="$gone" \
               python3 "$SCRIPTDIR/lib/verify-action.py")
      [ -n "$VERIFY" ] || VERIFY="UNKNOWN|the verifier produced no output at all -- treat this as unverified"
    }
    _act_recheck
    # FALLBACK PRESS. The real X click is always tried first -- sites that
    # flag synthetic input see nothing unusual. Only if the page shows NO response of any kind
    # (url, title, overlays, expanded state, text, and the target still present) is the SAME
    # element -- the one under the point just clicked, name-checked -- pressed through the page:
    # the pointer-event sequence, then focus+Enter. React-Aria/Base UI buttons (Clerk, Resend)
    # ignore the X click and answer these. Each stage is re-verified; it stops at the first response.
    _PRESS=""; _tried=""
    if [ "${VERIFY%%|*}" = NOCHANGE ] && [ "$gone" = present ]; then
      read -r _OX _OY < <(printf '%s' "$found" | python3 -c 'import sys,json;o=json.load(sys.stdin).get("o") or [0,0];print(o[0],o[1])' 2>/dev/null || echo "0 0")
      for _st in pointer enter; do
        _pr=$(SX="$T_x" SY="$T_y" OX="$_OX" OY="$_OY" T_NAME="$T_name" T_FRAME="$T_frame" STAGE="$_st" \
              docker exec -i -e SX -e SY -e OX -e OY -e T_NAME -e T_FRAME -e STAGE "$C" python3 - < "$SCRIPTDIR/lib/press-element.py" 2>/dev/null)
        case "$_pr" in *'"pressed": true'*) _tried="${_tried:+$_tried, }$_st" ;; *) echo "  fallback: $_st not attempted -- ${_pr:-no answer}"; break ;; esac
        sleep 1.2
        _act_recheck
        if [ "${VERIFY%%|*}" != NOCHANGE ]; then _PRESS="$_st"; echo "  fallback: X click was ignored; pressed via DOM ($_st)"; break; fi
      done
      [ -z "$_PRESS" ] && [ -n "${_tried:-}" ] && echo "  fallback: also pressed via DOM ($_tried) -- still no response"
    fi
    printf '  verify : %s\n' "${VERIFY#*|}"
    case "$VERIFY" in
      CHANGED*)  echo "  CONFIRMED: the page responded." ;;
      UNKNOWN*)  echo "  ** UNKNOWN ** -- not a success and not a failure. Check it yourself." ;;
      *)         echo "  NOT CONFIRMED from url/title alone. If you expected navigation, it did not happen." ;;
    esac
    # Semantic execution record. This is the row that makes repetition measurable.
    case "${VERIFY%%|*}" in
      CHANGED)  _OUT=changed ;;
      UNKNOWN)  _OUT=unknown ;;
      *)        _OUT=nochange ;;
    esac
    [ -n "$_PRESS" ] && _OUT="${_OUT}+dom_${_PRESS}"
    _exec_log "activate" "$q" "$T_role" "$T_name" "$_OUT" "$T_candidates" 0
    ;;
  fill)
    # PUT TEXT IN A FIELD WITHOUT COORDINATES.
    # `click <x> <y>` then `type` fails on React-Aria forms (Stripe's dashboard):
    # the synthetic click leaves focus on a DIV, `type` rightly refuses, and the
    # agent is left Tab-walking -- one agent spent ~400 of 631 commands that way.
    # Same root cause as `choose`: a coordinate click does not reliably FOCUS.
    # This focuses through the DOM, inserts as a real text-input event (React
    # sees it), and reads the field back. Exit: 0 verified, 2 no match,
    # 3 cannot read page, 4 ambiguous (refuses to guess), 5 did not stick.
    #   desktop.sh fill --label "Business name" "Acme Ltd"
    #   desktop.sh fill "textarea" ""            (empty text = clear the field)
    mode="sel"; [ "${1:-}" = "--label" ] && { mode="label"; shift; }
    q="${1:?usage: desktop.sh fill \"<css selector>\" | --label \"<field label>\" \"<text>\"}"
    [ $# -ge 2 ] || { echo "usage: desktop.sh fill \"<css selector>\" | --label \"<field label>\" \"<text>\"" >&2; exit 2; }
    MODE="$mode" Q="$q" TEXT="$2" docker exec -i -e MODE -e Q -e TEXT "$C" \
      python3 - < "$SCRIPTDIR/lib/fill-field.py"
    ;;
  choose)
    # PICK AN OPTION BY ITS VISIBLE TEXT from a custom ARIA combobox.
    # Opens it, scrolls the LISTBOX ITSELF (virtualized lists) until the option renders,
    # clicks with real mouse events, verifies the combobox now shows it. Falls back to
    # typing to filter. Also handles a native <select>.
    #   desktop.sh choose "Category" "Professional Services"     (label text)
    #   desktop.sh choose "#cat" "Professional Services"         (css selector)
    # Exit: 0 verified, 2 not found, 3 cannot read page, 4 ambiguous, 5 clicked but unverified.
    [ $# -ge 2 ] || { echo "usage: desktop.sh choose \"<combobox css selector | label text>\" \"<option text>\"" >&2; exit 2; }
    Q="$1" OPT="$2" docker exec -i -e Q -e OPT "$C" python3 - < "$SCRIPTDIR/lib/choose-option.py"
    ;;
  dropdown)
    # JS COMBOBOXES — the widgets `find` cannot see into.
    #
    # WHY `find` APPEARS TO FAIL ON THESE, because the failure is misleading:
    # the options are genuinely NOT in the DOM while the widget is shut, so
    # `find "[role=option]"` correctly returns nothing. And clicking the
    # combobox at screen coordinates does NOT open it -- a synthetic click does
    # not focus the underlying <input>, and these widgets open on FOCUS +
    # KEYBOARD. Two true observations that together read as "undriveable".
    # They are not. Verified live on react-select.
    #
    # This delegates to desktop-dropdown.sh rather than inlining the logic: that
    # script is the tested implementation and duplicating it into this 1400-line
    # shared file would give us two copies to keep in step.
    #
    #   desktop.sh dropdown list [n]              what are the options?
    #   desktop.sh dropdown pick <n> <index>      choose by position
    #   desktop.sh dropdown pick <n> --text "Foo" choose by visible label
    #
    # TRY THIS BEFORE REACHING FOR A MODEL OR A SCREENSHOT. It is deterministic,
    # free, uses no coordinates (so it cannot drift with scroll or window size),
    # and it CONFIRMS the selection by re-reading the widget's own text rather
    # than assuming a click that did not error worked.
    # NO `shift` HERE: the dispatcher already did `cmd="${1:-}"; shift`, so "$@" is
    # exactly the args after `dropdown`. Shifting again eats `list`/`pick` and
    # the delegate reports "unknown command: 0".
    #
    # PASS THE RESOLVED DESKTOP THROUGH. The delegate once defaulted to a fixed
    # desktop, so one agent running `dropdown list` had tabs/focus routed to its
    # OWN desktop while the CDP probe read ANOTHER agent's browser — somebody
    # else's signed-in session, reported as its own page. $DESK is already
    # resolved here; the delegate must inherit it rather than guess.
    export DESKTOP="$DESK" DESKTOP_CONTAINER="${DESK}-desktop"
    exec "$SCRIPTDIR/desktop-dropdown.sh" "$@"
    ;;
  revive)
    # THE REMEDY FOR A WEDGED RENDERER, and the second attempt at it.
    #
    # The first version sent ctrl+F5 with xdotool and DID NOT WORK -- it was run
    # twice on a focused, hung mail tab with no effect. A
    # keystroke is delivered to the window, and the window is exactly the thing
    # that has stopped processing. Verified the active window really was the
    # hung tab at the time, so this was not a targeting mistake; the approach
    # was simply wrong.
    #
    # What DOES work is the DevTools HTTP endpoint, because it is served by the
    # BROWSER process rather than the page's renderer: /json/close/<id> closed a
    # hung shop page first try ("Target is closing", 8 targets -> 7) after
    # clicking its X in the tab overlay had done nothing at all.
    #
    # Closes every unresponsive target and reopens its URL, so a hung app comes
    # back rather than merely going away. --close-only skips the reopen, for
    # abandoned junk you do not want back.
    #
    # DESTRUCTIVE IN ONE NARROW WAY: an unsaved draft in a hung tab is gone.
    # It was already unreachable -- that is what "hung" means -- but say so.
    # DRY RUN BY DEFAULT. Added immediately after revive was run on another
    # agent's desktop against a hung tab that was a LIVE signed-in mail
    # session. Closing it dropped the session and left an account picker
    # someone had to click through.
    #
    # The tool was not wrong; running it unprompted on someone else's desktop
    # was. So it now SHOWS what it would close and stops. --yes performs it.
    # A destructive default on a shared machine is a trap that will catch the
    # next person exactly as it caught the last one.
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
    print("like webmail it can drop the signed-in session too - the tab may come")
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
    # was there or to choose one, so the refusal became a dead end. An agent hit
    # exactly this trying to verify the iframe fix.
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
  close-tab)
    # Close a tab via CDP /json/close/<id>. Arg: number from `tabs`, or a substring of its url/title.
    # Only the FIRST match is closed, so a vague substring cannot wipe several tabs.
    q="${1:?usage: desktop.sh close-tab <number from 'desktop.sh tabs'|url-or-title substring>}"
    docker exec -i -e Q="$q" "$C" python3 - <<'PYCLOSE'
import json, os, sys, urllib.request
B = "http://127.0.0.1:9222"; q = os.environ["Q"]
try:
    t = json.load(urllib.request.urlopen(B + "/json", timeout=5))
except Exception as e:
    print("no CDP on 9222 (%s)" % e, file=sys.stderr); sys.exit(1)
pages = [x for x in t if x.get("type") == "page" and x.get("webSocketDebuggerUrl")]
if q.isdigit():
    i = int(q)
    hit = pages[i-1] if 1 <= i <= len(pages) else None
else:
    hit = next((p for p in pages if q.lower() in (p.get("url","")+" "+p.get("title","")).lower()), None)
if not hit:
    print("no tab matches %r (see: desktop.sh tabs)" % q, file=sys.stderr); sys.exit(1)
urllib.request.urlopen(B + "/json/close/" + hit["id"], timeout=5).read()
print("closed: %s  %s" % ((hit.get("title") or "")[:40], (hit.get("url") or "")[:60]))
PYCLOSE
    ;;
  focus)
    # NAMED `focus`, NOT `tab` -- `tab <url>` already exists and opens a URL in
    # a new tab. The first cut called this `tab <n>` and was silently
    # unreachable: the earlier case matched first, so `tab 2` cheerfully
    # reported "opened 2 in a new tab". A colliding subcommand does not error,
    # it just does something else.
    n="${1:?usage: desktop.sh focus <number from 'desktop.sh tabs'>}"
    # ACTIVATE IS NOT ENOUGH. /json/activate raises the tab, but a page raised
    # PROGRAMMATICALLY can still report document.hasFocus() === false -- found
    # when an activated window was active at the X level and its page
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
      yes) printf '%s' "$tid" > "$DROOT/${DESK}/.focustab"
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
    # `fit` RESIZES WINDOWS. It cannot change the display SCALE, and for a year
    # it reported "fitted to WxH" either way -- true about the window, silent
    # about the thing the caller actually cares about. Once that read
    # as success while the CSS viewport stayed at 500x149, and the agent it
    # misled kept re-running it. So fit now reports what the page ENDS UP with,
    # not just what it did.
    X 'read w h < <(xdotool getdisplaygeometry); \
       for win in $(xdotool search --class chromium 2>/dev/null); do \
         g=$(xdotool getwindowgeometry $win | awk "/Geometry/ {print \$2}"); \
         ww=${g%%x*}; [ -z "$ww" ] && continue; [ "$ww" -lt 400 ] && continue; \
         xdotool windowmove $win 0 0; xdotool windowsize $win $w $h; \
       done; echo "fitted to ${w}x${h}"'
    _report_css_viewport ;;

  *) sed -n '3,19p' "$0" | sed 's/^# \?//'; exit 2 ;;
esac
