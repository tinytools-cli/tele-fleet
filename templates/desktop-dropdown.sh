#!/usr/bin/env bash
# Read and set JS dropdowns DETERMINISTICALLY — no model, no screenshot, no coordinates.
#
# THE BUG THIS CLOSES. Agents could not operate JS comboboxes — Cloudflare's token form
# defeated four separate techniques and pushed work back onto the operator, which is exactly what the
# agent-desktops skill exists to prevent. The stated conclusion was "find cannot see the options,
# so these widgets are undriveable".
#
# THAT CONCLUSION WAS WRONG, AND HERE IS WHY IT LOOKED RIGHT. The options genuinely are NOT in the
# DOM while the widget is shut. Every attempt to see them first — `find "[role=option]"` — returned
# nothing, correctly. And every attempt to OPEN the widget first used a synthetic click at screen
# coordinates, which does not focus the underlying input, so the widget never opened. Two true
# observations that together produced a false conclusion: "there is nothing to see" rather than
# "I have not opened it".
#
# WHAT ACTUALLY WORKS, verified live on react-select:
#   1. focus the widget's <input> through the DOM  — no coordinates involved
#   2. dispatch a REAL ArrowDown KeyboardEvent     — this is what opens these widgets
#   3. the options now exist, with STABLE IDS      — react-select-2-option-0, -1, -2 ...
#   4. select by dispatching the full pointer sequence on the option element
#      (pointerdown, mousedown, pointerup, mouseup, click) — a bare .click() is often ignored
#   5. verify by re-reading the WIDGET's own text, not the page's
#
# Coordinates are never used, so nothing here can drift with scroll position, window size or the
# viewport-scale bug that has bitten us before.
#
#   desktop-dropdown.sh list [n]            enumerate options of the nth combobox (default 0)
#   desktop-dropdown.sh pick <n> <index>    select option <index> of the nth combobox
#   desktop-dropdown.sh pick <n> --text "Foo"   select by visible label
set -uo pipefail

DESK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/desktop.sh"
# WHICH CONTAINER. desktop.sh exports DESKTOP and DESKTOP_CONTAINER when it delegates here, so the
# normal path inherits the caller's own desktop. Running this script DIRECTLY has no such context,
# so it applies the same rule desktop.sh does -- never a hardcoded default. A hardcoded default
# once meant one agent read ANOTHER agent's browser: its own session on screen, somebody else's
# page in the answer.
if [ -n "${DESKTOP_CONTAINER:-}" ]; then
  CONT="$DESKTOP_CONTAINER"
else
  DROOT="${DESKTOP_ROOT:-$HOME/.fleet/desktops}"
  _a=$(printf '%s' "${TIX_AGENT:-}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
  _d="${DESKTOP:-}"
  [ -z "$_d" ] && [ -n "$_a" ] && [ -d "$DROOT/$_a" ] && _d="$_a"
  [ -z "$_d" ] && [ -n "$_a" ] && _d="${DEFAULT_DESKTOP:-$(head -n1 "$DROOT/.default" 2>/dev/null | tr -cd 'a-z0-9_-')}"
  [ -n "$_d" ] || { echo "WHICH DESKTOP? set DESKTOP=<name> (or TIX_AGENT) -- refusing to guess" >&2; exit 2; }
  export DESKTOP="$_d"
  CONT="${_d}-desktop"
  # Wake it if it was stopped to save memory, the same as desktop.sh does.
  if [ "$(docker inspect -f '{{.State.Running}}' "$CONT" 2>/dev/null)" = false ] && [ "${DESKTOP_WAKE:-1}" != 0 ]; then
    docker start "$CONT" >/dev/null && sleep "${DESKTOP_WAKE_WAIT:-20}"
  fi
fi
PROBE=/tmp/dropdown-probe.py

cmd="${1:-}"; [ -n "$cmd" ] || { sed -n '/^#   desktop-dropdown/,/^#   desktop-dropdown.sh pick <n> --text/p' "$0" | sed 's/^# *//'; exit 2; }

# The CDP bridge lives inside the container: 9222 is bound to the container's own loopback, and
# `websockets` is present there. Written out each run so the script is self-contained.
read -r -d '' PY <<'PYEOF' || true
import json,urllib.request,asyncio,sys
import websockets
JS=sys.argv[1]
t=[x for x in json.load(urllib.request.urlopen("http://127.0.0.1:9222/json",timeout=5))
   if x.get("type")=="page" and x.get("webSocketDebuggerUrl")]
if not t: print(json.dumps({"err":"no page target — is the browser running?"})); raise SystemExit
async def go():
    async with websockets.connect(t[0]["webSocketDebuggerUrl"],max_size=8_000_000,open_timeout=6) as ws:
        await ws.send(json.dumps({"id":1,"method":"Runtime.evaluate",
            "params":{"expression":JS,"returnByValue":True,"awaitPromise":True}}))
        while True:
            m=json.loads(await asyncio.wait_for(ws.recv(),timeout=20))
            if m.get("id")==1:
                r=m.get("result",{}).get("result",{})
                if "value" in r: print(r["value"])
                else: print(json.dumps({"err":json.dumps(m)[:200]}))
                return
asyncio.run(go())
PYEOF
printf '%s' "$PY" | docker exec -i "$CONT" bash -c "cat > $PROBE" 2>/dev/null || {
  echo "  cannot write probe into $CONT" >&2; exit 1; }

# Shared JS: locate the nth combobox and open it. Returns the widget + its options.
open_js() {
cat <<JSEOF
(async () => {
  const boxes=[...document.querySelectorAll("[role=combobox]")];
  const cb=boxes[$1];
  if(!cb) return JSON.stringify({err:"no combobox at index $1", comboboxes:boxes.length});
  const widget=cb.closest("[class*=container]")||cb.parentElement;
  const input=widget.querySelector("input")||cb;
  input.focus();
  input.dispatchEvent(new KeyboardEvent("keydown",
    {key:"ArrowDown",code:"ArrowDown",keyCode:40,which:40,bubbles:true}));
  await new Promise(r=>setTimeout(r,600));
  const opts=[...document.querySelectorAll("[role=option]")].map((e,i)=>({
    i, id:e.id||"", text:(e.innerText||"").replace(/\s+/g," ").trim().slice(0,60)}));
  return JSON.stringify({comboboxes:boxes.length, opened:$1, options:opts.length, items:opts,
                         widgetText:(widget.innerText||"").replace(/\s+/g," ").trim().slice(0,60)});
})()
JSEOF
}

run() { docker exec "$CONT" python3 "$PROBE" "$1" 2>&1; }

# Focus flaps between tabs on this box; re-assert before touching the page.
"$DESK" tabs >/dev/null 2>&1; "$DESK" focus 1 >/dev/null 2>&1

case "$cmd" in
  list)
    n="${2:-0}"
    run "$(open_js "$n")" | python3 -c '
