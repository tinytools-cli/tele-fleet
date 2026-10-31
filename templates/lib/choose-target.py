# choose-target.py -- pick ONE element to act on, or refuse and say why.
#
# This is "candidate reduction before you ask anything" done deterministically. It runs on the
# host, reads resolve-elements.py's JSON on stdin, and prints the chosen element as JSON.
#
# TWO RULES, and both come from real failures:
#
# 1. PREFER THE INTERACTIVE ELEMENT WHEN BOXES TIE. `find --text "Privacy"` on a live page
#    returns <li>, <a> and <div> with the SAME bounding box -- the link and its wrappers. The
#    existing smallest-area sort is a coin toss between them and led with the <li>, which is not
#    clickable. Clicking a listitem's centre happens to work only because the link fills it.
#    Naming the <a> makes the log row true as well as the click.
#
# 2. REFUSE WHEN THE CANDIDATES ARE DIFFERENT THINGS. `activate "a"` on a page of twenty links
#    is not a request anyone can satisfy correctly; acting on the smallest is a guess dressed as
#    a decision. Distinct accessible names of comparable size => ambiguous => print them and
#    exit 4. Being told "which of these did you mean" costs one turn. Clicking the wrong control
#    on a live console costs considerably more, and once it opened reply drafts on real
#    customer mail.
#
# Exit 0 chose one · 4 ambiguous, candidates listed · 2 nothing usable.
import sys, json

INTERACTIVE = {"link", "button", "textbox", "searchbox", "checkbox", "radio", "combobox",
               "menuitem", "menuitemcheckbox", "menuitemradio", "tab", "option", "slider",
               "switch", "spinbutton"}

d = json.load(sys.stdin)
els = d.get("els") or []
if not els:
    print("no usable candidates", file=sys.stderr); sys.exit(2)

inter = [e for e in els if e.get("role") in INTERACTIVE]
pool = inter or els
pool.sort(key=lambda e: e["w"] * e["h"])
best = pool[0]
area = max(1, best["w"] * best["h"])

# Comparable size = within 3x the area of the smallest. A page-wide wrapper that merely
# CONTAINS the target is not a rival candidate; a sibling button right next to it is.
rivals, seen = [], set()
for e in pool:
    nm = (e.get("name") or "").strip().lower()
    if e["w"] * e["h"] > area * 3:
        continue
    if nm and nm not in seen:
        seen.add(nm); rivals.append(e)

if len(rivals) > 1:
    print("AMBIGUOUS: %d different controls match, of similar size." % len(rivals), file=sys.stderr)
    print("  Acting on any of them would be a guess. Say which one:", file=sys.stderr)
    for e in rivals[:10]:
        print("    %-10s %-40s  (%dx%d)" % (e.get("role"), (e.get("name") or "")[:40],
                                            e["w"], e["h"]), file=sys.stderr)
    print("  -> re-run with a precise selector, or --text with the exact label.", file=sys.stderr)
    sys.exit(4)

best["url"] = d.get("url") or ""
best["candidates"] = len(els)
best["interactive"] = len(inter)
print(json.dumps(best))
