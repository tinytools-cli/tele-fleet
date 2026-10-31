# resolve-elements.py -- WHERE IS IT ON SCREEN, and WHAT IS IT.
#
# Extracted from desktop.sh so that `find` and `activate` share ONE copy of the
# coordinate math. That math has had three separate subtle bugs (unscaled origin at dpr!=1
#, 1px wrapper elements matching, collapsed/scaled viewports returning plausible
# nonsense). Each was found once and fixed once; a second copy is a second place for
# them to come back, in a file where nobody would think to look.
#
# Runs INSIDE the desktop container -- 9222 is bound to the container's own loopback.
#
#   MODE=sel|text  Q=<selector or text>   [RESOLVE_JSON=1]
#
# Exit codes are load-bearing: 2 = read the page, nothing matched. 3 = could not read
# the page at all. 6 = viewport is unusable, every coordinate would be a lie. The distinction
# between 2 and 3 is the entire point -- "nothing there" and "I cannot see" had been the same
# answer, and every wrapper around this then guessed from English prose.

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
EXPR = r"""(() => {
  const FR = %s;
  if (!FR && !document.hasFocus()) return JSON.stringify({skip:1});
  // A COLLAPSED VIEWPORT MAKES EVERY COORDINATE BELOW A LIE, and silently.
  // Seen once: a desktop's browser window was 43 PIXELS TALL. Elements were
  // scrolled far outside it, so getBoundingClientRect returned positions that
  // mapped to other windows entirely -- two agents spent an evening clicking
  // things that were not there, each assuming a stacking or scroll bug. The
  // numbers looked perfectly plausible the whole time. `desktop.sh fit` fixes
  // it in one command; the point is to be TOLD rather than to debug it twice.
  //
  // TWO DIFFERENT FAULTS PRODUCE A SMALL CSS VIEWPORT AND THEY HAVE OPPOSITE
  // CURES, so the guard has to say WHICH. Naming the wrong one costs more than
  // saying nothing: once this told an agent to run `fit` while the real
  // cause was a 3x DISPLAY SCALE. `fit` resized the window, truthfully reported
  // "fitted to 1280x720", and changed nothing -- because the window was never
  // small. The CSS viewport is the physical size DIVIDED BY dpr: a healthy
  // 1500x447 render area reports as 500x149 at 3x. It retried, escalated, and
  // stayed blocked on a live task while both messages were individually true.
  const dpr = window.devicePixelRatio || 1;
  if (!FR && (window.innerHeight < 200 || window.innerWidth < 400)) {
    return JSON.stringify({tiny: [window.innerWidth, window.innerHeight],
                           dpr: dpr,
                           phys: [Math.round(window.innerWidth * dpr),
                                  Math.round(window.innerHeight * dpr)]});
  }
  // THE ORIGIN IS IN CSS PIXELS AND MUST BE SCALED BY dpr, SAME AS THE RECT.
  // The old form added screenX/screenY and the chrome height UNSCALED, then
  // scaled only the element rect. Identical when dpr == 1, wrong by the whole
  // origin when it is not -- and the original verification was done on a
  // dpr == 1 desktop, so it never showed.
  //
  // An agent hit it: find reported a tile at y=164, the real position was
  // ~301, and its clicks opened the address-bar padlock instead. X looked fine
  // ONLY because screenX happens to be 0 there -- 0 + l*dpr == (0 + l)*dpr --
  // which is why this read as a Y-specific bug for a year.
  //
  // Measured on both desktops, which disagree and both fit (screenY + chrome):
  //   desktop A: dpr 1, screenY 27,  chrome 91 -> viewport top 118 css
  //   desktop B: dpr 2, screenY 134, chrome 0  -> viewport top 134 css
  // chrome is clamped at >= 0 because one real tab reported -971.
  // Inside a child frame the origin is the TOP page's origin plus the frame's
  // offset (both CSS px), computed by the caller -- a frame's own screenX is the
  // window's, and knows nothing about where the frame sits in the page.
  const oxc = FR ? FR.ox : window.screenX;
  const oyc = FR ? FR.oy : window.screenY + Math.max(0, window.outerHeight - window.innerHeight);
  let els;
  if (%s === "text") {
    const needle = %s.toLowerCase();
    els = [...document.querySelectorAll('a,button,input,textarea,select,[role],label,span,div,li,td')]
      .filter(e => { const t = (e.innerText || (((e.type||'').toLowerCase()==='password'||/password/i.test(e.getAttribute('autocomplete')||'')) ? '' : e.value) || e.getAttribute('aria-label') || '').trim().toLowerCase();
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
    // for a login account row once -- clicking its centre lands on
    // whatever sits above or below the hairline, never the row. Nothing under
    // ~8px tall is a real click target, and a degenerate rect is a WRAPPER,
    // which is the wrong element even when the click happens to land.
    if (r.width < 8 || r.height < 8) continue;
    if (r.bottom < 0 || r.right < 0 || r.top > window.innerHeight || r.left > window.innerWidth) continue;
    const st = getComputedStyle(e);
    if (st.visibility === 'hidden' || st.display === 'none' || +st.opacity === 0) continue;
    // ROLE AND ACCESSIBLE NAME -- what the element IS and what a person would
    // call it, as opposed to where it happens to sit this second. These two
    // fields are the whole point of this design: an execution record
    // saying `activate button "Continue"` can be compared across runs, sites
    // and agents. One saying `click 640,420` cannot be compared with anything,
    // which is why "how repetitive is our work" was unanswerable from a log of
    // 12,158 rows.
    // Implicit roles only for the handful that actually come up here; an
    // unmapped tag returns its own name rather than a wrong guess.
    const IMPLICIT = {a:'link', button:'button', select:'combobox', textarea:'textbox',
                      img:'img', h1:'heading', h2:'heading', h3:'heading', form:'form',
                      table:'table', ul:'list', ol:'list', li:'listitem', nav:'navigation'};
    const tg = e.tagName.toLowerCase();
    let role = e.getAttribute('role') || '';
    if (!role && tg === 'input') {
      const ty = (e.getAttribute('type') || 'text').toLowerCase();
      role = ({checkbox:'checkbox', radio:'radio', submit:'button', button:'button',
               reset:'button', range:'slider', search:'searchbox'})[ty] || 'textbox';
    }
    if (!role) role = IMPLICIT[tg] || tg;
    // Accessible name, in the order a screen reader would resolve it. The
    // labelledby branch matters on real apps: a bare <input> whose only name
    // lives in a sibling <label> otherwise logs as "" and is unmatchable.
    let nm = e.getAttribute('aria-label') || '';
    if (!nm) {
      const lb = e.getAttribute('aria-labelledby');
      if (lb) nm = lb.split(/\s+/).map(i => (document.getElementById(i) || {}).innerText || '').join(' ');
    }
    if (!nm && e.id) {
      const l = document.querySelector('label[for=' + CSS.escape(e.id) + ']');
      if (l) nm = l.innerText || '';
    }
    if (!nm) nm = e.getAttribute('placeholder') || e.innerText || (((e.type||'').toLowerCase()==='password'||/password/i.test(e.getAttribute('autocomplete')||'')) ? '' : e.value)
                  || e.getAttribute('title') || e.getAttribute('alt') || '';
    nm = nm.replace(/\s+/g, ' ').trim().slice(0, 64);
    out.push({
      tag: tg, id: e.id || '', role: role, name: nm,
      label: ((e.getAttribute('aria-label') || e.placeholder || e.innerText || (((e.type||'').toLowerCase()==='password'||/password/i.test(e.getAttribute('autocomplete')||'')) ? '' : e.value) || '').trim()).slice(0, 48),
      x: Math.round((oxc + r.left + r.width / 2) * dpr),
      y: Math.round((oyc + r.top + r.height / 2) * dpr),
      w: Math.round(r.width * dpr), h: Math.round(r.height * dpr)});
    if (out.length >= 20) break;
  }
  return JSON.stringify({url: location.href, n: out.length, els: out, o: [oxc, oyc]});
})()"""
def expr(fr=None):
    return EXPR % (json.dumps(fr), json.dumps(mode), qj, qj)

