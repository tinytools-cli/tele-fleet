# choose-option.py -- pick an option BY VISIBLE TEXT from a custom (ARIA) combobox / listbox.
#
# WHY. Meta Business Suite's Category field is div[role=combobox][aria-haspopup=listbox]; its popup is a
# role=listbox of role=option rows, VIRTUALIZED (only ~10 exist in the DOM). `desktop.sh scroll` wheels the
# page, not the listbox, so "Professional Services" never rendered and a human had to pick it.
#
# WHAT. Resolve the combobox (css selector, else label/visible text) -> open it -> find role=option by text
# -> if absent, scroll the LISTBOX ITSELF (scrollTop on it or its scrollable ancestor/descendant) step by step
# until the option renders or the end -> click it with real CDP mouse events -> VERIFY the combobox now shows
# the text. If never found, fall back to typing the text into the combobox (filter) where it accepts typing.
# Native <select> is handled too (set + input/change events).
#
# Runs INSIDE the container. Env: Q=<css selector | label text>  OPT=<option text>
# Exit: 0 chosen+verified  2 combobox or option not found  3 cannot read page  4 ambiguous  5 clicked, not verified
import os, sys, json, urllib.request, asyncio
try:
    import websockets
except Exception:
    print("websockets missing in container", file=sys.stderr); sys.exit(3)

Q, OPT = os.environ.get("Q", ""), os.environ.get("OPT", "")
try:
    targets = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=5))
except Exception as e:
    print("no CDP on 9222 (%s)" % e, file=sys.stderr); sys.exit(3)
