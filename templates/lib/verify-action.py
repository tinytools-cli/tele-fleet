# verify-action.py -- did the action do anything, according to the BROWSER.
#
# Extracted from an inline heredoc after a stray paren broke that heredoc
# and the command REPORTED A VERDICT ANYWAY: the verifier died with a SyntaxError, VERIFY came
# back empty, the case-statement default said "NOT CONFIRMED", and the execution record logged
# `outcome: nochange`. A check that could not run announced the absence of a change -- inside
# the feature whose stated purpose is to stop exactly that.
#
# Hence: its own file, with tests, and NO verdict is ever produced by falling through.
#
# Reads env: B_URL B_TITLE A (page-state json) A_RC GONE
# Prints one line: CHANGED|... · NOCHANGE|... · UNKNOWN|...
import os, sys, json


def verdict():
    if os.environ.get("A_RC") != "0" or not (os.environ.get("A") or "").strip():
        return ("UNKNOWN", "the click was sent, but the page could not be re-read afterwards")
    try:
        a = json.loads(os.environ["A"])
    except ValueError:
        return ("UNKNOWN", "the page returned something unreadable after the click")

    changes = []
    if a.get("url") != os.environ.get("B_URL", ""):
        changes.append("url -> %s" % (a.get("url") or "")[:70])
    if a.get("title") != os.environ.get("B_TITLE", ""):
        changes.append("title -> %r" % (a.get("title") or "")[:50])
    if a.get("ready") != "complete":
        changes.append("still loading (%s)" % a.get("ready"))

    # IN-PAGE RESPONSES. B is the full before-state; older callers do not pass it.
    try:
        b = json.loads(os.environ.get("B") or "{}")
    except ValueError:
        b = {}
    if "ov" in b and "ov" in a and a["ov"] != b["ov"]:
        changes.append("%s (overlays %s -> %s)" % ("a dialog/menu opened" if a["ov"] > b["ov"] else "a dialog/menu closed", b["ov"], a["ov"]))
    if "sel" in b and "sel" in a and a["sel"] != b["sel"]:
        changes.append("selection changed")
    if "exp" in b and "exp" in a and a["exp"] != b["exp"]:
        changes.append("a widget %s" % ("expanded" if a["exp"] > b["exp"] else "collapsed"))
    if "th" in b and "th" in a and a["th"] != b["th"]:
        changes.append("page text changed (%+d chars)" % (a.get("tl", 0) - b.get("tl", 0)))

    if "fx" in b and "fx" in a and a["fx"] != b["fx"]:
        changes.append("iframe content changed")
    gone = os.environ.get("GONE", "unchecked")
    if gone == "gone":
        changes.append("the target is no longer on the page")
    if changes:
        return ("CHANGED", "; ".join(changes))
    if gone == "present":
        return ("NOCHANGE", "url, title and the target are all unchanged -- "
                            "the click did nothing visible")
    return ("NOCHANGE", "url and title are unchanged, and the target could not be "
                        "re-checked -- the click may have done something in-page")


if __name__ == "__main__":
    try:
        k, msg = verdict()
    except Exception as e:
        # Never let a crash here become a verdict.
        k, msg = "UNKNOWN", "the verifier itself failed (%s)" % str(e)[:80]
    sys.stdout.write("%s|%s\n" % (k, msg))