# CROSS-ORIGIN FRAMES. The EXPR above runs in the top
# document, and a cross-origin iframe's DOM is invisible from there -- so on
# an enterprise portal that embeds its app in a cross-origin iframe, find/activate saw the portal shell
# and reported "no visible match" for a Submit button sitting right there.
#
# Mechanism: Page.getFrameTree, then per child frame Page.createIsolatedWorld
# and ONE Runtime.evaluate with that contextId. Pure request/response. The
# first attempt hung the shared desktop lock for six minutes because it
# used Page.enable, which STREAMS events forever; nothing here enables any
# domain, every recv has its own timeout, and the whole pass sits under
# FRAME_BUDGET. Blowing the budget degrades to main-frame-only and SAYS so.
#
# Frame offset = the owner <iframe>'s content-box position in its parent,
# found via DOM.getFrameOwner -> resolveNode -> callFunctionOn, summed down
# nested frames. The owner is resolved in its own frame's main world, so this
# works whether or not that parent is itself cross-origin.
FRAME_BUDGET = 8
MAX_FRAMES = 15
async def _frame_els(ws, origin):
    seq = [1000]
    async def call(method, params):
        seq[0] += 1; i = seq[0]
        await ws.send(json.dumps({"id": i, "method": method, "params": params}))
        while True:
            m = json.loads(await asyncio.wait_for(ws.recv(), timeout=4))
            if m.get("id") == i:
                return m
    ft = ((await call("Page.getFrameTree", {})).get("result") or {}).get("frameTree")
    if not ft:
        return [], None
    out, n, skipped = [], 0, 0
    stack = [(c, 0.0, 0.0) for c in ft.get("childFrames") or []]
    while stack:
        node, px, py = stack.pop(0)
        fid = node["frame"]["id"]; furl = node["frame"].get("url") or ""
        n += 1
        if n > MAX_FRAMES:
            skipped += 1; continue
        own = (await call("DOM.getFrameOwner", {"frameId": fid})).get("result") or {}
        if not own.get("backendNodeId"):
            continue
        obj = ((await call("DOM.resolveNode", {"backendNodeId": own["backendNodeId"]})).get("result") or {}).get("object") or {}
        if not obj.get("objectId"):
            continue
        r = await call("Runtime.callFunctionOn", {"objectId": obj["objectId"], "returnByValue": True,
            "functionDeclaration": "function(){var r=this.getBoundingClientRect();"
                                   "return [r.left+this.clientLeft,r.top+this.clientTop,this.clientWidth,this.clientHeight];}"})
        rect = (((r.get("result") or {}).get("result") or {}).get("value")) or [0, 0, 0, 0]
        if rect[2] < 8 or rect[3] < 8:
            continue  # hidden or 1px tracking frame -- nothing clickable in it
        fx, fy = px + rect[0], py + rect[1]
        w = (await call("Page.createIsolatedWorld", {"frameId": fid, "worldName": "desktop-find"})).get("result") or {}
        cid = w.get("executionContextId")
        if not cid:
            continue
        v = await call("Runtime.evaluate", {"expression": expr({"ox": origin[0] + fx, "oy": origin[1] + fy}),
                                            "contextId": cid, "returnByValue": True})
        try:
            fd = json.loads((((v.get("result") or {}).get("result") or {}).get("value")) or "{}")
        except Exception:
            fd = {}
        host = furl.split("/")[2] if furl.count("/") >= 2 else "frame"
        for e in fd.get("els") or []:
            e["frame"] = host
            out.append(e)
        stack.extend((c, fx, fy) for c in node.get("childFrames") or [])
    return out, ("%d frame(s) beyond the first %d were NOT searched" % (skipped, MAX_FRAMES) if skipped else None)