import sys,json
try: d=json.loads(sys.stdin.read().strip() or "{}")
except ValueError as e: print("  unreadable probe result: %s" % e); sys.exit(1)
if d.get("err"): print("  %s" % d["err"]); sys.exit(1)
print("  %d combobox(es) on the page; opened #%s" % (d.get("comboboxes",0), d.get("opened")))
if not d.get("options"):
    print("  NO OPTIONS APPEARED. The widget may not use role=option, or may need a different key.")
    print("  This is UNKNOWN, not empty — do not report the dropdown as having no values.")
    sys.exit(1)
for o in d["items"]: print("   [%d] %s   (id=%s)" % (o["i"], o["text"], o["id"]))
print("  select with: desktop-dropdown.sh pick %s <index>" % d.get("opened"))' ;;

  pick)
    n="${2:-0}"; shift 2 2>/dev/null || true
    if [ "${1:-}" = "--text" ]; then want="${2:-}"; idx=0; else idx="${1:-}"; want=""; fi
    [ -n "$idx$want" ] || { echo "  usage: pick <combobox-n> <index> | pick <n> --text \"Label\"" >&2; exit 2; }
    # Build the JS literal in PYTHON, not by string-pasting in bash. Doing it with
    # ${want:+...} produced `JSON.stringify("TypeScript")` pasted raw into the source and a
    # SyntaxError — the label is user text and must be escaped by something that knows JS quoting.
    if [ -n "$want" ]; then
      wantjs=$(printf '%s' "$want" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
    else
      wantjs=null
    fi
    js=$(cat <<JSEOF
(async () => {
  const boxes=[...document.querySelectorAll("[role=combobox]")];
  const cb=boxes[$n];
  if(!cb) return JSON.stringify({err:"no combobox at index $n"});
  const widget=cb.closest("[class*=container]")||cb.parentElement;
  const input=widget.querySelector("input")||cb;
  const before=(widget.innerText||"").replace(/\s+/g," ").trim().slice(0,60);
  input.focus();
  input.dispatchEvent(new KeyboardEvent("keydown",
    {key:"ArrowDown",code:"ArrowDown",keyCode:40,which:40,bubbles:true}));
  await new Promise(r=>setTimeout(r,600));
  const opts=[...document.querySelectorAll("[role=option]")];
  if(!opts.length) return JSON.stringify({err:"widget did not open / no role=option nodes"});
  const wanted=$wantjs;
  let pick = wanted ? opts.find(o=>(o.innerText||"").toLowerCase().includes(String(wanted).toLowerCase())) : opts[$idx];
  if(!pick) return JSON.stringify({err:"no matching option", available:opts.map(o=>(o.innerText||"").trim().slice(0,30))});
  const label=(pick.innerText||"").replace(/\s+/g," ").trim().slice(0,60);
  for(const t of ["pointerdown","mousedown","pointerup","mouseup","click"])
    pick.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true,view:window}));
  await new Promise(r=>setTimeout(r,700));
  const after=(widget.innerText||"").replace(/\s+/g," ").trim().slice(0,60);
  const key=label.replace(/[^A-Za-z ]/g,"").trim().slice(0,18);
  return JSON.stringify({picked:label, before, after,
                         confirmed: key.length>2 && after.toLowerCase().includes(key.toLowerCase()),
                         stillOpen: document.querySelectorAll("[role=option]").length});
})()
JSEOF
)
    run "$js" | python3 -c '
import sys,json
try: d=json.loads(sys.stdin.read().strip() or "{}")
except ValueError as e: print("  unreadable probe result: %s" % e); sys.exit(1)
if d.get("err"):
    print("  %s" % d["err"])
    for a in (d.get("available") or [])[:8]: print("     available: %s" % a)
    sys.exit(1)
print("  picked  : %s" % d["picked"])
print("  widget  : %r -> %r" % (d.get("before"), d.get("after")))
# Never claim success from "the click did not error". Confirm against the widget own text.
if d.get("confirmed"): print("  CONFIRMED: the widget now shows the chosen value.")
else: print("  ** NOT CONFIRMED ** the widget text did not change to match. Treat as FAILED and verify by hand.")' ;;

  *) echo "  unknown command: $cmd (use list | pick)" >&2; exit 2 ;;
esac
