# press-element.py -- press the element under a point THROUGH THE PAGE, when a real X click did nothing.
#
# WHY. React-Aria / Base UI / Radix buttons -- Clerk's and Resend's dashboards --
# frequently ignore the xdotool click that `activate` sends: 38 of 69 activates in the log reported
# "nothing changed". Rotating an app's API keys once only worked by focusing the button through
# the DOM and pressing Enter, or dispatching the full pointer sequence. That was done by hand, five
# times, with throwaway scripts. This is that, once, tested.
#
# SAME ELEMENT, NOT A NEW GUESS. It takes the exact point `activate` just clicked and asks the page
# what is there (elementFromPoint), then walks up to the nearest pressable ancestor. It refuses unless
# that element's accessible name contains the name activate resolved -- so a fallback can never press
# something the agent did not ask for.
#
# Runs INSIDE the container. Env: SX SY (screen px of the click), OX OY (CSS origin from the resolver),
#   T_NAME (resolved name), STAGE=pointer|enter
# Prints JSON: {pressed:bool, how, tag, name} or {pressed:false, why}. Exit 0 always unless CDP is gone (3).

import os, sys, json, urllib.request, asyncio
try:
    import websockets
except Exception:
    print(json.dumps({"pressed": False, "why": "websockets missing"})); sys.exit(3)

sx, sy = float(os.environ["SX"]), float(os.environ["SY"])
ox, oy = float(os.environ.get("OX") or 0), float(os.environ.get("OY") or 0)
tname, stage = os.environ.get("T_NAME", ""), os.environ.get("STAGE", "pointer")
# T_FRAME is the host of the iframe the resolver found the element in. A cross-origin
# iframe is its own CDP target (type "iframe"), so press THAT target; the page's coordinates mean
# nothing inside it, so the element is found by exact name (the resolver's own rule) instead.
tframe = os.environ.get("T_FRAME", "")
try:
    _all = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=5))
    if tframe:
        pages = [t for t in _all if t.get("type") == "iframe" and t.get("webSocketDebuggerUrl")
                 and (t.get("url", "").split("/") + ["", "", ""])[2] == tframe]
    else:
        pages = [t for t in _all if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
except Exception as e:
    print(json.dumps({"pressed": False, "why": "no CDP (%s)" % e})); sys.exit(3)

JS = r"""(() => {
  const FR = %(fr)s;
  if (!FR && !document.hasFocus()) return JSON.stringify({skip: 1});
  const dpr = window.devicePixelRatio || 1;
  const cx = %(sx)s / dpr - %(ox)s, cy = %(sy)s / dpr - %(oy)s;
  const hit = FR ? null : document.elementFromPoint(cx, cy);
  if (!hit && !FR) return JSON.stringify({pressed: false, why: 'nothing at that point'});
  const P = 'button,a[href],[role=button],[role=menuitem],[role=menuitemradio],[role=option],[role=tab],[role=link],[role=switch],[role=checkbox],input[type=submit],input[type=button],summary';
  const norm = s => (s || '').replace(/\s+/g, ' ').trim().toLowerCase();
  const nameOf = e => norm(e.getAttribute('aria-label') || e.innerText || ((e.type||'').toLowerCase()==='password' ? '' : e.value) || e.getAttribute('title'));
  const want = norm(%(tname)s);
  let t = hit ? (hit.closest(P) || hit) : null, nm = t ? nameOf(t) : '', moved = false;
  if (want && !nm.includes(want) && !want.includes(nm || '\u0000')) {
    // COVERED TARGET (found on a real dashboard): a sticky header sat over the button, so the X
    // click AND elementFromPoint both hit the header. Look the target up by EXACT name among
    // pressable elements; only if exactly one exists, bring it to the viewport centre and use it.
    const cands = [...document.querySelectorAll(P)].filter(e => nameOf(e) === want);
    if (cands.length !== 1)
      return JSON.stringify({pressed: false, why: 'element at the click point is ' + JSON.stringify(nm.slice(0, 50)) +
        ' (target covered?) and ' + cands.length + ' elements are named ' + JSON.stringify(want) + ' -- refusing'});
    t = cands[0]; t.scrollIntoView({block: 'center'}); nm = nameOf(t); moved = true;
  }
  t.focus({preventScroll: true});
  if (%(stage)s === 'pointer') {
    const r = t.getBoundingClientRect(), o = {bubbles: true, cancelable: true, composed: true,
      clientX: r.x + r.width / 2, clientY: r.y + r.height / 2, button: 0, buttons: 1,
      pointerId: 1, pointerType: 'mouse', isPrimary: true, view: window};
    for (const ty of ['pointerover', 'pointerenter', 'pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'])
      t.dispatchEvent(ty.startsWith('pointer') ? new PointerEvent(ty, o) : new MouseEvent(ty, o));
  }
  return JSON.stringify({pressed: true, moved: moved, focused: document.activeElement === t, tag: t.tagName.toLowerCase(), name: nm.slice(0, 60)});
})()"""

async def main():
    for t in pages:
        try:
            async with websockets.connect(t["webSocketDebuggerUrl"], max_size=4_000_000, open_timeout=5) as ws:
                async def call(i, m, p):
                    await ws.send(json.dumps({"id": i, "method": m, "params": p}))
                    while True:
                        r = json.loads(await asyncio.wait_for(ws.recv(), timeout=6))
                        if r.get("id") == i: return r
                expr = JS % {"sx": sx, "sy": sy, "ox": ox, "oy": oy, "tname": json.dumps(tname), "stage": json.dumps(stage), "fr": json.dumps(bool(tframe))}
                v = json.loads((await call(1, "Runtime.evaluate", {"expression": expr, "returnByValue": True}))["result"]["result"]["value"])
                if v.get("skip"): continue
                if v.get("pressed") and stage == "enter":
                    if not v.get("focused"):
                        v = {"pressed": False, "why": "target would not take focus for Enter"}
                    else:
                        for i, ty in enumerate(("keyDown", "keyUp")):
                            await call(2 + i, "Input.dispatchKeyEvent", {"type": ty, "key": "Enter", "code": "Enter",
                                                                         "windowsVirtualKeyCode": 13, "text": "\r" if ty == "keyDown" else ""})
                v["how"] = stage
                print(json.dumps(v)); return 0
        except Exception as e:
            print(json.dumps({"pressed": False, "why": "page unreadable: %s" % str(e)[:80]})); return 0
    print(json.dumps({"pressed": False, "why": "no focused page"})); return 0

sys.exit(asyncio.run(main()))