# OUT-OF-PROCESS IFRAMES. Page.getFrameTree lists a cross-site iframe
# (Twilio TrustHub -> Persona) but Page.createIsolatedWorld cannot reach it: its DOM lives in
# another renderer, which /json exposes as its own target with type "iframe". So: connect to that
# target's websocket and run the same EXPR there. Its offset in the page comes from the parent:
# the iframe target's id IS the frame id, so DOM.getFrameOwner finds the <iframe> element.
# Only iframes directly under the page are done; an OOPIF nested in an OOPIF is not.
async def _oopif_els(ws, origin):
    seq = [2000]
    async def call(w, method, params):
        seq[0] += 1; i = seq[0]
        await w.send(json.dumps({"id": i, "method": method, "params": params}))
        while True:
            m = json.loads(await asyncio.wait_for(w.recv(), timeout=4))
            if m.get("id") == i:
                return m
    out = []
    for t in targets:
        if t.get("type") != "iframe" or not t.get("webSocketDebuggerUrl"):
            continue
        try:
            own = (await call(ws, "DOM.getFrameOwner", {"frameId": t["id"]})).get("result") or {}
            if not own.get("backendNodeId"):
                continue
            obj = ((await call(ws, "DOM.resolveNode", {"backendNodeId": own["backendNodeId"]})).get("result") or {}).get("object") or {}
            r = await call(ws, "Runtime.callFunctionOn", {"objectId": obj.get("objectId"), "returnByValue": True,
                "functionDeclaration": "function(){var r=this.getBoundingClientRect();"
                                       "return [r.left+this.clientLeft,r.top+this.clientTop,this.clientWidth,this.clientHeight];}"})
            rect = (((r.get("result") or {}).get("result") or {}).get("value")) or [0, 0, 0, 0]
            if rect[2] < 8 or rect[3] < 8:
                continue
            async with websockets.connect(t["webSocketDebuggerUrl"], max_size=8_000_000, open_timeout=4) as fw:
                v = await call(fw, "Runtime.evaluate", {"expression": expr({"ox": origin[0] + rect[0], "oy": origin[1] + rect[1]}),
                                                        "returnByValue": True})
            fd = json.loads((((v.get("result") or {}).get("result") or {}).get("value")) or "{}")
        except Exception:
            continue
        url = t.get("url") or ""
        host = url.split("/")[2] if url.count("/") >= 2 else "frame"
        for e in fd.get("els") or []:
            e["frame"] = host
            out.append(e)
    return out