pages = [t for t in targets if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
pages += [dict(t, oopif=True) for t in targets if t.get("type") == "iframe" and t.get("webSocketDebuggerUrl")]

# Shared helpers, prepended to every evaluate. State lives on window.__ch (combobox element).
LIB = r"""
const OPT = %(opt)s, Q = %(q)s, OOPIF = %(oopif)s;
const norm = s => (s || '').replace(/\s+/g, ' ').trim().toLowerCase();
const vis = e => { const r = e.getBoundingClientRect(), s = getComputedStyle(e); return r.width > 1 && r.height > 1 && s.visibility !== 'hidden' && s.display !== 'none'; };
const names = e => { const o = [e.getAttribute('aria-label'), e.getAttribute('placeholder'), e.getAttribute('name')];
  (e.getAttribute('aria-labelledby') || '').split(/\s+/).forEach(id => { const l = id && document.getElementById(id); if (l) o.push(l.innerText); });
  if (e.id) document.querySelectorAll('label[for="' + CSS.escape(e.id) + '"]').forEach(l => o.push(l.innerText));
  const w = e.closest('label'); if (w) o.push(w.innerText);
  o.push(e.innerText, e.value); return o.map(norm).filter(Boolean); };
const shown = e => norm(e.tagName === 'SELECT' ? (e.selectedOptions[0] || {}).text : (e.value !== undefined && e.value !== '' && e.tagName === 'INPUT') ? e.value : (e.innerText || e.getAttribute('aria-label')));
const listboxOf = cb => { const ids = ((cb.getAttribute('aria-controls') || '') + ' ' + (cb.getAttribute('aria-owns') || '')).split(/\s+/).filter(Boolean);
  for (const id of ids) { const l = document.getElementById(id); if (l && (l.getAttribute('role') === 'listbox' || l.querySelector('[role=option]'))) return l; }
  const all = [...document.querySelectorAll('[role=listbox]')].filter(vis); return all.length ? all[all.length - 1] : null; };
const optsOf = lb => lb ? [...lb.querySelectorAll('[role=option]')].filter(vis) : [];
const findOpt = lb => { const os = optsOf(lb), w = norm(OPT);
  let m = os.filter(o => norm(o.innerText || o.getAttribute('aria-label')) === w);
  if (!m.length) m = os.filter(o => norm(o.innerText || o.getAttribute('aria-label')).includes(w));
  return m; };
const scroller = lb => { const ok = e => e.scrollHeight > e.clientHeight + 2 && /(auto|scroll)/.test(getComputedStyle(e).overflowY);
  if (ok(lb)) return lb; let e = lb.parentElement; while (e && e !== document.documentElement) { if (ok(e)) return e; e = e.parentElement; }
  return [...lb.querySelectorAll('*')].find(ok) || null; };
"""

RESOLVE = r"""(() => {
  if (!OOPIF && !document.hasFocus()) return JSON.stringify({skip: 1});
  const CB = '[role=combobox], select, input[aria-haspopup], input[aria-autocomplete], [aria-haspopup=listbox]';
  let hits = [];
  try { hits = [...document.querySelectorAll(Q)].filter(vis); } catch (x) {}
  if (!hits.length) { const want = norm(Q), all = [...document.querySelectorAll(CB)].filter(vis);
    hits = all.filter(e => names(e).some(n => n === want));
    if (!hits.length) hits = all.filter(e => names(e).some(n => n.includes(want))); }
  const d = e => ({tag: e.tagName.toLowerCase(), role: e.getAttribute('role') || '', id: e.id || '', label: (names(e)[0] || '').slice(0, 50)});
  if (!hits.length) return JSON.stringify({none: 1, seen: [...document.querySelectorAll(CB)].filter(vis).slice(0, 12).map(d)});
  if (hits.length > 1) return JSON.stringify({many: hits.slice(0, 10).map(d)});
  const e = hits[0]; e.scrollIntoView({block: 'center'}); window.__ch = e;
  if (e.tagName === 'SELECT') {
    const o = [...e.options].filter(o => norm(o.text) === norm(OPT)); const o2 = o.length ? o : [...e.options].filter(o => norm(o.text).includes(norm(OPT)));
    if (o2.length !== 1) return JSON.stringify({native: 1, matches: o2.length, options: [...e.options].slice(0, 30).map(o => o.text)});
    e.focus(); e.value = o2[0].value; e.dispatchEvent(new Event('input', {bubbles: true})); e.dispatchEvent(new Event('change', {bubbles: true}));
    return JSON.stringify({native: 1, done: 1, shown: shown(e)});
  }
  return JSON.stringify({ok: d(e), expanded: e.getAttribute('aria-expanded') === 'true'});
})()"""

CENTER = r"""(() => { const e = window.__ch; if (!e) return 'null'; const r = e.getBoundingClientRect();
  return JSON.stringify({x: r.x + r.width / 2, y: r.y + r.height / 2}); })()"""

# Is the option rendered? If not, scroll the listbox one step. Returns state; never throws.
STEP = r"""(() => { const cb = window.__ch, lb = listboxOf(cb);
  if (!lb) return JSON.stringify({nolb: 1});
  let m = findOpt(lb);
  if (m.length > 1) return JSON.stringify({many: m.slice(0, 8).map(o => (o.innerText || '').trim().slice(0, 50))});
  if (m.length === 1) { m[0].scrollIntoView({block: 'nearest'}); const r = m[0].getBoundingClientRect();
    window.__chopt = m[0]; return JSON.stringify({found: 1, x: r.x + r.width / 2, y: r.y + r.height / 2}); }
  const sc = scroller(lb);
  if (!sc) return JSON.stringify({noscroll: 1, count: optsOf(lb).length});
  const before = sc.scrollTop; sc.scrollTop = before + Math.max(20, Math.floor(sc.clientHeight * 0.7));
  sc.dispatchEvent(new Event('scroll', {bubbles: true}));
  return JSON.stringify({scrolled: 1, moved: sc.scrollTop !== before, top: sc.scrollTop, max: sc.scrollHeight - sc.clientHeight});
})()"""

TOP = r"""(() => { const lb = listboxOf(window.__ch); const sc = lb && scroller(lb); if (sc) { sc.scrollTop = 0; sc.dispatchEvent(new Event('scroll', {bubbles: true})); } return 1; })()"""

# DOM-level pointer sequence, used inside cross-origin iframes where page coordinates mean nothing.
DOMCLICK = r"""(() => { const t = window.__chopt; if (!t) return 'no'; const r = t.getBoundingClientRect();
  const o = {bubbles: true, cancelable: true, composed: true, clientX: r.x + r.width / 2, clientY: r.y + r.height / 2, button: 0, buttons: 1, pointerId: 1, pointerType: 'mouse', isPrimary: true, view: window};
  for (const ty of ['pointerover', 'pointerenter', 'pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) t.dispatchEvent(ty.startsWith('pointer') ? new PointerEvent(ty, o) : new MouseEvent(ty, o));
  return 'ok'; })()"""

VERIFY = r"""(() => { const e = window.__ch; if (!e || !e.isConnected) return JSON.stringify({gone: 1});
  const s = shown(e), w = norm(OPT); return JSON.stringify({shown: s, ok: s.includes(w), expanded: e.getAttribute('aria-expanded') === 'true'}); })()"""

async def main():
    none_msgs = []
    for t in pages:
        try:
            async with websockets.connect(t["webSocketDebuggerUrl"], max_size=4_000_000, open_timeout=5) as ws:
                seq = [0]
                async def call(method, params):
                    seq[0] += 1; i = seq[0]
                    await ws.send(json.dumps({"id": i, "method": method, "params": params}))
                    while True:
                        m = json.loads(await asyncio.wait_for(ws.recv(), timeout=8))
                        if m.get("id") == i: return m
                sub = {"opt": json.dumps(OPT), "q": json.dumps(Q), "oopif": json.dumps(bool(t.get("oopif")))}
                async def ev(js):
                    r = await call("Runtime.evaluate", {"expression": "(() => {" + LIB.replace("%(opt)s", sub["opt"]).replace("%(q)s", sub["q"]).replace("%(oopif)s", sub["oopif"]) + " return " + js + "; })()", "returnByValue": True})
                    v = (r.get("result", {}).get("result") or {}).get("value")
                    return json.loads(v) if isinstance(v, str) else v
                async def mouse(x, y):
                    for typ, kw in (("mouseMoved", {}), ("mousePressed", {"button": "left", "buttons": 1, "clickCount": 1}),
                                    ("mouseReleased", {"button": "left", "clickCount": 1})):
                        await call("Input.dispatchMouseEvent", dict({"type": typ, "x": x, "y": y}, **kw))
                async def click_el(c, how_el):
                    if t.get("oopif"):
                        await ev(DOMCLICK)
                    else:
                        await mouse(c["x"], c["y"])
                r = await ev(RESOLVE)
                if r.get("skip"): continue
                where = t.get("url", "")[:80]
                if r.get("none"):
                    none_msgs.append("no combobox matched %r on %s" % (Q, where))
                    none_msgs += ["  combobox: %-8s %-14s %-24s %s" % (f["tag"], f["role"], f["id"][:24], f["label"]) for f in r["seen"]]
                    continue
                if r.get("many"):
                    print("%d comboboxes match %r -- refusing to guess:" % (len(r["many"]), Q), file=sys.stderr)
                    for f in r["many"]: print("  %-8s %-14s %-24s %s" % (f["tag"], f["role"], f["id"][:24], f["label"]), file=sys.stderr)
                    return 4
                if r.get("native"):
                    if r.get("done"):
                        print("chose %r in native <select> -- verified, it shows %r" % (OPT, r["shown"])); return 0
                    print("native <select>: %d options match %r. Options: %s" % (r["matches"], OPT, "; ".join(r["options"])), file=sys.stderr); return 2
                # --- ARIA combobox ---
                f = r["ok"]; name = f["label"] or f["id"] or f["tag"]
                if not r["expanded"]:
                    c = await ev(CENTER)
                    await call("Runtime.evaluate", {"expression": "window.__ch.focus({preventScroll:true})", "returnByValue": True})
                    if t.get("oopif"):
                        await call("Runtime.evaluate", {"expression": "window.__ch.click()", "returnByValue": True})
                    else:
                        await mouse(c["x"], c["y"])
                    await asyncio.sleep(0.5)
                async def search():
                    """scroll the listbox to the top, then step down until the option renders or the end."""
                    await ev(TOP); await asyncio.sleep(0.15)
                    steps = 0; stuck = 0
                    for steps in range(1, 400):
                        s = await ev(STEP)
                        if s.get("found") or s.get("many") or s.get("nolb") or s.get("noscroll"): return s, steps
                        await asyncio.sleep(0.12)
                        if not s.get("moved"):
                            stuck += 1
                            if stuck >= 2: return s, steps   # end of the list
                        else: stuck = 0
                    return s, steps
                s, steps = await search()
                typed = False
                if not s.get("found") and not s.get("many"):
                    # FALLBACK: type to filter, where the combobox accepts typing.
                    ok = await ev("(() => { const e = window.__ch; const i = e.matches('input,textarea,[contenteditable]') ? e : e.querySelector('input,textarea,[contenteditable]'); if (!i) return false; i.focus(); if (i.select) i.select(); window.__chin = i; return true; })()")
                    if ok:
                        await call("Input.insertText", {"text": OPT}); typed = True
                        await asyncio.sleep(0.6)
                        s, st2 = await search(); steps += st2
                if s.get("many"):
                    print("%d options match %r -- be more exact: %s" % (len(s["many"]), OPT, " | ".join(s["many"])), file=sys.stderr); return 4
                if not s.get("found"):
                    why = {"nolb": "no open listbox appeared after opening the combobox", "noscroll": "listbox has no scrollable container"}.get(next((k for k in ("nolb", "noscroll") if s.get(k)), ""), "reached the end of the list")
                    print("option %r not found in combobox %r: %s (%d scroll steps%s)." % (OPT, name, why, steps, ", typing fallback tried" if typed else ""), file=sys.stderr); return 2
                await click_el(s, None)
                await asyncio.sleep(0.5)
                v = await ev(VERIFY)
                if v.get("ok"):
                    print("chose %r in combobox %r after %d scroll step(s)%s -- verified, it shows %r" % (OPT, name, steps, " (typed to filter)" if typed else "", v["shown"][:80])); return 0
                if v.get("gone"):
                    print("clicked %r but the combobox element was replaced; cannot verify. Run read/find to check." % OPT, file=sys.stderr); return 5
                print("clicked %r but combobox %r now shows %r, not the option." % (OPT, name, v.get("shown", "")[:80]), file=sys.stderr); return 5
        except Exception as e:
            print("page %s unreadable: %s" % (t.get("url", "")[:60], e), file=sys.stderr)
    if none_msgs:
        print("\n".join(none_msgs), file=sys.stderr); return 2
    print("no focused page -- run: desktop.sh tabs / focus <n>", file=sys.stderr); return 3

sys.exit(asyncio.run(main()))
