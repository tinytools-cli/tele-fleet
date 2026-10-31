# fill-field.py -- put text in a form field WITHOUT coordinates.
#
# THE BUG THIS CLOSES. One agent spent ~400 of 631 desktop commands on Stripe's
# dashboard doing "key Tab; type x; did it land?" loops. `find` listed the fields correctly, with
# positions. The failure was the NEXT step: `click <x> <y>` on a React-Aria input left
# document.activeElement on a DIV, `type` (correctly) refused to type into nothing, and the only
# way left to reach a field was to Tab-walk to it one keystroke at a time.
#
# Same root cause as the dropdown bug: a synthetic pointer click at screen coordinates
# does not reliably FOCUS these inputs. The page itself can: element.focus() is exact, needs no
# geometry, and cannot drift with scroll, window size or display scale.
#
# Then Input.insertText over CDP -- a real text-input event, which React's onChange sees (setting
# .value directly does NOT fire it and the form silently keeps the old value). Then VERIFY by
# reading the field back. A fill that did not stick must say so.
#
# Runs INSIDE the desktop container (9222 is the container's own loopback).
#   MODE=sel|label  Q=<css selector | label text>  TEXT=<text, may be empty = clear>
#
# Exit codes ("nothing there" and "cannot see" must never be the same answer):
#   0 filled and verified   2 read the page, no field matched   3 could not read the page
#   4 more than one field matched -- refuse to guess             5 typed, but the value did not stick

import os, sys, json, urllib.request, asyncio
try:
    import websockets
except Exception:
    print("websockets missing in container", file=sys.stderr); sys.exit(3)

mode, q, text = os.environ.get("MODE", "sel"), os.environ.get("Q", ""), os.environ.get("TEXT", "")
try:
    targets = json.load(urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=5))
except Exception as e:
    print("no CDP on 9222 (%s)" % e, file=sys.stderr); sys.exit(3)
