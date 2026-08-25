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
# Where the desktops live. One place, overridable, never hardcoded.
FLEET_DESKTOPS="$FLEET_DESKTOPS"

# WHICH DESKTOP. There can be more than one. Select with DESKTOP=<name>, or
# DESKTOP_CONTAINER for a container whose name is not "<name>-desktop".
#
# FAILS CLOSED WHEN IT CANNOT TELL WHO IS ASKING. An earlier version defaulted
# to one particular desktop so that unattended watchers kept working without
# passing anything. That default handed somebody else's signed-in browser to
# every caller who forgot to be explicit — including an interactive session,
# which does not inherit the agent identity either. Guessing an owner once put
# an agent onto a colleague's Outlook.
#
# A default that is right for two callers and dangerous for the rest is a trap,
# not a default. Unknown identity refuses and says what to pass; callers that
# genuinely want a specific desktop name it themselves.
_default_desk() {
  case "${TIX_AGENT:-}" in
    "") echo "" ;;
    *)  [ -d "$FLEET_DESKTOPS/${TIX_AGENT}" ] && echo "$TIX_AGENT" || echo "shared" ;;
  esac
}
DESK="${DESKTOP:-$(_default_desk)}"
if [ -z "$DESK" ]; then
  echo "WHICH DESKTOP? I cannot tell who is asking (TIX_AGENT is not set)." >&2
  echo "  Refusing rather than guessing — guessing once put an agent on somebody" >&2
  echo "  else's signed-in browser." >&2
  echo "" >&2
  echo "  Say it explicitly:   DESKTOP=<name> $0 $*" >&2
  echo "  Available:           $(ls -d "$FLEET_DESKTOPS"/*/ 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')" >&2
  exit 2
fi
C="${DESKTOP_CONTAINER:-${DESK}-desktop}"
SHOT_DIR="$FLEET_DESKTOPS/${DESK}/shots"
X() { docker exec -u abc "$C" bash -c "DISPLAY=:1 $*" 2>/dev/null; }

docker ps --format '{{.Names}}' | grep -qx "$C" || { echo "desktop container '$C' is not running" >&2; exit 1; }
mkdir -p "$SHOT_DIR"

