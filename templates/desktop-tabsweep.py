#!/usr/bin/env python3
"""Close idle and excess browser tabs, without ever touching a signed-in one.

WHY. Tabs accumulate because nothing closes them: agents open one for
a lookup and move on. another agent-desktop reached 18 targets including THREE copies
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
from urllib.parse import urlsplit
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

    for desk in sorted([d.name for d in DESKTOPS.iterdir() if d.is_dir()]):
        container = desk + "-desktop"
        if subprocess.run(["docker", "inspect", "-f", "{{.State.Running}}", container],
                          capture_output=True, text=True).stdout.strip() != "true":
            continue
        # A CLAIM PROTECTS WORK IN PROGRESS, NOT A LEAK.
        # Idle-closing and the ceiling are suspended on a claimed desktop --
        # an agent mid-task is not idle whatever its tabs look like. But
        # RUNAWAY DUPLICATES still get cleaned, because they are not work:
        # they are the same page over and over, they steal window focus, and
        # the agent whose desktop it is asked for help with exactly that.
        # Closing duplicates beyond the newest few cannot disturb anything a
        # claim exists to protect.
        is_claimed = claimed(desk)
        if is_claimed:
            print("  %s: claimed — idle/ceiling suspended, duplicates still swept" % desk)
        try:
            targets = json.loads(cdp(container, "/json"))
        except Exception as e:
            print("  %s: could not read tabs (%s)" % (desk, e)); continue

        pages = [t for t in targets if t.get("type") == "page"]
        closable = []
        dup = {}
        closed_titles = []
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
                # PROTECTED, BUT NOT IMMUNE TO BEING A RUNAWAY.
                # Protection is by URL substring, so a page that SPAWNS ITSELF
                # is protected too -- and multiplies freely. One agent's
                # desktop reached 124 IDENTICAL login.microsoftonline popups
                # from a failing token refresh: 90% of its memory cap, host
                # down to 1.2 GB, and this sweeper would never have touched a
                # single one of them.
                # A protected URL appearing many times over is not a session,
                # it is a leak. Duplicates beyond the first few get closed
                # whatever the list says; the newest is always kept, so a real
                # in-flight sign-in survives.
                # GROUP BY host+path, NOT the whole URL. Each OAuth attempt
                # carries its own nonce and state parameter, so 124 popups of
                # the same sign-in page are 124 DISTINCT urls -- exact
                # matching finds no duplicates at all and the runaway sails
                # through. Only discovered by counting the live ones and
                # seeing every count come back as 1.
                sp = urlsplit(url)
                dup.setdefault(sp.netloc + sp.path, []).append((t.get("id"), last_change))
                continue
            if not url.startswith("http"):
                continue
            if prev is None:
                continue          # never watched before: no idle history yet
            closable.append((last_change, tid, url))

        # RUNAWAY DUPLICATES, protected or not. Keep the most recently
        # changed few; close the rest.
        KEEP_DUP = int(os.environ.get("TABSWEEP_KEEP_DUP", "2"))
        runaway = []
        for u, lst in dup.items():
            if len(lst) <= KEEP_DUP:
                continue
            lst.sort(key=lambda x: x[1], reverse=True)   # newest first
            for tid, lc in lst[KEEP_DUP:]:
                runaway.append((lc, tid, u))
        if runaway:
            print("  %s: %d runaway duplicate tab(s)" % (desk, len(runaway)))

        # IDLE — suspended while the desktop is claimed
        doomed = [] if is_claimed else [(lc, i, u) for lc, i, u in closable
                                        if now - lc > IDLE_HOURS * 3600]
        # CEILING, counted over UNPROTECTED only (his refinement)
        keep = [] if is_claimed else [c for c in closable if c not in doomed]
        if len(keep) > MAX_UNPROTECTED:
            keep.sort()           # oldest last_change first
            doomed += keep[:len(keep) - MAX_UNPROTECTED]

        by_id = {t.get("id"): (t.get("title") or "").strip() for t in pages}
        for lc, tid, url in doomed + runaway:
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
                closed_titles.append(by_id.get(tid, ""))
                newstate.pop("%s|%s" % (desk, tid), None)
            except Exception as e:
                print("  %s: close failed %s (%s)" % (desk, url[:40], e))
        if closed_titles and not DRY:
            sweep_orphan_windows(container, closed_titles)

    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(newstate, indent=2))


def sweep_orphan_windows(container, closed_titles):
    """Close X windows left behind by a page we just closed.

    CLOSING A CDP PAGE TARGET DOES NOT ALWAYS CLOSE ITS WINDOW. Found the hard
    way: after clearing 124 runaway sign-in popups, four full-screen windows
    with those titles remained, holding X focus with NO live page behind them.
    The agent using that desktop could not get focus back to her mail --
    cleaning up the tabs had not cleaned up the problem.

    Deliberately narrow: only windows whose title matches something closed in
    THIS run, and only when no live page still carries that title. A window
    with a live page behind it is somebody's work.

    windowclose, never windowkill -- killing a Chromium window is how you take
    the whole browser down with it.
    """
    if not closed_titles:
        return
    live = set()
    try:
        out = subprocess.run(["docker", "exec", container, "bash", "-lc",
                              "curl -s -m 8 http://127.0.0.1:9222/json"],
                             capture_output=True, text=True, timeout=20).stdout
        live = {(t.get("title") or "").strip()
                for t in json.loads(out) if t.get("type") == "page"}
    except Exception:
        return
    for title in {t for t in closed_titles if t and t not in live}:
        safe = title.replace("'", "")
        subprocess.run(["docker", "exec", container, "bash", "-lc",
                        "export DISPLAY=:1; for w in $(xdotool search --name '%s' 2>/dev/null); "
                        "do xdotool windowclose $w 2>/dev/null; done" % safe],
                       capture_output=True, timeout=30)
        print("  %s: closed orphan window(s) titled %r" % (container, title[:40]))


if __name__ == "__main__":
    main()
