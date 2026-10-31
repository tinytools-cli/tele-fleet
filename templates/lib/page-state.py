# page-state.py -- the cheap local truth about the focused page.
#
# THIS IS THE "LOCAL VERIFICATION" HALF of the design, and the reason it exists is one line
# from its spec:
#
#     "Do not optimize for fewer checks. Optimize for fewer model-mediated checks."
#
# An earlier goal runner verified a step by asking a model whether the page looked right. That is a network
# round trip, a bill, and a judgement call, to answer a question the browser can answer exactly:
# did the URL change, did the thing I clicked go away, did the title move. Those are facts, they
# cost ~150ms, and they cannot be wrong in the way a model can be wrong.
#
# Prints one JSON object: {url, title, ready, hasFocus}. Exit 3 if the page cannot be read at
# all -- NOT exit 0 with empty fields, because "I could not look" and "nothing changed" are
# different answers and conflating them is a defect class of its own.
import sys, json, urllib.request, asyncio
try:
    import websockets
except Exception:
    print("websockets missing in container", file=sys.stderr); sys.exit(3)
try:
    targets = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=5))
except Exception as e:
    print("no CDP on 9222 (%s)" % e, file=sys.stderr); sys.exit(3)
pages = [t for t in targets if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
if not pages:
    print("no page target", file=sys.stderr); sys.exit(3)

# ov/exp/tl: url/title cannot see a dialog open, a menu drop or a
# form section appear -- all of which read as "the click did nothing" and pushed agents to retry
# or screenshot. Counting open overlays, expanded widgets and the page's text length lets
# verify-action.py see in-page responses for ~1ms more work.
EXPR = """(() => { const vis = e => { const r = e.getBoundingClientRect(); return r.width > 2 && r.height > 2; };
  return JSON.stringify({
  url: location.href, title: document.title,
  ready: document.readyState, hasFocus: document.hasFocus(),
  ov: [...document.querySelectorAll('[role=dialog],[role=alertdialog],[aria-modal=true],dialog[open],[role=menu],[role=listbox]')].filter(vis).length,
  exp: document.querySelectorAll('[aria-expanded=true]').length,
  // sel: which options are chosen -- a radio/checkbox/tab click changes nothing else visible.
  sel: [...document.querySelectorAll('[aria-checked=true],[aria-selected=true],[aria-pressed=true],input:checked')].map(e => e.id || e.getAttribute('name') || (e.innerText || '').slice(0, 20)).join('|'),
  tl: (document.body && document.body.innerText || '').length,
  // th: hash of the visible text with DIGITS stripped -- catches same-length content swaps that tl
  // misses, while clocks, counters and timers (digits only) do not read as the click working.
  th: (() => { const t = (document.body && document.body.innerText || '').replace(/[0-9]/g, ''); let h = 0;
               for (let i = 0; i < t.length; i++) h = (h * 31 + t.charCodeAt(i)) | 0; return h; })()}); })()"""

# a cross-origin iframe's content is invisible to EXPR above, so a click inside one
# (Persona inside Twilio TrustHub) read as "nothing changed". fx = text length + digit-stripped
# hash per iframe target, compared by verify-action.py like th. Absent when there are no iframes.
FEXPR = """(() => { const t = (document.body && document.body.innerText || ''); const u = t.replace(/[0-9]/g, ''); let h = 0;
  for (let i = 0; i < u.length; i++) h = (h * 31 + u.charCodeAt(i)) | 0; return t.length + ':' + h; })()"""
async def frames_fx():
    out = []
    for t in targets:
        if t.get("type") != "iframe" or not t.get("webSocketDebuggerUrl"):
            continue
        try:
            async with websockets.connect(t["webSocketDebuggerUrl"], max_size=4_000_000, open_timeout=3) as fw:
                await fw.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {"expression": FEXPR, "returnByValue": True}}))
                while True:
                    m = json.loads(await asyncio.wait_for(fw.recv(), timeout=3))
                    if m.get("id") == 1:
                        out.append(str((((m.get("result") or {}).get("result") or {}).get("value")) or "")); break
        except Exception:
            out.append("?")
    return "|".join(out)

async def go():
    for t in pages:
        try:
            async with websockets.connect(t["webSocketDebuggerUrl"], max_size=4_000_000,
                                          open_timeout=5) as ws:
                await ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate",
                                          "params": {"expression": EXPR, "returnByValue": True}}))
                while True:
                    m = json.loads(await asyncio.wait_for(ws.recv(), timeout=6))
                    if m.get("id") == 1:
                        v = (((m.get("result") or {}).get("result") or {}).get("value")) or ""
                        if not v:
                            break
                        d = json.loads(v)
                        # Only the focused page is the one the user's click will land on.
                        # An unfocused page's state is somebody else's tab.
                        if not d.get("hasFocus"):
                            break
                        fx = await frames_fx()
                        if fx: d["fx"] = fx
                        print(json.dumps(d))
                        return
        except Exception:
            continue
    print("no focused page could be read", file=sys.stderr)
    sys.exit(3)

asyncio.run(go())