# ── one agent on the desktop at a time ──────────────────────────────────────
# There is ONE X session and several agents that can drive it: interactive
# sessions, and fresh agents woken by the trigger dispatcher, which run with no
# knowledge of each other. On 2026-08-24 two agent sessions drove this browser
# concurrently — a click meant for a dialog landed on the WhatsApp tab because
# the other one moved focus mid-action. She spotted it and backed off.
#
# It is not only input: `shot` writes a SHARED /config/.shot.xwd and a SHARED
# screen.png, so two captures at once corrupt each other's image — and the
# caller cannot tell, which is the dangerous part.
#
# So every command takes an exclusive lock for its (short) duration. Failing
# loudly when the desktop is busy beats interleaving two agents' actions.
# One lock PER DESKTOP: two agents on the same screen must serialise, but an agent
# working on his own screen must not be blocked by another agent working on hers.
LOCK="$FLEET_DESKTOPS/${DESK}/.desktop.lock"
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
if ! flock -w "${DESKTOP_LOCK_WAIT:-20}" 9 2>/dev/null; then
  # Do not just say "busy" — say what to do instead:
  # an agent turned away should be told which desktop IS free, and only told to
  # wait when they all are. A bare refusal makes agents invent workarounds,
  # which is how two of them ended up driving one screen in the first place.
  free=""
  for other in $FLEET_DESKTOPS/*/; do
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
# desktop, which on 2026-08-25 popped the wallpaper dialog and, on the next
# attempt, silently did nothing while still printing "opened". A navigation that
# reports success without navigating is the worst possible failure mode: I only
# caught it by screenshotting and noticing the tab title had not changed.
# On one agent's desktop the same fault could type over his live Outlook session.
# So: choose one window deliberately, activate it, VERIFY focus landed there,
# and refuse to type if it did not. Tracked in an internal ticket.
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
# THE INCIDENT THIS PREVENTS (2026-08-25). An agent clicked Outlook's search
# bar, the click landed on the message LIST instead, and her typed query became
# Outlook single-key shortcuts -- "R" opened REPLY on real customer threads in
# the operator's real work inbox. Two compose panes. Nothing sent, by luck.
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
# would break legitimate typing. "a short message
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
  local st="$FLEET_DESKTOPS/${DESK}/.focus.state" v prev
  v=$(_focus_verdict | tail -1)
  prev=$(cat "$st" 2>/dev/null)
  printf '%s' "$v" > "$st" 2>/dev/null
  case "$v" in
    UNSAFE*)
      [ "${prev%% *}" = "UNSAFE" ] && return 0        # already said so; stay quiet
      echo "⚠ NOTHING TEXT-EDITABLE HAS FOCUS (${v#UNSAFE }) — these keystrokes will act as SHORTCUTS, not text." >&2
      echo "  This is how a typed search became 'R' = reply on real mail (an internal ticket)." >&2
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
    # plan (an internal ticket). This does not forbid `shot` -- sometimes you genuinely need
    # to see layout or find click coordinates -- but it names the alternative
    # every time, because the default habit was "photograph it to check", and
    # that habit is what produced a 190 MB session that was half image data.
    # REFUSED BY DEFAULT. agents read, control and
    # execute through the CLI; screenshots are not the working method.
    #
    # This used to be a polite NOTE and it did not change behaviour -- agents
    # kept photographing pages to read them, which was the single largest line
    # on the plan (one session 190 MB, 48% image data, 666 shots) AND the source
    # of the worst bug of the day: coordinates measured off an image are a
    # guess, and a half-scale image aimed every click on every desktop at the
    # wrong place for hours, opening reply panes on real customer mail (an internal ticket).
    #
    # A block is only fair now that there is a real alternative for every
    # ordinary case, which there is as of a later change:
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
      # THE MESSAGE IS THE DOCUMENTATION. "shouldn't
      # that info come from a message when they try to access? that way we
      # don't have to proactively inform." Correct -- and my reflex had been to
      # go and brief the agents by hand, which does not scale and misses anyone
      # woken later. A tool that changes its rules must teach them at the point
      # of refusal: WHAT to do instead, WHO set the rule (so it is not mistaken
      # for a bug worth routing around), and WHERE the full story is.
      echo "SCREENSHOTS ARE OFF — this is a deliberate rule, not a fault." >&2
      echo "Agents read, control and execute through the CLI. Use instead:" >&2
      echo "" >&2
      echo "    $0 read                        what the page SAYS" >&2
      echo "    $0 find \"<css selector>\"       WHERE to click -> screen x,y" >&2
      echo "    $0 find --text \"Send\"          same, by visible text" >&2
      echo "    $0 pagetitle                   did anything change" >&2
      echo "" >&2
      echo "  find reads coordinates from the page itself, so they cannot drift" >&2
      echo "  from what is rendered — a half-scale screenshot mis-aimed every" >&2
      echo "  click on every desktop for hours on 2026-08-25 (an internal ticket)." >&2
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
    ffmpeg -y -loglevel error -i "$FLEET_DESKTOPS/${DESK}/config/.shot.xwd" "$out" 2>/dev/null \
      || { echo "convert failed" >&2; exit 1; }
    rm -f "$FLEET_DESKTOPS/${DESK}/config/.shot.xwd"
    # DO NOT DOWNSCALE. This block used to halve the image to save tokens
    # (2x smaller = ~4x cheaper to read) and it CAUSED A REAL INCIDENT on
    # 2026-08-25: the screen is 2048x2532, the saved PNG was 1024x1266, and
    # nothing said so. `click` takes ABSOLUTE screen coordinates, so every
    # coordinate an agent measured off a screenshot landed at HALF position --
    # up and to the left of the target, every single time.
    #
    # What that looked like in practice: An agent clicked Outlook's search bar and
    # landed on the message LIST. Focus went to the list, so her typed query
    # became Outlook keyboard shortcuts, and "R" opened REPLY on real customer
    # threads in the operator's real work inbox. Two compose panes opened. Nothing was
    # sent, but only by luck.
    #
    # The optimisation broke the one thing a screenshot is FOR. Telling agents
    # to "remember to double the coordinates" is not a fix -- it is the same
    # foot-gun with a warning label. The cost problem is already solved properly
    # by steering to `read` above, which is ~1% of the cost, not 25%.
    #
    # If you are about to re-add this: don't. See the incident above.

    # PROVE THE IMAGE MATCHES THE SCREEN before handing it over. Tonight's
    # incident (an internal ticket) ran for hours because a screenshot silently disagreed
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
    elif [ "$sw" != "$iw" ] || [ "$sh" != "$ih" ]; then
      echo "REFUSING THIS SCREENSHOT: it is ${iw}x${ih} but the screen is ${sw}x${sh}." >&2
      echo "  Coordinates read off it will NOT match what 'click' does - click takes" >&2
      echo "  ABSOLUTE screen coordinates. This exact mismatch opened reply panes on" >&2
      echo "  real mail on 2026-08-25 (an internal ticket). Fix the capture; do not scale by hand." >&2
      exit 1
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
      # every xdotool call silently, and still print "opened" — an agent lost time
      # to exactly that on a fresh desktop (2026-08-24) with the operator waiting.
      #
      # Detect by CLASS, not by window NAME: a browser showing
      # "X - The Everything App" contains no "chrom" in its title, so a
      # name-based check reports "no browser" while one is plainly on screen.
      # The original code had this flaw too and would silently type into
      # nothing whenever the page title lacked the word chrome.
      #
      # ALWAYS via /usr/local/bin/chrome, never the raw binary: the wrapper is
      # where --proxy-pac-url lives, and launching around it silently sends
      # traffic out from the datacenter instead of his home connection (an internal ticket).
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
      # desktop and hostile on a shared one: on 2026-08-24 an agent's published
      # mockup was sitting on a desktop waiting for the operator to sign in
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
      X "xdotool key ctrl+t"; sleep 2
      X "xdotool type --delay 30 -- $(printf '%q' "${1:?url}")"; sleep 1
      X "xdotool key Return"
      echo "opened ${1} in a new tab" ;;
  read)
    # Ask the page what it SAYS instead of photographing it.
    #
    # WHY THIS EXISTS. Screenshots were the single largest cost on the whole
    # plan (an internal ticket): one session was 190 MB, 48% base64 image data, 666 shots.
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
    docker exec -i "$C" python3 - "${1:-4000}" <<'PYCDP' 2>/dev/null
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
# THE FOCUSED PAGE, not simply the first one CDP lists. Found by an agent in live
# testing on 2026-08-25: `read` returned a stray "Bad Gateway" tab's content
# while `find` and `pagetitle` both correctly reported Outlook as focused at the
# same instant. pages[0] is whatever order the debugger happens to return, so
# `read` was confidently describing a DIFFERENT WINDOW than the one being driven
# -- the worst shape of wrong, because the output looks perfectly valid.
#
# `find` got this right from the start and `read` did not, purely because read
# was written first and I never came back to it. Same selection logic now.
def _focused(pages):
    import asyncio as _a, json as _j, websockets as _w
    async def probe(t):
        try:
            async with _w.connect(t["webSocketDebuggerUrl"], max_size=1_000_000, open_timeout=4) as ws:
                await ws.send(_j.dumps({"id":99,"method":"Runtime.evaluate",
                                        "params":{"expression":"document.hasFocus()","returnByValue":True}}))
                for _ in range(20):
                    m = _j.loads(await _a.wait_for(ws.recv(), timeout=4))
                    if m.get("id") == 99:
                        return bool((((m.get("result") or {}).get("result") or {}).get("value")))
        except Exception:
            return False
        return False
    async def pick():
        for t in pages:
            if await probe(t):
                return t
        return None
    return _a.run(pick())

t = _focused(pages)
if t is None:
    # Say so rather than silently reading an arbitrary tab. A wrong answer that
    # looks right is worse than no answer -- that is the whole lesson of an internal ticket.
    print("no FOCUSED page — click the window you mean, then read again.", file=sys.stderr)
    print("  (%d page target(s) open; refusing to guess which one you meant)" % len(pages), file=sys.stderr)
    sys.exit(4)
async def go():
    async with websockets.connect(t["webSocketDebuggerUrl"], max_size=20_000_000) as ws:
        await ws.send(json.dumps({"id":1,"method":"Runtime.evaluate","params":{
            "expression":"JSON.stringify({t:document.title,u:location.href,x:document.body?document.body.innerText:''})",
            "returnByValue":True}}))
        while True:
            m = json.loads(await ws.recv())
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
    # both targets. (`:hover` does NOT track in this X session -- that was my
    # first verifier and it returned NONE for everything, which looked like a
    # broken mapping and was a broken test.)
    #
    # WHY IT MATTERS BEYOND COST. Screenshots were the largest single line on
    # the plan, but the sharper problem is that coordinates read off an image
    # are a GUESS, and on 2026-08-25 a half-scale image aimed every click on
    # every desktop at the wrong place for hours (an internal ticket). These coordinates come
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
  const dpr = window.devicePixelRatio || 1;
  const ox = window.screenX, oy = window.screenY + (window.outerHeight - window.innerHeight);
  let els;
  if (%s === "text") {
    const needle = %s.toLowerCase();
    els = [...document.querySelectorAll('a,button,input,textarea,select,[role],label,span,div,li,td')]
      .filter(e => { const t = (e.innerText || e.value || e.getAttribute('aria-label') || '').trim().toLowerCase();
                     return t && t.includes(needle) && e.children.length < 3; });
  } else { els = [...document.querySelectorAll(%s)]; }
  const out = [];
  for (const e of els) {
    const r = e.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) continue;
    if (r.bottom < 0 || r.right < 0 || r.top > window.innerHeight || r.left > window.innerWidth) continue;
    const st = getComputedStyle(e);
    if (st.visibility === 'hidden' || st.display === 'none' || +st.opacity === 0) continue;
    out.push({
      tag: e.tagName.toLowerCase(), id: e.id || '',
      label: ((e.getAttribute('aria-label') || e.placeholder || e.innerText || e.value || '').trim()).slice(0, 48),
      x: Math.round(ox + (r.left + r.width / 2) * dpr),
      y: Math.round(oy + (r.top + r.height / 2) * dpr),
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