async def go():
    for t in pages:
        try:
            async with websockets.connect(t["webSocketDebuggerUrl"], max_size=8_000_000, open_timeout=5) as ws:
                await ws.send(json.dumps({"id":1,"method":"Runtime.evaluate",
                                          "params":{"expression":expr(),"returnByValue":True}}))
                while True:
                    m = json.loads(await asyncio.wait_for(ws.recv(), timeout=6))
                    if m.get("id") == 1:
                        v = (((m.get("result") or {}).get("result") or {}).get("value")) or "{}"
                        d = json.loads(v)
                        if d.get("tiny"):
                            w, h = d["tiny"]
                            dpr = d.get("dpr") or 1
                            pw, ph = (d.get("phys") or [w, h])
                            print("REFUSING: the CSS viewport is %dx%d." % (w, h), file=sys.stderr)
                            print("  Every coordinate from a viewport that size is wrong -- elements", file=sys.stderr)
                            print("  sit outside it and map onto other windows.", file=sys.stderr)
                            # WHICH FAULT IS IT: reuse the SAME 400x200 limits the
                            # guard above applies to CSS, but against the PHYSICAL
                            # area. If the window physically has room and only the
                            # division by dpr makes it small, the window is fine and
                            # the DISPLAY SCALE is the fault. If the physical area is
                            # tiny too, the window really is collapsed.
                            # Invented thresholds got this wrong once already: the
                            # first cut demanded 600px physical height, but a healthy
                            # 720px window only has ~447 after browser chrome, so
                            # real measured numbers still fell through to "run fit" --
                            # the very bug this branch exists to fix.
                            if dpr > 1.01 and pw >= 400 and ph >= 200:
                                print("  CAUSE: THE DISPLAY IS SCALED %gx -- the window is fine." % dpr, file=sys.stderr)
                                print("  It is really %dx%d physical; Chromium divides by the scale," % (pw, ph), file=sys.stderr)
                                print("  so a correctly-sized window still reports a tiny viewport.", file=sys.stderr)
                                print("  `fit` CANNOT FIX THIS -- it will resize the window and report", file=sys.stderr)
                                print("  success, because the window was never the problem.", file=sys.stderr)
                                print("  The display follows the VIEWER's pixel density, so this shows", file=sys.stderr)
                                print("  up when someone views the desktop from a phone, and it CLEARS", file=sys.stderr)
                                print("  ON ITS OWN when they next view it from a normal-density screen.", file=sys.stderr)
                                print("  There is no self-service fix yet. If you are blocked,", file=sys.stderr)
                                print("  say so to your operator rather than re-running fit -- re-running fit is", file=sys.stderr)
                                print("  exactly the loop this message exists to stop.", file=sys.stderr)
                            else:
                                print("  CAUSE: the window is collapsed (scale is %gx). Fix it with:" % dpr, file=sys.stderr)
                                print("      desktop.sh fit", file=sys.stderr)
                                print("  then run find again.", file=sys.stderr)
                            sys.exit(6)
                        if d.get("skip"): break
                        # CROSS-ORIGIN FRAMES. See _frame_els below.
                        try:
                            fe, fnote = await asyncio.wait_for(_frame_els(ws, d.get("o") or [0, 0]), timeout=FRAME_BUDGET)
                        except (asyncio.TimeoutError, TimeoutError):
                            fe, fnote = [], "frame search gave up after %ds -- child frames NOT searched" % FRAME_BUDGET
                        except Exception as ex:
                            fe, fnote = [], "frame search failed (%s) -- child frames NOT searched" % ex
                        try:
                            fe += await asyncio.wait_for(_oopif_els(ws, d.get("o") or [0, 0]), timeout=FRAME_BUDGET)
                        except Exception:
                            pass
                        if fnote:
                            print("note: " + fnote, file=sys.stderr)
                        if fe:
                            els = (d.get("els") or []) + fe
                            els.sort(key=lambda e: e["w"] * e["h"])
                            d["els"] = els[:20]
                            d["n"] = len(d["els"])
                        if not d.get("els"):
                            print("no visible match for: %s" % q, file=sys.stderr)
                            print("  the page IS reachable -- try a looser selector, or --text", file=sys.stderr)
                            sys.exit(2)
                        # RESOLVE_JSON is how `activate` consumes this. The
                        # human table stays byte-identical when it is unset --
                        # `find` is the most-used command on the box (2,373
                        # calls in 23 days) and this extraction must not change
                        # a single character of what it prints.
                        if os.environ.get("RESOLVE_JSON"):
                            print(json.dumps(d))
                            return
                        print("page: %s" % (d.get("url") or "")[:90])
                        for e in d["els"]:
                            name = (e["tag"] + ("#" + e["id"] if e["id"] else ""))
                            if e.get("frame"):
                                name = "[%s] %s" % (e["frame"] if e["frame"][:1].isdigit() else e["frame"].split(".")[0], name)
                            print("  %-22s %5d,%-5d  (%dx%d)  %s" % (name, e["x"], e["y"], e["w"], e["h"], e["label"]))
                        print("  -> click with: desktop.sh click <x> <y>")
                        return
        except Exception:
            continue
    print("no focused page could be read", file=sys.stderr)
    sys.exit(3)
async def _bounded():
    try:
        await asyncio.wait_for(go(), timeout=30)
    except (asyncio.TimeoutError, TimeoutError):
        print("find gave up after 30s -- the page never answered", file=sys.stderr)
        sys.exit(3)
asyncio.run(_bounded())
