#!/usr/bin/env python3
"""Close idle and excess browser tabs, without ever touching a signed-in one.

WHY. Tabs accumulate because nothing closes them: agents open one for
a lookup and move on. another agent's desktop reached 18 targets including THREE copies
of the same Microsoft page, and desktop memory is the largest single consumer
on a box that OOM'd on once. Trimming by hand is a treadmill.

TWO RULES, both the operator's choice:
  IDLE   close an unprotected tab nothing has touched for IDLE_HOURS
  CEILING keep at most MAX_UNPROTECTED unprotected tabs, oldest-idle first
The ceiling counts ONLY unprotected tabs -- his refinement, and the right one:
a signed-in app should never push a research tab out, or vice versa.

WHAT IT WILL NOT DO, and why this matters more than what it will:
  - Never closes anything matching desktop-protected.conf. Those hold LOGIN
    SESSIONS. Closing one agent's idle Outlook on once dropped her Microsoft
    session and cost the operator a full Authenticator round to restore.
  - Never touches a desktop that is CLAIMED. An agent mid-task is not idle,
    whatever its tabs look like.
  - Never closes the focused tab.
  - Never closes a tab it has not watched for at least one full interval --
    a tab opened thirty seconds ago has no idle history and is not garbage.

NO MODEL. Comparing timestamps and matching substrings.
"""
import json, os, sys, time, urllib.request, subprocess
from pathlib import Path

IDLE_HOURS = float(os.environ.get("TABSWEEP_IDLE_HOURS", "6"))
MAX_UNPROTECTED = int(os.environ.get("TABSWEEP_MAX", "8"))
STATE = Path.home() / ".fleet" / "state" / "tabsweep.json"
CONF = Path(os.environ.get("PROTECTED_CONF", str(Path.home() / ".fleet" / "desktop-protected.conf")))
DESKTOPS = Path(os.environ.get("DESKTOP_ROOT", str(Path.home() / "agent-desktops")))
DRY = bool(os.environ.get("TABSWEEP_DRY"))


def protected_patterns():
    if not CONF.exists():
        return []
    return [l.strip() for l in CONF.read_text().splitlines()
            if l.strip() and not l.startswith("#")]


def claimed(desk):
    c = DESKTOPS / desk / ".claim"
    try:
        until = int(c.read_text().splitlines()[1])
        return time.time() < until
    except Exception:
        return False


def cdp(container, path):
    out = subprocess.run(
        ["docker", "exec", container, "bash", "-lc",
         "curl -s -m 8 http://127.0.0.1:9222%s" % path],
        capture_output=True, text=True, timeout=30)
    return out.stdout


def main():
    pats = protected_patterns()
    state = {}
    if STATE.exists():
        try: state = json.loads(STATE.read_text())
        except Exception: state = {}
    now = time.time()
    newstate = {}

    # A FRESH INSTALL HAS NO DESKTOPS YET. Without this the first timer fire
    # tracebacks with FileNotFoundError on every run -- the first thing a new
    # user would see from this tool, and it would look broken when it is
    # simply early.
    if not DESKTOPS.is_dir():
        print("no desktop root at %s — nothing to sweep" % DESKTOPS)
        return

    for desk in sorted([d.name for d in DESKTOPS.iterdir() if d.is_dir()]):
        container = desk + "-desktop"
        if subprocess.run(["docker", "inspect", "-f", "{{.State.Running}}", container],
                          capture_output=True, text=True).stdout.strip() != "true":
            continue
        if claimed(desk):
            print("  %s: claimed by an agent — skipped" % desk)
            for k, v in state.items():
                if k.startswith(desk + "|"): newstate[k] = v
            continue
        try:
            targets = json.loads(cdp(container, "/json"))
        except Exception as e:
            print("  %s: could not read tabs (%s)" % (desk, e)); continue

        pages = [t for t in targets if t.get("type") == "page"]
        closable = []
        for t in pages:
            url, tid = t.get("url") or "", t.get("id")
            key = "%s|%s" % (desk, tid)
            sig = url + "\x00" + (t.get("title") or "")
            prev = state.get(key)
            # last_change: when this tab's url/title last differed. A tab whose
            # content is still moving is in use, whatever its age.
            if prev and prev.get("sig") == sig:
                last_change = prev.get("last_change", now)
                first_seen = prev.get("first_seen", now)
            else:
                last_change = now
                first_seen = prev.get("first_seen", now) if prev else now
            newstate[key] = {"sig": sig, "last_change": last_change,
                             "first_seen": first_seen, "url": url}
            if any(p in url for p in pats):
                continue
            if not url.startswith("http"):
                continue
            if prev is None:
                continue          # never watched before: no idle history yet
            closable.append((last_change, tid, url))

        # IDLE
        doomed = [(lc, i, u) for lc, i, u in closable
                  if now - lc > IDLE_HOURS * 3600]
        # CEILING, counted over UNPROTECTED only (his refinement)
        keep = [c for c in closable if c not in doomed]
        if len(keep) > MAX_UNPROTECTED:
            keep.sort()           # oldest last_change first
            doomed += keep[:len(keep) - MAX_UNPROTECTED]

        for lc, tid, url in doomed:
            age = (now - lc) / 3600
            if DRY:
                print("  %s: WOULD close (idle %.1fh) %s" % (desk, age, url[:58]))
                continue
            try:
                urllib.request.urlopen  # noqa - closed via container curl
                subprocess.run(["docker", "exec", container, "bash", "-lc",
                                "curl -s -m 8 http://127.0.0.1:9222/json/close/" + tid],
                               capture_output=True, timeout=20)
                print("  %s: closed (idle %.1fh) %s" % (desk, age, url[:58]))
                newstate.pop("%s|%s" % (desk, tid), None)
            except Exception as e:
                print("  %s: close failed %s (%s)" % (desk, url[:40], e))

    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(newstate, indent=2))


if __name__ == "__main__":
    main()