pages = [t for t in targets if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
# a cross-origin iframe is its own target (type "iframe"). Try it after the pages; its
# document never has focus while the user is in the parent, so the hasFocus skip does not apply.
pages += [dict(t, oopif=True) for t in targets if t.get("type") == "iframe" and t.get("webSocketDebuggerUrl")]

# Resolve to exactly one VISIBLE, EDITABLE field, focus it, and select its contents so the
# insert REPLACES rather than appends. Label matching mirrors how a human names a field.
RESOLVE = r"""(() => {
  if (!%s && !document.hasFocus()) return JSON.stringify({skip:1});
  const MODE = %s, Q = %s;
  const EDIT = 'input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=submit]):not([type=button]):not([disabled]), textarea:not([disabled]), [contenteditable=""], [contenteditable=true]';
  const vis = e => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e);
    return r.width > 2 && r.height > 2 && s.visibility !== 'hidden' && s.display !== 'none'; };
  const norm = s => (s || '').replace(/\s+/g, ' ').trim().toLowerCase();
  const names = e => {
    const out = [e.getAttribute('aria-label'), e.getAttribute('placeholder'), e.getAttribute('name')];
    (e.getAttribute('aria-labelledby') || '').split(/\s+/).forEach(id => { const l = id && document.getElementById(id); if (l) out.push(l.innerText); });
    if (e.id) document.querySelectorAll('label[for="' + CSS.escape(e.id) + '"]').forEach(l => out.push(l.innerText));
    const w = e.closest('label'); if (w) out.push(w.innerText);
    return out.map(norm).filter(Boolean);
  };
  let all;
  try { all = [...document.querySelectorAll(MODE === 'sel' ? Q : EDIT)]; }
  catch (x) { return JSON.stringify({err: 'bad selector: ' + x.message}); }
  all = all.filter(e => vis(e) && e.matches(EDIT));
  let hits = all;
  if (MODE === 'label') {
    const want = norm(Q);
    const exact = all.filter(e => names(e).some(n => n === want));
    hits = exact.length ? exact : all.filter(e => names(e).some(n => n.includes(want)));
  }
  const desc = e => ({tag: e.tagName.toLowerCase(), id: e.id || '', label: (names(e)[0] || '').slice(0, 60)});
  if (hits.length === 0) return JSON.stringify({none: 1, fields: all.slice(0, 15).map(desc)});
  if (hits.length > 1) return JSON.stringify({many: hits.slice(0, 10).map(desc)});
  const e = hits[0];
  e.scrollIntoView({block: 'center'});
  e.focus();
  if (document.activeElement !== e) return JSON.stringify({nofocus: desc(e), active: document.activeElement && document.activeElement.tagName});
  if (e.isContentEditable) { document.execCommand('selectAll'); } else { e.select(); }
  window.__fillTarget = e;
  return JSON.stringify({ok: desc(e)});
})()"""

READBACK = r"""(() => { const e = window.__fillTarget; if (!e) return JSON.stringify({gone:1});
  const pw = (e.type||'').toLowerCase()==='password'||/password/i.test(e.getAttribute('autocomplete')||'');  // never emit password values
  return JSON.stringify({v: e.isContentEditable ? e.innerText : e.value, pw: pw, n: (e.value||'').length, focused: document.activeElement === e}); })()"""

async def call(ws, n, method, params):
    await ws.send(json.dumps({"id": n, "method": method, "params": params}))
    while True:
        m = json.loads(await asyncio.wait_for(ws.recv(), timeout=8))
        if m.get("id") == n: return m

async def main():
    none_msgs = []
    for t in pages:
        try:
            async with websockets.connect(t["webSocketDebuggerUrl"], max_size=4_000_000, open_timeout=5) as ws:
                ev = lambda n, x: call(ws, n, "Runtime.evaluate", {"expression": x, "returnByValue": True})
                r = json.loads((await ev(1, RESOLVE % (json.dumps(bool(t.get("oopif"))), json.dumps(mode), json.dumps(q))))["result"]["result"]["value"])
                if r.get("skip"): continue
                where = t.get("url", "")[:90]
                if r.get("err"): print(r["err"], file=sys.stderr); return 2
                if r.get("none"):
                    # Not here -- the field may be in another frame. Report only if no target has it.
                    none_msgs.append("no field matched %r on %s%s" % (q, where, " (iframe)" if t.get("oopif") else ""))
                    none_msgs += ["  field: %-9s %-32s %s" % (f["tag"], f["id"][:32], f["label"]) for f in r["fields"]]
                    continue
                if r.get("many"):
                    print("%d fields match %r -- refusing to guess. Be more specific (css selector, or a fuller label):" % (len(r["many"]), q), file=sys.stderr)
                    for f in r["many"]: print("  %-9s %-32s %s" % (f["tag"], f["id"][:32], f["label"]), file=sys.stderr)
                    return 4
                if r.get("nofocus"):
                    print("found %s but it would not take focus (active: %s)" % (r["nofocus"], r.get("active")), file=sys.stderr); return 5
                if text:
                    await call(ws, 2, "Input.insertText", {"text": text})
                else:
                    for i, typ in enumerate(("keyDown", "keyUp")):
                        await call(ws, 3 + i, "Input.dispatchKeyEvent", {"type": typ, "key": "Delete", "code": "Delete", "windowsVirtualKeyCode": 46})
                await asyncio.sleep(0.3)
                b = json.loads((await ev(9, READBACK))["result"]["result"]["value"])
                f = r["ok"]; label = f["label"] or f["id"] or f["tag"]
                if b.get("v") == text:
                    print("filled %s %r with %d chars -- verified%s" % (f["tag"], label, len(text), " (in iframe %s)" % where if t.get("oopif") else "")); return 0
                print("typed into %s %r but it now holds %r, not what was sent." % (f["tag"], label, ("[password, %d chars]" % b.get("n", 0)) if b.get("pw") else (b.get("v") or "")[:120]), file=sys.stderr)
                print("  (a field that reformats input -- phone, card, date -- can differ legitimately; read it and judge)", file=sys.stderr)
                return 5
        except Exception as e:
            print("page %s unreadable: %s" % (t.get("url", "")[:60], e), file=sys.stderr)
    if none_msgs:
        print("\n".join(none_msgs), file=sys.stderr); return 2
    print("no focused page to fill -- run: desktop.sh tabs / focus <n>", file=sys.stderr)
    return 3

sys.exit(asyncio.run(main()))
