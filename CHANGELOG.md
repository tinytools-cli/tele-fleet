# Changelog

## v0.3.0

**A desktop per agent, and two working-method skills.**

- **One desktop per agent, routed by name.** `desktop.sh` picks the desktop from the caller's
  `TIX_AGENT`: its own if `~/.fleet/desktops/<agent>/` exists, otherwise the name in
  `~/.fleet/desktops/.default`, otherwise it **refuses** rather than guessing. No script names
  anyone; adding a desktop is `DESKTOPS=...,<name>` and a re-run. `desktop-dropdown.sh` applies
  the same rule when run directly instead of falling back to a hardcoded container.
- **Wake on use and a memory cap.** A stopped desktop is started by the first command that needs
  it (`DESKTOP_WAKE=0` turns that off). Each container runs under `DESKTOP_MEM` (default 3g).
- **New: `desktop-mem-watch.sh`.** Run from cron; writes a warning that `desktop.sh` prints on
  every command when a desktop nears its cap, and records out-of-memory kills. Sends nothing
  anywhere.
- **Act by name, then verify.** New `goal`, `activate`, `fill`, `choose`, `dropdown`, `close-tab`
  and `fit` commands, backed by helpers in `lib/` (installed to `~/.fleet/bin/lib/`). Each one
  finds the element in the DOM, acts, and checks with the browser whether anything changed, and
  says plainly when nothing did, when more than one element matched, or when the page could not
  be read.
- **New: `desktop-report.py`.** Summarises what the desktops have been doing and failing at, from
  the usage log.
- **`desktop-tabsweep.py`:** a tab showing a signed-out or logged-out page is no longer treated
  as protected, so dead sessions get swept.
- **Browser launch falls back to `chromium`** when the image has no `chrome` wrapper. The
  previous installer never created one, so the debugging port never came up.
- **Installer:** writes `.default` from `DESKTOP_DEFAULT`, else `shared`, else the only desktop;
  with several per-agent desktops it writes none and says why.
- **New skills: `continuous-work`** (keep working unattended until a stated end point, with a
  heartbeat and watchers, then stop with a report) **and `autonomous-ticket-loop`** (work a tix
  backlog one verified unit at a time). Skills now install even when no desktop is requested;
  `agent-desktops` installs only when there is a desktop.
- **`agent-desktops` skill rewritten** for per-agent routing, wake on use, memory warnings and
  the new commands.
- **Scrub widened** to more personal names, company names and source-machine paths, and several
  personal references that slipped through earlier releases are removed.

## v0.2.0

**Desktop tooling brought up to date** — this is the release to take if you want the
virtual-desktop work.

- `desktop.sh` roughly doubles in size: tab listing and switching (`tabs`, `focus <n>`),
  per-desktop claims so two agents cannot interleave on one screen (`claim`, `release`,
  `claims`, `waiting`), `revive` for wedged renderers, an append-only usage log, reading
  inside same-origin iframes, and a refusal to emit click coordinates from a collapsed
  viewport.
- **Screen-coordinate fix.** The mapping added the window origin *unscaled* and then scaled
  the element rectangle. Identical at `devicePixelRatio == 1`, and wrong by the whole origin
  on any HiDPI display — where it presented as a Y-axis-only bug, because the X origin
  happens to be zero. Every click on such a screen was landing in the wrong place.
- **`read` and `find` no longer hang.** The reply loop had no timeout of any kind and held
  the shared desktop lock while it waited, so one slow page blocked every agent. Bounded now,
  with a message that says which page never answered.
- **New: `desktop-tabsweep.py` + `desktop-protected.conf`.** Closes idle and excess tabs, and
  will never close anything holding a login session. Skips claimed desktops entirely.
- **Routing is now by convention.** A desktop is chosen from the agent's own name, falling
  back to a shared one — no agent names are baked into the tool.
- **Scrub hardened.** It now also rejects agent names, source-fleet desktop names and private
  tracker keys. Verified by planting a leak and confirming it blocks; the first version of
  those patterns was over-escaped and passed the planted file silently.


All notable changes to tele-fleet are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

The installer predates this file — the commits from initial extraction through
the Telefleet rename are not reconstructed here. This is the first tagged
version.

## [0.1.0] - once

First tagged release. Fixes five silent fail-open bugs found auditing a real
install, all filed as GitHub issues and closed against this release:

- The `agent-desktops` skill hardcoded the author's own agent name as
  the infrastructure owner. Skill templates now go through the same `{{...}}`
  placeholder substitution `CLAUDE.md` gets, with a new `{{MAIN}}` token.
- `start-agent.sh` silently fell back to expiring interactive-login
  credentials when no long-lived Claude token was set up. It now warns on
  stderr and points at `claude setup-token`.
- `work-guard.sh`'s tix stop-hook adapter was never installed anywhere the
  guard actually looked (`TIX_DIR` vs. tix's real install path), so ticket
  enforcement was silently a no-op. The installer now fetches the adapter
  from upstream tix.
- `~/.fleet/tests/acceptance.sh` — the suite `CLAUDE.main.md` tells agents to
  run — was never installed by `06-start.sh`, so it never existed on a real
  install. Now installed alongside `installer/lib.sh`.
- `work-guard.sh`'s two fail-open exits were silent. Both now say why on
  stderr before exiting 0, so a missing dependency reads as a warning instead
  of being indistinguishable from a working install.

Also fixed two stale `tix-cli` → `tinytools-cli` references left from the
GitHub org rename.
